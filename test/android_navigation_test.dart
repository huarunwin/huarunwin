import 'dart:async';
import 'dart:io';
import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/models.dart';
import 'package:huarunwin/data/repository.dart';
import 'package:huarunwin/data/site_models.dart';
import 'package:huarunwin/main.dart';
import 'package:huarunwin/services/app_controller.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:huarunwin/ui/app_download_button.dart';
import 'package:huarunwin/ui/app_library_page.dart';
import 'package:huarunwin/ui/compact_navigation.dart';
import 'package:huarunwin/ui/page_components.dart';
import 'package:huarunwin/ui/site_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NavigationPages extends CatalogRepository {
  NavigationPages(super.directory);

  final requests = <String>[];
  final refreshes = <String>[];
  final saved = <String, SiteSnapshot>{};
  final pending = <String, Completer<SiteSnapshot>>{};
  bool fail = false;

  @override
  SiteSnapshot? cachedPage(String url) => saved[url];

  @override
  Future<SiteSnapshot> page(String url, {bool refresh = false}) async {
    final path = Uri.parse(url).path;
    requests.add(path);
    if (refresh) refreshes.add(path);
    if (pending[path] case final pending?) return pending.future;
    if (fail) throw const SocketException('offline');
    final timeline = path.startsWith('/history/');
    return saved[url] = SiteSnapshot(
      SiteDocument(
        url: url,
        title: '公开栏目 $path',
        directory: !timeline,
        nextUrl: path == '/vps' ? 'https://huarun.win/vps/page/2' : null,
        items: [
          if (!timeline)
            for (var index = 0; index < 20; index++)
              SiteItem(title: '$path 条目 $index', url: '$url/item-$index'),
        ],
        blocks: [
          if (timeline) const SiteBlock(runs: [SiteText('纪事正文')]),
        ],
      ),
      DateTime.now(),
    );
  }
}

