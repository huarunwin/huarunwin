import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/services/android_package.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:huarunwin/ui/adaptive_dialog.dart';
import 'package:huarunwin/ui/android_signing_key_dialog.dart';
import 'package:huarunwin/ui/theme.dart';

const portable = {
  'id': 'personal-key',
  'label': '个人密钥 Fixture',
  'certificateSha256': 'aabbcc',
  'exportable': true,
};
const legacy = {
  'id': 'legacy-key',
  'label': '本机密钥 Fixture',
  'certificateSha256': 'ccddee',
};

void main() {
  final calls = <MethodCall>[];
  final selected = <AndroidSigningKey?>[];
  var keys = <Map<String, Object>>[];
  Future<Object?> Function(MethodCall)? operation;
  setUp(() {
    calls.clear();
    selected.clear();
    keys = [];
    operation = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeInstaller.channel, (call) async {
          calls.add(call);
          return switch (call.method) {
            'apkSigningKeys' => keys,
            'createApkSigningKey' => portable,
            _ => await operation!(call),
          };
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NativeInstaller.channel, null);
  });

  Future<void> showKeys(
    WidgetTester tester, {
    double scale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(brightness),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => selected.add(
                await showAdaptiveForm<AndroidSigningKey>(
                  context: context,
                  enableDrag: false,
                  builder: (context) =>
                      AndroidSigningKeyDialog(installer: NativeInstaller()),
                ),
              ),
              child: const Text('开启重签'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('开启重签'));
    await tester.pumpAndSettle();
  }

  Future<void> passwords(
    WidgetTester tester,
    String password, [
    String? repeat,
  ]) async {
    await tester.enterText(
      find.byKey(const ValueKey('signing-backup-password')),
      password,
    );
    if (repeat != null) {
      await tester.enterText(
        find.byKey(const ValueKey('signing-backup-repeat')),
        repeat,
      );
    }
    await tester.pump();
  }

  testWidgets('new personal key prompts backup once and allows deferral', (
    tester,
  ) async {
    await showKeys(tester);
    await tester.tap(find.text('创建并使用'));
    await tester.pumpAndSettle();
    expect(find.text('备份签名密钥'), findsOneWidget);
    expect(find.textContaining('重装华润赢或换机后'), findsOneWidget);
    expect(calls.map((call) => call.method), [
      'apkSigningKeys',
      'createApkSigningKey',
    ]);
    await tester.tap(find.text('稍后'));
    await tester.pumpAndSettle();
    expect(selected.single!.id, portable['id']);
    expect(selected.single!.exportable, isTrue);
    keys = [portable];
    await tester.tap(find.text('开启重签'));
    await tester.pumpAndSettle();
    expect(find.text('备份签名密钥'), findsNothing);
    expect(find.text('尚未在本机导出备份'), findsOneWidget);
    expect(find.byKey(const ValueKey('export-signing-key')), findsOneWidget);
  });

  testWidgets(
    'key choices stay pending and certificate details follow the selection',
    (tester) async {
      keys = [portable, legacy];
      await showKeys(tester);
      expect(
        tester
            .widget<ListTile>(
              find.widgetWithText(ListTile, portable['label']! as String),
            )
            .selected,
        isTrue,
      );
      expect(find.text(portable['certificateSha256']! as String), findsNothing);
      await tester.ensureVisible(find.text('证书信息'));
      await tester.tap(find.text('证书信息'));
      await tester.pumpAndSettle();
      expect(
        find.text(portable['certificateSha256']! as String),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text(legacy['label']!));
      await tester.tap(find.text(legacy['label']!));
      await tester.pumpAndSettle();
      expect(selected, isEmpty);
      expect(find.text(portable['certificateSha256']! as String), findsNothing);
      expect(find.byKey(const ValueKey('export-signing-key')), findsNothing);
      await tester.ensureVisible(find.text('证书信息'));
      await tester.tap(find.text('证书信息'));
      await tester.pumpAndSettle();
      expect(find.text(legacy['certificateSha256']!), findsOneWidget);
      await tester.tap(find.text('使用此密钥'));
      await tester.pumpAndSettle();
      expect(selected.single!.id, legacy['id']);
      expect(calls.map((call) => call.method), ['apkSigningKeys']);
    },
  );

  testWidgets(
    'password visibility is independent and resets after picker cancellation',
    (tester) async {
      keys = [portable];
      operation = (_) async => null;
      await showKeys(tester);
      await tester.tap(find.byKey(const ValueKey('export-signing-key')));
      await tester.pumpAndSettle();
      final password = find.byKey(const ValueKey('signing-backup-password'));
      final repeat = find.byKey(const ValueKey('signing-backup-repeat'));
      expect(
        tester
            .widget<TextField>(
              find.descendant(of: password, matching: find.byType(TextField)),
            )
            .obscureText,
        isTrue,
      );
      await tester.ensureVisible(
        find.descendant(of: password, matching: find.byTooltip('显示密码')),
      );
      await tester.tap(
        find.descendant(of: password, matching: find.byTooltip('显示密码')),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.descendant(of: password, matching: find.byType(TextField)),
            )
            .obscureText,
        isFalse,
      );
      expect(
        tester
            .widget<TextField>(
              find.descendant(of: repeat, matching: find.byType(TextField)),
            )
            .obscureText,
        isTrue,
      );
      await passwords(tester, 'fixture-password', 'fixture-password');
      await tester.tap(find.text('立即备份'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.descendant(of: password, matching: find.byType(TextField)),
            )
            .obscureText,
        isTrue,
      );
      expect(tester.widget<TextFormField>(password).controller!.text, isEmpty);
      expect(tester.widget<TextFormField>(repeat).controller!.text, isEmpty);
      expect(find.text('备份密码至少需要 8 个字符'), findsNothing);
    },
  );

  testWidgets(
    'export validates password and confirmation before invoking document picker',
    (tester) async {
      keys = [portable];
      await showKeys(tester);
      await tester.tap(find.byKey(const ValueKey('export-signing-key')));
      await tester.pumpAndSettle();
      await passwords(tester, 'short', 'short');
      await tester.tap(find.text('立即备份'));
      await tester.pumpAndSettle();
      expect(find.text('备份密码至少需要 8 个字符'), findsOneWidget);
      expect(calls.map((call) => call.method), ['apkSigningKeys']);
      await passwords(tester, 'valid-password', 'different-password');
      await tester.tap(find.text('立即备份'));
      await tester.pumpAndSettle();
      expect(find.text('两次输入的密码不一致'), findsOneWidget);
      expect(calls, hasLength(1));
    },
  );

  testWidgets(
    'cancelled document export leaves status unchanged; successful export records timestamp',
    (tester) async {
      keys = [portable];
      operation = (_) async => null;
      await showKeys(tester);
      await tester.tap(find.byKey(const ValueKey('export-signing-key')));
      await tester.pumpAndSettle();
      await passwords(tester, 'fixture-password', 'fixture-password');
      await tester.tap(find.text('立即备份'));
      await tester.pumpAndSettle();
      expect(find.text('备份签名密钥'), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('signing-backup-password')),
            )
            .controller!
            .text,
        isEmpty,
      );
      expect(calls.last.arguments, {
        'keyId': portable['id'],
        'expectedCertificateSha256': portable['certificateSha256'],
        'password': 'fixture-password',
      });
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(find.text('尚未在本机导出备份'), findsOneWidget);
      operation = (_) async => {
        ...portable,
        'lastExportedAt': DateTime(2026, 10, 18, 12, 30).millisecondsSinceEpoch,
      };
      await tester.tap(find.byKey(const ValueKey('export-signing-key')));
      await tester.pumpAndSettle();
      await passwords(tester, 'fixture-password', 'fixture-password');
      await tester.tap(find.text('立即备份'));
      await tester.pumpAndSettle();
      expect(find.text('上次导出：2026-10-18 12:30'), findsOneWidget);
      expect(find.text('尚未在本机导出备份'), findsNothing);
      await tester.tap(find.text('使用此密钥'));
      await tester.pumpAndSettle();
      expect(selected.single!.lastExportedAt, DateTime(2026, 10, 18, 12, 30));
    },
  );

  testWidgets(
    'import failure is retryable; restore selects imported identity without creating a new key',
    (tester) async {
      keys = [legacy];
      operation = (_) async =>
          throw PlatformException(code: 'signing_key', message: '备份密码不正确');
      await showKeys(tester);
      await tester.ensureVisible(
        find.byKey(const ValueKey('import-signing-key')),
      );
      await tester.tap(find.byKey(const ValueKey('import-signing-key')));
      await tester.pumpAndSettle();
      await passwords(tester, 'incorrect-password');
      await tester.tap(find.text('选择文件并导入'));
      await tester.pumpAndSettle();
      expect(find.text('备份密码不正确'), findsOneWidget);
      expect(selected, isEmpty);
      operation = (_) async => portable;
      await passwords(tester, 'correct-password');
      await tester.tap(find.text('选择文件并导入'));
      await tester.pumpAndSettle();
      expect(find.text(portable['label']! as String), findsOneWidget);
      expect(find.text(legacy['label']!), findsOneWidget);
      expect(find.text('备份签名密钥'), findsNothing);
      await tester.tap(find.text('使用此密钥'));
      await tester.pumpAndSettle();
      expect(selected.single!.id, portable['id']);
      expect(calls.map((call) => call.method), [
        'apkSigningKeys',
        'importApkSigningKey',
        'importApkSigningKey',
      ]);
    },
  );

  testWidgets('legacy key remains usable and explicitly cannot be exported', (
    tester,
  ) async {
    keys = [legacy];
    await showKeys(tester);
    expect(
      find.textContaining('此旧密钥保存在 Android Keystore，无法导出'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('export-signing-key')), findsNothing);
    await tester.tap(find.text('使用此密钥'));
    await tester.pumpAndSettle();
    expect(selected.single!.exportable, isFalse);
    expect(calls.map((call) => call.method), ['apkSigningKeys']);
  });

  testWidgets(
    'unreadable local key requires explicit recovery or a different identity',
    (tester) async {
      keys = [
        {...portable, 'available': false},
      ];
      await showKeys(tester);
      expect(find.text('本机副本不可用'), findsOneWidget);
      expect(find.byKey(const ValueKey('export-signing-key')), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '使用此密钥'))
            .onPressed,
        isNull,
      );
      expect(find.byKey(const ValueKey('import-signing-key')), findsOneWidget);
      await tester.tap(find.text('新建个人密钥'));
      await tester.pump();
      expect(find.text('创建并使用'), findsOneWidget);
      expect(calls.map((call) => call.method), ['apkSigningKeys']);
    },
  );

  testWidgets(
    'pending transfer prevents duplicate requests and cancellation restores usable controls',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      keys = [portable];
      final response = Completer<Object?>();
      operation = (_) => response.future;
      await showKeys(tester);
      await tester.tap(find.byKey(const ValueKey('export-signing-key')));
      await tester.pumpAndSettle();
      await passwords(tester, 'fixture-password', 'fixture-password');
      await tester.tap(find.text('立即备份'));
      await tester.pump();
      expect(find.text('正在处理…'), findsNWidgets(2));
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('signing-backup-password')),
            )
            .enabled,
        isFalse,
      );
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '取消').last)
            .onPressed,
        isNull,
      );
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.text('备份签名密钥'), findsOneWidget);
      await tester.tapAt(const Offset(195, 10));
      await tester.pump();
      expect(find.text('备份签名密钥'), findsOneWidget);
      await tester.drag(find.text('备份签名密钥'), const Offset(0, 600));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('备份签名密钥'), findsOneWidget);
      await tester.tap(find.text('取消').last);
      await tester.pump();
      expect(
        calls.where((call) => call.method == 'exportApkSigningKey'),
        hasLength(1),
      );
      response.complete(null);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.text('立即备份'), findsOneWidget);
      await tester.tap(find.text('取消').last);
      await tester.pumpAndSettle();
      expect(find.text('尚未在本机导出备份'), findsOneWidget);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'small screen and large text keep backup form actions reachable above keyboard ($brightness)',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetViewInsets);
        keys = [portable];
        await showKeys(tester, scale: 1.8, brightness: brightness);
        final export = find.byKey(const ValueKey('export-signing-key'));
        final panel = tester
            .widget<Material>(
              find.ancestor(of: export, matching: find.byType(Material)).first,
            )
            .color!;
        final background = Theme.of(
          tester.element(find.byType(AndroidSigningKeyDialog)),
        ).bottomSheetTheme.backgroundColor!;
        expect(
          panel.computeLuminance(),
          greaterThan(background.computeLuminance()),
        );
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('export-signing-key')),
          120,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.byKey(const ValueKey('export-signing-key')));
        await tester.pumpAndSettle();
        tester.view.viewInsets = const FakeViewPadding(bottom: 240);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('立即备份').hitTestable(), findsOneWidget);
        expect(find.text('取消').last.hitTestable(), findsOneWidget);
        await tester.ensureVisible(
          find.byKey(const ValueKey('signing-backup-repeat')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('signing-backup-repeat')).hitTestable(),
          findsOneWidget,
        );
      },
    );
  }

  test('old saved key metadata defaults to non-exportable and new metadata round-trips', () {
    expect(AndroidSigningKey.fromMap(legacy).exportable, isFalse);
    final metadata = {...portable, 'lastExportedAt': 1792300000000};
    expect(AndroidSigningKey.fromMap(metadata).toJson(), metadata);
  });
}
