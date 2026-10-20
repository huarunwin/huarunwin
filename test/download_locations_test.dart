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

  Future<DownloadLocations> load() async {
    final result = await DownloadLocations.load(
      preferences: preferences,
      legacyDirectory: legacy,
      defaultDirectory: defaults,
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
    defaults = Directory(p.join(sandbox.path, 'Downloads', 'huarunwin'));
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
      final previous = preferences.getStringList('desktopDownloadDirectories');
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
      expect(preferences.getStringList('desktopDownloadDirectories'), previous);
      expect(changes, 0);
      expect(await collision.readAsString(), 'keep');
      await location.selectDirectory(p.join(sandbox.path, 'valid'));
      expect(changes, 1);
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
