import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/models.dart';
import 'package:huarunwin/services/download_copies.dart';
import 'package:huarunwin/services/downloads.dart';

import 'downloads_test.dart' show PackageAdapter;

class _Copies extends AndroidDownloadCopies {
  _Copies(this.destination) {
    enabled = true;
    treeUri = 'content://fixture/tree/downloads';
    directoryLabel = 'Fixture Downloads';
  }
  final File destination;
  bool fail = false;
  Completer<void>? pending;
  final entered = Completer<void>();
  int calls = 0;

  @override
  Future<({String uri, String directory})> save({
    required String id,
    required String path,
    required CancelToken cancelToken,
    String? sha256,
  }) async {
    calls++;
    if (!entered.isCompleted) entered.complete();
    if (pending != null) {
      await Future.any([pending!.future, cancelToken.whenCancel]);
    }
    if (cancelToken.isCancelled) throw cancelToken.cancelError!;
    if (fail) {
      throw PlatformException(code: 'copy_permission', message: '请重新授权文件夹。');
    }
    await File(path).copy(destination.path);
    return (
      uri: 'content://fixture/document/app.apk',
      directory: directoryLabel!,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late DownloadManager manager;
  late _Copies copies;
  late DownloadTask task;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('huarun-copy-test-');
    final managed = await Directory('${root.path}/managed').create();
    copies = _Copies(File('${root.path}/exported.apk'));
    manager = DownloadManager(
      managed,
      copies: copies,
      readAndroidMetadata: false,
    );
    task = DownloadTask(
      id: 'fixture',
      appName: 'Fixture',
      url: 'https://example.com/app.apk',
      filePath: '${managed.path}/fixture/app.apk',
      platform: 'Android',
      kind: 'apk',
      createdAt: DateTime.now(),
      state: DownloadState.downloaded,
    );
    await File(task.filePath).parent.create();
    await File(task.filePath).writeAsBytes([1, 2, 3, 4]);
    manager.tasks.add(task);
  });

  tearDown(() async {
    await manager.flushHistory();
    manager.dispose();
    manager.client.close(force: true);
    manager.macResolver.client.close(force: true);
    copies.dispose();
    await root.delete(recursive: true);
  });

  test(
    'copy failure preserves installation and retries without downloading',
    () async {
      copies.fail = true;
      await manager.saveDownloadCopy(task);
      expect(task.state, DownloadState.downloaded);
      expect(task.canInstallOn('Android'), isTrue);
      expect(task.error, isNull);
      expect(task.copyError, contains('授权'));
      expect(await File(task.filePath).readAsBytes(), [1, 2, 3, 4]);
      copies.fail = false;
      await manager.saveDownloadCopy(task);
      expect(task.copyError, isNull);
      expect(task.copyUri, 'content://fixture/document/app.apk');
      expect(copies.calls, 2);
      await manager.remove(task);
      expect(await copies.destination.readAsBytes(), [1, 2, 3, 4]);
    },
  );

  test(
    'copy cancellation prevents concurrent copies and source deletion',
    () async {
      copies.pending = Completer<void>();
      final saving = manager.saveDownloadCopy(task);
      await copies.entered.future;
      expect(task.savingCopy, isTrue);
      await manager.saveDownloadCopy(task);
      expect(copies.calls, 1);
      await expectLater(manager.remove(task), throwsStateError);
      manager.cancelDownloadCopy(task);
      await saving;
      expect(task.savingCopy, isFalse);
      expect(task.state, DownloadState.downloaded);
      expect(task.copyError, contains('取消'));
      expect(await File(task.filePath).exists(), isTrue);
    },
  );

  test(
    'interrupted copy restores as retryable without changing download state',
    () {
      task.savingCopy = true;
      final restored = DownloadTask.fromJson(task.toJson());
      expect(restored.savingCopy, isFalse);
      expect(restored.copyError, contains('中断'));
      expect(restored.state, DownloadState.downloaded);
      expect(restored.canInstallOn('Android'), isTrue);
    },
  );

  for (final enabled in [true, false]) {
    test(
      'completed APK respects automatic copy preference: $enabled',
      () async {
        copies.enabled = enabled;
        manager.client.httpClientAdapter = PackageAdapter(
          () => ResponseBody.fromBytes(
            [1, 2, 3, 4],
            200,
            headers: {
              Headers.contentLengthHeader: ['4'],
              Headers.contentTypeHeader: ['application/octet-stream'],
            },
          ),
        );
        final download = await manager.download(
          const CatalogApp(
            id: 'new',
            name: 'New',
            url: 'https://example.com/app',
          ),
          const DownloadLink(
            url: 'https://example.com/new.apk',
            label: 'APK',
            platform: 'Android',
            kind: 'apk',
          ),
        );
        while (download.busy || download.savingCopy) {
          final changed = Completer<void>();
          void listener() {
            if (!download.busy &&
                !download.savingCopy &&
                !changed.isCompleted) {
              changed.complete();
            }
          }

          manager.addListener(listener);
          try {
            if (download.busy || download.savingCopy) {
              await changed.future.timeout(const Duration(seconds: 5));
            }
          } finally {
            manager.removeListener(listener);
          }
        }
        await manager.flushHistory();
        expect(download.state, DownloadState.downloaded);
        expect(copies.calls, enabled ? 1 : 0);
        expect(download.copyUri != null, enabled);
      },
    );
  }
}
