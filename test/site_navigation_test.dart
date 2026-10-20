import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/models.dart';
import 'package:huarunwin/data/repository.dart';
import 'package:huarunwin/data/site_models.dart';
import 'package:huarunwin/main.dart';
import 'package:huarunwin/services/app_controller.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:huarunwin/ui/airport_catalog.dart';
import 'package:huarunwin/ui/components.dart';
import 'package:huarunwin/ui/site_page.dart';
import 'package:huarunwin/ui/vps_catalog.dart';
import 'package:shared_preferences/shared_preferences.dart';

const airportDocument = SiteDocument(
  url: 'https://huarun.win/jichang',
  title: '机场目录',
  directory: true,
  items: [
    SiteItem(
      title: '示例机场',
      url: 'https://huarun.win/jichang/example',
      facets: {
        '付款周期': ['月付'],
      },
      facts: {'对应月流量': '200GB/月', '付款金额': '¥20月付'},
      price: 20,
      traffic: 200,
    ),
  ],
);

const vpsDocument = SiteDocument(
  url: 'https://huarun.win/vps',
  title: 'VPS 目录',
  directory: true,
  items: [
    SiteItem(
      title: '示例 VPS',
      url: 'https://huarun.win/vps/example/basic',
      facts: {'内存': '2 GB', '官方报价': 'USD 5 / 月', '人民币参考价': '约 ¥35 / 月'},
      memory: 2,
      price: 35,
    ),
  ],
);

class PendingPages extends CatalogRepository {
  PendingPages(super.directory);
  late Completer<SiteSnapshot> pending;
  SiteSnapshot? saved;
  int requests = 0;

  @override
  SiteSnapshot? cachedPage(String url) =>
      saved?.document.url == Uri.parse(url).removeFragment().toString()
      ? saved
      : null;

  @override
  Future<SiteSnapshot> page(String url, {bool refresh = false}) async {
    requests++;
    pending = Completer<SiteSnapshot>();
    return saved = await pending.future;
  }
}

