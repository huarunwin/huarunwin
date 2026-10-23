import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/repository.dart';
import 'package:huarunwin/data/site_models.dart';
import 'package:huarunwin/services/app_controller.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:huarunwin/ui/components.dart';
import 'package:huarunwin/ui/corrections_page.dart';
import 'package:huarunwin/ui/settings.dart';
import 'package:huarunwin/ui/site_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

final correctionUri = CorrectionsPage.uri.replace(
  queryParameters: {...CorrectionsPage.uri.queryParameters, 'theme': 'light'},
);

class FakeWebView extends WebViewPlatform {
  late FakeController controller;
  late FakeNavigation navigation;

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => controller = FakeController(params);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => navigation = FakeNavigation(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => FakeWebViewWidget(params);
}

class FakeController extends PlatformWebViewController {
  FakeController(super.params) : super.implementation();

  final requests = <Uri>[];
  late FakeNavigation navigation;
  JavaScriptMode? mode;
  void Function(ScrollPositionChange)? onScroll;
  JavaScriptChannelParams? channel;
  final scripts = <String>[];
  int reloads = 0;

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async =>
      mode = javaScriptMode;

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async => navigation = handler as FakeNavigation;

  @override
  Future<void> setOnScrollPositionChange(
    void Function(ScrollPositionChange)? callback,
  ) async {
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      throw UnimplementedError(
        'Native scroll callback is unavailable on macOS',
      );
    }
    onScroll = callback;
  }

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async =>
      channel = params;

  @override
  Future<void> runJavaScript(String javaScript) async =>
      scripts.add(javaScript);

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    requests.add(params.uri);
    navigation.started(params.uri.toString());
    navigation.finished(params.uri.toString());
  }

  @override
  Future<void> reload() async => reloads++;
}

class FakeNavigation extends PlatformNavigationDelegate {
  FakeNavigation(super.params) : super.implementation();

  late PageEventCallback started, finished;
  late WebResourceErrorCallback resourceError;
  late HttpResponseErrorCallback httpError;
  late NavigationRequestCallback request;

  @override
  Future<void> setOnPageStarted(PageEventCallback callback) async =>
      started = callback;
  @override
  Future<void> setOnPageFinished(PageEventCallback callback) async =>
      finished = callback;
  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback callback) async =>
      resourceError = callback;
  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback callback) async =>
      httpError = callback;
  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback callback,
  ) async => request = callback;
}

class FakeWebViewWidget extends PlatformWebViewWidget {
  FakeWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) =>
      FakeGestureView(params.gestureRecognizers);
}

class FakeGestureView extends StatefulWidget {
  const FakeGestureView(this.factories, {super.key});
  final Set<Factory<OneSequenceGestureRecognizer>> factories;

  @override
  State<FakeGestureView> createState() => _FakeGestureViewState();
}

class _FakeGestureViewState extends State<FakeGestureView> {
  final controller = FakePlatformViewController();

  @override
  Widget build(BuildContext context) => PlatformViewSurface(
    controller: controller,
    hitTestBehavior: PlatformViewHitTestBehavior.opaque,
    gestureRecognizers: widget.factories,
  );
}

class FakePlatformViewController extends PlatformViewController {
  @override
  int get viewId => 0;

  @override
  Future<void> dispatchPointerEvent(PointerEvent event) async {}

  @override
  Future<void> clearFocus() async {}

  @override
  Future<void> dispose() async {}
}

class PublicPages extends CatalogRepository {
  PublicPages(super.directory);

  @override
  Future<SiteSnapshot> page(String url, {bool refresh = false}) async =>
      SiteSnapshot(
        SiteDocument(
          url: url,
          title: '关于网站',
          blocks: const [
            SiteBlock(runs: [SiteText('公开正文')]),
          ],
        ),
        DateTime.now(),
      );
}

