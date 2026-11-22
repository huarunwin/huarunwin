import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/catalog_filters.dart';
import 'package:huarunwin/data/html_parser.dart';
import 'package:huarunwin/data/models.dart';
import 'package:huarunwin/data/repository.dart';
import 'package:huarunwin/main.dart';
import 'package:huarunwin/ui/page_components.dart';
import 'package:huarunwin/services/app_controller.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:huarunwin/ui/app_download_button.dart';
import 'package:huarunwin/ui/catalog_controls.dart';
import 'package:huarunwin/ui/compact_navigation.dart';
import 'package:huarunwin/ui/components.dart';
import 'package:shared_preferences/shared_preferences.dart';

const examples = [
  CatalogApp(
    id: 'multi',
    name: 'Multi Example',
    url: 'https://huarun.win/apps/multi',
    core: '多内核',
    platforms: ['macOS', 'Android'],
    source: '开源',
    price: '免费',
    priceCategory: '免费',
    starCount: 100,
    starsToday: 0,
    stars7Days: 2,
    stars30Days: 80,
    ratingCount: 0,
  ),
  CatalogApp(
    id: 'single',
    name: 'Single Example',
    url: 'https://huarun.win/apps/single',
    core: 'Mihomo',
    platforms: ['macOS'],
    source: '开源',
    price: '免费下载',
    priceCategory: '待核实',
    starCount: 50,
    starsToday: 4,
    stars7Days: 5,
    stars30Days: 50,
  ),
  CatalogApp(
    id: 'paid',
    name: 'Paid Example',
    url: 'https://huarun.win/apps/paid',
    core: '自研',
    platforms: ['iOS'],
    source: '未公开',
    price: r'$2.99',
    priceCategory: '付费',
    ratingCount: 20,
  ),
];

class FilterRepository extends CatalogRepository {
  FilterRepository(super.directory);
  int coreCalls = 0, detailCalls = 0;
  @override
  Future<CatalogSnapshot> catalog({bool refresh = false, String? core}) async {
    if (core != null) coreCalls++;
    return CatalogSnapshot(
      core == null ? examples : [examples.first],
      DateTime.now(),
    );
  }

  @override
  Future<DetailSnapshot> detail(CatalogApp app, {bool refresh = false}) async {
    detailCalls++;
    return DetailSnapshot(
      AppDetails(
        app: app,
        updatedAt: app.id == 'single' ? '2026-10-17' : '2026-10-01',
      ),
      DateTime.now(),
    );
  }
}

class DelayedDetails extends FilterRepository {
  DelayedDetails(super.directory);
  final requests = <Completer<DetailSnapshot>>[];
  @override
  Future<DetailSnapshot> detail(CatalogApp app, {bool refresh = false}) {
    final result = Completer<DetailSnapshot>();
    requests.add(result);
    return result.future;
  }
}