void main() {
  late Directory directory;
  late PendingPages repository;
  late AppController controller;
  late DownloadManager downloads;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('huarun-site-navigation');
    repository = PendingPages(directory);
    SharedPreferences.setMockInitialValues({});
    controller = AppController(
      repository,
      await SharedPreferences.getInstance(),
    );
    controller.snapshot = CatalogSnapshot(const [], DateTime.now());
    downloads = DownloadManager(directory);
  });

  tearDown(() {
    controller.dispose();
    downloads.dispose();
    repository.client.close(force: true);
    directory.deleteSync(recursive: true);
  });

  Future<void> desktop(WidgetTester tester, Widget app) async {
    tester.view.physicalSize = const Size(1240, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(app);
  }

  testWidgets(
    'wide navigation hides reading and technology in expanded and icon sidebars',
    (tester) async {
      await desktop(
        tester,
        HuarunApp(controller: controller, downloads: downloads),
      );
      await tester.pumpAndSettle();
      for (final toggle in ['收起侧边栏', '展开侧边栏']) {
        expect(
          find.byKey(const ValueKey('nav-group-applications')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('nav-site-/vps')), findsOneWidget);
        expect(find.byKey(const ValueKey('nav-site-/jichang')), findsOneWidget);
        for (final group in ['reading', 'technology']) {
          expect(find.byKey(ValueKey('nav-group-$group')), findsNothing);
        }
        for (final path in [
          '/feed',
          '/people',
          '/articles',
          '/history/apps',
          '/history/cores',
          '/history/protocols',
          '/cores',
          '/protocols',
        ]) {
          expect(find.byKey(ValueKey('nav-site-$path')), findsNothing);
        }
        expect(find.text('偏好设置'), findsOneWidget);
        expect(find.text('访问 huarun.win'), findsOneWidget);
        await tester.tap(find.byTooltip(toggle));
        await tester.pumpAndSettle();
      }
      expect(repository.requests, 0);
      expect(tester.takeException(), isNull);
    },
  );

  for (final document in [airportDocument, vpsDocument]) {
    final vps = document == vpsDocument;
    final subject = vps ? 'VPS' : '机场';
    final headingText = subject;
    final itemTitle = document.items.single.title;
    final shellFinder = find.byType(vps ? VpsCatalog : AirportCatalog);
    final prefix = vps ? 'vps' : 'airport';
    final searchField = find.descendant(
      of: shellFinder,
      matching: find.byType(TextField),
    );
    final filterMenu = find.byKey(ValueKey('$prefix-filter-price'));
    final sortMenu = find.byKey(ValueKey('$prefix-sort'));

    testWidgets(
      '$subject tab keeps its shell while loading and restores warm content in the first frame',
      (tester) async {
        await desktop(
          tester,
          HuarunApp(controller: controller, downloads: downloads),
        );
        await tester.tap(find.text(subject));
        await tester.pump();
        expect(shellFinder, findsOneWidget);
        expect(find.byType(AppBar), findsNothing);
        final refreshButton = find.descendant(
          of: find.byType(RefreshIconButton),
          matching: find.byType(IconButton),
        );
        final refreshSize = tester.getSize(refreshButton);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(tester.widget<IconButton>(refreshButton).onPressed, isNull);
        expect(searchField, findsNothing);
        expect(filterMenu, findsNothing);
        expect(sortMenu, findsNothing);
        expect(find.text('已载入 0 条'), findsNothing);
        expect(find.text('没有找到匹配的$subject'), findsNothing);
        final shell = tester.state(shellFinder);
        final heading = tester.getTopLeft(
          find.descendant(of: shellFinder, matching: find.text(headingText)),
        );

        repository.pending.complete(SiteSnapshot(document, DateTime.now()));
        await tester.pumpAndSettle();
        expect(tester.state(shellFinder), same(shell));
        expect(
          tester.getTopLeft(
            find.descendant(of: shellFinder, matching: find.text(headingText)),
          ),
          heading,
        );
        expect(searchField, findsOneWidget);
        final searchPosition = tester.getTopLeft(searchField);
        expect(find.text(itemTitle), findsOneWidget);
        expect(filterMenu, findsOneWidget);
        expect(sortMenu, findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(tester.getSize(refreshButton), refreshSize);
        expect(tester.widget<IconButton>(refreshButton).onPressed, isNotNull);

        await tester.tap(find.byKey(const ValueKey('nav-applications')));
        await tester.pumpAndSettle();
        await tester.tap(find.text(subject));
        await tester.pump();
        expect(find.text(itemTitle), findsOneWidget);
        expect(searchField, findsOneWidget);
        expect(tester.getTopLeft(searchField), searchPosition);
        expect(filterMenu, findsOneWidget);
        expect(sortMenu, findsOneWidget);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(repository.requests, 1);

        await tester.tap(find.byTooltip('刷新内容'));
        await tester.pump();
        expect(find.text(itemTitle), findsOneWidget);
        expect(searchField, findsOneWidget);
        expect(tester.getTopLeft(searchField), searchPosition);
        expect(filterMenu, findsOneWidget);
        expect(sortMenu, findsOneWidget);
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(tester.widget<IconButton>(refreshButton).onPressed, isNull);
        expect(tester.getSize(refreshButton), refreshSize);
        await tester.tap(find.byTooltip('刷新内容'));
        expect(repository.requests, 2);
        repository.pending.completeError(const SocketException('offline'));
        await tester.pumpAndSettle();
        expect(find.text(itemTitle), findsOneWidget);
        expect(find.text('刷新失败，保留当前内容。'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(tester.widget<IconButton>(refreshButton).onPressed, isNotNull);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.macOS),
    );

    testWidgets(
      'initial $subject failure and retry retain the same directory shell',
      (tester) async {
        await desktop(
          tester,
          MaterialApp(
            home: SitePage(
              url: '${document.url}/page/2',
              controller: controller,
              downloads: downloads,
            ),
          ),
        );
        final shell = tester.state(shellFinder);
        repository.pending.completeError(const SocketException('offline'));
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: shellFinder, matching: find.text(headingText)),
          findsOneWidget,
        );
        expect(find.text('暂时无法加载$subject'), findsOneWidget);
        expect(searchField, findsNothing);
        expect(filterMenu, findsNothing);
        expect(sortMenu, findsNothing);
        expect(find.text('没有找到匹配的$subject'), findsNothing);
        expect(find.byType(AppBar), findsNothing);

        await tester.tap(find.text('重试'));
        await tester.pump();
        expect(searchField, findsNothing);
        expect(filterMenu, findsNothing);
        expect(sortMenu, findsNothing);
        repository.pending.complete(SiteSnapshot(document, DateTime.now()));
        await tester.pumpAndSettle();
        expect(tester.state(shellFinder), same(shell));
        expect(find.text(itemTitle), findsOneWidget);
        expect(searchField, findsOneWidget);
        expect(filterMenu, findsOneWidget);
        expect(sortMenu, findsOneWidget);
        expect(repository.requests, 2);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$subject detail still opens the reader instead of the directory shell',
      (tester) async {
        await desktop(
          tester,
          MaterialApp(
            home: SitePage(
              url: document.items.single.url,
              controller: controller,
              downloads: downloads,
            ),
          ),
        );
        expect(shellFinder, findsNothing);
        repository.pending.complete(
          SiteSnapshot(
            SiteDocument(
              url: document.items.single.url,
              title: '示例$subject说明',
              blocks: const [
                SiteBlock(runs: [SiteText('公开详情正文')]),
              ],
            ),
            DateTime.now(),
          ),
        );
        await tester.pumpAndSettle();
        expect(shellFinder, findsNothing);
        expect(find.text('公开详情正文'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
