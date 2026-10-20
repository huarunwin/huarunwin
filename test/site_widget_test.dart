import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:html/parser.dart' as html;
import 'package:huarunwin/data/repository.dart';
import 'package:huarunwin/data/site_models.dart';
import 'package:huarunwin/data/site_parser.dart';
import 'package:huarunwin/services/app_controller.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:huarunwin/ui/site_page.dart';
import 'package:huarunwin/ui/theme.dart';

class PublicPages extends CatalogRepository {
  PublicPages(this.pages) : super(Directory.systemTemp);
  final Map<String, String> pages;
  final List<String> calls = [];
  @override
  Future<SiteSnapshot> page(String url, {bool refresh = false}) async {
    calls.add(url);
    return SiteSnapshot(
      PublicSiteParser().parse(pages[url]!, url),
      DateTime(2026, 10, 17),
    );
  }
}

class FilterPages extends CatalogRepository {
  FilterPages() : super(Directory.systemTemp);
  @override
  Future<SiteSnapshot> page(String url, {bool refresh = false}) async =>
      SiteSnapshot(
        SiteDocument(
          url: url,
          title: '生态动态',
          directory: true,
          items: const [
            SiteItem(
              title: '文章甲',
              url: 'https://huarun.win/feed/a',
              facets: {
                '类型': ['文章'],
              },
            ),
            SiteItem(
              title: '发布乙',
              url: 'https://huarun.win/feed/b',
              facets: {
                '类型': ['发布'],
              },
            ),
          ],
        ),
        DateTime(2026, 10, 17),
      );
}

String listPage(
  String title, {
  String? previous,
  String? next,
  String memory = '1',
}) =>
    '''
<main><section class="catalog"><h1>VPS 目录</h1>
<article class="vps-card"><h2><a class="vps-card-link" href="/vps/example/$title">$title</a></h2>
<p class="vps-reference-price">¥ 20 / 月</p><p class="vps-monthly">按月付款</p>
<dl><dt>内存</dt><dd>$memory GB</dd></dl></article>
<nav class="vps-pagination">
${previous == null ? '' : '<a href="$previous">上一页</a>'}
${next == null ? '' : '<a href="$next">下一页</a>'}
</nav></section></main>''';

