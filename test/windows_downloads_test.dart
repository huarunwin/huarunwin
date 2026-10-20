import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/models.dart';
import 'package:huarunwin/services/download_platform.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:huarunwin/ui/downloads_page.dart';

class WindowsPageDownloads extends DownloadManager {
  WindowsPageDownloads(super.directory) : super(writeHistory: (_) async {});
  @override
  Future<void> refresh() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late DownloadManager manager;
  late List<MethodCall> calls;
  var widgetTest = false;
  setUp(() async {
    widgetTest = false;
    directory = await Directory.systemTemp.createTemp('huarun-windows-');
    manager = DownloadManager(directory);
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeInstaller.channel, (call) async {
          calls.add(call);
          return true;
        });
  });
  tearDown(() async {
    if (!widgetTest) await manager.flushHistory();
    manager.dispose();
    manager.client.close(force: true);
    manager.macResolver.client.close(force: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeInstaller.channel, null);
    directory.deleteSync(recursive: true);
  });

  Future<DownloadTask> import(String kind) async {
    final source = await File('${directory.path}/Local App.$kind')
        .writeAsString('abc');
    await manager.importFile(source, platform: 'Windows');
    return manager.tasks.first;
  }

  test(
    'Windows imports preserve original installers and their platform',
    () async {
      for (final kind in ['exe', 'msi', 'msix', 'zip']) {
        final task = await import(kind);
        expect(task.platform, 'Windows');
        expect(task.kind, kind);
        expect(task.canInstallOn('macOS'), isFalse);
        expect(task.canHandOff, isTrue);
        await manager.remove(task);
        expect(
          await File('${directory.path}/Local App.$kind').readAsString(),
          'abc',
        );
      }
      await expectLater(
        manager.importFile(File('wrong.apk'), platform: 'Windows'),
        throwsFormatException,
      );
    },
  );

  test(
    'Windows system handoff stays unconfirmed after refresh and restart',
    () async {
      final task = await import('msi');
      await manager.handOff(task);
      expect(calls.single.method, 'openPackage');
      expect(calls.single.arguments, {'path': task.filePath});
      expect(task.state, DownloadState.handedOff);
      expect(task.installedPath, isNull);
      await manager.refresh();
      await manager.flushHistory();
      manager.tasks.clear();
      await manager.restore();
      expect(manager.tasks.single.state, DownloadState.handedOff);
    },
  );

  test(
    'Windows failed system launch retains the installer for retry',
    () async {
      final task = await import('exe');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            NativeInstaller.channel,
            (_) async =>
                throw PlatformException(code: 'open_package', message: '已取消'),
          );
      await manager.handOff(task);
      expect(task.state, DownloadState.downloaded);
      expect(task.error, '已取消');
      expect(task.canHandOff, isTrue);
      expect(await File(task.filePath).exists(), isTrue);
    },
  );

  test('Windows checksum mismatch blocks system launch', () async {
    final imported = await import('exe');
    final task = DownloadTask.fromJson({
      ...imported.toJson(),
      'sha256': 'f' * 64,
    });
    manager.tasks
      ..clear()
      ..add(task);
    await manager.handOff(task);
    expect(calls, isEmpty);
    expect(task.state, DownloadState.downloaded);
    expect(task.error, contains('SHA-256'));
  });

  test('Windows interrupted handoff restores a retry without claiming installation', () async {
    final task = await import('msix');
    task.state = DownloadState.installing;
    await manager.flushHistory();
    await File('${directory.path}/tasks.json')
        .writeAsString(jsonEncode([task.toJson()]));
    manager.tasks.clear();
    await manager.restore();
    expect(manager.tasks.single.state, DownloadState.downloaded);
    expect(manager.tasks.single.error, contains('尚未确认'));
  });

  test(
    'Windows recommends unique native packages without assuming emulation',
    () {
      DownloadLink asset(String arch, String kind) => DownloadLink(
        url: 'https://example.com/$arch.$kind',
        label: arch,
        architecture: arch,
        platform: 'Windows',
        kind: kind,
      );
      final arm = asset('arm64', 'exe'), x64 = asset('x64', 'msi');
      expect(recommendedWindowsPackage([x64, arm], 'arm64'), arm);
      expect(recommendedWindowsPackage([x64], 'arm64'), isNull);
      expect(
        recommendedWindowsPackage([arm, asset('arm64', 'msi')], 'arm64'),
        isNull,
      );
      expect(recommendedWindowsPackage([arm], null), isNull);
    },
  );

  testWidgets(
    'Windows exposes system installation and native reveal only for its packages',
    (tester) async {
      widgetTest = true;
      await tester.runAsync(manager.flushHistory);
      manager.dispose();
      manager.client.close(force: true);
      manager.macResolver.client.close(force: true);
      manager = WindowsPageDownloads(directory);
      final task = DownloadTask(
        id: 'windows',
        appName: 'Windows Fixture',
        url: '',
        filePath: '${directory.path}/fixture.exe',
        kind: 'exe',
        platform: 'Windows',
        state: DownloadState.downloaded,
        createdAt: DateTime.now(),
      );
      manager.tasks.add(task);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: DownloadsPage(manager: manager)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('安装本地 EXE / MSI / MSIX / ZIP'), findsOneWidget);
      expect(find.text('安装应用'), findsNothing);
      await tester.tap(find.text('使用系统安装器'));
      await tester.pumpAndSettle();
      expect(task.state, DownloadState.handedOff);
      expect(find.textContaining('安装结果尚未确认'), findsOneWidget);
      await tester.tap(find.text('查看文件'));
      await tester.pumpAndSettle();
      expect(calls.last.method, 'reveal');
      manager.tasks
        ..clear()
        ..add(
          DownloadTask.fromJson({
            ...task.toJson(),
            'platform': 'macOS',
            'kind': 'zip',
          }),
        );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DownloadsPage(key: UniqueKey(), manager: manager),
          ),
        ),
      );
      expect(find.text('使用系统安装器'), findsNothing);
      expect(find.text('安装应用'), findsNothing);
      await tester.runAsync(manager.flushHistory);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
