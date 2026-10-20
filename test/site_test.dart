import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/html_parser.dart';
import 'package:huarunwin/data/repository.dart';
import 'package:huarunwin/data/site_models.dart';
import 'package:huarunwin/data/site_parser.dart';

import 'repository_test.dart' show HtmlAdapter;

Iterable<SiteBlock> walk(Iterable<SiteBlock> blocks) sync* {
  for (final block in blocks) {
    yield block;
    yield* walk(block.children);
  }
}

String fixture(String name) =>
    File('test/fixtures/site/$name.html').readAsStringSync();
SiteDocument parse(String name, [String? route]) => PublicSiteParser().parse(
  fixture(name),
  'https://huarun.win/${route ?? name.replaceAll('_', '/')}',
);

void main() {
  final manifest = jsonDecode(
    File('test/fixtures/site/manifest.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  for (final entry in manifest.entries) {
    if (!SiteRoutes.isNative(Uri.parse(entry.value as String))) continue;
    test('published HTML: ${entry.key}', () {
      final page = PublicSiteParser().parse(
        File('test/fixtures/site/${entry.key}').readAsStringSync(),
        entry.value as String,
      );
      expect(page.title, isNotEmpty);
      expect(page.items.isNotEmpty || page.blocks.isNotEmpty, isTrue);
      expect(
        page.items.every((i) => Uri.parse(i.url).host == 'huarun.win'),
        isTrue,
      );
    });
  }

  test('VPS quotes retain currency, period, hardware and affiliate query', () {
    final page = parse('vps');
    final item = page.items.first;
    expect(item.facts['官方报价'], contains('CAD'));
    expect(item.price, 23.61);
    expect(item.memory, 1);
    expect(item.facets['地区'], contains('韩国'));
    expect(
      item.actions.single.url,
      'https://app.vmiss.com/aff.php?aff=6751&pid=62',
    );
    expect(page.nextUrl, 'https://huarun.win/vps/page/2');
    expect(
      page.groups.expand((g) => g.links).map((l) => l.url),
      contains('https://huarun.win/vps/topics/cn2-gia'),
    );
  });

  test('airports retain purchase redirect and distinguish monthly quota', () {
    final item = parse('jichang').items.first;
    expect(item.price, 123.33);
    expect(item.traffic, 500);
    expect(
      item.actions.single.url,
      'https://huarun.win/jichang/naixi/buy?source=catalog_card',
    );
    final blocks = walk(parse('jichang_naixi').blocks).toList();
    expect(
      blocks.map((b) => b.searchable).join(' '),
      contains('Smart Access 186天'),
    );
    expect(blocks.map((b) => b.searchable).join(' '), contains('割接通知'));
    expect(
      blocks.expand((b) => b.runs).map((r) => r.url),
      contains('https://huarun.win/jichang/naixi/buy?source=detail_primary'),
    );
  });

  test('people, release feed, rules, articles and protocol evidence are native data', () {
    expect(parse('people').items.first.facets['技术领域'], ['协议与传输']);
    expect(parse('rules').items.first.facets['适配环境'], contains('Shadowrocket'));
    expect(parse('feed').items.first.url, contains('/feed/candidate-'));
    expect(parse('feed_releases').items, isNotEmpty);
    expect(
      parse('articles').items.single.url,
      contains('/articles/flclash-install-failed'),
    );
    final protocol = walk(parse('protocols').blocks).toList();
    expect(protocol.any((b) => b.kind == BlockKind.disclosure), isTrue);
    expect(
      protocol.expand((b) => b.runs).map((r) => r.url),
      contains('https://github.com/XTLS/REALITY'),
    );
  });

  test('semantic reader preserves anchors, rich nested links, code and table cells', () {
    final page = PublicSiteParser().parse(
      '''<main><article class="legal-page">
      <h1>说明</h1><section id="guide"><h2>指南</h2>
      <a href="/rules/example?target=mac#usage"><div><strong>官方规则</strong><p>查看说明</p></div></a>
      <pre><code>echo &lt;hello&gt;\nnext</code></pre>
      <table><tr><th>字段</th><th>值</th></tr><tr><td>链接</td><td><a href="?x=1&amp;y=2">来源</a></td></tr></table>
      <details><summary>参考</summary><p>缺失、待核实</p></details>
      <p><em>斜体</em><del>已撤回</del></p>
      <script>privateState()</script><button>JS only</button></section></article></main>''',
      'https://huarun.win/about',
    );
    final blocks = walk(page.blocks).toList();
    expect(blocks.any((b) => b.id == 'guide'), isTrue);
    expect(
      blocks.expand((b) => b.runs).where((r) => r.text == '官方规则').single.url,
      'https://huarun.win/rules/example?target=mac#usage',
    );
    expect(
      blocks.where((b) => b.kind == BlockKind.code).single.text,
      'echo <hello>\nnext',
    );
    expect(
      blocks
          .where((b) => b.kind == BlockKind.table)
          .single
          .rows
          .last
          .last
          .single
          .url,
      'https://huarun.win/about?x=1&y=2',
    );
    expect(blocks.first.searchable, isNot(contains('privateState')));
    expect(blocks.map((b) => b.text).join(), isNot(contains('JS only')));
    expect(
      blocks.expand((b) => b.runs).singleWhere((r) => r.text == '已撤回').struck,
      isTrue,
    );
    expect(
      blocks.expand((b) => b.runs).singleWhere((r) => r.text == '斜体').italic,
      isTrue,
    );
  });

  test(
    'numeric filters exclude unknowns, preserve ties and use all search words',
    () {
      const known = SiteItem(
        title: 'Mac 规则',
        url: '/a',
        summary: 'Mihomo 配置',
        price: 5,
        memory: 2,
        facets: {
          '周期': ['月付'],
        },
      );
      const same = SiteItem(title: 'Mac 方案', url: '/b', price: 5, memory: 4);
      const unknown = SiteItem(title: 'Unknown', url: '/c');
      expect(const SiteQuery(sort: 'price').apply([unknown, known, same]), [
        known,
        same,
        unknown,
      ]);
      expect(const SiteQuery(text: 'mac mihomo').apply([same, known]), [known]);
      expect(const SiteQuery(minimumPrice: 5).apply([unknown, known]), isEmpty);
      expect(const SiteQuery(maximumPrice: 5).apply([unknown, known]), [known]);
      expect(const SiteQuery(minimumMemory: 3).apply([unknown, same, known]), [
        same,
      ]);
      expect(
        const SiteQuery(facets: {'周期': '月付'}).apply([unknown, same, known]),
        [known],
      );
    },
  );

  test(
    'public page cache survives malformed refresh; queries have distinct keys',
    () async {
      final dir = await Directory.systemTemp.createTemp('huarun-public-cache');
      addTearDown(() => dir.delete(recursive: true));
      final adapter = HtmlAdapter(fixture('vps'));
      final repo = CatalogRepository(
        dir,
        client: Dio()..httpClientAdapter = adapter,
      );
      final first = await repo.page('https://huarun.win/vps?billing=monthly');
      expect(first.cached, isFalse);
      expect(
        (await repo.page('https://huarun.win/vps?billing=monthly#top')).cached,
        isTrue,
      );
      expect(adapter.calls, 1);
      await repo.page('https://huarun.win/vps?billing=yearly');
      expect(adapter.calls, 2);
      adapter.body = '<main><h1>Maintenance</h1></main>';
      final fallback = await repo.page(
        'https://huarun.win/vps?billing=monthly',
        refresh: true,
      );
      expect(fallback.warning, isNotNull);
      expect(fallback.at, first.at);
      expect(fallback.document.items.first.url, first.document.items.first.url);
      expect(
        (await repo.page('https://huarun.win/vps?billing=monthly')).cached,
        isTrue,
      );
    },
  );

  test('online-only actions and arbitrary endpoints are never fetched as native pages', () async {
    final dir = await Directory.systemTemp.createTemp('huarun-route-test');
    addTearDown(() => dir.delete(recursive: true));
    final adapter = HtmlAdapter(fixture('vps'));
    final repo = CatalogRepository(
      dir,
      client: Dio()..httpClientAdapter = adapter,
    );
    for (final route in [
      '/account',
      '/corrections',
      '/master',
      '/api/feed',
      '/jichang/naixi/buy?source=x',
    ]) {
      expect(
        repo.page('https://huarun.win$route'),
        throwsA(isA<PageFormatException>()),
      );
    }
    expect(
      repo.page('https://evil.test/people'),
      throwsA(isA<PageFormatException>()),
    );
    expect(adapter.calls, 0);
  });
}