void main() {
  Future<(AppController, DownloadManager)> setup(CatalogRepository repo) async {
    SharedPreferences.setMockInitialValues({});
    final dir = Directory.systemTemp.createTempSync('huarun-site-widget');
    addTearDown(() => dir.deleteSync(recursive: true));
    return (
      AppController(repo, await SharedPreferences.getInstance()),
      DownloadManager(dir),
    );
  }

  testWidgets('reading catalog phone filters apply only after confirmation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final (controller, downloads) = await setup(FilterPages());
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: SitePage(
          url: 'https://huarun.win/feed',
          controller: controller,
          downloads: downloads,
        ),
      ),
    );
    await tester.pumpAndSettle();
    Future<void> openFilters() async {
      await tester.tap(find.byIcon(Icons.tune_rounded));
      await tester.pumpAndSettle();
    }

    await openFilters();
    await tester.tap(find.widgetWithText(ChoiceChip, '文章'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('文章甲'), findsOneWidget);
    expect(find.text('发布乙'), findsOneWidget);
    await openFilters();
    await tester.tap(find.widgetWithText(ChoiceChip, '文章'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(find.text('文章甲'), findsOneWidget);
    expect(find.text('发布乙'), findsNothing);
    await openFilters();
    await tester.tap(find.byTooltip('重置筛选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('发布乙'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'native directory collects earlier and later HTML pages and applies filters',
    (tester) async {
      final repo = PublicPages({
        'https://huarun.win/vps': listPage('第一页', next: '/vps/page/2'),
        'https://huarun.win/vps/page/2': listPage(
          '跨页条目',
          previous: '/vps',
          next: '/vps/page/3',
          memory: '8',
        ),
        'https://huarun.win/vps/page/3': listPage(
          '最后一页',
          previous: '/vps/page/2',
          memory: '16',
        ),
      });
      final (controller, downloads) = await setup(repo);
      tester.view.physicalSize = const Size(1240, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: SitePage(
            url: 'https://huarun.win/vps/page/2',
            controller: controller,
            downloads: downloads,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('跨页条目'), findsOneWidget);
      await tester.tap(find.text('载入全部页'));
      await tester.pumpAndSettle();
      expect(find.text('已载入 3 条'), findsOneWidget);
      expect(find.text('第一页'), findsOneWidget);
      expect(find.text('最后一页'), findsOneWidget);
      expect(repo.calls, [
        'https://huarun.win/vps/page/2',
        'https://huarun.win/vps',
        'https://huarun.win/vps/page/3',
      ]);
      await tester.tap(find.byKey(const ValueKey('vps-filter-memory')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('vps-memory-4')));
      await tester.pumpAndSettle();
      expect(find.text('匹配 2 / 已载入 3'), findsOneWidget);
      expect(find.text('第一页'), findsNothing);
      await tester.enterText(find.byType(TextField), '跨页');
      await tester.pumpAndSettle();
      expect(find.text('匹配 1 / 已载入 3'), findsOneWidget);
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'airport discovery layout retains public pagination and scoped search',
    (tester) async {
      String airport(String name, {String? next}) =>
          '''
<main><section class="catalog"><h1>机场目录</h1>
<article class="vps-card airport-entry">
<h2><a class="vps-card-link" href="/jichang/$name">$name</a></h2>
<dl><dt>对应月流量</dt><dd>200GB/月</dd></dl>
<p class="airport-product-price">¥20<span class="airport-product-period">月付</span></p>
<a href="/jichang/$name/buy?source=catalog_card">购买</a></article>
${next == null ? '' : '<nav class="airport-pagination"><a href="$next">下一页</a></nav>'}
</section></main>''';
      final repo = PublicPages({
        'https://huarun.win/jichang': airport('首屏机场', next: '/jichang/page/2'),
        'https://huarun.win/jichang/page/2': airport('跨页机场'),
      });
      final (controller, downloads) = await setup(repo);
      tester.view.physicalSize = const Size(1240, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: SitePage(
            url: 'https://huarun.win/jichang',
            controller: controller,
            downloads: downloads,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('机场'), findsOneWidget);
      expect(find.text('已载入 1 条'), findsOneWidget);
      expect(find.text('搜索已载入的机场、套餐或规格'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '跨页');
      await tester.pumpAndSettle();
      expect(find.text('匹配 0 / 已载入 1'), findsOneWidget);
      await tester.tap(find.text('载入全部页'));
      await tester.pumpAndSettle();
      expect(find.text('匹配 1 / 已载入 2'), findsOneWidget);
      expect(find.text('跨页机场'), findsOneWidget);
      expect(find.text('载入全部页'), findsNothing);
      expect(repo.calls, [
        'https://huarun.win/jichang',
        'https://huarun.win/jichang/page/2',
      ]);
      await tester.tap(find.byTooltip('刷新内容'));
      await tester.pumpAndSettle();
      expect(find.text('匹配 0 / 已载入 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'reader searches, opens a folded anchor and displays native code/table',
    (tester) async {
      final repo = PublicPages({
        'https://huarun.win/about': '''
      <main><article class="legal-page"><h1>阅读示例</h1>
      <a href="#target">跳到参考</a><p>前文</p>
      <details><summary>参考资料</summary><section id="target"><h2>目标段落</h2>
      <p>独特关键词</p><pre>sample command</pre>
      <table><tr><th>项目</th><th>状态</th></tr><tr><td>配置</td><td>待核实</td></tr></table>
      </section></details></article></main>''',
      });
      final (controller, downloads) = await setup(repo);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: SitePage(
            url: 'https://huarun.win/about',
            controller: controller,
            downloads: downloads,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('独特关键词'), findsNothing);
      await tester.enterText(find.byType(TextField), '独特关键词');
      await tester.pumpAndSettle();
      expect(find.text('1 处匹配'), findsOneWidget);
      await tester.tap(find.widgetWithText(ListTile, '独特关键词'));
      await tester.pumpAndSettle();
      expect(find.byType(Table), findsOneWidget);
      expect(find.text('sample command'), findsOneWidget);
      expect(find.text('待核实'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.byType(TextField),
        -300,
        scrollable: find.byWidgetPredicate(
          (widget) =>
              widget is Scrollable &&
              widget.axisDirection == AxisDirection.down,
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '待核实');
      await tester.pumpAndSettle();
      expect(find.text('1 处匹配'), findsOneWidget);
      await tester.tap(find.byType(ListTile));
      await tester.pumpAndSettle();
      expect(find.byType(Table), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final route in [
    '/history/apps',
    '/people/rprx',
    '/articles/flclash-install-failed',
    '/protocols',
    '/jichang/naixi',
  ]) {
    testWidgets(
      'published reading layout at phone and desktop widths: $route',
      (tester) async {
        final name = route.substring(1).replaceAll('/', '_');
        final source = html.parse(
          File('test/fixtures/site/$name.html').readAsStringSync(),
        );
        // Image URLs are covered by parser tests; these layout tests stay offline.
        for (final image in source.querySelectorAll('img')) {
          image.remove();
        }
        final repo = PublicPages({
          'https://huarun.win$route': source.outerHtml,
        });
        final (controller, downloads) = await setup(repo);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        Widget app(Brightness brightness) => MaterialApp(
          theme: appTheme(brightness),
          home: SitePage(
            url: 'https://huarun.win$route',
            controller: controller,
            downloads: downloads,
          ),
        );
        await tester.pumpWidget(app(Brightness.light));
        await tester.pumpAndSettle();
        expect(find.text('暂时无法加载'), findsNothing);
        expect(tester.takeException(), isNull);
        tester.view.physicalSize = const Size(1240, 900);
        await tester.pumpWidget(app(Brightness.dark));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }
}
