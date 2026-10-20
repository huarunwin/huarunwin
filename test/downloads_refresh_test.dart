import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/services/downloads.dart';

class PendingInstaller extends NativeInstaller {
  final result = Completer<String>();

  @override
  Future<String> install(
    String package, {
    required bool removeQuarantine,
    bool authorize = false,
    Map<String, String>? quitApplication,
    Map<String, String>? signerApproval,
    void Function(Map<String, String>)? onProgress,
  }) => result.future;
}

void main() {
  late Directory directory;
  late DownloadManager manager;
  late PendingInstaller installer;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('huarun-refresh-test');
    installer = PendingInstaller();
    manager = DownloadManager(directory, installer: installer);
  });

  tearDown(() async {
    await manager.flushHistory();
    manager.dispose();
    manager.client.close(force: true);
    manager.macResolver.client.close(force: true);
    await directory.delete(recursive: true);
  });

  DownloadTask task(
    String id, {
    DownloadState state = DownloadState.downloaded,
  }) {
    final task = DownloadTask(
      id: id,
      appName: 'Fixture $id',
      url: 'https://example.com/$id.zip',
      filePath: '${directory.path}/$id/package.zip',
      kind: 'zip',
      platform: 'macOS',
      createdAt: DateTime.now(),
      received: 4,
      total: 4,
      state: state,
    );
    manager.tasks.add(task);
    return task;
  }

  Future<void> package(DownloadTask task) async {
    await File(task.filePath).parent.create(recursive: true);
    await File(task.filePath).writeAsBytes([1, 2, 3, 4]);
  }

  Future<Directory> installedApp(DownloadTask task) async {
    final app = await Directory('${directory.path}/${task.id}.app').create();
    task.installedPath = app.path;
    return app;
  }

  test(
    'missing packages are persisted and can recover after being restored',
    () async {
      final missing = task('missing');
      final existing = task('existing');
      await package(existing);
      await manager.refresh();
      expect(missing.state, DownloadState.failed);
      expect(missing.packageAvailable, isFalse);
      expect(missing.error, contains('移动或删除'));
      expect(existing.state, DownloadState.downloaded);
      expect(manager.tasks, hasLength(2));
      await manager.flushHistory();
      final saved = jsonDecode(
        await File('${directory.path}/tasks.json').readAsString(),
      ) as List;
      final restored = DownloadTask.fromJson(
        Map<String, dynamic>.from(saved.first as Map),
      );
      expect(restored.packageAvailable, isFalse);
      final legacy = missing.toJson()..remove('packageAvailable');
      expect(DownloadTask.fromJson(legacy).packageAvailable, isFalse);

      await package(missing);
      await manager.refresh();
      expect(missing.state, DownloadState.downloaded);
      expect(missing.packageAvailable, isTrue);
      expect(missing.error, isNull);
      expect(manager.tasks, hasLength(2));
    },
  );

  test('removed installed app falls back to its available package', () async {
    final removed = task('removed', state: DownloadState.installed);
    await package(removed);
    final app = await installedApp(removed);
    await app.delete();
    await manager.refresh();
    expect(removed.state, DownloadState.downloaded);
    expect(removed.installedPath, isNull);
    expect(removed.packageAvailable, isTrue);
    expect(removed.canInstall, Platform.isMacOS);
    expect(removed.error, contains('重新安装'));
    expect(await File(removed.filePath).readAsBytes(), [1, 2, 3, 4]);
  });

  test(
    'installed app stays usable without its package; both missing fails',
    () async {
      final installed = task('installed', state: DownloadState.installed);
      final app = await installedApp(installed);
      final missing = task('both-missing', state: DownloadState.installed);
      missing.installedPath = '${directory.path}/Missing.app';
      await manager.refresh();
      expect(installed.state, DownloadState.installed);
      expect(installed.installedPath, app.path);
      expect(installed.packageAvailable, isFalse);
      expect(await app.exists(), isTrue);
      expect(missing.state, DownloadState.failed);
      expect(missing.installedPath, isNull);
      expect(missing.packageAvailable, isFalse);
      expect(missing.error, contains('重新下载或导入'));
    },
  );

  test(
    'overlapping refreshes share a request and never duplicate records',
    () async {
      task('missing');
      var notifications = 0;
      manager.addListener(() => notifications++);
      final first = manager.refresh();
      final second = manager.refresh();
      expect(identical(first, second), isTrue);
      expect(manager.refreshing, isTrue);
      await Future.wait([first, second]);
      expect(manager.refreshing, isFalse);
      expect(manager.tasks, hasLength(1));
      expect(notifications, 3); // Start, changed records, finish.
    },
  );

  test(
    'refresh leaves active, deleting and failed downloads unchanged',
    () async {
      final protected = [
        for (final state in [
          DownloadState.queued,
          DownloadState.downloading,
          DownloadState.installing,
          DownloadState.cancelled,
          DownloadState.failed,
        ])
          task(state.name, state: state),
        task('deleting')..deleting = true,
      ];
      final before = protected.map((task) => task.toJson()).toList();
      await manager.refresh();
      expect(protected.map((task) => task.toJson()).toList(), before);
      expect(manager.tasks, hasLength(protected.length));
    },
  );

  test('refresh does not overwrite a new installation', () async {
    final installing = task('install-race');
    await package(installing);
    final refreshing = manager.refresh();
    final installation = manager.install(installing);
    installer.result.complete('${directory.path}/New.app');
    await Future.wait([refreshing, installation]);
    expect(installing.state, DownloadState.installed);
    expect(installing.installedPath, '${directory.path}/New.app');
    expect(installing.error, isNull);
  }, skip: !Platform.isMacOS);

  test('refresh cannot resurrect a deleted task', () async {
    final removed = task('delete-race');
    await package(removed);
    final refreshing = manager.refresh();
    final removing = manager.remove(removed);
    await Future.wait([refreshing, removing]);
    expect(manager.tasks, isEmpty);
    expect(await File(removed.filePath).exists(), isFalse);
    await manager.flushHistory();
    expect(
      jsonDecode(await File('${directory.path}/tasks.json').readAsString()),
      isEmpty,
    );
  });

  test(
    'an unreadable path retains its record and allows a later retry',
    () async {
      final failedCheck = task('io-failure');
      await File(failedCheck.filePath).parent.create(recursive: true);
      await Link(failedCheck.filePath).create(failedCheck.filePath);
      final missing = task('missing');
      final before = failedCheck.toJson();
      await expectLater(manager.refresh(), throwsA(isA<FileSystemException>()));
      expect(manager.refreshing, isFalse);
      expect(failedCheck.toJson(), before);
      expect(missing.state, DownloadState.failed);
      await Link(failedCheck.filePath).delete();
      await package(failedCheck);
      await manager.refresh();
      expect(failedCheck.state, DownloadState.downloaded);
      expect(failedCheck.packageAvailable, isTrue);
    },
    skip: Platform.isWindows,
  );
}