void main() {
  late Directory folder;
  late NavigationPages repository;
  late AppController controller;
  late DownloadManager downloads;

  setUp(() async {
    folder = Directory.systemTemp.createTempSync('huarun-android-navigation');
    repository = NavigationPages(folder);
    SharedPreferences.setMockInitialValues({'catalogPlatform': '全部'});
    controller =
        AppController(repository, await SharedPreferences.getInstance())
          ..snapshot = CatalogSnapshot([
            for (var index = 0; index < 30; index++)
              CatalogApp(
                id: 'example-$index',
                name: '示例应用 $index',
                url: 'https://huarun.win/apps/example-$index',
                platforms: const ['Android'],
              ),
          ], DateTime.now());
    downloads = DownloadManager(folder);
  });

  tearDown(() {
    controller.dispose();
    downloads.dispose();
    repository.client.close(force: true);
    folder.deleteSync(recursive: true);
  });

  Future<void> show(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    double textScale = 1,
    FakeViewPadding padding = const FakeViewPadding(top: 32, bottom: 24),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.view.padding = padding;
    tester.view.viewPadding = padding;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      HuarunApp(controller: controller, downloads: downloads),
    );
    await tester.pumpAndSettle();
  }

  Future<void> select(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(
        of: find.byType(CompactNavigation),
        matching: find.text(label),
      ),
    );
    await tester.pumpAndSettle();
  }

  int index(WidgetTester tester) => tester
      .widget<CompactNavigation>(find.byType(CompactNavigation))
      .selectedIndex;
  String path(WidgetTester tester) =>
      Uri.parse(tester.widget<SitePage>(find.byType(SitePage)).url).path;
  ScrollPosition position(WidgetTester tester) => tester
      .state<ScrollableState>(
        find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        ),
      )
      .position;

  void expectScrollingTop(WidgetTester tester) {
    final viewport = find.byWidgetPredicate(
      (widget) =>
          widget is Scrollable && widget.axisDirection == AxisDirection.down,
    );
    expect(tester.getTopLeft(viewport).dy, 0);
    expect(
      tester.getTopLeft(find.byType(PageHeader)).dy,
      greaterThanOrEqualTo(32),
    );
    expect(
      tester.widget<RefreshIndicator>(find.byType(RefreshIndicator)).edgeOffset,
      32,
    );
  }

  for (final brightness in Brightness.values) {
    testWidgets(
      'catalog scrolls under the transparent status bar ($brightness)',
      (tester) async {
        controller.setTheme(
          brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
        );
        await show(tester);
        expectScrollingTop(tester);
        final card = find.byKey(
          ValueKey('android-app-${controller.snapshot!.apps.first.key}'),
        );
        position(tester).jumpTo(tester.getTopLeft(card).dy + 20);
        await tester.pumpAndSettle();
        expect(tester.getTopLeft(card).dy, closeTo(-20, .01));
        final hit = tester.hitTestOnBinding(const Offset(195, 16));
        expect(
          hit.path.any((entry) => entry.target == tester.renderObject(card)),
          isTrue,
        );

        tester.view.physicalSize = const Size(844, 390);
        tester.view.padding = const FakeViewPadding(
          left: 44,
          right: 24,
          bottom: 24,
        );
        tester.view.viewPadding = const FakeViewPadding(
          left: 44,
          right: 24,
          bottom: 24,
        );
        await tester.pumpAndSettle();
        position(tester).jumpTo(0);
        await tester.pumpAndSettle();
        final viewport = find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        );
        expect(tester.getRect(viewport).left, 44);
        expect(tester.getRect(viewport).right, 820);
        expect(tester.getTopLeft(find.byType(PageHeader)).dy, 34);
        tester.view.physicalSize = const Size(1240, 900);
        tester.view.padding = const FakeViewPadding(top: 32, bottom: 24);
        tester.view.viewPadding = const FakeViewPadding(top: 32, bottom: 24);
        await tester.pumpAndSettle();
        expect(
          tester.getTopLeft(find.byTooltip('收起侧边栏')).dy,
          greaterThanOrEqualTo(32),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Android content tabs load lazily and retain independent searches and scroll positions',
    (tester) async {
      await show(tester);
      expect(repository.requests, isEmpty);
      expect(
        tester
            .widget<CompactNavigation>(find.byType(CompactNavigation))
            .destinations
            .map((d) => d.label),
        ['发现', '应用库', 'VPS', '机场', '设置'],
      );
      await tester.enterText(find.byType(TextField), '示例应用');
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue);
      final catalogFocus = tester
          .widget<EditableText>(find.byType(EditableText))
          .focusNode;
      await tester.drag(find.text('示例应用 0'), const Offset(0, -500));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse);
      expect(catalogFocus.hasFocus, isFalse);
      expect(find.byType(TextField).hitTestable(), findsNothing);
      final appOffset = position(tester).pixels;
      await select(tester, 'VPS');
      expect(index(tester), 2);
      expect(path(tester), '/vps');
      expect(repository.requests, ['/vps']);
      await tester.enterText(find.byType(TextField), '条目');
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.drag(find.text('/vps 条目 0'), const Offset(0, -500));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse);
      final vpsState = tester.state(find.byType(SitePage));
      final vpsOffset = position(tester).pixels;
      expect(find.byType(TextField).hitTestable(), findsNothing);
      await select(tester, '机场');
      expect(path(tester), '/jichang');
      expect(repository.requests, ['/vps', '/jichang']);
      await select(tester, 'VPS');
      expect(tester.state(find.byType(SitePage)), same(vpsState));
      expect(position(tester).pixels, closeTo(vpsOffset, 0.01));
      position(tester).jumpTo(0);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '条目',
      );
      expect(repository.requests, ['/vps', '/jichang']);
      await select(tester, '发现');
      expect(position(tester).pixels, closeTo(appOffset, 0.01));
      position(tester).jumpTo(0);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '示例应用',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Android tabs can be activated through accessibility', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      await show(tester);
      final airportButton = find.bySemanticsLabel('机场');
      final airport = tester.getSemantics(airportButton);
      expect(airport.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      tester
          .renderObject(airportButton)
          .owner!
          .semanticsOwner!
          .performAction(airport.id, SemanticsAction.tap);
      await tester.pumpAndSettle();
      expect(index(tester), 3);
      expect(path(tester), '/jichang');
      expect(repository.requests, ['/jichang']);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'floating dock previews a swipe and keeps the final catalog card reachable',
    (tester) async {
      await show(tester);
      final dock = find.byKey(const ValueKey('android-navigation-bar'));
      final bar = tester.getRect(dock);
      final gesture = await tester.startGesture(
        Offset(bar.left + bar.width / 10, bar.center.dy),
      );
      await gesture.moveTo(Offset(bar.left + bar.width * .7, bar.center.dy));
      await tester.pump(const Duration(milliseconds: 300));
      expect(index(tester), 0);
      expect(repository.requests, isEmpty);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(index(tester), 3);
      expect(path(tester), '/jichang');
      expect(repository.requests, ['/jichang']);

      await select(tester, '发现');
      final last = find.text('示例应用 29');
      await tester.scrollUntilVisible(
        last,
        500,
        scrollable: find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        ),
      );
      position(tester).jumpTo(position(tester).maxScrollExtent);
      await tester.pumpAndSettle();
      expect(last.hitTestable(), findsOneWidget);
      expect(tester.getRect(last).bottom, lessThan(tester.getRect(dock).top));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'all content tabs reach the shared library and retain its search',
    (tester) async {
      await show(tester);
      expect(find.byType(AppLibraryPage), findsNothing);
      Object? libraryState;
      for (final label in ['发现', 'VPS', '机场']) {
        await select(tester, label);
        expectScrollingTop(tester);
        final selected = index(tester);
        await select(tester, '应用库');
        expect(index(tester), 1);
        final state = tester.state(find.byType(AppLibraryPage));
        if (libraryState == null) {
          libraryState = state;
          expect(find.text('应用库为空'), findsOneWidget);
          await tester.enterText(find.byType(TextField), 'fixture');
          await tester.pumpAndSettle();
          tester.testTextInput.hide();
          await tester.pumpAndSettle();
        } else {
          expect(state, same(libraryState));
          expect(
            tester.widget<TextField>(find.byType(TextField)).controller!.text,
            'fixture',
          );
        }
        expectScrollingTop(tester);
        expect(find.byTooltip('返回'), findsNothing);
        expect(find.byType(CompactNavigation), findsOneWidget);
        await select(tester, '设置');
        expect(find.text('设置'), findsNWidgets(2));
        expect(find.text('应用库'), findsOneWidget);
        await select(tester, label);
        expect(index(tester), selected);
      }
      expect(repository.requests, ['/vps', '/jichang']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a catalog download selects download tasks in the library tab', (
    tester,
  ) async {
    await show(tester);
    await tester.enterText(find.byType(TextField), '示例应用 0');
    await tester.pumpAndSettle();
    tester
        .widget<AppDownloadButton>(find.byType(AppDownloadButton).first)
        .onStarted();
    await tester.pumpAndSettle();
    expect(find.text('暂无下载任务'), findsOneWidget);
    expect(index(tester), 1);
    expect(find.byTooltip('返回'), findsNothing);
    await tester.enterText(find.byType(TextField), 'another-file');
    await tester.pumpAndSettle();
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await select(tester, '发现');
    expect(index(tester), 0);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '示例应用 0',
    );
    tester
        .widget<AppDownloadButton>(find.byType(AppDownloadButton).first)
        .onStarted();
    await tester.pumpAndSettle();
    expect(index(tester), 1);
    expect(find.text('暂无下载任务'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android can open settings after narrowing a sidebar page', (
    tester,
  ) async {
    await show(tester, size: const Size(1240, 900));
    await tester.tap(find.byKey(const ValueKey('nav-site-/vps')));
    await tester.pumpAndSettle();
    expect(path(tester), '/vps');
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    expect(path(tester), '/vps');
    await select(tester, '设置');
    expect(find.text('设置'), findsNWidgets(2));
    expect(index(tester), 4);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'switching tabs stops dispatching pagination while retaining loaded content',
    (tester) async {
      await show(tester);
      await select(tester, 'VPS');
      final more = find.text('载入全部页');
      await tester.scrollUntilVisible(
        more,
        500,
        scrollable: find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        ),
      );
      repository.pending['/vps/page/2'] = Completer<SiteSnapshot>();
      await tester.tap(more);
      await tester.pump();
      expect(repository.requests, ['/vps', '/vps/page/2']);
      await select(tester, '发现');
      repository.pending['/vps/page/2']!.complete(
        SiteSnapshot(
          const SiteDocument(
            url: 'https://huarun.win/vps/page/2',
            title: '第二页',
            directory: true,
            nextUrl: 'https://huarun.win/vps/page/3',
          ),
          DateTime.now(),
        ),
      );
      await tester.pumpAndSettle();
      expect(repository.requests, ['/vps', '/vps/page/2']);
      await select(tester, 'VPS');
      position(tester).jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.textContaining('已停止加载'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed Android content still exposes navigation and can pull to retry',
    (tester) async {
      await show(tester);
      repository.fail = true;
      await select(tester, 'VPS');
      expect(find.text('暂时无法加载VPS'), findsOneWidget);
      expect(find.byTooltip('更多'), findsNothing);
      repository.fail = false;
      await tester.dragFrom(const Offset(180, 270), const Offset(0, 420));
      await tester.pumpAndSettle();
      expect(repository.refreshes, ['/vps']);
      expect(find.text('/vps 条目 0'), findsOneWidget);
      expect(index(tester), 2);
      expect(tester.takeException(), isNull);
    },
  );

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'Android navigation remains usable in a narrow window at scale $scale',
      (tester) async {
        await show(tester, size: const Size(320, 720), textScale: scale);
        for (final label in ['VPS', '机场', '发现']) {
          await select(tester, label);
          expect(find.byTooltip('更多'), findsNothing);
          expect(tester.takeException(), isNull, reason: label);
        }
        await select(tester, '设置');
        expect(find.text('设置'), findsNWidgets(2));
        expect(index(tester), 4);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
