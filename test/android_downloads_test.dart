import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:huarunwin/services/android_package.dart';
import 'package:huarunwin/ui/downloads_page.dart';

class AndroidTask extends DownloadTask {
  AndroidTask(String root, {super.state = DownloadState.downloaded})
    : super(
        id: 'android-fixture',
        appName: 'Android Fixture',
        url: 'https://example.com/app.apk',
        filePath: '$root/fixture/app.apk',
        platform: 'Android',
        kind: 'apk',
        createdAt: DateTime(2026, 10, 17),
      );

  @override
  bool get canInstall => canInstallOn('Android');
}

class AndroidDownloads extends DownloadManager {
  AndroidDownloads(super.directory) : super(writeHistory: (_) async {});

  @override
  Future<void> refresh() async {}

  @override
  Future<AndroidApkDetails> readApkDetails(
    DownloadTask task,
    DownloadPackage package,
  ) async => AndroidApkDetails(
    info: AndroidPackageInfo.fromMap({
      'packageName': 'win.huarun.androidfixture',
    }),
    bytes: 4,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const packageName = 'win.huarun.androidfixture';
  late Directory directory;
  late DownloadManager manager;
  late AndroidTask task;
  late List<MethodCall> calls;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'huarun-android-download',
    );
    manager = DownloadManager(directory);
    task = AndroidTask(directory.path);
    await File(task.filePath).parent.create(recursive: true);
    await File(task.filePath).writeAsBytes([1, 2, 3, 4]);
    manager.tasks.add(task);
    calls = [];
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeInstaller.channel, null);
    await manager.flushHistory();
    manager.dispose();
    manager.client.close(force: true);
    manager.macResolver.client.close(force: true);
    await directory.delete(recursive: true);
  });

  void native(Future<Object?> Function(MethodCall) response) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeInstaller.channel, (call) async {
          calls.add(call);
          return response(call);
        });
  }

  test('only a complete Android APK offers installation on Android', () {
    expect(task.canInstallOn('Android'), isTrue);
    for (final platform in ['macOS', 'Windows', 'Linux', 'iOS', null]) {
      expect(task.canInstallOn(platform), isFalse);
    }
    for (final state in DownloadState.values.where(
      (state) =>
          state != DownloadState.downloaded && state != DownloadState.handedOff,
    )) {
      task.state = state;
      expect(task.canInstallOn('Android'), isFalse);
    }
    task.state = DownloadState.downloaded;
    task.packageAvailable = false;
    expect(task.canInstallOn('Android'), isFalse);
    final foreign = DownloadTask(
      id: 'foreign',
      appName: 'Foreign',
      url: '',
      filePath: '${directory.path}/foreign.zip',
      kind: 'zip',
      platform: 'macOS',
      createdAt: DateTime.now(),
      state: DownloadState.downloaded,
    );
    expect(foreign.canInstallOn('Android'), isFalse);
  });

  test(
    'installation waits for system success and persists package identity',
    () async {
      final completed = Completer<String>();
      native((_) => completed.future);
      final installing = manager.install(task);
      await Future<void>.delayed(Duration.zero);
      expect(calls.single.method, 'installApk');
      expect(calls.single.arguments, {'path': task.filePath});
      expect(task.state, DownloadState.installing);
      expect(task.installedPackage, isNull);
      await expectLater(manager.remove(task), throwsStateError);
      await manager.refresh();
      expect(calls, hasLength(1));
      completed.complete(packageName);
      await installing;
      await manager.flushHistory();
      expect(task.state, DownloadState.installed);
      expect(task.installedPackage, packageName);
      expect(task.installedPath, isNull);
      final saved = jsonDecode(
        await File('${directory.path}/tasks.json').readAsString(),
      ) as List;
      final restored = DownloadTask.fromJson(
        Map<String, dynamic>.from(saved.single as Map),
      );
      expect(restored.installedPackage, packageName);
      expect(restored.state, DownloadState.installed);
    },
  );

  for (final code in ['installation_cancelled', 'install_permission_denied']) {
    test('$code retains the downloaded package and permits retry', () async {
      native((_) async => throw PlatformException(code: code, message: code));
      await expectLater(
        manager.install(task),
        throwsA(isA<PlatformException>()),
      );
      expect(task.state, DownloadState.downloaded);
      expect(task.installedPackage, isNull);
      expect(task.error, code);
      expect(await File(task.filePath).readAsBytes(), [1, 2, 3, 4]);
      native((_) async => packageName);
      await manager.install(task);
      expect(task.state, DownloadState.installed);
      expect(task.installedPackage, packageName);
      expect(task.error, isNull);
    });
  }

  test('an empty system response cannot mark the package installed', () async {
    native((_) async => null);
    await expectLater(manager.install(task), throwsA(isA<PlatformException>()));
    expect(task.state, DownloadState.downloaded);
    expect(task.installedPackage, isNull);
  });

  test('system installer is explicit; other installers use handoff', () async {
    native((call) async => call.method == 'installApk' ? packageName : true);
    await manager.install(task, androidMethod: AndroidInstallMethod.system);
    expect(calls.single.arguments['method'], 'system');
    expect(task.state, DownloadState.installed);
    task.state = DownloadState.downloaded;
    calls.clear();
    await expectLater(
      manager.install(task, androidMethod: AndroidInstallMethod.other),
      throwsArgumentError,
    );
    expect(calls, isEmpty);
    expect(task.state, DownloadState.downloaded);
  });

  test('installation progress does not complete the task', () async {
    final completed = Completer<String>();
    native((_) => completed.future);
    final installing = manager.install(task);
    await Future<void>.delayed(Duration.zero);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final response = Completer<void>();
    messenger.handlePlatformMessage(
      NativeInstaller.channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('installProgress', {
          'package': task.filePath,
          'stage': 'waiting_confirmation',
        }),
      ),
      (_) => response.complete(),
    );
    await response.future;
    expect(task.installPhase, 'waiting_confirmation');
    expect(task.state, DownloadState.installing);
    expect(task.installedPackage, isNull);
    completed.complete(packageName);
    await installing;
    expect(task.state, DownloadState.installed);
    expect(task.installPhase, isNull);
  });

  test('local APK import keeps an independent managed copy', () async {
    final source = File('${directory.path}/local.apk');
    await source.writeAsBytes([5, 6, 7]);
    await manager.importFile(source, platform: 'Android');
    final imported = manager.tasks.first;
    expect(imported.platform, 'Android');
    expect(imported.kind, 'apk');
    expect(imported.filePath, isNot(source.path));
    await source.delete();
    expect(await File(imported.filePath).readAsBytes(), [5, 6, 7]);
    await expectLater(
      manager.importFile(
        File('${directory.path}/wrong.zip'),
        platform: 'Android',
      ),
      throwsFormatException,
    );
  });

  test(
    'inspection prevents removal and binds installation to the preview',
    () async {
      final inspected = Completer<Map<String, Object>>();
      native(
        (call) async =>
            call.method == 'inspectApk' ? inspected.future : packageName,
      );
      final inspection = manager.inspectApk(task);
      await Future<void>.delayed(Duration.zero);
      expect(task.checking, isTrue);
      expect(task.canInstall, isFalse);
      await expectLater(manager.remove(task), throwsStateError);
      inspected.complete({'packageName': packageName, 'fileSha256': 'c' * 64});
      await inspection;
      expect(task.checking, isFalse);
      await manager.install(task);
      expect(calls.last.arguments['expectedSha256'], 'c' * 64);
    },
  );

  test(
    'an external installer handoff remains unconfirmed after restore',
    () async {
      native((_) async => true);
      await manager.handOff(task);
      expect(task.state, DownloadState.handedOff);
      expect(task.installedPackage, isNull);
      await manager.refresh();
      expect(task.state, DownloadState.handedOff);
      await manager.flushHistory();
      manager.tasks.clear();
      await manager.restore();
      expect(manager.tasks.single.state, DownloadState.handedOff);
      expect(manager.tasks.single.canInstallOn('Android'), isTrue);
    },
  );

  test(
    'refresh checks Android package identity without treating it as a path',
    () async {
      task.state = DownloadState.installed;
      task.installedPackage = packageName;
      native((call) async {
        expect(call.method, 'isPackageInstalled');
        expect(call.arguments, {'packageName': packageName});
        return true;
      });
      await File(task.filePath).delete();
      await manager.refresh();
      expect(task.state, DownloadState.installed);
      expect(task.installedPackage, packageName);
      expect(task.packageAvailable, isFalse);

      await File(task.filePath).writeAsBytes([1, 2, 3, 4]);
      native((_) async => false);
      await manager.refresh();
      expect(task.state, DownloadState.downloaded);
      expect(task.installedPackage, isNull);
      expect(task.packageAvailable, isTrue);
      expect(task.canInstall, isTrue);
      expect(task.error, '应用已卸载，可以重新安装。');
    },
  );

  test('failed package status checks preserve the installed record', () async {
    task.state = DownloadState.installed;
    task.installedPackage = packageName;
    final before = task.toJson();
    native((_) async => throw PlatformException(code: 'package_status'));
    await expectLater(manager.refresh(), throwsA(isA<PlatformException>()));
    expect(task.toJson(), before);
  });

  test(
    'an interrupted Android installation restores its existing APK for retry',
    () async {
      task.state = DownloadState.installing;
      await File('${directory.path}/tasks.json')
          .writeAsString(jsonEncode([task.toJson()]));
      manager.tasks.clear();
      await manager.restore();
      final restored = manager.tasks.single;
      expect(restored.state, DownloadState.downloaded);
      expect(restored.installedPackage, isNull);
      expect(restored.packageAvailable, isTrue);
      expect(restored.error, contains('中断'));
    },
  );

  testWidgets(
    'Android download actions use system installation and open the installed app',
    (tester) async {
      await tester.runAsync(manager.flushHistory);
      manager.dispose();
      manager.client.close(force: true);
      manager.macResolver.client.close(force: true);
      manager = AndroidDownloads(directory)..tasks.add(task);
      final completed = Completer<String>();
      native(
        (call) async => switch (call.method) {
          'inspectApk' => {
            'packageName': packageName,
            'version': '1.2.3',
            'minimumSdk': 24,
            'fileSha256': 'a' * 64,
            'nativeAbis': ['arm64-v8a'],
          },
          'installApk' => completed.future,
          _ => null,
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DownloadsPage(manager: manager)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(find.text('安装应用')));
      await tester.pumpAndSettle();
      expect(find.text('开始安装'), findsNothing);
      expect(find.text(packageName), findsOneWidget);
      expect(find.text('安装包版本：1.2.3'), findsOneWidget);
      expect(calls.map((c) => c.method), ['inspectApk']);
      await tester.runAsync(() async {
        await tester.tap(find.text('继续安装'));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pump();
      expect(calls.last.arguments['expectedSha256'], 'a' * 64);
      expect(find.text('正在安装'), findsOneWidget);
      expect(task.state, DownloadState.installing);
      final delete = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '取消并删除'),
      );
      expect(delete.onPressed, isNull);
      completed.complete(packageName);
      await tester.pumpAndSettle();
      expect(find.text('已安装'), findsOneWidget);
      await tester.tap(find.text('打开应用'));
      await tester.pumpAndSettle();
      expect(calls.last.method, 'openAndroidApp');
      expect(calls.last.arguments, {'packageName': packageName});
      expect(tester.takeException(), isNull);
      await tester.runAsync(manager.flushHistory);
    },
  );
}
