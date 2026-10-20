import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:huarunwin/data/site_models.dart';
import 'package:huarunwin/data/site_parser.dart';
import 'package:huarunwin/ui/adaptive_dialog.dart';
import 'package:huarunwin/ui/theme.dart';
import 'package:huarunwin/ui/vps_catalog.dart';

const monthly = SiteItem(
  title: 'VMISS · 韩国 · 首尔',
  subtitle: 'KR.SEL.INTL.Basic',
  url: 'https://huarun.win/vps/vmiss/sel-intl-basic',
  facets: {
    '付款周期': ['按月付款'],
    '厂商': ['VMISS'],
    '地区': ['韩国', '首尔'],
    '网络': ['国际线路'],
  },
  facts: {
    'CPU': '1 vCPU',
    '内存': '2 GB',
    'SSD': '20 GB',
    '流量额度': '1 TB',
    '官方报价': 'CAD 5.00 / 月',
    '人民币参考价': '约 ¥23.61 / 月',
  },
  memory: 2,
  price: 23.61,
  actions: [SiteLink('购买', 'https://app.vmiss.com/aff.php?aff=6751&pid=62')],
);
const yearly = SiteItem(
  title: '示例厂商 · 香港',
  url: 'https://huarun.win/vps/example/yearly',
  facets: {
    '付款周期': ['按年付款'],
    '厂商': ['示例厂商'],
    '地区': ['香港'],
    '网络': ['CN2 GIA'],
  },
  facts: {'内存': '8 GB', '官方报价': 'USD 8 / 年', '人民币参考价': '约 ¥60 / 年'},
  memory: 8,
  price: 60,
);
const unknown = SiteItem(
  title: '规格待补全',
  url: 'https://huarun.win/vps/example/unknown',
);

Widget catalog({
  SiteDocument? document,
  Brightness brightness = Brightness.light,
  ValueChanged<String>? onOpen,
}) => MaterialApp(
  theme: appTheme(brightness),
  home: VpsCatalog(
    document:
        document ??
        const SiteDocument(
          url: 'https://huarun.win/vps',
          title: 'VPS 目录',
          directory: true,
        ),
    items: document?.items ?? const [monthly, yearly, unknown],
    embedded: true,
    loading: false,
    collecting: false,
    allLoaded: true,
    onRefresh: () async {},
    onCollect: () {},
    onStop: () {},
    onOpen: onOpen ?? (_) {},
    actions: const [],
    footer: const SizedBox(height: 20),
  ),
);