void main() {
  test('correction entry uses the production HTTPS page', () {
    expect(CorrectionsPage.uri, Uri.https('huarun.win', '/corrections/app'));
  });

  late Directory directory;
  late AppController controller;
  late DownloadManager downloads;
  late FakeWebView web;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('huarun-corrections');
    SharedPreferences.setMockInitialValues({});
    controller = AppController(
      PublicPages(directory),
      await SharedPreferences.getInstance(),
    );
    downloads = DownloadManager(directory);
    WebViewPlatform.instance = web = FakeWebView();
  });

  tearDown(() {
    controller.repository.client.close(force: true);
    controller.dispose();
    downloads.dispose();
    directory.deleteSync(recursive: true);
  });

  testWidgets('settings has one correction entry and opens the in-app form', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsPage(controller: controller, downloads: downloads),
        ),
      ),
    );
    await tester.scrollUntilVisible(find.text('反馈').hitTestable(), 400);
    expect(find.text('反馈'), findsOneWidget);
    for (final removed in ['账号中心', '信息纠错', '机场信息纠错', '机场纠错']) {
      expect(find.text(removed), findsNothing);
    }
    await tester.tap(find.text('反馈'));
    await tester.pumpAndSettle();
    expect(find.byType(WebViewWidget), findsOneWidget);
    expect(web.controller.requests, [correctionUri]);
    expect(web.controller.mode, JavaScriptMode.unrestricted);
    await tester.tap(
      find.byTooltip(
        MaterialLocalizations.of(tester.element(find.byType(CorrectionsPage)))
            .backButtonTooltip,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CorrectionsPage), findsNothing);
    expect(find.text('反馈'), findsOneWidget);
  });

  testWidgets('reader menu uses the same in-app correction page', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SitePage(
          url: 'https://huarun.win/about',
          controller: controller,
          downloads: downloads,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('页面操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('反馈'));
    await tester.pumpAndSettle();
    expect(find.byType(WebViewWidget), findsOneWidget);
    expect(web.controller.requests, [correctionUri]);
  });

  testWidgets(
    'macOS loads without native scroll support and scrolls its header through the page channel',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: CorrectionsPage()));
      await tester.pumpAndSettle();
      expect(find.byType(WebViewWidget), findsOneWidget);
      expect(find.text('无法打开反馈页面'), findsNothing);
      expect(web.controller.requests, [correctionUri]);
      expect(
        web.controller.scripts.singleWhere(
          (script) => script.contains("addEventListener('scroll'"),
        ),
        contains("addEventListener('scroll'"),
      );
      web.controller.channel!.onMessageReceived(
        const JavaScriptMessage(message: '500'),
      );
      await tester.pump();
      expect(find.byTooltip('刷新反馈页面').hitTestable(), findsNothing);
      web.controller.channel!.onMessageReceived(
        const JavaScriptMessage(message: '0'),
      );
      await tester.pump();
      expect(find.byTooltip('刷新反馈页面').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'Android web content pulls only at the top and waits for navigation to finish',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const MaterialApp(home: CorrectionsPage()));
      await tester.pumpAndSettle();
      expect(find.byTooltip('刷新反馈页面'), findsNothing);
      Future<void> drag(Offset offset) async {
        await tester.drag(find.byType(WebViewWidget), offset);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      }

      await drag(const Offset(0, 25));
      await tester.pumpAndSettle();
      expect(web.controller.reloads, 0);
      web.controller.onScroll!(const ScrollPositionChange(0, 300));
      await tester.pump();
      await drag(const Offset(0, 350));
      await tester.pumpAndSettle();
      expect(web.controller.reloads, 0);
      web.controller.onScroll!(const ScrollPositionChange(0, 0));
      await tester.pump();
      await drag(const Offset(0, -200));
      await tester.pumpAndSettle();
      await drag(const Offset(200, 0));
      await tester.pumpAndSettle();
      expect(web.controller.reloads, 0);

      final touch = await tester.startGesture(
        tester.getCenter(find.byType(WebViewWidget)),
      );
      await touch.moveBy(const Offset(1, -2));
      await touch.moveBy(const Offset(0, 30));
      await touch.moveBy(const Offset(0, 340));
      await touch.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(web.controller.reloads, 1);
      expect(find.byType(RefreshProgressIndicator), findsOneWidget);
      await drag(const Offset(0, 350));
      expect(web.controller.reloads, 1);
      web.navigation.finished(correctionUri.toString());
      await tester.pumpAndSettle();
      expect(find.byType(RefreshProgressIndicator), findsNothing);

      web.navigation.resourceError(
        const WebResourceError(
          errorCode: -1,
          description: 'offline',
          isForMainFrame: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('无法打开反馈页面'), findsOneWidget);
      await tester.dragFrom(const Offset(180, 250), const Offset(0, 400));
      await tester.pumpAndSettle();
      expect(web.controller.requests, [correctionUri, correctionUri]);
      expect(find.text('无法打开反馈页面'), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'Android fast web-content pull includes the first movement after gesture handoff',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const MaterialApp(home: CorrectionsPage()));
      await tester.pumpAndSettle();

      // A fast drag can cross the slop in a single coalesced move event.
      final touch = await tester.startGesture(
        tester.getCenter(find.byType(WebViewWidget)),
      );
      await touch.moveBy(const Offset(0, 350));
      await touch.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(web.controller.reloads, 1);
      expect(find.byType(RefreshProgressIndicator), findsOneWidget);
      web.navigation.finished(correctionUri.toString());
      await tester.pumpAndSettle();
      expect(find.byType(RefreshProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'legacy airport link, refresh, errors and scrolling stay in the app',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => openLink(
                  context,
                  'https://huarun.win/corrections/jichang?airport=example',
                ),
                child: const Text('原入口'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('原入口'));
      await tester.pumpAndSettle();
      expect(web.controller.requests, [correctionUri]);
      web.controller.onScroll!(const ScrollPositionChange(0, 500));
      await tester.pump();
      expect(find.byTooltip('刷新反馈页面').hitTestable(), findsNothing);
      web.controller.onScroll!(const ScrollPositionChange(0, 0));
      await tester.pump();
      expect(find.byTooltip('刷新反馈页面').hitTestable(), findsOneWidget);

      final button = find.descendant(
        of: find.byType(RefreshIconButton),
        matching: find.byType(IconButton),
      );
      final size = tester.getSize(button);
      web.navigation.started(correctionUri.toString());
      await tester.pump();
      expect(tester.getSize(button), size);
      expect(tester.widget<IconButton>(button).onPressed, isNull);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      web.navigation.resourceError(
        const WebResourceError(
          errorCode: -1,
          description: 'unavailable image',
          isForMainFrame: false,
        ),
      );
      await tester.pump();
      expect(find.text('无法打开反馈页面'), findsNothing);
      web.navigation.resourceError(
        const WebResourceError(
          errorCode: -1,
          description: 'offline',
          isForMainFrame: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('无法打开反馈页面'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(web.controller.requests, [correctionUri, correctionUri]);
      expect(find.text('无法打开反馈页面'), findsNothing);
      web.navigation.httpError(
        HttpResponseError(
          request: WebResourceRequest(
            uri: Uri.parse('https://huarun.win/icon.png'),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('无法打开反馈页面'), findsNothing);
      web.navigation.httpError(
        HttpResponseError(request: WebResourceRequest(uri: correctionUri)),
      );
      await tester.pumpAndSettle();
      expect(find.text('无法打开反馈页面'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('刷新反馈页面'));
      await tester.pump();
      expect(web.controller.reloads, 1);

      for (final url in [
        'https://huarun.win/account/login',
        'https://huarun.win/corrections/jichang',
      ]) {
        expect(
          await web.navigation.request(
            NavigationRequest(url: url, isMainFrame: true),
          ),
          NavigationDecision.navigate,
        );
      }
      expect(
        await web.navigation.request(
          const NavigationRequest(url: 'tel:123', isMainFrame: true),
        ),
        NavigationDecision.prevent,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(CorrectionsPage), findsNothing);
      expect(find.text('原入口'), findsOneWidget);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
