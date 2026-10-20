import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:huarunwin/ui/downloads_page.dart';
import 'package:huarunwin/ui/theme.dart';

class InstallDownloads extends DownloadManager {
  InstallDownloads(super.directory) : super(writeHistory: (_) async {});

  @override
  Future<void> refresh() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const target = {
    'path': '/Applications/Fixture.app',
    'bundleIdentifier': 'win.huarun.fixture',
  };
  final running = PlatformException(
    code: 'running',
    message: 'Fixture 正在运行，退出后才能继续安装。',
    details: target,
  );
  final permission = PlatformException(code: 'permission_required');
  late Directory directory;
  late InstallDownloads manager;
  late DownloadTask task;
  late List<MethodCall> calls;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('huarun-quit-install-');
    manager = InstallDownloads(directory);
    task = DownloadTask(
      id: 'fixture',
      appName: 'Fixture',
      url: '',
      filePath: '${directory.path}/Fixture.zip',
      kind: 'zip',
      platform: 'macOS',
      createdAt: DateTime(2026, 10, 17),
      state: DownloadState.downloaded,
    );
    manager.tasks.add(task);
    calls = [];
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeInstaller.channel, null);
    manager.dispose();
    manager.client.close(force: true);
    manager.macResolver.client.close(force: true);
    directory.deleteSync(recursive: true);
  });

  void mockInstall(Future<Object?> Function(MethodCall) response) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeInstaller.channel, (call) async {
          calls.add(call);
          return response(call);
        });
  }

  Future<void> start(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Scaffold(body: DownloadsPage(manager: manager)),
      ),
    );
    await tester.tap(find.text('安装应用'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始安装'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'running app asks for confirmation and cancel preserves it',
    (tester) async {
      mockInstall((_) async => throw running);
      await start(tester);
      expect(find.text('是否退出当前应用，继续安装？'), findsOneWidget);
      expect(find.textContaining('请先保存未完成的工作'), findsOneWidget);
      expect(calls.single.arguments['quitApplication'], isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(calls, hasLength(1));
      expect(task.state, DownloadState.downloaded);
      expect(find.text('安装应用'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    skip: !Platform.isMacOS,
  );

  testWidgets(
    'confirm quits only the approved target and resumes installation',
    (tester) async {
      final finishing = Completer<String>();
      mockInstall((_) async {
        if (calls.length == 1) throw running;
        return finishing.future;
      });
      await start(tester);
      await tester.tap(find.text('退出并继续安装'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(calls, hasLength(2));
      expect(calls.last.method, 'install');
      expect(calls.last.arguments, {
        'package': task.filePath,
        'removeQuarantine': true,
        'authorize': false,
        'quitApplication': target,
      });
      expect(task.state, DownloadState.installing);
      expect(find.text('安装应用'), findsNothing);
      final delete = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '取消并删除'),
      );
      expect(delete.onPressed, isNull);
      finishing.complete(target['path']!);
      await tester.pumpAndSettle();
      expect(task.state, DownloadState.installed);
      expect(find.text('打开应用'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    skip: !Platform.isMacOS,
  );

  for (final permissionFirst in [false, true]) {
    testWidgets(
      'quit and administrator confirmations both work, permissionFirst=$permissionFirst',
      (tester) async {
        mockInstall((_) async {
          if (calls.length == 1) throw permissionFirst ? permission : running;
          if (calls.length == 2) throw permissionFirst ? running : permission;
          return target['path'];
        });
        await start(tester);
        await tester.tap(find.text(permissionFirst ? '继续授权' : '退出并继续安装'));
        await tester.pumpAndSettle();
        expect(task.state, DownloadState.downloaded);
        await tester.tap(find.text(permissionFirst ? '退出并继续安装' : '继续授权'));
        await tester.pumpAndSettle();
        expect(calls, hasLength(3));
        expect(calls.first.arguments['authorize'], isFalse);
        expect(calls.first.arguments['quitApplication'], isNull);
        expect(calls.last.arguments['authorize'], isTrue);
        expect(calls.last.arguments['quitApplication'], target);
        expect(task.state, DownloadState.installed);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      skip: !Platform.isMacOS,
    );
  }

  testWidgets(
    'quit refusal stays retryable without repeating or force quitting',
    (tester) async {
      mockInstall((_) async {
        if (calls.length == 1) throw running;
        throw PlatformException(
          code: 'quit_failed',
          message: '请处理保存提示或手动退出后重试。',
        );
      });
      await start(tester);
      await tester.tap(find.text('退出并继续安装'));
      await tester.pumpAndSettle();
      expect(calls, hasLength(2));
      expect(task.state, DownloadState.downloaded);
      expect(task.installedPath, isNull);
      expect(find.text('请处理保存提示或手动退出后重试。'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('安装应用'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    skip: !Platform.isMacOS,
  );

  testWidgets(
    'a changed running target requires its own confirmation',
    (tester) async {
      const changed = {
        'path': '/Applications/Other.app',
        'bundleIdentifier': 'win.huarun.other',
      };
      mockInstall((_) async {
        if (calls.length == 1) throw running;
        throw PlatformException(code: 'running', details: changed);
      });
      await start(tester);
      await tester.tap(find.text('退出并继续安装'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Other 正在运行'), findsOneWidget);
      expect(calls.last.arguments['quitApplication'], target);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(calls, hasLength(2));
      expect(task.state, DownloadState.downloaded);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    skip: !Platform.isMacOS,
  );

  for (final approved in [false, true]) {
    testWidgets(
      'developer identity change requires explicit confirmation, approved=$approved',
      (tester) async {
        const change = {
          ...target,
          'oldIdentity': 'Team ID AAAAAAAAAA',
          'newIdentity': '未签名',
        };
        mockInstall((_) async {
          if (calls.length == 1) {
            throw PlatformException(code: 'signer_changed', details: change);
          }
          return target['path'];
        });
        await start(tester);
        expect(find.text('应用的开发者签名已变化'), findsOneWidget);
        expect(calls.single.arguments['signerApproval'], isNull);
        await tester.tap(find.text(approved ? '确认并继续' : '取消'));
        await tester.pumpAndSettle();
        if (approved) {
          expect(calls, hasLength(2));
          expect(calls.last.arguments['signerApproval'], change);
          expect(task.state, DownloadState.installed);
        } else {
          expect(calls, hasLength(1));
          expect(task.state, DownloadState.downloaded);
        }
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
      skip: !Platform.isMacOS,
    );
  }

  testWidgets(
    'native phases and signing metadata are scoped to the active package',
    (tester) async {
      final result = Completer<String>();
      mockInstall((_) => result.future);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: Scaffold(body: DownloadsPage(manager: manager)),
        ),
      );
      await tester.tap(find.text('安装应用'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('开始安装'));
      await tester.pump();
      void progress(String package, String stage) =>
          tester.binding.channelBuffers.push(
            NativeInstaller.channel.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('installProgress', {
                'package': package,
                'stage': stage,
                'signature': 'unsigned',
                'assessment': 'rejected',
              }),
            ),
            (_) {},
          );
      progress('/another/package.zip', 'extracting');
      await tester.pump();
      expect(task.installPhase, 'preparing');
      progress(task.filePath, 'copying');
      await tester.pump();
      expect(find.text('正在复制应用…'), findsOneWidget);
      expect(find.textContaining('未签名'), findsOneWidget);
      result.complete(target['path']!);
      await tester.pumpAndSettle();
      expect(task.state, DownloadState.installed);
      expect(task.installPhase, isNull);
      progress(task.filePath, 'extracting');
      await tester.pump();
      expect(task.installPhase, isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    skip: !Platform.isMacOS,
  );
}
