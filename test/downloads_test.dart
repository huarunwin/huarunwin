import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/models.dart';
import 'package:huarunwin/services/downloads.dart';

class PackageAdapter implements HttpClientAdapter {
  PackageAdapter(this.response);
  final ResponseBody Function() response;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => response();
  @override
  void close({bool force = false}) {}
}

Future<void> finished(DownloadManager manager, DownloadTask task) async {
  if (task.busy) {
    final done = Completer<void>();
    void listener() {
      if (!task.busy && !done.isCompleted) done.complete();
    }

    manager.addListener(listener);
    try {
      await done.future.timeout(const Duration(seconds: 5));
    } finally {
      manager.removeListener(listener);
    }
  }
  await manager.flushHistory();
}

void main() {
  const app = CatalogApp(
    id: 'test',
    name: 'Test',
    url: 'https://huarun.win/apps/test',
  );
  const link = DownloadLink(
    url: 'https://example.com/Test.dmg',
    label: 'Test',
    platform: 'macOS',
    kind: 'dmg',
  );
  late Directory directory;
  late Dio client;
  late DownloadManager manager;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('huarun-download-test');
    client = Dio();
    manager = DownloadManager(directory, client: client);
  });
  tearDown(() async {
    await manager.flushHistory();
    manager.dispose();
    client.close(force: true);
    await directory.delete(recursive: true);
  });

  test(
    'restore and removal accept canonical paths under a managed directory alias',
    () async {
      final alias = Link('${directory.path}-alias');
      await alias.create(directory.path);
      final folder = await Directory('${directory.path}/fixture').create();
      final package = await File('${folder.path}/fixture.apk')
          .writeAsBytes([1]);
      final task = DownloadTask(
        id: 'canonical',
        appName: 'Fixture',
        url: '',
        filePath: await package.resolveSymbolicLinks(),
        kind: 'apk',
        platform: 'Android',
        createdAt: DateTime.now(),
        state: DownloadState.downloaded,
      );
      await File('${directory.path}/tasks.json')
          .writeAsString(jsonEncode([task.toJson()]));
      final restored = DownloadManager(Directory(alias.path));
      try {
        await restored.restore();
        expect(restored.tasks.single.filePath, task.filePath);
        expect(restored.tasks.single.state, DownloadState.downloaded);
        await restored.remove(restored.tasks.single);
        expect(restored.tasks, isEmpty);
        expect(await folder.exists(), isFalse);
        expect(await directory.exists(), isTrue);
        expect(await alias.exists(), isTrue);
      } finally {
        await restored.flushHistory();
        restored.dispose();
        restored.client.close(force: true);
        restored.macResolver.client.close(force: true);
        await alias.delete();
      }
    },
    skip: Platform.isWindows
        ? 'Creating symbolic links needs Windows privileges.'
        : false,
  );

  test(
    'only completed bytes become a package and history survives restart',
    () async {
      client.httpClientAdapter = PackageAdapter(
        () => ResponseBody.fromBytes(
          [1, 2, 3, 4],
          200,
          headers: {
            'content-type': ['application/octet-stream'],
            'content-length': ['4'],
          },
        ),
      );
      final task = await manager.download(app, link);
      await finished(manager, task);
      expect(task.state, DownloadState.downloaded);
      expect(await File(task.filePath).readAsBytes(), [1, 2, 3, 4]);
      expect(await File('${task.filePath}.part').exists(), isFalse);
      final restored = DownloadManager(directory);
      await restored.restore();
      expect(restored.tasks.single.state, DownloadState.downloaded);
      expect(restored.tasks.single.filePath, task.filePath);
      restored.client.close();
      restored.dispose();
    },
  );

  test(
    'a malformed history item does not prevent later downloads from restoring',
    () async {
      final first = DownloadTask(
        id: 'first',
        appName: 'First',
        url: link.url,
        filePath: '${directory.path}/First.dmg',
        kind: 'dmg',
        createdAt: DateTime.now(),
        state: DownloadState.downloaded,
      );
      final second = DownloadTask(
        id: 'second',
        appName: 'Second',
        url: link.url,
        filePath: '${directory.path}/Second.dmg',
        kind: 'dmg',
        createdAt: DateTime.now(),
        state: DownloadState.downloaded,
      );
      final original = jsonEncode([
        first.toJson(),
        {'id': 'broken'},
        second.toJson(),
      ]);
      await File('${directory.path}/tasks.json').writeAsString(original);

      await Future.wait([manager.restore(), manager.restore()]);
      await manager.flushHistory();
      await manager.restore();

      expect(manager.tasks.map((task) => task.id), ['first', 'second']);
      final backups = await Directory('${directory.path}/history-recovery')
          .list(recursive: true)
          .where((entry) => entry is File)
          .cast<File>()
          .toList();
      expect(backups, hasLength(1));
      expect(await backups.single.readAsString(), original);
      expect(manager.historyWarning, contains('备份'));
    },
  );

  test(
    'failed recovery backup protects history until refresh can save it',
    () async {
      final index = File('${directory.path}/tasks.json');
      const original = '[{"id":"broken"}]';
      await index.writeAsString(original);
      final blocker = await File('${directory.path}/history-recovery')
          .writeAsString('blocked');
      await manager.restore();
      await manager.flushHistory();
      final source = await File('${directory.path}/import.dmg')
          .writeAsBytes([1, 2, 3]);
      await manager.importFile(source, platform: 'macOS');
      await manager.flushHistory();

      expect(await index.readAsString(), original);
      expect(manager.historyWarning, contains('暂停保存'));

      await blocker.delete();
      await manager.refresh();
      await manager.flushHistory();
      final backups = await Directory('${directory.path}/history-recovery')
          .list(recursive: true)
          .where((entry) => entry is File)
          .cast<File>()
          .toList();
      expect(await backups.single.readAsString(), original);
      expect(
        (jsonDecode(await index.readAsString()) as List).single['id'],
        manager.tasks.single.id,
      );
      expect(manager.historyWarning, isNot(contains('暂停保存')));
    },
  );

  test(
    'unreadable history is retried without dropping new or old tasks',
    () async {
      final indexPath = '${directory.path}/tasks.json';
      await Directory(indexPath).create();
      await manager.restore();
      final source = await File('${directory.path}/import.dmg')
          .writeAsBytes([1]);
      await manager.importFile(source, platform: 'macOS');
      await manager.flushHistory();
      expect(await Directory(indexPath).exists(), isTrue);
      expect(manager.historyWarning, contains('无法读取'));

      await Directory(indexPath).delete();
      final old = DownloadTask(
        id: 'old',
        appName: 'Old',
        url: link.url,
        filePath: source.path,
        kind: 'dmg',
        createdAt: DateTime.now(),
        state: DownloadState.downloaded,
      );
      await File(indexPath).writeAsString(jsonEncode([old.toJson()]));
      await manager.refresh();
      await manager.flushHistory();

      expect(manager.tasks, hasLength(2));
      expect(manager.tasks.any((task) => task.id == 'old'), isTrue);
      expect(jsonDecode(await File(indexPath).readAsString()), hasLength(2));
      expect(manager.historyWarning, isNull);
    },
  );

  test('each corrupt history keeps an independent exact byte backup', () async {
    final index = File('${directory.path}/tasks.json');
    final first = [0xff, 0xfe, 0x00];
    final second = utf8.encode('[{"unfinished":');
    await index.writeAsBytes(first);
    await manager.restore();
    await manager.flushHistory();
    await index.writeAsBytes(second);
    final restored = DownloadManager(directory);
    try {
      await restored.restore();
      await restored.flushHistory();
      final backups = await Directory('${directory.path}/history-recovery')
          .list(recursive: true)
          .where((entry) => entry is File)
          .cast<File>()
          .toList();
      final bytes = await Future.wait(
        backups.map((file) => file.readAsBytes()),
      );
      expect(bytes, unorderedEquals([first, second]));
      expect(jsonDecode(await index.readAsString()), isEmpty);
    } finally {
      restored.dispose();
      restored.client.close(force: true);
      restored.macResolver.client.close(force: true);
    }
  });

  test(
    'file inspection errors keep valid records available for retry',
    () async {
      final package = Link('${directory.path}/unreadable.dmg');
      await package.create(package.path);
      final task = DownloadTask(
        id: 'unreadable',
        appName: 'Unreadable',
        url: link.url,
        filePath: package.path,
        kind: 'dmg',
        createdAt: DateTime.now(),
        state: DownloadState.downloaded,
      );
      await File('${directory.path}/tasks.json')
          .writeAsString(jsonEncode([task.toJson()]));
      await manager.restore();
      await manager.flushHistory();

      expect(manager.tasks.single.id, task.id);
      expect(manager.tasks.single.state, DownloadState.downloaded);
      expect(manager.historyWarning, contains('暂时无法检查'));
      expect(
        await Directory('${directory.path}/history-recovery').exists(),
        isFalse,
      );

      await package.delete();
      await File(package.path).writeAsBytes([1]);
      await manager.refresh();
      expect(manager.tasks.single.packageAvailable, isTrue);
      expect(manager.historyWarning, isNull);
    },
    skip: Platform.isWindows
        ? 'Creating symbolic links needs Windows privileges.'
        : false,
  );

  test(
    'a republished resource with a new public digest does not reuse old bytes',
    () async {
      const url =
          'https://github.com/owner/repo/releases/download/nightly/file.zip';
      DownloadLink resource(List<int> bytes) => DownloadLink(
        url: url,
        label: 'file.zip',
        kind: 'resource',
        version: 'nightly',
        sha256: sha256.convert(bytes).toString(),
      );
      client.httpClientAdapter = PackageAdapter(
        () => ResponseBody.fromBytes([1], 200),
      );
      final original = await manager.download(app, resource([1]));
      await finished(manager, original);
      client.httpClientAdapter = PackageAdapter(
        () => ResponseBody.fromBytes([2], 200),
      );
      final republished = await manager.download(app, resource([2]));
      await finished(manager, republished);
      expect(manager.tasks, hasLength(2));
      expect(republished, isNot(same(original)));
      expect(await File(original.filePath).readAsBytes(), [1]);
      expect(await File(republished.filePath).readAsBytes(), [2]);
      expect(republished.checksumVerified, isTrue);
    },
  );

  test('HTML download responses and incomplete files are rejected', () async {
    client.httpClientAdapter = PackageAdapter(
      () => ResponseBody.fromString(
        '<html>login</html>',
        200,
        headers: {
          'content-type': ['text/html'],
        },
      ),
    );
    final task = await manager.download(app, link);
    await finished(manager, task);
    expect(task.state, DownloadState.failed);
    expect(await File(task.filePath).exists(), isFalse);
    client.httpClientAdapter = PackageAdapter(
      () => ResponseBody.fromBytes(
        [1, 2],
        200,
        headers: {
          'content-length': ['10'],
        },
      ),
    );
    await manager.retry(task);
    expect(task.state, DownloadState.failed);
    expect(task.error, contains('不完整'));
    expect(await File('${task.filePath}.part').exists(), isFalse);
  });

  test('ordinary release resources keep version history and never offer installation', () async {
    client.httpClientAdapter = PackageAdapter(
      () => ResponseBody.fromString(
        '{"version":"v1"}',
        200,
        headers: {
          'content-type': ['application/json'],
        },
      ),
    );
    const resource = DownloadLink(
      url: 'https://github.com/owner/repo/releases/download/v1/metadata.json',
      label: 'metadata.json',
      kind: 'resource',
      version: 'v1',
      releaseUrl: 'https://github.com/owner/repo/releases/tag/v1',
    );
    final task = await manager.download(app, resource);
    await finished(manager, task);
    expect(task.state, DownloadState.downloaded);
    expect(await File(task.filePath).readAsString(), '{"version":"v1"}');
    expect(task.canHandOff, isFalse);
    for (final platform in ['macOS', 'Android', 'Windows', 'Linux']) {
      expect(task.canInstallOn(platform), isFalse);
    }
    await manager.install(task);
    await manager.handOff(task);
    expect(task.state, DownloadState.downloaded);
    final restored = DownloadManager(directory);
    await restored.restore();
    expect(restored.tasks.single.version, 'v1');
    expect(restored.tasks.single.releaseUrl, resource.releaseUrl);
    expect(restored.tasks.single.kind, 'resource');
    restored.client.close(force: true);
    restored.macResolver.client.close(force: true);
    restored.dispose();
    final legacy = task.toJson()
      ..remove('version')
      ..remove('releaseUrl');
    expect(DownloadTask.fromJson(legacy).version, isNull);
    expect(DownloadTask.fromJson(legacy).releaseUrl, isNull);
  });

  test('cancel without a validator discards partial files and retry starts from zero', () async {
    final subscribed = Completer<void>();
    final chunks = StreamController<Uint8List>(onListen: subscribed.complete);
    client.httpClientAdapter = PackageAdapter(
      () => ResponseBody(chunks.stream, 200),
    );
    final task = await manager.download(app, link);
    await subscribed.future.timeout(const Duration(seconds: 5));
    chunks.add(Uint8List.fromList([1, 2]));
    manager.cancel(task);
    await chunks.close();
    await finished(manager, task);
    expect(task.state, DownloadState.cancelled);
    expect(await File(task.filePath).exists(), isFalse);
    expect(await File('${task.filePath}.part').exists(), isFalse);
    client.httpClientAdapter = PackageAdapter(
      () => ResponseBody.fromBytes([3, 4, 5], 200),
    );
    await manager.retry(task);
    expect(task.state, DownloadState.downloaded);
    expect(task.received, 3);
    expect(await File(task.filePath).readAsBytes(), [3, 4, 5]);
  });

  test(
    'restart marks interrupted work and missing files instead of success',
    () async {
      final interrupted = DownloadTask(
        id: '1',
        appName: 'Test',
        url: link.url,
        filePath: '${directory.path}/Test.dmg',
        kind: 'dmg',
        createdAt: DateTime.now(),
        state: DownloadState.installing,
      );
      final missing = DownloadTask(
        id: '2',
        appName: 'Missing',
        url: link.url,
        filePath: '${directory.path}/Missing.dmg',
        kind: 'dmg',
        createdAt: DateTime.now(),
        state: DownloadState.downloaded,
      );
      await File('${directory.path}/tasks.json')
          .writeAsString(jsonEncode([interrupted.toJson(), missing.toJson()]));
      await manager.restore();
      expect(manager.tasks[0].state, DownloadState.cancelled);
      expect(manager.tasks[1].state, DownloadState.failed);
      expect(manager.tasks.every((t) => t.error != null), isTrue);
    },
  );
  test(
    'delete cancels an active download before removing files and history',
    () async {
      final subscribed = Completer<void>();
      final chunks = StreamController<Uint8List>(onListen: subscribed.complete);
      client.httpClientAdapter = PackageAdapter(
        () => ResponseBody(chunks.stream, 200),
      );
      final task = await manager.download(app, link);
      await subscribed.future.timeout(const Duration(seconds: 5));
      chunks.add(Uint8List.fromList([1, 2]));
      final removing = manager.remove(task);
      await chunks.close();
      await removing;
      expect(manager.tasks, isEmpty);
      expect(await File(task.filePath).exists(), isFalse);
      expect(await File('${task.filePath}.part').exists(), isFalse);
      expect(
        jsonDecode(await File('${directory.path}/tasks.json').readAsString()),
        isEmpty,
      );
    },
  );

  test(
    'delete removes a completed package, preserving the installed application',
    () async {
      client.httpClientAdapter = PackageAdapter(
        () => ResponseBody.fromBytes([1, 2], 200),
      );
      final task = await manager.download(app, link);
      await finished(manager, task);
      final installed = await File('${directory.path}/Installed.app')
          .writeAsString('installed fixture');
      task.state = DownloadState.installed;
      task.installedPath = installed.path;
      await manager.remove(task);
      expect(await File(task.filePath).exists(), isFalse);
      expect(await installed.readAsString(), 'installed fixture');
      expect(manager.tasks, isEmpty);
    },
  );

  test('installation in progress cannot be deleted', () async {
    final task = DownloadTask(
      id: 'active',
      appName: 'Test',
      url: link.url,
      filePath: '${directory.path}/Test.dmg',
      kind: 'dmg',
      createdAt: DateTime.now(),
      state: DownloadState.installing,
    );
    manager.tasks.add(task);
    await expectLater(manager.remove(task), throwsStateError);
    expect(manager.tasks, contains(task));
  });
  test(
    'delete refuses a download folder redirected outside managed storage',
    () async {
      final outside = await Directory.systemTemp.createTemp(
        'huarun-delete-guard',
      );
      addTearDown(() => outside.delete(recursive: true));
      final file = await File('${outside.path}/Keep.dmg').writeAsString('keep');
      await Link('${directory.path}/redirect').create(outside.path);
      final task = DownloadTask(
        id: 'redirect',
        appName: 'Test',
        url: link.url,
        filePath: '${directory.path}/redirect/Keep.dmg',
        kind: 'dmg',
        createdAt: DateTime.now(),
        state: DownloadState.downloaded,
      );
      manager.tasks.add(task);
      await expectLater(
        manager.remove(task),
        throwsA(isA<FileSystemException>()),
      );
      expect(await file.readAsString(), 'keep');
      expect(manager.tasks, contains(task));
    },
    skip: Platform.isWindows
        ? 'Creating symbolic links needs Windows privileges.'
        : false,
  );
}