void size(WidgetTester tester, Size value) {
  tester.view.physicalSize = value;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> select(WidgetTester tester, String menu, String option) async {
  await tester.ensureVisible(find.byKey(ValueKey(menu)));
  await tester.tap(find.byKey(ValueKey(menu)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey(option)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'desktop VPS menus intersect known facets, memory and reference price across resizing',
    (tester) async {
      size(tester, const Size(620, 980));
      await tester.pumpWidget(catalog());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('vps-filters')), findsNothing);
      expect(find.byKey(const ValueKey('vps-filter-traffic')), findsNothing);

      void expectMenusFit() {
        for (final key in [
          'vps-filter-付款周期',
          'vps-filter-厂商',
          'vps-filter-地区',
          'vps-filter-网络',
          'vps-filter-memory',
          'vps-filter-price',
        ]) {
          final menu = find.byKey(ValueKey(key));
          expect(menu.hitTestable(), findsOneWidget);
          final rect = tester.getRect(menu);
          expect(rect.left, greaterThanOrEqualTo(32));
          expect(rect.right, lessThanOrEqualTo(588));
          expect(rect.height, greaterThanOrEqualTo(40));
        }
        expect(tester.takeException(), isNull);
      }

      expectMenusFit();
      await select(tester, 'vps-filter-memory', 'vps-memory-4');
      expect(find.text('匹配 1 / 已载入 3'), findsOneWidget);
      expect(find.text(yearly.title), findsOneWidget);
      expect(find.text(unknown.title), findsNothing);
      await tester.tap(find.text('重置筛选'));
      await tester.pumpAndSettle();
      await select(tester, 'vps-filter-厂商', 'vps-厂商-VMISS');
      await select(tester, 'vps-filter-地区', 'vps-地区-韩国');
      await select(tester, 'vps-filter-付款周期', 'vps-付款周期-按月付款');
      await select(tester, 'vps-filter-price', 'vps-price-¥10–30');
      expect(find.text('匹配 1 / 已载入 3'), findsOneWidget);
      expect(find.text(monthly.title), findsOneWidget);
      expect(find.text(yearly.title), findsNothing);
      expectMenusFit();

      tester.view.physicalSize = const Size(1240, 900);
      await tester.pumpAndSettle();
      expect(find.text('参考价 ¥10–30'), findsOneWidget);
      tester.view.physicalSize = const Size(620, 980);
      await tester.pumpAndSettle();
      expect(find.text('匹配 1 / 已载入 3'), findsOneWidget);
      expectMenusFit();
      await tester.tap(find.text('重置筛选'));
      await tester.pumpAndSettle();
      expect(find.text('已载入 3 条'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('vps-sort')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('内存从高到低'));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text(yearly.title)).dy,
        lessThan(tester.getTopLeft(find.text(monthly.title)).dy),
      );
    },
    variant: TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    }),
  );

  testWidgets(
    'phone VPS menus filter immediately and custom prices require confirmation',
    (tester) async {
      size(tester, const Size(390, 844));
      await tester.pumpWidget(catalog());
      await tester.pumpAndSettle();

      Future<void> openAndSelect() async {
        await select(tester, 'vps-filter-memory', 'vps-memory-4');
        await select(tester, 'vps-filter-price', 'vps-price-自定义…');
        await tester.pumpAndSettle();
        final fields = find.descendant(
          of: find.byType(AdaptiveDialog),
          matching: find.byType(TextFormField),
        );
        await tester.ensureVisible(fields.last);
        await tester.enterText(fields.first, '0');
        await tester.enterText(fields.last, '60');
      }

      await openAndSelect();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('匹配 1 / 已载入 3'), findsOneWidget);
      expect(find.byTooltip('人民币参考价格：不限；下限不含、上限包含，保留原付款周期'), findsOneWidget);
      await openAndSelect();
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.first, '80');
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(find.text('上限须大于下限'), findsOneWidget);
      await tester.enterText(fields.first, '0');
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(find.text('匹配 1 / 已载入 3'), findsOneWidget);
      expect(find.text(yearly.title), findsOneWidget);
      expect(find.text(monthly.title), findsNothing);
      expect(find.text(unknown.title), findsNothing);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  testWidgets(
    'published VPS cards keep original quotes, hardware, affiliate and native directory links',
    (tester) async {
      size(tester, const Size(1240, 900));
      final source = html.parse(
        File('test/fixtures/site/vps.html').readAsStringSync(),
      );
      for (final image in source.querySelectorAll('img')) {
        image.remove();
      }
      final document = PublicSiteParser().parse(
        source.outerHtml,
        'https://huarun.win/vps',
      );
      final opened = <String>[];
      await tester.pumpWidget(catalog(document: document, onOpen: opened.add));
      await tester.pumpAndSettle();
      final first = document.items.first;
      final card = find
          .ancestor(
            of: find.text(first.title).first,
            matching: find.byType(Card),
          )
          .first;
      expect(
        find.descendant(of: card, matching: find.text(first.facts['官方报价']!)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: card,
          matching: find.text('人民币参考价：${first.facts['人民币参考价']}'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text('流量额度')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('vps-filter-traffic')), findsNothing);
      await tester.tap(
        find.descendant(
          of: card,
          matching: find.text(first.actions.first.label),
        ),
      );
      expect(opened.single, 'https://app.vmiss.com/aff.php?aff=6751&pid=62');
      await tester.tap(find.text(first.title).first);
      expect(opened.last, first.url);

      final category = document.groups
          .expand((g) => g.links)
          .firstWhere((l) => l.url.endsWith('/vps/topics/cn2-gia'));
      await tester.tap(find.byKey(const ValueKey('vps-directory-menu')));
      await tester.pumpAndSettle();
      final option = find.byKey(ValueKey('vps-directory-${category.url}'));
      await tester.ensureVisible(option);
      await tester.tap(option);
      await tester.pumpAndSettle();
      expect(opened.last, category.url);
      expect(
        find.byType(Card).evaluate().length,
        lessThan(document.items.length),
      );
      final scroll = find.byKey(const ValueKey('vps-catalog-scroll'));
      await tester.drag(scroll, const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(find.text('VPS').hitTestable(), findsNothing);
      expect(find.byType(TextField).hitTestable(), findsNothing);
      await tester.drag(scroll, const Offset(0, 1800));
      await tester.pumpAndSettle();
      for (final width in [320.0, 390.0, 460.0, 940.0, 1240.0]) {
        tester.view.physicalSize = Size(width, 980);
        await tester.pumpWidget(
          catalog(document: document, brightness: Brightness.dark),
        );
        await tester.pumpAndSettle();
        if (width < 600) {
          expect(find.byTooltip('网格视图'), findsNothing);
          expect(find.byTooltip('列表视图'), findsNothing);
          expect(tester.takeException(), isNull, reason: 'compact at $width');
          continue;
        }
        await tester.tap(find.byTooltip('列表视图'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'list at $width');
        await tester.tap(find.byTooltip('网格视图'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'grid at $width');
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'large text wraps VPS menus and scoped directory retains its title',
    (tester) async {
      size(tester, const Size(620, 980));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        catalog(
          document: const SiteDocument(
            url: 'https://huarun.win/vps/locations/region-hong-kong',
            title: '香港 VPS 套餐',
            directory: true,
            items: [monthly, yearly, unknown],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('VPS'), findsOneWidget);
      expect(
        tester.getTopLeft(find.byKey(const ValueKey('vps-filter-price'))).dy,
        greaterThan(
          tester.getTopLeft(find.byKey(const ValueKey('vps-filter-付款周期'))).dy,
        ),
      );
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
