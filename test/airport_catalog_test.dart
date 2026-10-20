import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:huarunwin/data/site_models.dart';
import 'package:huarunwin/data/site_parser.dart';
import 'package:huarunwin/ui/airport_catalog.dart';
import 'package:huarunwin/ui/theme.dart';

const monthly = SiteItem(
  title: '月付机场',
  url: 'https://huarun.win/jichang/monthly',
  facets: {
    '付款周期': ['月付'],
  },
  facts: {'对应月流量': '200GB/月', '付款金额': '¥20月付'},
  price: 20,
  traffic: 200,
  actions: [
    SiteLink(
      '购买',
      'https://huarun.win/jichang/monthly/buy?source=catalog_card',
    ),
    SiteLink('使用说明', 'https://example.com/guide?from=catalog'),
  ],
);
const package = SiteItem(
  title: '按量套餐',
  url: 'https://huarun.win/jichang/package',
  facets: {
    '付款周期': ['一次性'],
  },
  facts: {'套餐流量': '1000GB套餐', '付款金额': '¥60一次性'},
  price: 60,
);
const unknown = SiteItem(
  title: '待补全机场',
  url: 'https://huarun.win/jichang/unknown',
);

Widget catalog({
  List<SiteItem> items = const [monthly, package, unknown],
  Brightness brightness = Brightness.light,
  ValueChanged<String>? onOpen,
}) => MaterialApp(
  theme: appTheme(brightness),
  home: AirportCatalog(
    document: const SiteDocument(
      url: 'https://huarun.win/jichang',
      title: '机场',
      directory: true,
    ),
    items: items,
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

void main() {
  testWidgets(
    'phone filter menus apply immediately and distinguish total from monthly traffic',
    (tester) async {
      size(tester, const Size(390, 844));
      await tester.pumpWidget(catalog());
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('airport-filter-traffic')));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(4, 40));
      await tester.pumpAndSettle();
      expect(find.text('已载入 3 条'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('airport-filter-traffic')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('airport-traffic-200')));
      await tester.pumpAndSettle();
      expect(find.text('匹配 1 / 已载入 3'), findsOneWidget);
      expect(find.text('月付机场'), findsOneWidget);
      expect(find.text('按量套餐'), findsNothing);
      expect(find.text('待补全机场'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('airport-filter-traffic')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('airport-traffic-0')));
      await tester.pumpAndSettle();
      expect(find.text('已载入 3 条'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    testWidgets(
      'medium ${platform.name} keeps inline airport filters and selections after resize',
      (tester) async {
        size(tester, const Size(620, 880));
        await tester.pumpWidget(catalog());
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('airport-filters')), findsNothing);

        void expectSingleRow() {
          final menus = [
            'airport-filter-付款周期',
            'airport-filter-traffic',
            'airport-filter-price',
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

        Future<void> select(String menu, String option) async {
          await tester.tap(find.byKey(ValueKey(menu)));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(ValueKey(option)));
          await tester.pumpAndSettle();
        }

        expectSingleRow();
        await select('airport-filter-traffic', 'airport-traffic-1000');
        expect(find.text('没有找到匹配的机场'), findsOneWidget);
        expect(find.byTooltip('明确月流量下限：至少 1000 GB / 月'), findsOneWidget);
        expectSingleRow();
        await select('airport-filter-traffic', 'airport-traffic-200');
        await select('airport-filter-付款周期', 'airport-付款周期-月付');
        await select('airport-filter-price', 'airport-price-¥10–30');
        expect(find.text('匹配 1 / 已载入 3'), findsOneWidget);
        expect(find.text('月付机场'), findsOneWidget);
        expect(find.text('按量套餐'), findsNothing);
        expect(find.text('待补全机场'), findsNothing);
        expectSingleRow();

        tester.view.physicalSize = const Size(1240, 900);
        await tester.pumpAndSettle();
        expect(find.text('金额 ¥10–30'), findsOneWidget);
        tester.view.physicalSize = const Size(620, 880);
        await tester.pumpAndSettle();
        expect(find.text('匹配 1 / 已载入 3'), findsOneWidget);
        expectSingleRow();
        await tester.tap(find.text('重置筛选'));
        await tester.pumpAndSettle();
        expect(find.text('已载入 3 条'), findsOneWidget);
        expectSingleRow();
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }

  testWidgets(
    'large text wraps inline airport menus and custom prices require confirmation',
    (tester) async {
      size(tester, const Size(620, 980));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(catalog());
      await tester.pumpAndSettle();
      final period = find.byKey(const ValueKey('airport-filter-付款周期'));
      final price = find.byKey(const ValueKey('airport-filter-price'));
      expect(
        tester.getTopLeft(price).dy,
        greaterThan(tester.getTopLeft(period).dy),
      );

      Future<void> enterCustomPrice() async {
        await tester.tap(price);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('airport-price-自定义…')));
        await tester.pumpAndSettle();
        final fields = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextFormField),
        );
        await tester.enterText(fields.first, '0');
        await tester.enterText(fields.last, '20');
      }

      await enterCustomPrice();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('已载入 3 条'), findsOneWidget);
      await enterCustomPrice();
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(find.text('匹配 1 / 已载入 3'), findsOneWidget);
      expect(find.text('月付机场'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets(
    'desktop price filters validate bounds and preserve every action URL',
    (tester) async {
      size(tester, const Size(1240, 900));
      final opened = <String>[];
      await tester.pumpWidget(catalog(onOpen: opened.add));
      await tester.pumpAndSettle();
      await tester.tap(find.text('购买'));
      await tester.tap(find.text('使用说明'));
      expect(opened, monthly.actions.map((link) => link.url).toList());
      await tester.tap(find.text('付款金额不限'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('自定义…'));
      await tester.pumpAndSettle();
      final fields = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextFormField),
      );
      await tester.enterText(fields.first, '60');
      await tester.enterText(fields.last, '10');
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(find.text('上限须大于下限'), findsOneWidget);
      await tester.enterText(fields.first, '0');
      await tester.enterText(fields.last, '20');
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(find.text('匹配 1 / 已载入 3'), findsOneWidget);
      expect(find.text('月付机场'), findsOneWidget);
      expect(find.text('按量套餐'), findsNothing);
      expect(find.text('待补全机场'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'published airport cards support lazy scrolling, both views and themes',
    (tester) async {
      size(tester, const Size(1240, 900));
      final source = html.parse(
        File('test/fixtures/site/jichang.html').readAsStringSync(),
      );
      for (final image in source.querySelectorAll('img')) {
        image.remove();
      }
      final document = PublicSiteParser().parse(
        source.outerHtml,
        'https://huarun.win/jichang',
      );
      await tester.pumpWidget(catalog(items: document.items));
      await tester.pumpAndSettle();
      expect(
        find.byType(Card).evaluate().length,
        lessThan(document.items.length),
      );
      await tester.tap(find.byTooltip('列表视图'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final scroll = find.byKey(const ValueKey('airport-catalog-scroll'));
      await tester.drag(scroll, const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(find.text('机场').hitTestable(), findsNothing);
      expect(find.byType(TextField).hitTestable(), findsNothing);
      await tester.drag(scroll, const Offset(0, 1800));
      await tester.pumpAndSettle();
      for (final width in [390.0, 320.0, 940.0, 1240.0]) {
        tester.view.physicalSize = Size(width, 844);
        await tester.pumpWidget(
          catalog(items: document.items, brightness: Brightness.dark),
        );
        await tester.pumpAndSettle();
        if (width < 600) {
          expect(find.byTooltip('网格视图'), findsNothing);
          expect(find.byTooltip('列表视图'), findsNothing);
          expect(tester.takeException(), isNull, reason: 'compact at $width');
          continue;
        }
        await tester.tap(find.byTooltip('网格视图'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'grid at $width');
        await tester.tap(find.byTooltip('列表视图'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'list at $width');
      }
    },
  );
}
