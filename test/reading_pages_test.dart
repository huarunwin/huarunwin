import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:huarunwin/data/repository.dart';
import 'package:huarunwin/data/site_models.dart';
import 'package:huarunwin/data/site_parser.dart';
import 'package:huarunwin/services/app_controller.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:huarunwin/ui/site_page.dart';
import 'package:huarunwin/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

Iterable<SiteBlock> walk(Iterable<SiteBlock> blocks) sync* {
  for (final block in blocks) {
    yield block;
    yield* walk(block.children);
  }
}

String fixture(String name) =>
    File('test/fixtures/site/$name.html').readAsStringSync();
SiteDocument parse(String name) => PublicSiteParser().parse(
  fixture(name),
  'https://huarun.win/${name.replaceAll('_', '/')}',
);

class ReadingPages extends CatalogRepository {
  ReadingPages(super.directory, this.document);
  final SiteDocument document;
  final pages = <String, SiteDocument>{};
  final requests = <String>[];
  @override
  Future<SiteSnapshot> page(String url, {bool refresh = false}) async {
    requests.add(url);
    return SiteSnapshot(
      pages[Uri.parse(url).removeFragment().toString()] ?? document,
      DateTime(2026, 10, 18),
    );
  }
}

void main() {
  test('person feeds retain their reading type through pagination', () {
    for (final path in ['/people/rprx/feed', '/people/rprx/feed/page/2']) {
      final uri = Uri.parse('https://huarun.win$path');
      expect(SiteRoutes.readingKind(uri), SiteReadingKind.feed);
      expect(SiteRoutes.readingDirectory(uri), isTrue);
    }
    expect(
      SiteRoutes.readingKind(Uri.parse('https://huarun.win/people/rprx')),
      SiteReadingKind.person,
    );
  });

  test(
    'reading headers appear once and preserve searchable metadata and links',
    () {
      for (final name in [
        'people_rprx',
        'articles_flclash-install-failed',
        'cores_mihomo',
        'protocols_vless-reality',
        'feed_candidate-7366114cabbc373809adee8fc1305b0a',
      ]) {
        final doc = parse(name);
        final reading = doc.reading!;
        expect(reading.title, isNotEmpty);
        expect(doc.blocks.first, reading.overview);
        expect(
          walk(doc.blocks).where(
            (block) =>
                block.kind == BlockKind.heading && block.text == reading.title,
          ),
          isEmpty,
        );
        expect(reading.overview.searchable, contains(reading.title));
        for (final value in reading.metadata) {
          expect(reading.overview.searchable, contains(value));
        }
        for (final action in reading.actions) {
          expect(
            reading.overview.runs.map((run) => run.url),
            contains(action.url),
          );
        }
      }
      final article = parse('articles_flclash-install-failed');
      expect(
        walk(article.blocks).where((block) => block.kind == BlockKind.gallery),
        isNotEmpty,
      );
      expect(
        walk(article.blocks)
            .where((block) => block.kind == BlockKind.image)
            .length,
        html
            .parse(fixture('articles_flclash-install-failed'))
            .querySelectorAll('.article-content article img')
            .length,
      );
      expect(
        walk(article.blocks).map((block) => block.ownText).join(' '),
        isNot(contains('点图放大，左右切换')),
      );
    },
  );

  test('every published history event keeps its anchor, date and evidence', () {
    for (final name in ['history_apps', 'history_cores', 'history_protocols']) {
      final doc = parse(name);
      final original = html.parse(fixture(name));
      final events = walk(doc.blocks)
          .where((block) => block.kind == BlockKind.event)
          .toList();
      final guides = walk(doc.blocks).where(
        (block) =>
            block.kind == BlockKind.disclosure &&
            (block.text.startsWith('阅读导览') ||
                block.id == 'current-recommendations'),
      );
      expect(guides, isNotEmpty);
      expect(guides.every((guide) => !guide.open), isTrue);
      expect(events.length, original.querySelectorAll('.history-event').length);
      for (final node in original.querySelectorAll('.history-event')) {
        final block = events.singleWhere((block) => block.id == node.id);
        expect(block.item!.title, isNotEmpty);
        expect(block.item!.date, isNotEmpty);
        expect(block.item!.url, endsWith('#${node.id}'));
        for (final source in node.querySelectorAll(
          '.history-sources a[href]',
        )) {
          final target = Uri.parse(doc.url)
              .resolve(source.attributes['href']!)
              .toString();
          expect(
            walk([block]).expand((child) => child.runs).map((run) => run.url),
            contains(target),
          );
        }
      }
    }
  });

  test(
    'history guides preserve visible lineage nodes and compact app links',
    () {
      final core = parse('history_cores');
      final original = html.parse(fixture('history_cores'));
      final blocks = walk(core.blocks).toList();
      for (final node in original.querySelectorAll(
        '.history-lineage-compact-node',
      )) {
        final block = blocks.singleWhere((block) => block.id == node.id);
        expect(block.item!.title, node.querySelector('strong')!.text);
        expect(block.item!.date, node.querySelector('time')!.text);
        expect(block.item!.summary, node.querySelector('em')!.text);
        final link = node.parent!.querySelector('a');
        expect(
          block.item!.url,
          link == null
              ? ''
              : Uri.parse(core.url)
                    .resolve(link.attributes['href']!)
                    .toString(),
        );
      }
      final apps = parse('history_apps');
      expect(
        walk(apps.blocks)
            .where(
              (block) =>
                  block.kind == BlockKind.related &&
                  block.item!.url.contains('/apps/'),
            )
            .length,
        html
            .parse(fixture('history_apps'))
            .querySelectorAll('a.history-tool-app')
            .length,
      );
      expect(
        walk(apps.blocks)
            .singleWhere((block) => block.id == 'history-year-title-2012')
            .text,
        '2012 · 1 个节点',
      );
    },
  );

  test(
    'people source anchors and related clients survive structured list parsing',
    () {
      final page = parse('people_rprx');
      final original = html.parse(fixture('people_rprx'));
      final blocks = walk(page.blocks).toList();
      for (final source in original.querySelectorAll(
        '.person-source-card[id]',
      )) {
        expect(blocks.any((block) => block.id == source.id), isTrue);
      }
      expect(
        blocks
            .where(
              (block) =>
                  block.kind == BlockKind.related &&
                  block.item!.url.contains('/apps/'),
            )
            .length,
        original.querySelectorAll('.person-related-app-card').length,
      );
      final core = parse('cores_mihomo');
      final originalCore = html.parse(fixture('cores_mihomo'));
      for (final person in originalCore.querySelectorAll(
        '.core-profile-card h3 a[href^="/people/"]',
      )) {
        final url = Uri.parse(core.url)
            .resolve(person.attributes['href']!)
            .toString();
        final related = walk(core.blocks).singleWhere(
          (block) => block.kind == BlockKind.related && block.item!.url == url,
        );
        expect(related.item!.actions, isNotEmpty);
        for (final source in person.parent!.parent!.querySelectorAll(
          'a[href]',
        )) {
          final target = Uri.parse(core.url)
              .resolve(source.attributes['href']!)
              .toString();
          if (target != url) {
            expect(
              related.item!.actions.map((link) => link.url),
              contains(target),
            );
          }
        }
      }
      expect(
        walk(core.blocks)
            .where(
              (block) =>
                  block.kind == BlockKind.related &&
                  block.item!.url.contains('/apps/'),
            )
            .length,
        originalCore.querySelectorAll('.core-profile-app').length,
      );
    },
  );

  test('directory metadata uses published roles, projects, times and protocol conditions', () {
    final people = parse('people');
    expect(people.items.first.facets['群体'], ['时代先驱与核心创立者']);
    expect(people.items.first.badges, contains('Xray-core (Project X)'));
    expect(people.groups.single.links.first.label, '全部人物');
    expect(
      people.blocks.map((block) => block.searchable).join(' '),
      isNot(contains('17 位开拓奠基人')),
    );
    final feed = parse('feed');
    expect(feed.items.first.byline, isNotEmpty);
    expect(feed.items.first.publishedAt, isNotNull);
    expect(feed.groups.single.links.map((link) => link.label), [
      '作者发言',
      '历史回顾',
      '版本发布',
    ]);
    final protocol = parse('protocols');
    expect(protocol.items.first.facts['编辑推荐'], contains('4.5'));
    expect(protocol.items.first.facts['使用前提'], contains('两端支持'));
    expect(protocol.items.first.facts['限制'], contains('不适用于普通 HTTP CDN'));
    expect(
      protocol.blocks.map((block) => block.searchable).join(' '),
      contains('未做跨地区网络实测'),
    );
  });

  test('date sorting keeps unknown dates last and ties in published order', () {
    const unknown = SiteItem(title: '无日期', url: '/unknown');
    final early = SiteItem(
      title: '早',
      url: '/early',
      publishedAt: DateTime.utc(2020),
    );
    final late = SiteItem(
      title: '晚',
      url: '/late',
      publishedAt: DateTime.utc(2026),
    );
    final tie = SiteItem(
      title: '同日',
      url: '/tie',
      publishedAt: DateTime.utc(2026),
    );
    expect(const SiteQuery(sort: 'newest').apply([unknown, early, late, tie]), [
      late,
      tie,
      early,
      unknown,
    ]);
    expect(const SiteQuery(sort: 'oldest').apply([unknown, early, late, tie]), [
      early,
      late,
      tie,
      unknown,
    ]);
  });

  late Directory directory;
  late ReadingPages repository;
  late AppController controller;
  late DownloadManager downloads;

  Future<void> setup(SiteDocument document) async {
    directory = Directory.systemTemp.createTempSync('huarun-reading');
    SharedPreferences.setMockInitialValues({});
    repository = ReadingPages(directory, document);
    controller = AppController(
      repository,
      await SharedPreferences.getInstance(),
    );
    downloads = DownloadManager(directory);
    addTearDown(() {
      controller.dispose();
      repository.client.close(force: true);
      downloads.client.close(force: true);
      downloads.macResolver.client.close(force: true);
      downloads.dispose();
      directory.deleteSync(recursive: true);
    });
  }

  void viewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  for (final name in [
    'feed',
    'people',
    'articles',
    'cores',
    'protocols',
    'history_apps',
    'history_cores',
    'history_protocols',
    'cores_mihomo',
    'protocols_vless-reality',
    'articles_flclash-install-failed',
  ]) {
    testWidgets(
      'public reading content reflows on desktop, phone and large text: $name',
      (tester) async {
        final document = parse(name);
        await setup(document);
        viewport(tester, const Size(1120, 900));
        Future<void> pump(Brightness brightness, double scale) async {
          await tester.pumpWidget(
            MaterialApp(
              theme: appTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: SitePage(
                url: document.url,
                controller: controller,
                downloads: downloads,
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }

        await pump(Brightness.light, 1);
        tester.view.physicalSize = const Size(390, 844);
        await pump(Brightness.dark, 1);
        tester.view.physicalSize = const Size(340, 844);
        await pump(Brightness.light, 1.8);
      },
    );
  }

  testWidgets(
    'editorial categories and pagination preserve the embedded page',
    (tester) async {
      const origin = 'https://huarun.win';
      const groups = [
        SiteLinkGroup('动态分类', [
          SiteLink('作者发言', '$origin/feed', selected: true),
          SiteLink('版本发布', '$origin/feed/releases'),
        ]),
      ];
      const initial = SiteDocument(
        url: '$origin/feed',
        title: '生态动态',
        directory: true,
        groups: groups,
        items: [SiteItem(title: '作者发言示例', url: '$origin/feed/author')],
      );
      const releases = SiteDocument(
        url: '$origin/feed/releases',
        title: '版本发布',
        directory: true,
        nextUrl: '$origin/feed/releases/page/2',
        pagination: [SiteLink('下一页', '$origin/feed/releases/page/2')],
        items: [SiteItem(title: '版本发布示例', url: '$origin/feed/release')],
      );
      const second = SiteDocument(
        url: '$origin/feed/releases/page/2',
        title: '版本发布第二页',
        directory: true,
        previousUrl: '$origin/feed/releases',
        items: [SiteItem(title: '第二页的版本', url: '$origin/feed/release-2')],
      );
      await setup(initial);
      repository.pages.addAll({releases.url: releases, second.url: second});
      viewport(tester, const Size(1120, 900));
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: SitePage(
            url: initial.url,
            controller: controller,
            downloads: downloads,
            embedded: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '保留不到下一分类的搜索');
      await tester.tap(find.byTooltip('动态分类'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('版本发布').last);
      await tester.pumpAndSettle();
      expect(find.byType(SitePage), findsOneWidget);
      expect(find.text('版本发布示例'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '',
      );
      await tester.ensureVisible(find.text('下一页'));
      await tester.tap(find.text('下一页'));
      await tester.pumpAndSettle();
      expect(find.byType(SitePage), findsOneWidget);
      expect(find.text('第二页的版本'), findsOneWidget);
      expect(repository.requests, [initial.url, releases.url, second.url]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'directory anchors open both supplementary notes and inner disclosure',
    (tester) async {
      final document = PublicSiteParser().parse('''
      <main><article class="history-page"><h1>协议选型</h1>
      <div class="core-profile-grid"><a class="core-profile-card" href="/protocols/example"><h2>协议示例</h2><p>简介</p></a></div>
      <details><summary>评分方法</summary><h2 id="method">公开评分依据示例</h2><p>基于公开设计</p></details>
      </article></main>
    ''', 'https://huarun.win/protocols');
      await setup(document);
      viewport(tester, const Size(390, 844));
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: SitePage(
            url: '${document.url}#method',
            controller: controller,
            downloads: downloads,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('公开评分依据示例').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'history changes chronological order and jumps to the chosen year',
    (tester) async {
      final document = parse('history_apps');
      final events =
          walk(document.blocks)
              .where((block) => block.kind == BlockKind.event)
              .toList()
            ..sort(
              (a, b) => a.item!.publishedAt!.compareTo(b.item!.publishedAt!),
            );
      final early = find.text(events.first.item!.title);
      final late = find.text(events.last.item!.title);
      await setup(document);
      viewport(tester, const Size(1120, 900));
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: SitePage(
            url: document.url,
            controller: controller,
            downloads: downloads,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(early).dy, lessThan(tester.getTopLeft(late).dy));
      await tester.tap(find.byTooltip('时间阅读顺序'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('最新优先').last);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(late).dy, lessThan(tester.getTopLeft(early).dy));
      await tester.tap(find.byTooltip('跳至年份'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2012').last);
      await tester.pumpAndSettle();
      expect(early.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reader search opens a folded source and Escape respects upper routes',
    (tester) async {
      final document = PublicSiteParser().parse(
        '''<main><article class="history-page">
      <div class="article-content"><article><header><h1>阅读示例</h1><p class="lead">公开简介</p></header>
      <section><h2 id="chapter">章节</h2>${List.generate(25, (i) => '<p>正文段落 $i</p>').join()}
      <details><summary>来源考据</summary><p id="evidence">唯一考据文本</p></details></section>
      </article></div></article></main>''',
        'https://huarun.win/articles/example',
      );
      await setup(document);
      viewport(tester, const Size(390, 844));
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => SitePage(
                      url: document.url,
                      controller: controller,
                      downloads: downloads,
                    ),
                  ),
                ),
                child: const Text('打开阅读'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开阅读'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      await tester.tap(find.byTooltip('阅读目录'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('阅读示例'), findsOneWidget);
      await tester.tap(find.byTooltip('查找正文'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '唯一考据文本');
      await tester.pumpAndSettle();
      expect(find.text('1 处匹配'), findsOneWidget);
      await tester.tap(find.widgetWithText(ListTile, '唯一考据文本'));
      await tester.pumpAndSettle();
      expect(find.text('唯一考据文本').hitTestable(), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('打开阅读'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('long source sections land with their heading visible', (
    tester,
  ) async {
    final document = parse('people_rprx');
    final sourceLink = document.reading!.actions.firstWhere(
      (link) => link.label.contains('项考据'),
    );
    await setup(document);
    viewport(tester, const Size(390, 844));
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: SitePage(
          url: document.url,
          controller: controller,
          downloads: downloads,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(sourceLink.label));
    await tester.pumpAndSettle();
    expect(find.text('一手来源与考据').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'article image preview browses original images without leaving the reader',
    (tester) async {
      final document = parse('articles_flclash-install-failed');
      await setup(document);
      viewport(tester, const Size(1120, 900));
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: SitePage(
            url: document.url,
            controller: controller,
            downloads: downloads,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final image = find.byWidgetPredicate(
        (widget) =>
            widget is CachedNetworkImage &&
            widget.imageUrl.contains('01-install-blocked'),
      );
      await tester.ensureVisible(image);
      await tester.pumpAndSettle();
      await tester.tap(
        find.ancestor(of: image, matching: find.byType(InkWell)).first,
      );
      await tester.pumpAndSettle();
      final count = walk(document.blocks)
          .where((block) => block.kind == BlockKind.image)
          .length;
      expect(find.text('1 / $count'), findsOneWidget);
      await tester.tap(find.byTooltip('下一张'));
      await tester.pumpAndSettle();
      expect(find.text('2 / $count'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byTooltip('关闭预览'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
