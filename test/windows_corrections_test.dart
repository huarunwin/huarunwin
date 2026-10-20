import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/ui/corrections_page.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart'
    as windows;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const plugin = MethodChannel('io.jns.webview.win');
  const view = MethodChannel('io.jns.webview.win/42');
  const events = MethodChannel('io.jns.webview.win/42/events');
  final calls = <MethodCall>[];
  String? runtime;
  Completer<Map<String, Object>>? initializing;
  late Completer<void> disposed;

  setUp(() {
    runtime = '142.0.0.0';
    initializing = null;
    disposed = Completer<void>();
    calls.clear();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(plugin, (call) async {
      calls.add(call);
      if (call.method == 'dispose') disposed.complete();
      return switch (call.method) {
        'getWebViewVersion' => runtime,
        'initialize' => initializing?.future ?? {'textureId': 42},
        _ => null,
      };
    });
    messenger.setMockMethodCallHandler(view, (call) async {
      calls.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(events, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final channel in [plugin, view, events]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  Future<void> event(WidgetTester tester, String type, Object value) async {
    tester.binding.channelBuffers.push(
      events.name,
      const StandardMethodCodec().encodeSuccessEnvelope({
        'type': type,
        'value': value,
      }),
      (_) {},
    );
    await tester.pump();
  }

  Future<void> open(WidgetTester tester) async {
    expect(WebViewPlatform.instance, isNull);
    tester.view.physicalSize = const Size(1240, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: CorrectionsPage()));
    await tester.pump();
  }

  testWidgets('missing Windows runtime gives a specific recovery and retries', (
    tester,
  ) async {
    runtime = null;
    await open(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('缺少 Microsoft Edge WebView2'), findsOneWidget);
    expect(find.text('安装网页组件'), findsOneWidget);
    expect(calls.where((c) => c.method == 'initialize'), isEmpty);
    runtime = '142.0.0.0';
    await tester.tap(find.text('重试'));
    await tester.pump();
    await event(tester, 'loadingStateChanged', 2);
    await tester.pumpAndSettle();
    expect(find.byType(windows.Webview), findsOneWidget);
    expect(find.text('无法打开纠错页面'), findsNothing);
    expect(
      calls.singleWhere((c) => c.method == 'loadUrl').arguments,
      'https://huarun.win/corrections/app?theme=light',
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(const SizedBox());
      await disposed.future.timeout(const Duration(seconds: 5));
    });
    expect(calls.where((c) => c.method == 'dispose'), hasLength(1));
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets(
    'Windows load errors retry the page and cancellation stays usable',
    (tester) async {
      await open(tester);
      await event(tester, 'loadingStateChanged', 2);
      await tester.pumpAndSettle();
      await event(
        tester,
        'onLoadError',
        windows.WebErrorStatus.operationCanceled.index,
      );
      expect(find.text('无法打开纠错页面'), findsNothing);
      await event(
        tester,
        'onLoadError',
        windows.WebErrorStatus.disconnected.index,
      );
      await tester.pumpAndSettle();
      expect(find.text('无法打开纠错页面'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pump();
      await event(tester, 'loadingStateChanged', 2);
      await tester.pumpAndSettle();
      expect(calls.where((c) => c.method == 'loadUrl'), hasLength(2));
      await tester.tap(find.byTooltip('刷新纠错页面'));
      await tester.pump();
      expect(calls.where((c) => c.method == 'reload'), hasLength(1));
      await event(tester, 'loadingStateChanged', 2);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox());
        await disposed.future.timeout(const Duration(seconds: 5));
      });
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets('Windows native Escape returns through the page message bridge', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const CorrectionsPage()),
            ),
            child: const Text('打开纠错'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开纠错'));
    await tester.pump();
    await event(tester, 'loadingStateChanged', 2);
    await tester.pumpAndSettle();
    expect(
      calls
          .singleWhere((c) => c.method == 'addScriptToExecuteOnDocumentCreated')
          .arguments,
      contains("event.key === 'Escape'"),
    );
    await event(tester, 'webMessageReceived', '{"type":"huarun-page-back"}');
    await tester.pumpAndSettle();
    expect(find.byType(CorrectionsPage), findsNothing);
    expect(find.text('打开纠错'), findsOneWidget);
    await tester.runAsync(
      () => disposed.future.timeout(const Duration(seconds: 5)),
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets(
    'leaving during Windows initialization releases its native view',
    (tester) async {
      initializing = Completer<Map<String, Object>>();
      await open(tester);
      expect(calls.where((c) => c.method == 'initialize'), hasLength(1));
      await tester.pumpWidget(const SizedBox());
      initializing!.complete({'textureId': 42});
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => disposed.future.timeout(const Duration(seconds: 5)),
      );
      expect(calls.where((c) => c.method == 'dispose'), hasLength(1));
      expect(calls.where((c) => c.method == 'loadUrl'), isEmpty);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
