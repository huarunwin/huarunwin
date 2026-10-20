import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/services/android_package.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:huarunwin/ui/adaptive_dialog.dart';
import 'package:huarunwin/ui/android_install_dialog.dart';
import 'package:huarunwin/ui/theme.dart';

void main() {
  final task = DownloadTask(
    id: 'apk',
    appName: '测试应用',
    url: '',
    filePath: '/app.apk',
    kind: 'apk',
    platform: 'Android',
    createdAt: DateTime.now(),
  );
  final info = AndroidPackageInfo.fromMap({
    'packageName': 'win.huarun.fixture',
    'version': '1.2',
    'certificateSha256': ['abc'],
  });
  for (final brightness in Brightness.values) {
    testWidgets(
      'installer choices wait for confirmation; signing is opt-in ($brightness)',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 1.8;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final calls = <String>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(NativeInstaller.channel, (call) async {
              calls.add(call.method);
              if (call.method == 'apkSigningKeys') {
                return [
                  {
                    'id': 'key',
                    'label': '个人密钥',
                    'certificateSha256': 'cert',
                    'exportable': true,
                  },
                ];
              }
              return null;
            });
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(NativeInstaller.channel, null),
        );
        AndroidInstallSelection? selection;
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(brightness),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    selection = await showAdaptiveForm<AndroidInstallSelection>(
                      context: context,
                      enableDrag: false,
                      builder: (_) => AndroidInstallDialog(
                        task: task,
                        info: info,
                        installer: NativeInstaller(),
                      ),
                    );
                  },
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        final own = find.byKey(const ValueKey('installer-huarun'));
        expect(
          find.descendant(of: own, matching: find.byIcon(Icons.check_rounded)),
          findsOneWidget,
        );
        expect(calls, isEmpty);
        expect(find.text('管理密钥'), findsNothing);
        final toggle = find.byKey(const ValueKey('install-resign-apk'));
        await tester.ensureVisible(toggle);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(calls, ['apkSigningKeys']);
        expect(find.text('选择重签密钥'), findsNothing);
        expect(find.text('管理密钥'), findsOneWidget);
        expect(find.text('重签并安装').hitTestable(), findsOneWidget);
        final other = find.byKey(const ValueKey('installer-other'));
        await tester.ensureVisible(other);
        await tester.tap(other);
        await tester.pumpAndSettle();
        expect(find.text('管理密钥'), findsNothing);
        expect(find.text('继续安装').hitTestable(), findsOneWidget);
        expect(selection, isNull);
        await tester.tap(find.text('继续安装'));
        await tester.pumpAndSettle();
        expect(selection!.method, AndroidInstallMethod.other);
        expect(selection!.resignKey, isNull);
        expect(calls, ['apkSigningKeys']);
        selection = null;
        await tester.tap(find.text('打开'));
        await tester.pumpAndSettle();
        final system = find.byKey(const ValueKey('installer-system'));
        await tester.ensureVisible(system);
        await tester.tap(system);
        await tester.pumpAndSettle();
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(selection, isNull);
        expect(calls, ['apkSigningKeys']);
        expect(tester.takeException(), isNull);
      },
    );
  }

  Future<List<AndroidInstallSelection?>> openInstall(
    WidgetTester tester,
    Future<Object?> Function(MethodCall) native, {
    DownloadTask? inputTask,
    DownloadPackage? package,
    bool repackOnly = false,
  }) async {
    final selections = <AndroidInstallSelection?>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeInstaller.channel, native);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(NativeInstaller.channel, null),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => selections.add(
                await showAdaptiveForm<AndroidInstallSelection>(
                  context: context,
                  enableDrag: false,
                  builder: (_) => AndroidInstallDialog(
                    task: inputTask ?? task,
                    package: package,
                    repackOnly: repackOnly,
                    info: info,
                    installer: NativeInstaller(),
                  ),
                ),
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    return selections;
  }

  Future<void> enableSigning(WidgetTester tester) async {
    final toggle = find.byKey(const ValueKey('install-resign-apk'));
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
  }

  for (final kind in ['original', 'signed', 'renamed']) {
    testWidgets('$kind APK can be signed again from the install panel', (
      tester,
    ) async {
      const personal = AndroidSigningKey(
        id: 'personal',
        label: '个人密钥',
        certificateSha256: 'certificate',
      );
      final input = DownloadTask(
        id: kind,
        appName: '测试应用',
        url: '',
        filePath: '/app.apk',
        kind: 'apk',
        platform: 'Android',
        createdAt: DateTime.now(),
        resignKey: kind == 'original' ? null : personal,
        originalPackageName: kind == 'renamed'
            ? 'win.huarun.original'
            : info.packageName,
        resignPackageName: kind == 'renamed' ? info.packageName : null,
      );
      final selections = await openInstall(
        tester,
        (call) async {
          if (call.method == 'apkSigningKeys') return [personal.toJson()];
          expect(call.method, 'resolveApkSigningKey');
          return {...personal.toJson(), 'created': false};
        },
        inputTask: input,
        package: kind == 'original'
            ? DownloadPackage.original
            : DownloadPackage.resigned,
      );
      expect(
        find.text(input.packageLabel(input.defaultPackage)),
        findsOneWidget,
      );
      await enableSigning(tester);
      final confirm = find.text('重签并安装');
      await tester.ensureVisible(confirm);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(selections.single!.resignKey!.id, personal.id);
      expect(selections.single!.resignPackageName, isNull);
    });
  }

  testWidgets(
    'standalone repack requires a valid draft and cancellation creates no identity',
    (tester) async {
      final calls = <String>[];
      final selections = await openInstall(tester, (call) async {
        calls.add(call.method);
        return <Object>[];
      }, repackOnly: true);
      expect(find.text('安装方式'), findsNothing);
      expect(find.text('生成副本'), findsOneWidget);
      expect(calls, ['apkSigningKeys']);
      final rename = find.byKey(const ValueKey('change-apk-package-name'));
      await tester.ensureVisible(rename);
      await tester.tap(rename);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('apk-package-name')),
        'invalid',
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '生成副本'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(selections.single, isNull);
      expect(calls, ['apkSigningKeys']);
    },
  );

  testWidgets(
    'first confirmed install creates a default key; later installs reuse it without a picker',
    (tester) async {
      const personal = {
        'id': 'personal',
        'label': '个人密钥 Fixture',
        'certificateSha256': 'fingerprint',
        'exportable': true,
      };
      var created = false;
      final calls = <MethodCall>[];
      final selections = await openInstall(tester, (call) async {
        calls.add(call);
        if (call.method == 'apkSigningKeys') return created ? [personal] : [];
        expect(call.method, 'resolveApkSigningKey');
        final first = !created;
        expect(
          call.arguments,
          first
              ? isEmpty
              : {
                  'keyId': 'personal',
                  'expectedCertificateSha256': 'fingerprint',
                },
        );
        created = true;
        return {...personal, 'created': first};
      });
      await enableSigning(tester);
      expect(find.text('选择重签密钥'), findsNothing);
      expect(find.textContaining('首次确认重签时自动生成'), findsOneWidget);
      expect(calls.map((call) => call.method), ['apkSigningKeys']);
      await tester.tap(find.text('重签并安装'));
      await tester.pumpAndSettle();
      expect(find.text('备份签名密钥'), findsOneWidget);
      expect(selections, isEmpty);
      await tester.tap(find.text('稍后'));
      await tester.pumpAndSettle();
      expect(selections.single!.resignKey!.id, 'personal');
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await enableSigning(tester);
      await tester.tap(find.text('重签并安装'));
      await tester.pumpAndSettle();
      expect(find.text('备份签名密钥'), findsNothing);
      expect(selections, hasLength(2));
      expect(selections.last!.resignKey!.certificateSha256, 'fingerprint');
      expect(calls.map((call) => call.method), [
        'apkSigningKeys',
        'resolveApkSigningKey',
        'apkSigningKeys',
        'resolveApkSigningKey',
      ]);
    },
  );

  testWidgets(
    'missing default blocks installation; an in-flight resolution cannot duplicate or fall back',
    (tester) async {
      final pending = Completer<Object?>();
      final calls = <String>[];
      final selections = await openInstall(tester, (call) async {
        calls.add(call.method);
        if (call.method == 'apkSigningKeys') return [];
        expect(call.method, 'resolveApkSigningKey');
        return pending.future;
      });
      await enableSigning(tester);
      await tester.tap(find.text('重签并安装'));
      await tester.pump();
      final confirm = find.widgetWithText(FilledButton, '重签并安装');
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      final context = tester.element(find.byType(AndroidInstallDialog));
      expect(await Navigator.of(context).maybePop(), isTrue);
      await tester.pump();
      expect(find.byType(AndroidInstallDialog), findsOneWidget);
      pending.completeError(
        PlatformException(code: 'signing_key', message: '签名密钥已不可用，请导入备份恢复。'),
      );
      await tester.pumpAndSettle();
      expect(find.text('签名密钥已不可用，请导入备份恢复。'), findsOneWidget);
      expect(find.text('继续安装'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '重签并安装'))
            .onPressed,
        isNull,
      );
      expect(selections, isEmpty);
      expect(calls, ['apkSigningKeys', 'resolveApkSigningKey']);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(selections, [null]);
    },
  );
}
