import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:huarunwin/data/site_models.dart';
import 'package:huarunwin/data/site_parser.dart';
import 'package:huarunwin/services/app_controller.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:huarunwin/ui/service_detail_components.dart';
import 'package:huarunwin/ui/site_page.dart';
import 'package:huarunwin/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'site_test.dart' show fixture, walk;
import 'site_widget_test.dart' show PublicPages;

void main() {
  test(
    'VPS overview preserves quote, uncertainty and original purchase URL',
    () {
      final doc = PublicSiteParser().parse(
        fixture('vps_vmiss_sel-intl-basic'),
        'https://huarun.win/vps/vmiss/sel-intl-basic',
      );
      final detail = doc.service!;
      expect(detail.title, 'KR.SEL.INTL.Basic');
      expect(detail.price, 'CAD 5.00 / 月');
      expect(detail.referencePrice, contains('23.61'));
      expect(detail.referenceNote, contains('结算以官网原币报价为准'));
      expect(detail.highlights['流量额度'], contains('重置周期未注明'));
      expect(
        detail.purchase!.url,
        'https://app.vmiss.com/aff.php?aff=6751&pid=62',
      );
      final blocks = walk(doc.blocks).toList();
      expect(
        blocks.where((block) => block.kind == BlockKind.offer),
        hasLength(3),
      );
      expect(blocks.any((block) => block.kind == BlockKind.facts), isTrue);
      expect(
        blocks.map((block) => block.searchable).join(' '),
        contains('未单独核实'),
      );
      expect(
        blocks.where((block) => block.id == 'detail-title').single,
        detail.overview,
      );
    },
  );

  test('airport offers preserve billing periods and zero quotas without monthly price equivalents', () {
    final doc = PublicSiteParser().parse(
      fixture('jichang_naixi'),
      'https://huarun.win/jichang/naixi',
    );
    final detail = doc.service!;
    expect(detail.highlights['公开套餐'], '8 款');
    expect(detail.image, startsWith('https://huarun.win/jichang-icons/'));
    expect(
      detail.purchase!.url,
      'https://huarun.win/jichang/naixi/buy?source=detail_primary',
    );
    final offers = walk(doc.blocks)
        .where((block) => block.kind == BlockKind.offer)
        .map((block) => block.item!)
        .toList();
    expect(offers, hasLength(8));
    final semiannual = offers.singleWhere(
      (item) => item.title == 'Smart Access 186天',
    );
    expect(semiannual.facts['付款金额'], contains('/ 半年'));
    expect(semiannual.facts['付款金额'], contains('623.7'));
    expect(semiannual.facts['流量'], '500 GB / 月');
    expect(semiannual.facts['设备数'], '2 台');
    expect(offers.last.facts['流量'], '0 GB / 月');
    expect(
      walk(doc.blocks).map((block) => block.ownText).join(' '),
      isNot(contains('103.95')),
    );
    final supportingText = doc.blocks
        .map((block) => block.searchable)
        .join(' ');
    expect(supportingText, contains('Telegram'));
    expect(supportingText, contains('割接通知'));
  });

  test('multiple or missing VPS prices stay explicit and parser reuse leaves ordinary readers intact', () {
    final parser = PublicSiteParser();
    final doc = parser.parse('''<main><article class="detail-page vps-detail">
      <header class="vps-detail-hero"><h1>套餐</h1></header>
      <aside class="vps-price-panel"><h2>官方报价</h2>
      <div class="vps-price-option"><p class="vps-card-price">USD 5 / 月</p></div>
      <div class="vps-price-option"><p class="vps-card-price">USD 50 / 年</p></div>
      </aside></article></main>''', 'https://huarun.win/vps/example/basic');
    expect(doc.service!.price, isEmpty);
    expect(doc.service!.purchase, isNull);
    final text = doc.blocks.map((block) => block.searchable).join(' ');
    expect(text, contains('USD 5 / 月'));
    expect(text, contains('USD 50 / 年'));
    final ordinary = parser.parse(
      '''<main><article class="legal-page"><h1>关于</h1>
      <dl><dt>状态</dt><dd>待核实</dd></dl></article></main>''',
      'https://huarun.win/about',
    );
    expect(ordinary.service, isNull);
    expect(ordinary.blocks.last.kind, BlockKind.table);
  });

  testWidgets('primary service action uses the exact published redirect', (
    tester,
  ) async {
    final detail = PublicSiteParser()
        .parse(fixture('jichang_naixi'), 'https://huarun.win/jichang/naixi')
        .service!;
    final opened = <String>[];
    // Avoid network images while checking the actual primary action.
    final offline = SiteServiceDetails(
      kind: detail.kind,
      title: detail.title,
      overview: detail.overview,
      purchase: detail.purchase,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ServiceDetailHero(detail: offline, onOpen: opened.add),
        ),
      ),
    );
    await tester.tap(find.text('购买'));
    expect(opened, [
      'https://huarun.win/jichang/naixi/buy?source=detail_primary',
    ]);
  });

  for (final (name, route) in [
    ('vps_vmiss_sel-intl-basic', '/vps/vmiss/sel-intl-basic'),
    ('jichang_naixi', '/jichang/naixi'),
  ]) {
    testWidgets(
      'service details resize, omit search and keep headers scrolling: $route',
      (tester) async {
        final source = html.parse(fixture(name));
        for (final image in source.querySelectorAll('img')) {
          image.remove();
        }
        final url = 'https://huarun.win$route';
        final repository = PublicPages({url: source.outerHtml});
        SharedPreferences.setMockInitialValues({});
        final directory = Directory.systemTemp.createTempSync('service-detail');
        final controller = AppController(
          repository,
          await SharedPreferences.getInstance(),
        );
        final downloads = DownloadManager(directory);
        addTearDown(() {
          controller.dispose();
          repository.client.close(force: true);
          downloads.dispose();
          downloads.client.close(force: true);
          downloads.macResolver.client.close(force: true);
          directory.deleteSync(recursive: true);
        });
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1240, 900);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        Widget app(double scale, Brightness brightness) => MaterialApp(
          theme: appTheme(brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: SitePage(
            url: url,
            controller: controller,
            downloads: downloads,
          ),
        );
        await tester.pumpWidget(app(1, Brightness.light));
        await tester.pumpAndSettle();
        expect(find.byType(ServiceDetailHero), findsOneWidget);
        expect(find.byType(TextField), findsNothing);
        expect(find.byTooltip('查找正文'), findsNothing);
        void checkActionColors({required bool compact}) {
          final action = find.descendant(
            of: find.byType(ServiceDetailHero),
            matching: find.byType(FilledButton),
          );
          final colors = Theme.of(tester.element(action)).colorScheme;
          final style = tester.widget<FilledButton>(action).style!;
          expect(
            style.backgroundColor!.resolve({}),
            compact ? colors.primary : colors.surfaceContainer,
          );
          expect(
            style.foregroundColor!.resolve({}),
            compact ? colors.onPrimary : colors.primary,
          );
          expect(style.textStyle!.resolve({})!.fontSize, compact ? 16 : 14);
        }

        checkActionColors(compact: false);
        expect(tester.takeException(), isNull);
        for (final size in [const Size(390, 844), const Size(320, 740)]) {
          tester.view.physicalSize = size;
          await tester.pumpWidget(app(1.6, Brightness.dark));
          await tester.pumpAndSettle();
          checkActionColors(compact: true);
          expect(tester.takeException(), isNull);
        }
        tester.view.physicalSize = const Size(390, 844);
        await tester.pumpWidget(app(1, Brightness.light));
        await tester.pumpAndSettle();
        checkActionColors(compact: true);
        expect(find.byTooltip('查找正文'), findsNothing);
        await tester.drag(
          find.byKey(const ValueKey('site-content-scroll')),
          const Offset(0, -600),
        );
        await tester.pumpAndSettle();
        expect(find.byTooltip('刷新内容').hitTestable(), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'service Escape returns only after closing the upper menu',
    (tester) async {
      final source = html.parse(fixture('jichang_naixi'));
      source.querySelectorAll('img').forEach((node) => node.remove());
      final repository = PublicPages({
        'https://huarun.win/jichang/naixi': source.outerHtml,
      });
      SharedPreferences.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync('service-return');
      final controller = AppController(
        repository,
        await SharedPreferences.getInstance(),
      );
      final downloads = DownloadManager(directory);
      addTearDown(() {
        controller.dispose();
        repository.client.close(force: true);
        downloads.dispose();
        downloads.client.close(force: true);
        downloads.macResolver.client.close(force: true);
        directory.deleteSync(recursive: true);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              child: const Text('打开详情'),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => SitePage(
                    url: 'https://huarun.win/jichang/naixi',
                    controller: controller,
                    downloads: downloads,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开详情'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('页面操作'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(ServiceDetailHero), findsOneWidget);
      await tester.tap(find.text('Nexitally 奶昔'));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('打开详情'), findsOneWidget);
      await tester.tap(find.text('打开详情'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('查找正文'), findsNothing);
      await tester.drag(
        find.byKey(const ValueKey('site-content-scroll')),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('打开详情'), findsOneWidget);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.windows,
    }),
  );
}
