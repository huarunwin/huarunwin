import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/catalog_filters.dart';
import 'package:huarunwin/data/html_parser.dart';
import 'package:huarunwin/data/models.dart';

void main() {
  final parser = SiteHtmlParser();

  test(
    'period counts use exact HTML values and preserve zero and unknown data',
    () {
      final apps = parser.catalog('''
      <article class="app-card"><a href="/apps/exact"><h2>Exact</h2></a>
        <dl aria-label="GitHub Star 统计" data-stars-today="0" data-stars-7d="1249" data-stars-30d="3000">
          <div><dt>7日</dt><dd>+1,249</dd></div>
          <div><dt>30日</dt><dd>+3.0%</dd></div>
          <div><dt>总 Star</dt><dd>100,000</dd></div>
        </dl>
        <dl aria-label="GitHub Star 统计" data-stars-today="0" data-stars-7d="1249" data-stars-30d="3000">
          <div><dt>7日</dt><dd>+1,249</dd></div>
        </dl>
      </article>
      <article class="app-card"><a href="/apps/legacy"><h2>Legacy</h2></a>
        <dl aria-label="GitHub Star 统计" data-stars-today="-1" data-stars-30d="4.8%">
          <div><dt>7日</dt><dd>+50</dd></div>
          <div><dt>30日</dt><dd>+4.8%</dd></div>
          <div><dt>总 Star</dt><dd>200</dd></div>
        </dl>
      </article>''');
      final exact = apps.first;
      expect(exact.starsToday, 0);
      expect(exact.stars7Days, 1249);
      expect(exact.stars30Days, 3000);
      expect(exact.starCount, 100000);
      expect(apps.last.starsToday, isNull);
      expect(apps.last.stars7Days, 50);
      expect(apps.last.stars30Days, isNull);
      expect(CatalogApp.fromJson(exact.toJson()).toJson(), exact.toJson());
      final legacy = Map<String, dynamic>.from(exact.toJson())
        ..remove('starsToday')
        ..remove('stars30Days');
      expect(CatalogApp.fromJson(legacy).stars7Days, 1249);
      expect(CatalogApp.fromJson(legacy).starsToday, isNull);
      expect(CatalogApp.fromJson(legacy).stars30Days, isNull);
      final detail = parser.detail('''<article class="detail-page">
      <h1 id="detail-title">Exact</h1></article>''', exact);
      expect(detail.app.starsToday, 0);
      expect(detail.app.stars30Days, 3000);
    },
  );

  test(
    'visible period counts parse without treating a percentage as a count',
    () {
      final apps = parser.catalog('''
      <article class="app-card"><a href="/apps/visible"><h2>Visible</h2></a>
        <dl aria-label="GitHub Star 统计">
          <div><dt>今日新增</dt><dd>0</dd></div>
          <div><dt>30 日新增</dt><dd>+240</dd></div>
          <div><dt>新增比例</dt><dd>+2.4%</dd></div>
        </dl>
      </article>''');
      expect(apps.single.starsToday, 0);
      expect(apps.single.stars30Days, 240);
      expect(apps.single.stars7Days, isNull);
    },
  );

  CatalogApp app(
    String id, {
    int? today,
    int? week,
    int? month,
    int? total,
    String source = '开源',
    bool withdrawn = false,
  }) => CatalogApp(
    id: id,
    name: id,
    url: 'https://huarun.win/apps/$id',
    starsToday: today,
    stars7Days: week,
    stars30Days: month,
    starCount: total,
    source: source,
    withdrawn: withdrawn,
  );

  test(
    'period selection keeps actual zeros and never substitutes another period',
    () {
      final apps = [
        app('zero', today: 0, week: 9, month: 400),
        app('today', today: 3, week: 2, month: 10),
        app('missing', week: 100),
        app('negative', today: -1),
        app('closed', today: 100, source: '未公开'),
        app('withdrawn', today: 500, withdrawn: true),
      ];
      expect(
        filterCatalog(
          apps,
          sort: CatalogSort.stars,
          starPeriod: CatalogStarPeriod.today,
        ).map((app) => app.id),
        ['today', 'zero', 'withdrawn'],
      );
      expect(
        filterCatalog(
          apps,
          sort: CatalogSort.stars,
          starPeriod: CatalogStarPeriod.month,
        ).map((app) => app.id),
        ['zero', 'today'],
      );
    },
  );

  test(
    'shares use unrounded count divided by a positive total and stable ties',
    () {
      final apps = [
        app('lower', week: 1241, total: 100000),
        app('higher', week: 1249, total: 100000),
        app('tie', week: 2498, total: 200000),
        app('zero', week: 0, total: 100),
        app('zero-total', week: 0, total: 0),
        app('missing-total', week: 2000),
        app('missing-count', total: 100),
        app('withdrawn', week: 100, total: 100, withdrawn: true),
      ];
      expect(
        filterCatalog(
          apps,
          sort: CatalogSort.stars,
          starMetric: CatalogStarMetric.share,
        ).map((app) => app.id),
        ['higher', 'tie', 'lower', 'zero', 'withdrawn'],
      );
      expect(
        filterCatalog(apps, sort: CatalogSort.stars).map((app) => app.id),
        [
          'tie',
          'missing-total',
          'higher',
          'lower',
          'zero',
          'zero-total',
          'withdrawn',
        ],
      );
    },
  );
}
