import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:huarunwin/ui/android_incoming_apks.dart';

import 'android_downloads_test.dart' show AndroidDownloads, AndroidTask;

class PendingDownloads extends AndroidDownloads {
  PendingDownloads(super.directory);
  final adopted = Completer<DownloadTask>();
  int adoptionCount = 0;
  @override
  Future<DownloadTask> adoptAndroidApk(Map<Object?, Object?> entry) {
    adoptionCount++;
    return adopted.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DownloadManager manager;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('huarun-incoming-test');
    manager = DownloadManager(directory);
  });
  tearDown(() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(AndroidIncomingApks.channel, null);
    messenger.setMockMethodCallHandler(NativeInstaller.channel, null);
    if (manager is! PendingDownloads) await manager.flushHistory();
    manager.dispose();
    manager.client.close(force: true);
    manager.macResolver.client.close(force: true);
    directory.deleteSync(recursive: true);
  });
  Future<Map<String, Object>> incoming() async {
    final file = File('${directory.path}/incoming-test/fixture.apk');
    await file.parent.create(recursive: true);
    await file.writeAsBytes([1, 2, 3]);
    return {'id': 'incoming-test', 'path': file.path, 'name': 'fixture.apk'};
  }

  test(
    'adoption is durable and idempotent across history restoration',
    () async {
      final entry = await incoming();
      final task = await manager.adoptAndroidApk(entry);
      expect(task.platform, 'Android');
      expect(task.canInstallOn('Android'), isTrue);
      final saved = jsonDecode(
        await File('${directory.path}/tasks.json').readAsString(),
      ) as List;
      expect(saved.single['id'], entry['id']);
      expect(await manager.adoptAndroidApk(entry), same(task));
      expect(manager.tasks, hasLength(1));
      manager.tasks.clear();
      await manager.restore();
      final restored = manager.tasks.single;
      expect(await manager.adoptAndroidApk(entry), same(restored));
      expect(restored.installedPackage, isNull);
    },
  );

  test(
    'adoption rejects escaped paths and retries a failed history save',
    () async {
      final entry = await incoming();
      await expectLater(
        manager.adoptAndroidApk({...entry, 'id': '../bad'}),
        throwsFormatException,
      );
      await manager.flushHistory();
      manager.dispose();
      manager.client.close(force: true);
      manager.macResolver.client.close(force: true);
      var failing = true;
      manager = DownloadManager(
        directory,
        writeHistory: (_) async {
          if (failing) throw const FileSystemException('disk full');
        },
      );
      await expectLater(
        manager.adoptAndroidApk(entry),
        throwsA(isA<FileSystemException>()),
      );
      expect(manager.tasks, hasLength(1));
      failing = false;
      expect(await manager.adoptAndroidApk(entry), same(manager.tasks.single));
      expect(manager.tasks, hasLength(1));
    },
  );

  for (final failed in [false, true]) {
    testWidgets(
      'incoming APK is acknowledged only after durable adoption (failed=$failed)',
      (tester) async {
        manager.dispose();
        manager.client.close(force: true);
        manager.macResolver.client.close(force: true);
        final downloads = PendingDownloads(directory);
        manager = downloads;
        final task = AndroidTask(directory.path);
        manager.tasks.add(task);
        final navigator = GlobalKey<NavigatorState>();
        final calls = <String>[];
        final nativeCalls = <String>[];
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(AndroidIncomingApks.channel, (
          call,
        ) async {
          calls.add(call.method);
          return call.method == 'pendingApks'
              ? [
                  {'id': 'incoming-test', 'path': task.filePath},
                ]
              : null;
        });
        messenger.setMockMethodCallHandler(NativeInstaller.channel, (
          call,
        ) async {
          nativeCalls.add(call.method);
          return {'packageName': 'test.app', 'fileSha256': 'a' * 64};
        });
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            builder: (_, child) => AndroidIncomingApks(
              manager: downloads,
              navigatorKey: navigator,
              child: child!,
            ),
            home: const Scaffold(body: Text('首页')),
          ),
        );
        await tester.pumpAndSettle();
        expect(downloads.adoptionCount, 1);
        expect(calls, ['pendingApks']);
        expect(nativeCalls, isEmpty);
        if (failed) {
          downloads.adopted.completeError(
            const FileSystemException('disk full'),
          );
          await tester.pumpAndSettle();
          expect(calls, ['pendingApks']);
          expect(find.text('首页'), findsOneWidget);
          expect(nativeCalls, isEmpty);
        } else {
          downloads.adopted.complete(task);
          await tester.pumpAndSettle();
          expect(calls, ['pendingApks', 'ackApk']);
          expect(find.text('安装 Android Fixture'), findsOneWidget);
          expect(nativeCalls, ['inspectApk']);
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          expect(nativeCalls, ['inspectApk']);
          expect(task.state, DownloadState.downloaded);
          navigator.currentState!.pop();
          await tester.pumpAndSettle();
          expect(find.text('首页'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
