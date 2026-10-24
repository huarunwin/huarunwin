import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/models.dart';
import 'package:huarunwin/services/download_locations.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

class _PackageAdapter implements HttpClientAdapter {
  int status = 500;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromBytes([1, 2, 3], status);

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory sandbox;
  late Directory legacy;
  late Directory defaults;
  late SharedPreferences preferences;
  final locations = <DownloadLocations>[];
  final managers = <DownloadManager>[];

  Future<DownloadLocations> load({
    List<DownloadDirectoryOption>? options,
  }) async {
    final result = await DownloadLocations.load(
      preferences: preferences,
      legacyDirectory: legacy,
      defaultDirectory: defaults,
      directoryOptions: options,
    );
    locations.add(result);
    return result;
  }

  DownloadManager manager(DownloadLocations location) {
    final result = DownloadManager(legacy, locations: location);
    managers.add(result);
    return result;
  }

  Future<void> finish(DownloadManager downloads, DownloadTask task) async {
    while (task.busy) {
      final done = Completer<void>();
      void listener() {
        if (!task.busy && !done.isCompleted) done.complete();
      }

      downloads.addListener(listener);
      try {
        if (task.busy) await done.future.timeout(const Duration(seconds: 5));
      } finally {
        downloads.removeListener(listener);
      }
    }
    await downloads.flushHistory();
  }

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('huarun-locations-');
    legacy = Directory(p.join(sandbox.path, 'support', 'downloads'));
    defaults = Directory(
      p.join(sandbox.path, 'Downloads', 'HuaRunWin Downloads'),
    );
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
  });

  tearDown(() async {
    for (final downloads in managers) {
      await downloads.flushHistory();
      downloads.dispose();
      downloads.client.close(force: true);
      downloads.macResolver.client.close(force: true);
    }
    managers.clear();
    for (final location in locations) {
      location.dispose();
    }
    locations.clear();
    await sandbox.delete(recursive: true);
  });

  test(
    'fresh installations use system Downloads without eagerly creating it',
    () async {
      final location = await load();
      expect(location.directory.path, defaults.path);
      expect(await defaults.exists(), isFalse);
      expect(
        (await location.prepareDirectory()).path,
        await defaults.resolveSymbolicLinks(),
      );
      expect(await legacy.exists(), isFalse);
    },
  );

  test('existing installations retain the legacy download directory', () async {
    await legacy.create(recursive: true);
    final location = await load();
    expect(location.directory.path, legacy.path);
    expect(await defaults.exists(), isFalse);
  });

  test('Android uses the first writable external directory', () async {
    final preferred = Directory(p.join(sandbox.path, 'external', 'Download'));
    final fallback = Directory(p.join(sandbox.path, 'external', 'downloads'));
    expect(
      (await DownloadLocations.firstWritableDirectory([preferred, fallback]))
          ?.path,
      preferred.path,
    );
    expect(await preferred.list().isEmpty, isTrue);
    expect(await fallback.exists(), isFalse);
  });

  test('unusable external directories allow the next location', () async {
    final blocked = await File(p.join(sandbox.path, 'blocked'))
        .writeAsString('keep');
    final fallback = Directory(p.join(sandbox.path, 'external', 'downloads'));
    expect(
      (await DownloadLocations.firstWritableDirectory([
        Directory(blocked.path),
        fallback,
      ]))?.path,
      fallback.path,
    );
    expect(
      await DownloadLocations.firstWritableDirectory([Directory(blocked.path)]),
      isNull,
    );
    expect(await blocked.readAsString(), 'keep');
  });

  test(
    'selection and reset survive reload and retain historical roots',
    () async {
      final location = await load();
      final selected = p.join(sandbox.path, '自选目录 & spaces');
      await location.selectDirectory(selected);
      expect(await Directory(selected).list().isEmpty, isTrue);
      final reloaded = await load();
      expect(reloaded.directory.path, selected);
      await reloaded.resetDirectory();
      final reset = await load();
      expect(reset.directory.path, defaults.path);
      expect(
        reset.managedRoot(p.join(selected, 'task', 'file.exe'))?.path,
        selected,
      );
      expect(
        reset.managedRoot(p.join(sandbox.path, 'outside', 'file.exe')),
        isNull,
      );
    },
  );

  test(
    'failed selection leaves preferences unchanged and allows retry',
    () async {
      final location = await load();
      final previous = preferences.getStringList('downloadDirectories');
      var changes = 0;
      location.addListener(() => changes++);
      await expectLater(
        location.selectDirectory('relative'),
        throwsA(isA<FileSystemException>()),
      );
      final collision = await File(p.join(sandbox.path, 'file'))
          .writeAsString('keep');
      await expectLater(
        location.selectDirectory(collision.path),
        throwsA(isA<FileSystemException>()),
      );
      expect(location.directory.path, defaults.path);
      expect(preferences.getStringList('downloadDirectories'), previous);
      expect(changes, 0);
      expect(await collision.readAsString(), 'keep');
      await location.selectDirectory(p.join(sandbox.path, 'valid'));
      expect(changes, 1);
    },
  );

  test('desktop preferences migrate without moving existing files', () async {
    final oldRoot = p.join(sandbox.path, 'Downloads', 'huarunwin');
    await preferences.setStringList('desktopDownloadDirectories', [oldRoot]);
    final location = await load();
    expect(location.directory.path, oldRoot);
    expect(preferences.getStringList('downloadDirectories')!.first, oldRoot);
    await location.resetDirectory();
    final reloaded = await load();
    expect(reloaded.directory.path, defaults.path);
    expect(
      reloaded.managedRoot(p.join(oldRoot, 'task', 'file.apk'))?.path,
      oldRoot,
    );
  });

  test('Android selection accepts only app-owned storage locations', () async {
    final external = Directory(p.join(sandbox.path, 'external', 'downloads'));
    final options = [
      DownloadDirectoryOption('应用内部存储', defaults),
      DownloadDirectoryOption('应用专用外部存储', external),
    ];
    final location = await load(options: options);
    final outside = p.join(sandbox.path, 'shared');
    await expectLater(
      location.selectDirectory(outside),
      throwsA(isA<FileSystemException>()),
    );
    expect(await Directory(outside).exists(), isFalse);
    await location.selectDirectory(external.path);
    expect((await load(options: options)).directory.path, external.path);
    await location.resetDirectory();
    expect(location.directory.path, defaults.path);
  });

  test(
    'incoming APK follows the selected root after durable adoption',
    () async {
      await legacy.create(recursive: true);
      final location = await load();
      final external = p.join(sandbox.path, 'external', 'downloads');
      await location.selectDirectory(external);
      final downloads = manager(location);
      await downloads.restore();
      final staged = File(
        p.join(legacy.path, 'incoming-fixture', 'fixture.apk'),
      );
      await staged.parent.create();
      await staged.writeAsBytes([1, 2, 3]);
      final entry = {'id': 'incoming-fixture', 'path': staged.path};
      final task = await downloads.adoptAndroidApk(entry);
      expect(
        p.dirname(p.dirname(task.filePath)),
        await Directory(external).resolveSymbolicLinks(),
      );
      expect(await File(task.filePath).readAsBytes(), [1, 2, 3]);
      expect(await staged.exists(), isFalse);
      expect(await downloads.adoptAndroidApk(entry), same(task));
      final restored = manager(await load());
      await restored.restore();
      expect(
        await restored.adoptAndroidApk(entry),
        same(restored.tasks.single),
      );
      await restored.remove(restored.tasks.single);
      expect(await File(task.filePath).exists(), isFalse);
    },
  );

  test(
    'failed adoption retains its staging copy until history is saved',
    () async {
      await legacy.create(recursive: true);
      final location = await load();
      await location.selectDirectory(
        p.join(sandbox.path, 'external', 'downloads'),
      );
      var failing = true;
      final downloads = DownloadManager(
        legacy,
        locations: location,
        writeHistory: (_) async {
          if (failing) throw const FileSystemException('fixture disk error');
        },
      );
      managers.add(downloads);
      final staged = File(
        p.join(legacy.path, 'incoming-failure', 'fixture.apk'),
      );
      await staged.parent.create();
      await staged.writeAsBytes([1, 2, 3]);
      final entry = {'id': 'incoming-failure', 'path': staged.path};
      await expectLater(
        downloads.adoptAndroidApk(entry),
        throwsA(isA<FileSystemException>()),
      );
      expect(await staged.readAsBytes(), [1, 2, 3]);
      failing = false;
      final adopted = await downloads.adoptAndroidApk(entry);
      expect(downloads.tasks, [adopted]);
      expect(await File(adopted.filePath).readAsBytes(), [1, 2, 3]);
      expect(await staged.exists(), isFalse);
    },
  );

  test(
    'concurrent selection and task preparation preserve operation order',
    () async {
      final location = await load();
      final first = p.join(sandbox.path, 'first');
      final second = p.join(sandbox.path, 'second');
      final selectingFirst = location.selectDirectory(first);
      final preparingFirst = location.prepareDirectory();
      final selectingSecond = location.selectDirectory(second);
      final preparingSecond = location.prepareDirectory();
      await Future.wait([selectingFirst, selectingSecond]);
      expect(
        (await preparingFirst).path,
        await Directory(first).resolveSymbolicLinks(),
      );
      expect(
        (await preparingSecond).path,
        await Directory(second).resolveSymbolicLinks(),
      );
      expect(location.directory.path, second);
    },
  );

  test(
    'imports across nested roots restore and remove only their own files',
    () async {
      final location = await load();
      final downloads = manager(location);
      await downloads.restore();
      final source = await File(p.join(sandbox.path, '测试 & package.exe'))
          .writeAsString('fixture');
      await downloads.importFile(source, platform: 'Windows');
      final original = downloads.tasks.single;
      final originalRoot = p.dirname(p.dirname(original.filePath));
      // A user may choose a folder nested inside an old task's directory.
      final nested = p.join(p.dirname(original.filePath), 'nested');
      await location.selectDirectory(nested);
      await downloads.importFile(source, platform: 'Windows');
      final newer = downloads.tasks.first;
      await downloads.flushHistory();
      expect(p.dirname(p.dirname(newer.filePath)), nested);
      expect(location.managedRoot(original.filePath)?.path, originalRoot);
      expect(await File(p.join(nested, 'tasks.json')).exists(), isFalse);
      final index = jsonDecode(
        await File(p.join(legacy.path, 'tasks.json')).readAsString(),
      ) as List;
      expect(index, hasLength(2));
      final restored = manager(await load());
      await restored.restore();
      expect(restored.tasks, hasLength(2));
      await restored.remove(
        restored.tasks.singleWhere((t) => t.id == original.id),
      );
      expect(await File(original.filePath).exists(), isFalse);
      expect(await File(newer.filePath).readAsString(), 'fixture');
      await restored.remove(restored.tasks.single);
      expect(await source.readAsString(), 'fixture');
      expect(await defaults.exists(), isTrue);
    },
  );

  test(
    'retry keeps its original root and new downloads use the new selection',
    () async {
      final location = await load();
      final downloads = manager(location);
      await downloads.restore();
      final adapter = _PackageAdapter();
      downloads.client.httpClientAdapter = adapter;
      const app = CatalogApp(
        id: 'fixture',
        name: 'Fixture',
        url: 'https://huarun.win/apps/fixture',
      );
      const link = DownloadLink(
        url: 'https://example.com/fixture.exe',
        label: 'Fixture',
        kind: 'exe',
        platform: 'Windows',
      );
      final old = await downloads.download(app, link);
      await finish(downloads, old);
      expect(old.state, DownloadState.failed);
      final oldPath = old.filePath;
      final selected = p.join(sandbox.path, 'new downloads');
      await location.selectDirectory(selected);
      adapter.status = 200;
      await downloads.retry(old);
      await finish(downloads, old);
      expect(old.state, DownloadState.downloaded);
      expect(old.filePath, oldPath);
      final newer = await downloads.download(
        app,
        const DownloadLink(
          url: 'https://example.com/new.exe',
          label: 'New',
          kind: 'exe',
          platform: 'Windows',
        ),
      );
      await finish(downloads, newer);
      expect(newer.state, DownloadState.downloaded);
      expect(
        p.dirname(p.dirname(newer.filePath)),
        await Directory(selected).resolveSymbolicLinks(),
      );
      expect(await File(old.filePath).readAsBytes(), [1, 2, 3]);
      expect(await File(newer.filePath).readAsBytes(), [1, 2, 3]);
    },
  );
}