void main() {
  test('HTML prices and exact metrics preserve unknowns and avoid duplicate mobile counts', () {
    final apps = SiteHtmlParser().catalog('''
      <article class="app-card"><a href="/apps/restricted"><h2>Restricted</h2></a>
        <span class="source open">源码公开 · 许可受限</span><span class="price paid">免费下载</span>
        <span class="card-action-subtext">待核实</span>
        <dl aria-label="GitHub Star 统计" title="source observation"><div><dt>7日</dt><dd>+1,234</dd></div><div><dt>总 Star</dt><dd>22,000</dd></div></dl>
        <dl class="card-app-store-metrics"><div><dt>评分数</dt><dd>0</dd></div></dl>
        <dl class="card-mobile-store-metrics"><div><dt>评分数</dt><dd>0</dd></div></dl>
      </article>
      <article class="app-card"><a href="/apps/missing"><h2>Missing</h2></a>
        <dl aria-label="GitHub Star 统计"><div><dt>7日</dt><dd data-missing="true">—</dd></div></dl>
      </article>
      <article class="app-card"><a href="/apps/percent"><h2>Percent</h2></a>
        <span class="price paid">\$2.99</span>
        <dl aria-label="GitHub Star 统计"><div><dt>7日</dt><dd>+2.4%</dd></div></dl>
      </article>''');
    expect(apps.first.sourceCategory, '开源');
    expect(apps.first.priceCategory, '待核实');
    expect(apps.first.stars7Days, 1234);
    expect(apps.first.starCount, 22000);
    expect(apps.first.ratingCount, 0);
    expect(apps[1].stars7Days, isNull);
    expect(apps[1].priceCategory, isNull);
    expect(apps[2].stars7Days, isNull);
    expect(apps[2].priceCategory, '付费');
    expect(filterCatalog(apps, price: '免费'), isEmpty);
    expect(CatalogApp.fromJson(apps.first.toJson()).stars7Days, 1234);
  });

  test(
    '7-day store rating changes read signed values from either card block',
    () {
      final apps = SiteHtmlParser().catalog('''
      <article class="app-card"><a href="/apps/change"><h2>Change</h2></a>
        <dl class="card-app-store-metrics" title="App Store US 商店：99,017；观察时间：2026-11-14">
          <div><dt>7日评分变化</dt><dd>+1,234</dd></div>
          <div><dt>评分数</dt><dd>99,017</dd></div>
        </dl>
        <dl class="card-mobile-store-metrics">
          <div><dt>评分数</dt><dd>99,017</dd></div>
          <div><dt>7日变化</dt><dd>+1,234</dd></div>
        </dl>
      </article>
      <article class="app-card"><a href="/apps/negative"><h2>Negative</h2></a>
        <dl class="card-app-store-metrics">
          <div><dt>7日评分变化</dt><dd>-3</dd></div>
          <div><dt>评分数</dt><dd>1,030</dd></div>
        </dl>
      </article>
      <article class="app-card"><a href="/apps/zero"><h2>Zero</h2></a>
        <dl class="card-mobile-store-metrics">
          <div><dt>7日变化</dt><dd>0</dd></div>
          <div><dt>评分数</dt><dd>105</dd></div>
        </dl>
      </article>
      <article class="app-card"><a href="/apps/percent"><h2>Percent</h2></a>
        <dl class="card-app-store-metrics">
          <div><dt>7日评分变化</dt><dd>+2.4%</dd></div>
          <div><dt>评分数</dt><dd>12,357</dd></div>
        </dl>
      </article>
      <article class="app-card"><a href="/apps/missing"><h2>Missing</h2></a>
        <dl class="card-app-store-metrics">
          <div><dt>7日评分变化</dt><dd data-missing="true">—</dd></div>
          <div><dt>评分数</dt><dd>12,357</dd></div>
        </dl>
      </article>''');
      // Desktop and mobile blocks are duplicates, never a sum.
      expect(apps[0].ratingCount, 99017);
      expect(apps[0].ratingCountLabel, '99,017');
      expect(apps[0].ratingChange7Days, 1234);
      expect(apps[0].ratingChangeLabel, '+1,234');
      expect(apps[0].ratingNote, contains('App Store US'));
      expect(apps[1].ratingChange7Days, -3);
      expect(apps[1].ratingChangeLabel, '-3');
      expect(apps[2].ratingChange7Days, 0);
      expect(apps[2].ratingChangeLabel, '0');
      expect(apps[3].ratingChange7Days, isNull);
      expect(apps[3].ratingCount, 12357);
      expect(apps[4].ratingChange7Days, isNull);
      expect(CatalogApp.fromJson(apps[0].toJson()).ratingChange7Days, 1234);
      final detail = SiteHtmlParser().detail(
        '<article class="detail-page"><h1 id="detail-title">Change</h1></article>',
        apps[0],
      );
      expect(detail.app.ratingChange7Days, 1234);
    },
  );

  testWidgets('update date uses the same labelled column as published stats', (
    tester,
  ) async {
    Future<void> metric({
      required String value,
      bool hasDate = true,
      double width = 600,
    }) async => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: width,
            child: Align(
              alignment: Alignment.topLeft,
              child: UpdateDateMetric(value: value, hasDate: hasDate),
            ),
          ),
        ),
      ),
    );

    await metric(value: '2026-11-15');
    expect(find.text('更新日期'), findsOneWidget);
    expect(find.text('2026-11-15'), findsOneWidget);
    final scheme = Theme.of(tester.element(find.text('2026-11-15')))
        .colorScheme;
    final date = tester.widget<Text>(find.text('2026-11-15'));
    // The date is a published figure, not a highlighted sort criterion.
    expect(date.style!.color, scheme.onSurface);
    expect(date.style!.color, isNot(scheme.primary));
    expect(date.style!.fontWeight, FontWeight.w600);
    expect(date.style!.fontSize, 13);
    expect(find.byType(Tooltip), findsNothing);
    // Fixed, left aligned column: the value starts at the caption's edge and
    // stays inside its width rather than stretching across the card.
    expect(
      tester.getRect(find.text('2026-11-15')).left,
      tester.getRect(find.text('更新日期')).left,
    );
    expect(tester.getRect(find.text('2026-11-15')).right, lessThan(90));

    // A date the website did not publish keeps its status text but stays muted.
    await metric(value: '日期未读取', hasDate: false);
    expect(find.text('日期未读取'), findsOneWidget);
    expect(
      tester.widget<Text>(find.text('日期未读取')).style!.color,
      scheme.onSurfaceVariant,
    );
    expect(tester.widget<Text>(find.text('日期未读取')).overflow, isNull);

    // A narrow statistics area keeps the caption and scales the value.
    await metric(value: '2026-11-15', width: 130);
    expect(find.text('更新日期'), findsOneWidget);
    expect(find.text('2026-11-15'), findsOneWidget);
    expect(tester.widget<Text>(find.text('2026-11-15')).overflow, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'store rating metrics hide the change column when no value is published',
    (tester) async {
      Future<void> metrics(CatalogApp app, {double width = 800}) async =>
          tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: width,
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: StoreRatingMetrics(app: app),
                  ),
                ),
              ),
            ),
          );
      const withChange = CatalogApp(
        id: 'change',
        name: 'Change',
        url: 'https://huarun.win/apps/change',
        ratingCount: 99017,
        ratingChange7Days: 192,
        ratingNote: 'App Store US 商店：99,017',
      );
      const countOnly = CatalogApp(
        id: 'count',
        name: 'Count',
        url: 'https://huarun.win/apps/count',
        ratingCount: 12357,
      );
      await metrics(withChange);
      expect(find.text('7日评分变化'), findsOneWidget);
      expect(find.text('+192'), findsOneWidget);
      expect(find.text('评分数'), findsOneWidget);
      expect(find.text('99,017'), findsOneWidget);
      // The footer shows plain figures, with no hover note for the source.
      expect(find.byType(Tooltip), findsNothing);
      // Every published figure stays neutral: the footer carries no colour.
      final scheme = Theme.of(tester.element(find.text('+192'))).colorScheme;
      expect(
        tester.widget<Text>(find.text('+192')).style!.color,
        scheme.onSurface,
      );
      expect(
        tester.widget<Text>(find.text('99,017')).style!.color,
        scheme.onSurface,
      );
      final twoColumnCountLeft = tester.getRect(find.text('评分数')).left;
      // A missing baseline drops the whole column on wide layouts too: no em
      // dash placeholder, and the published count returns to the left edge.
      await metrics(countOnly);
      expect(find.text('7日评分变化'), findsNothing);
      expect(find.text('—'), findsNothing);
      expect(find.text('评分数'), findsOneWidget);
      expect(find.text('12,357'), findsOneWidget);
      // No hover explanation is needed for a column that is not shown.
      expect(find.byType(Tooltip), findsNothing);
      // The count stays neutral and moves one column to the left.
      expect(
        tester.widget<Text>(find.text('12,357')).style!.color,
        scheme.onSurface,
      );
      expect(
        tester.getRect(find.text('评分数')).left,
        lessThan(twoColumnCountLeft - 90),
      );
      // Narrow windows follow the same rule.
      final wideCountLeft = tester.getRect(find.text('评分数')).left;
      tester.view.physicalSize = const Size(460, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await metrics(countOnly, width: 400);
      expect(find.text('7日评分变化'), findsNothing);
      expect(find.text('—'), findsNothing);
      expect(find.text('评分数'), findsOneWidget);
      expect(find.text('12,357'), findsOneWidget);
      expect(tester.getRect(find.text('评分数')).left, closeTo(wideCountLeft, 1));
      // A narrow statistics area in a wide window follows the same rule.
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      await tester.pump();
      await metrics(countOnly, width: 130);
      expect(find.text('7日变化'), findsNothing);
      expect(find.text('—'), findsNothing);
      expect(find.text('评分数'), findsOneWidget);
      expect(find.text('12,357'), findsOneWidget);
      // A published change stays visible even when the area is narrow:
      // short captions stay and values scale instead of being ellipsized.
      await metrics(withChange, width: 130);
      expect(find.text('7日变化'), findsOneWidget);
      expect(find.text('+192'), findsOneWidget);
      expect(find.text('99,017'), findsOneWidget);
      expect(tester.widget<Text>(find.text('99,017')).overflow, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('open source growth metrics show period gain, share and total', (
    tester,
  ) async {
    const app = CatalogApp(
      id: 'growth',
      name: 'Growth',
      url: 'https://huarun.win/apps/growth',
      starCount: 158424,
      starsToday: 4,
      stars7Days: 1528,
      stars30Days: 7287,
      starNote: 'GitHub 观察时间：2026-11-14',
    );
    Future<void> metrics({
      CatalogApp item = app,
      CatalogStarPeriod period = CatalogStarPeriod.week,
      double width = 600,
    }) async => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: width,
            child: Align(
              alignment: Alignment.topLeft,
              child: OpenSourceGrowthMetrics(app: item, period: period),
            ),
          ),
        ),
      ),
    );

    await metrics();
    expect(find.text('7 日新增'), findsOneWidget);
    expect(find.text('7 日新增占比'), findsOneWidget);
    expect(find.text('总 Star'), findsOneWidget);
    expect(find.text('+1,528'), findsOneWidget);
    // A share is a composition, not a growth rate: no plus sign.
    expect(find.text('1.0%'), findsOneWidget);
    expect(find.text('+1.0%'), findsNothing);
    expect(find.text('158,424'), findsOneWidget);
    // Fixed columns keep a steady rhythm and leave the rest of a wide row
    // empty instead of stretching to fill the card: 84 dp + 14 dp gap.
    final firstLeft = tester.getRect(find.text('7 日新增')).left;
    final secondLeft = tester.getRect(find.text('7 日新增占比')).left;
    final thirdLeft = tester.getRect(find.text('总 Star')).left;
    expect(secondLeft - firstLeft, closeTo(98, 1));
    expect(thirdLeft - secondLeft, closeTo(98, 1));
    expect(tester.getRect(find.text('158,424')).right, lessThan(320));
    expect(find.byType(Tooltip), findsNothing);
    // All three figures stay neutral; no sort column is colour-coded.
    final scheme = Theme.of(tester.element(find.text('+1,528'))).colorScheme;
    for (final value in ['+1,528', '1.0%', '158,424']) {
      expect(
        tester.widget<Text>(find.text(value)).style!.color,
        scheme.onSurface,
      );
    }
    // The period drives both the gain and the share; the total stays published.
    await metrics(period: CatalogStarPeriod.month);
    expect(find.text('30 日新增'), findsOneWidget);
    expect(find.text('30 日新增占比'), findsOneWidget);
    expect(find.text('+7,287'), findsOneWidget);
    expect(find.text('4.6%'), findsOneWidget);
    expect(find.text('158,424'), findsOneWidget);
    // Unknown values stay visible instead of becoming zeros.
    await metrics(
      item: const CatalogApp(
        id: 'unknown',
        name: 'Unknown',
        url: 'https://huarun.win/apps/unknown',
      ),
    );
    expect(find.text('—'), findsNWidgets(3));
    // Narrow cards keep all three figures with short captions, without an
    // extra info affordance at the end of the row.
    await metrics(width: 200);
    expect(find.text('7日'), findsOneWidget);
    expect(find.text('占比'), findsOneWidget);
    expect(find.text('Star'), findsOneWidget);
    expect(find.text('+1,528'), findsOneWidget);
    expect(find.byIcon(Icons.info_outline_rounded), findsNothing);
    // Neither the sorting notice nor the published title is shown on cards.
    expect(find.byType(Tooltip), findsNothing);
    expect(find.textContaining('网站原始标题'), findsNothing);
    // With the download button beside the figures, the statistics area can be
    // much narrower: short captions stay and long values scale, never clip.
    await metrics(width: 130);
    expect(find.text('7日'), findsOneWidget);
    expect(find.text('占比'), findsOneWidget);
    expect(find.text('Star'), findsOneWidget);
    expect(find.text('158,424'), findsOneWidget);
    expect(tester.widget<Text>(find.text('158,424')).overflow, isNull);
    expect(
      find.ancestor(of: find.text('158,424'), matching: find.byType(FittedBox)),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  test('combined filters use authoritative core membership, not the multi-core label', () {
    expect(
      filterCatalog(
        examples,
        platform: 'macOS',
        source: '开源',
        price: '免费',
        query: 'multi example',
        coreIds: {'client:multi'},
      ).map((app) => app.id),
      ['multi'],
    );
    expect(filterCatalog(examples, price: '待核实').map((app) => app.id), [
      'single',
    ]);
    expect(filterCatalog(examples, price: '付费').map((app) => app.id), ['paid']);
    expect(
      filterCatalog(examples, coreIds: {'client:multi'}, price: '付费'),
      isEmpty,
    );
  });

  test('sorts preserve ties, known zeroes and missing dates, and place withdrawn apps last', () {
    final all = [
      ...examples,
      const CatalogApp(
        id: 'tie',
        name: 'Tie',
        url: 'https://huarun.win/apps/tie',
        source: '开源',
        stars7Days: 2,
        ratingCount: 0,
      ),
      const CatalogApp(
        id: 'gone',
        name: 'Gone',
        url: 'https://huarun.win/apps/gone',
        source: '开源',
        stars7Days: 100,
        ratingCount: 100,
        withdrawn: true,
      ),
    ];
    expect(filterCatalog(all, sort: CatalogSort.stars).map((app) => app.id), [
      'single',
      'multi',
      'tie',
      'gone',
    ]);
    expect(filterCatalog(all, sort: CatalogSort.ratings).map((app) => app.id), [
      'paid',
      'multi',
      'tie',
      'gone',
    ]);
    expect(
      filterCatalog(
        all,
        sort: CatalogSort.updated,
        updateDates: {
          'client:multi': DateTime(2026, 10, 1),
          'client:single': DateTime(2026, 10, 17),
        },
      ).map((app) => app.id),
      ['single', 'multi', 'paid', 'tie', 'gone'],
    );
    expect(catalogDate('2026-02-30'), isNull);
    expect(catalogDate('2026-10-17T00:00:00Z'), DateTime(2026, 10, 17));
  });

  late Directory folder;
  late FilterRepository repository;
  late AppController controller;
  late DownloadManager downloads;
  setUp(() async {
    folder = Directory.systemTemp.createTempSync('huarun-filters');
    SharedPreferences.setMockInitialValues({'catalogPlatform': '全部'});
    repository = FilterRepository(folder);
    controller = AppController(
      repository,
      await SharedPreferences.getInstance(),
    );
    controller.snapshot = CatalogSnapshot(examples, DateTime.now());
    downloads = DownloadManager(folder);
  });
  tearDown(() async {
    controller.dispose();
    repository.client.close(force: true);
    downloads.client.close(force: true);
    downloads.macResolver.client.close(force: true);
    downloads.dispose();
    await folder.delete(recursive: true);
  });

  test(
    'date loading is on demand, bounded, stoppable, and retries failures',
    () async {
      final delayed = DelayedDetails(folder);
      final state = AppController(
        delayed,
        await SharedPreferences.getInstance(),
      );
      final apps = [
        for (var i = 0; i < 8; i++)
          CatalogApp(id: '$i', name: '$i', url: 'https://huarun.win/apps/$i'),
      ];
      expect(delayed.requests, isEmpty);
      final loading = state.loadUpdateDates(apps);
      expect(delayed.requests, hasLength(4));
      state.stopDateLoading();
      final retry = state.loadUpdateDates(apps.take(1).toList());
      // Starting a new selection must still respect the global request limit.
      expect(delayed.requests, hasLength(4));
      for (final request in delayed.requests) {
        request.complete(
          DetailSnapshot(AppDetails(app: apps.first), DateTime.now()),
        );
      }
      await loading;
      await Future<void>.delayed(Duration.zero);
      expect(delayed.requests, hasLength(5));
      expect(state.loadingDates, isTrue);
      delayed.requests.last.completeError(const SocketException('offline'));
      await retry;
      expect(state.updateDateFailures, {'client:0'});
      final recover = state.loadUpdateDates(apps.take(1).toList(), retry: true);
      delayed.requests.last.complete(
        DetailSnapshot(
          AppDetails(app: apps.first, updatedAt: '2026-10-17'),
          DateTime.now(),
        ),
      );
      await recover;
      expect(state.updateDates['client:0'], DateTime(2026, 10, 17));
      expect(state.updateDateFailures, isEmpty);
      state.dispose();
      delayed.client.close(force: true);
    },
  );

  Future<void> mount(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      HuarunApp(controller: controller, downloads: downloads),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'desktop combines filters, preserves multi-core apps and switches views',
    (tester) async {
      await mount(tester, const Size(1240, 900));
      expect(repository.detailCalls, 0);
      await tester.tap(find.byKey(const ValueKey('catalog-filter-内核')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('filter-内核-Xray')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('catalog-filter-价格')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('filter-价格-免费')));
      await tester.pumpAndSettle();
      expect(find.text('Multi Example'), findsOneWidget);
      expect(find.text('Single Example'), findsNothing);
      expect(repository.coreCalls, 1);
      await tester.tap(find.byTooltip('列表视图'));
      await tester.pumpAndSettle();
      expect(controller.catalogGrid, false);
      expect(controller.preferences.getBool('catalogGrid'), false);
      expect(find.text('Multi Example'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('catalog-sort-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sort-updated')));
      await tester.pumpAndSettle();
      expect(repository.detailCalls, 1);
      expect(find.text('2026-10-01'), findsOneWidget);
      expect(find.text('更新日期'), findsWidgets);
      final dateScheme = Theme.of(tester.element(find.text('2026-10-01')))
          .colorScheme;
      expect(
        tester.widget<Text>(find.text('2026-10-01')).style!.color,
        dateScheme.onSurface,
      );
      expect(
        tester.widget<Text>(find.text('2026-10-01')).style!.color,
        isNot(dateScheme.primary),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop list view keeps the figures beside a centred download action',
    (tester) async {
      await mount(tester, const Size(1240, 900));
      await tester.tap(find.byTooltip('列表视图'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('catalog-sort-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sort-stars')));
      await tester.pumpAndSettle();

      final stats = find.byType(OpenSourceGrowthMetrics).first;
      final card = find.ancestor(of: stats, matching: find.byType(Card)).first;
      final button = find.descendant(
        of: card,
        matching: find.byType(AppDownloadButton),
      );
      expect(button, findsOneWidget);
      final statsRect = tester.getRect(stats);
      final buttonRect = tester.getRect(button);
      // One row: the compact left-aligned group sits immediately before the
      // action, and both share the same vertical centre in the list card.
      expect(statsRect.right, lessThan(buttonRect.left));
      expect(buttonRect.left - statsRect.right, lessThan(40));
      expect(statsRect.center.dy, closeTo(buttonRect.center.dy, 2));
      final first = find.descendant(of: stats, matching: find.text('7 日新增'));
      final second = find.descendant(of: stats, matching: find.text('7 日新增占比'));
      final third = find.descendant(of: stats, matching: find.text('总 Star'));
      expect(first, findsOneWidget);
      expect(second, findsOneWidget);
      expect(third, findsOneWidget);
      expect(
        tester.getRect(second).left - tester.getRect(first).left,
        closeTo(98, 1),
      );
      expect(
        tester.getRect(third).left - tester.getRect(second).left,
        closeTo(98, 1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop list view keeps the same row when text grows on a narrow window',
    (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await mount(tester, const Size(940, 600));
      await tester.tap(find.byTooltip('列表视图'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('catalog-sort-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sort-stars')));
      await tester.pumpAndSettle();

      final stats = find.byType(OpenSourceGrowthMetrics).first;
      final card = find.ancestor(of: stats, matching: find.byType(Card)).first;
      final button = find.descendant(
        of: card,
        matching: find.byType(AppDownloadButton),
      );
      expect(button, findsOneWidget);
      expect(
        tester.getRect(stats).right,
        lessThan(tester.getRect(button).left),
      );
      expect(
        tester.getRect(stats).center.dy,
        closeTo(tester.getRect(button).center.dy, 2),
      );
      // Large text falls back to equal columns instead of overflowing the
      // fixed-height list card.
      expect(find.text('7 日新增'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop heat sorting shares filter styling and exposes period and metric menus',
    (tester) async {
      await mount(tester, const Size(1240, 900));
      await tester.tap(find.byTooltip('列表视图'));
      await tester.pumpAndSettle();
      final sorting = find.byKey(const ValueKey('catalog-sort-menu'));
      final menu = tester.widget<CatalogMenu<CatalogSort>>(sorting);
      expect(menu.filled, isTrue);
      expect(menu.icon, isNull);
      expect(
        find.byKey(const ValueKey('catalog-star-period-menu')),
        findsNothing,
      );
      await tester.tap(sorting);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sort-stars')));
      await tester.pumpAndSettle();
      final period = find.byKey(const ValueKey('catalog-star-period-menu'));
      final metric = find.byKey(const ValueKey('catalog-star-metric-menu'));
      expect(
        tester.getRect(period).left,
        greaterThan(tester.getRect(sorting).right),
      );
      expect(
        tester.getRect(metric).left,
        greaterThan(tester.getRect(period).right),
      );
      expect(tester.getRect(period).top, tester.getRect(sorting).top);

      await tester.tap(period);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('star-period-today')));
      await tester.pumpAndSettle();
      expect(find.text('今日新增'), findsWidgets);
      expect(find.text('+4'), findsOneWidget);
      expect(find.text('0.0%'), findsOneWidget);
      await tester.tap(period);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('star-period-month')));
      await tester.pumpAndSettle();
      expect(find.text('30 日新增'), findsWidgets);
      expect(find.text('+80'), findsOneWidget);
      expect(find.text('80.0%'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Multi Example')).dy,
        lessThan(tester.getTopLeft(find.text('Single Example')).dy),
      );

      await tester.tap(metric);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('star-metric-share')));
      await tester.pumpAndSettle();
      expect(find.text('100.0%'), findsOneWidget);
      expect(find.text('80.0%'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Single Example')).dy,
        lessThan(tester.getTopLeft(find.text('Multi Example')).dy),
      );

      await tester.tap(sorting);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sort-comprehensive')));
      await tester.pumpAndSettle();
      expect(period, findsNothing);
      expect(metric, findsNothing);
      await tester.tap(sorting);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sort-stars')));
      await tester.pumpAndSettle();
      expect(find.byTooltip('新增 Star 周期：30 日'), findsOneWidget);
      expect(find.byTooltip('新增 Star 排序依据：新增占比'), findsOneWidget);
      tester.view.physicalSize = const Size(620, 980);
      await tester.pumpAndSettle();
      expect(period.hitTestable(), findsOneWidget);
      expect(metric.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'missing period statistics remain empty and allow returning to comprehensive',
    (tester) async {
      controller.snapshot = CatalogSnapshot([
        const CatalogApp(
          id: 'legacy',
          name: 'Legacy',
          url: 'https://huarun.win/apps/legacy',
          source: '开源',
          stars7Days: 10,
        ),
      ], DateTime.now());
      await mount(tester, const Size(1240, 900));
      await tester.tap(find.byKey(const ValueKey('catalog-sort-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sort-stars')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('catalog-star-period-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('star-period-month')));
      await tester.pumpAndSettle();
      expect(find.text('暂无所选周期的开源统计'), findsOneWidget);
      expect(find.text('Legacy'), findsNothing);
      await tester.tap(find.text('切回综合'));
      await tester.pumpAndSettle();
      expect(find.text('Legacy'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('catalog-star-period-menu')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final largeText in [false, true]) {
    testWidgets(
      'Android heat menus apply selections immediately with large text $largeText',
      (tester) async {
        if (largeText) {
          tester.platformDispatcher.textScaleFactorTestValue = 2;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        }
        await mount(tester, Size(largeText ? 390 : 320, 844));
        await tester.tap(find.byKey(const ValueKey('catalog-sort-menu')));
        await tester.pumpAndSettle();
        final stars = find.byKey(const ValueKey('sort-stars'));
        await tester.ensureVisible(stars);
        await tester.tap(stars);
        await tester.pumpAndSettle();
        final period = find.byKey(const ValueKey('catalog-star-period-menu'));
        await tester.ensureVisible(period);
        await tester.tap(period);
        await tester.pumpAndSettle();
        expect(find.text('确认'), findsNothing);
        await tester.tapAt(const Offset(4, 40));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<CatalogSortControls>(find.byType(CatalogSortControls))
              .starPeriod,
          CatalogStarPeriod.week,
        );
        await tester.tap(period);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('star-period-month')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<CatalogSortControls>(find.byType(CatalogSortControls))
              .starPeriod,
          CatalogStarPeriod.month,
        );
        final metric = find.byKey(const ValueKey('catalog-star-metric-menu'));
        await tester.ensureVisible(metric);
        await tester.tap(metric);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('star-metric-share')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<CatalogSortControls>(find.byType(CatalogSortControls))
              .starMetric,
          CatalogStarMetric.share,
        );
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.android),
    );
  }

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    testWidgets('medium ${platform.name} keeps five inline filter menus', (
      tester,
    ) async {
      await mount(tester, const Size(620, 880));
      expect(find.byType(CompactNavigation), findsOneWidget);
      expect(find.byKey(const ValueKey('catalog-filter-button')), findsNothing);

      void expectSingleRow() {
        final menus = [
          'catalog-type-menu',
          'catalog-platform-menu',
          'catalog-filter-内核',
          'catalog-filter-代码状态',
          'catalog-filter-价格',
        ].map((key) => find.byKey(ValueKey(key)));
        final top = tester.getTopLeft(menus.first).dy;
        for (final menu in menus) {
          expect(menu.hitTestable(), findsOneWidget);
          final rect = tester.getRect(menu);
          expect(rect.top, closeTo(top, 0.1));
          expect(rect.left, greaterThanOrEqualTo(32));
          expect(rect.right, lessThanOrEqualTo(588));
          expect(rect.height, greaterThanOrEqualTo(40));
        }
        expect(tester.takeException(), isNull);
      }

      expectSingleRow();
      await tester.tap(find.byKey(const ValueKey('catalog-filter-代码状态')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('filter-代码状态-源码不完整')));
      await tester.pumpAndSettle();
      expect(find.text('没有找到匹配的应用'), findsOneWidget);
      expect(find.byTooltip('代码状态筛选：源码不完整'), findsOneWidget);
      expectSingleRow();

      tester.view.physicalSize = const Size(1240, 900);
      await tester.pumpAndSettle();
      expect(find.text('代码状态 · 源码不完整'), findsOneWidget);
      tester.view.physicalSize = const Size(620, 880);
      await tester.pumpAndSettle();
      expectSingleRow();
      await tester.tap(find.text('重置筛选'));
      await tester.pumpAndSettle();
      expect(find.text('Multi Example'), findsOneWidget);
      expect(find.text('代码状态'), findsOneWidget);
      expectSingleRow();
    }, variant: TargetPlatformVariant.only(platform));
  }

  testWidgets(
    'inline filters wrap with large text and keep full menu options',
    (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await mount(tester, const Size(620, 980));
      final type = find.byKey(const ValueKey('catalog-type-menu'));
      final source = find.byKey(const ValueKey('catalog-filter-代码状态'));
      expect(
        tester.getTopLeft(source).dy,
        greaterThan(tester.getTopLeft(type).dy),
      );
      await tester.tap(source);
      await tester.pumpAndSettle();
      expect(find.text('源码不完整'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('filter-代码状态-开源')));
      await tester.pumpAndSettle();
      expect(find.text('Multi Example'), findsOneWidget);
      expect(find.text('Paid Example'), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'desktop platform menu sits before core and applies only a chosen option',
    (tester) async {
      await mount(tester, const Size(940, 600));
      final platform = find.byKey(const ValueKey('catalog-platform-menu'));
      final core = find.byKey(const ValueKey('catalog-filter-内核'));
      expect(tester.getRect(platform).top, tester.getRect(core).top);
      expect(
        tester.getRect(platform).right,
        lessThan(tester.getRect(core).left),
      );
      expect(
        find.descendant(of: platform, matching: find.text('平台')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('platform-option-macOS')), findsNothing);

      await tester.tap(platform);
      await tester.pumpAndSettle();
      expect(controller.catalogPlatform, '全部');
      final lastOption = find.byKey(
        const ValueKey('platform-option-Asuswrt-Merlin'),
      );
      await tester.ensureVisible(lastOption);
      expect(lastOption.hitTestable(), findsOneWidget);
      expect(controller.catalogPlatform, '全部');
      await tester.tapAt(const Offset(900, 580));
      await tester.pumpAndSettle();
      expect(controller.catalogPlatform, '全部');
      expect(tester.widget<PageHeader>(find.byType(PageHeader)).title, '发现');

      await tester.tap(platform);
      await tester.pumpAndSettle();
      final mac = find.byKey(const ValueKey('platform-option-macOS'));
      await tester.ensureVisible(mac);
      await tester.tap(mac);
      await tester.pumpAndSettle();
      expect(tester.widget<PageHeader>(find.byType(PageHeader)).title, '发现');
      expect(controller.catalogPlatform, 'macOS');
      expect(find.byTooltip('平台与设备：Mac'), findsOneWidget);
      expect(
        find.descendant(of: platform, matching: find.text('Mac')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'Android platform popup applies selection and stays usable after resize',
    (tester) async {
      await mount(tester, const Size(390, 844));
      await tester.tap(find.byKey(const ValueKey('catalog-platform-menu')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('platform-option-Asuswrt-Merlin')),
      );
      await tester.tap(
        find.byKey(const ValueKey('platform-option-Asuswrt-Merlin')),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('平台与设备：Asuswrt-Merlin'), findsOneWidget);
      expect(tester.widget<PageHeader>(find.byType(PageHeader)).title, '发现');
      await tester.tap(find.byKey(const ValueKey('catalog-platform-menu')));
      await tester.pumpAndSettle();
      expect(
        find
            .byKey(const ValueKey('platform-option-Asuswrt-Merlin'))
            .hitTestable(),
        findsOneWidget,
      );
      await tester.tapAt(const Offset(4, 40));
      await tester.pumpAndSettle();

      tester.view.physicalSize = const Size(1800, 900);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('catalog-platform-menu')),
        findsOneWidget,
      );
      await tester.tap(find.text('重置筛选'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('平台与设备：全部').hitTestable(), findsOneWidget);
      expect(find.text('Multi Example'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'Android platform popup scrolls and dismisses without changing selection',
    (tester) async {
      await mount(tester, const Size(390, 844));
      await tester.tap(find.byKey(const ValueKey('catalog-platform-menu')));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('确认'), findsNothing);
      final all = find.byKey(const ValueKey('platform-option-全部'));
      expect(
        find.descendant(of: all, matching: find.byIcon(Icons.check_rounded)),
        findsOneWidget,
      );
      final last = find.byKey(const ValueKey('platform-option-Asuswrt-Merlin'));
      expect(last.hitTestable(), findsNothing);
      await tester.ensureVisible(last);
      await tester.pumpAndSettle();
      expect(last.hitTestable(), findsOneWidget);
      expect(controller.catalogPlatform, '全部');
      await tester.tapAt(const Offset(4, 40));
      await tester.pumpAndSettle();
      expect(controller.catalogPlatform, '全部');
      await tester.tap(find.byKey(const ValueKey('catalog-platform-menu')));
      await tester.pumpAndSettle();
      expect(all.hitTestable(), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('platform-option-Android')),
        findsNothing,
      );
      expect(controller.catalogPlatform, '全部');
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'Android price filters apply immediately and rating sorting keeps zero',
    (tester) async {
      await mount(tester, const Size(390, 844));
      await tester.tap(find.byKey(const ValueKey('catalog-filter-价格')));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(4, 40));
      await tester.pumpAndSettle();
      expect(find.byTooltip('价格：全部'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('catalog-filter-价格')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('filter-价格-免费')));
      await tester.pumpAndSettle();
      expect(find.byTooltip('价格：免费'), findsOneWidget);
      expect(find.text('Multi Example'), findsOneWidget);
      expect(find.text('Paid Example'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('catalog-sort-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('sort-ratings')));
      await tester.pumpAndSettle();
      expect(find.text('评分数'), findsWidgets);
      expect(find.text('0'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    for (final largeText in [false, true]) {
      testWidgets(
        'Android filter and sort menus remain usable in $mode with large text $largeText',
        (tester) async {
          controller.setTheme(mode);
          if (largeText) {
            tester.platformDispatcher.textScaleFactorTestValue = 2;
            addTearDown(
              tester.platformDispatcher.clearTextScaleFactorTestValue,
            );
          }
          await mount(tester, Size(largeText ? 390 : 320, 844));
          final keys = [
            'catalog-type-menu',
            'catalog-platform-menu',
            'catalog-filter-内核',
            'catalog-filter-代码状态',
            'catalog-filter-价格',
          ];
          final first = tester.getRect(find.byKey(ValueKey(keys.first)));
          for (final key in keys) {
            final rect = tester.getRect(find.byKey(ValueKey(key)));
            expect(rect.top, closeTo(first.top, .1));
            expect(rect.height, greaterThanOrEqualTo(44));
          }
          expect(find.byType(CatalogSortTabs), findsNothing);
          final sorting = find.byKey(const ValueKey('catalog-sort-menu'));
          final sortRect = tester.getRect(sorting);
          expect(sortRect.height, closeTo(first.height, .1));
          expect(sortRect.top, greaterThan(first.bottom));
          await tester.tap(find.byKey(const ValueKey('catalog-platform-menu')));
          await tester.pumpAndSettle();
          final options = tester.widgetList<PopupMenuItem<({String value})>>(
            find.byType(PopupMenuItem<({String value})>),
          );
          expect(options.first.value!.value, '全部');
          expect(options.elementAt(1).value!.value, 'Android');
          expect(find.byType(BottomSheet), findsNothing);
          expect(find.text('确认'), findsNothing);
          await tester.tapAt(const Offset(4, 40));
          await tester.pumpAndSettle();
          expect(controller.catalogPlatform, '全部');
          await tester.tap(find.byKey(const ValueKey('catalog-type-menu')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('type-client')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('catalog-type-menu')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('type-all')));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('catalog-platform-menu')),
            findsOneWidget,
          );
          await tester.tap(find.byKey(const ValueKey('catalog-platform-menu')));
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('platform-option-Android')),
          );
          await tester.pumpAndSettle();
          expect(controller.catalogPlatform, 'Android');
          await tester.ensureVisible(sorting);
          await tester.tap(sorting);
          await tester.pumpAndSettle();
          await tester.tapAt(const Offset(4, 40));
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<CatalogSortControls>(find.byType(CatalogSortControls))
                .sort,
            CatalogSort.comprehensive,
          );
          expect(
            find.byKey(const ValueKey('catalog-star-period-menu')),
            findsNothing,
          );
          await tester.tap(sorting);
          await tester.pumpAndSettle();
          final stars = find.byKey(const ValueKey('sort-stars'));
          await tester.ensureVisible(stars);
          await tester.tap(stars);
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('catalog-star-period-menu')),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('catalog-star-metric-menu')),
            findsOneWidget,
          );
          expect(find.text('Multi Example'), findsOneWidget);
          expect(find.text('Paid Example'), findsNothing);
          expect(tester.takeException(), isNull);
        },
        variant: TargetPlatformVariant.only(TargetPlatform.android),
      );
    }
  }
}
