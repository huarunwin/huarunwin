import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:huarunwin/ui/detail.dart';
import 'package:huarunwin/ui/site_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'repository_test.dart' show HtmlAdapter;
import 'site_widget_test.dart' show PublicPages;

String fixture(String name) =>
    File('test/fixtures/applications/$name.html').readAsStringSync();
List<CatalogApp> mixedApps() => SiteHtmlParser().catalog(fixture('catalog'));

class TypedRepository extends CatalogRepository {
  TypedRepository(super.directory);
  final calls = <String>[];
  @override
  Future<DetailSnapshot> detail(CatalogApp app, {bool refresh = false}) async {
    calls.add(app.key);
    final file = switch (app.type) {
      ApplicationType.server => 'server',
      ApplicationType.subscriptionTool => 'tool',
      ApplicationType.ruleConfig => 'rule',
      _ => null,
    };
    return DetailSnapshot(
      file == null
          ? AppDetails(app: app)
          : SiteHtmlParser().detail(fixture(file), app),
      DateTime.now(),
    );
  }
}

class LinkedPages extends PublicPages {
  LinkedPages(super.pages);
  CatalogApp? requested;
  @override
  Future<DetailSnapshot> detail(CatalogApp app, {bool refresh = false}) async {
    requested = app;
    return DetailSnapshot(
      SiteHtmlParser().detail(fixture('server'), app),
      DateTime.now(),
    );
  }
}

void main() {
  test('published mixed cards retain types, separate environments and exact statistics', () {
    final apps = mixedApps();
    expect(apps.map((a) => a.type), ApplicationType.values);
    final server = apps[1], tool = apps[2], rule = apps[3];
    expect(server.environments, ['Linux', 'Windows']);
    expect(server.badges, containsAll(['Xray', '管理面板']));
    expect(tool.environments, ['iOS', 'macOS']);
    expect(tool.alias, '塔台');
    expect(rule.environments, contains('Mihomo'));
    expect(rule.versionSummary, contains('配置快照'));
    for (final app in apps.skip(1)) {
      expect(app.platforms, isEmpty);
      expect(app.core, isEmpty);
      expect(app.source, isEmpty);
      expect(app.sourceCategory, isNull);
      expect(app.priceCategory, isNull);
      expect(app.stars7Days, isNotNull);
      expect(CatalogApp.fromJson(app.toJson()).toJson(), app.toJson());
    }
    expect(
      server.stars7Days,
      416,
    ); // Exact fixture count, not duplicated mobile metrics.
    final legacy = CatalogApp.fromJson({
      'id': 'old',
      'name': 'Old',
      'url': 'https://huarun.win/apps/old',
    });
    expect(legacy.type, ApplicationType.client);
  });

  test(
    'type and route isolate same slugs and reject conflicting or foreign cards',
    () {
      final apps = SiteHtmlParser().catalog('''
      <article class="app-card"><a href="/apps/shared"><h2>Client</h2></a></article>
      <article class="app-card" data-application-type="server"><a href="/servers/shared"><h2>Server</h2></a></article>
      <article class="app-card" data-application-type="rule-config"><a href="/rules/shared?q=keep"><h2>Rules</h2></a></article>
      <article class="app-card" data-application-type="server"><a href="/apps/mismatch"><h2>Invalid</h2></a></article>
      <article class="app-card" data-application-type="future"><a href="/rules/unknown"><h2>Unknown</h2></a></article>
      <article class="app-card"><a class="app-card-detail" href="https://example.com/servers/foreign"><h2>Foreign</h2></a></article>
      <article class="app-card"><a href="/vps/shared"><h2>VPS</h2></a></article>
    ''');
      expect(apps.map((a) => a.key), [
        'client:shared',
        'server:shared',
        'rule-config:shared',
      ]);
      expect(apps.last.url, endsWith('?q=keep'));
    },
  );

  test('client filters exclude resource metadata while type, search and stars include resources', () {
    final apps = mixedApps();
    expect(
      filterCatalog(apps, type: ApplicationType.server).single.id,
      '3x-ui',
    );
    expect(
      filterCatalog(apps, query: '塔台').single.type,
      ApplicationType.subscriptionTool,
    );
    expect(
      filterCatalog(apps, query: '规则 Mihomo').single.type,
      ApplicationType.ruleConfig,
    );
    for (final result in [
      filterCatalog(apps, platform: 'macOS'),
      filterCatalog(apps, source: '开源'),
      filterCatalog(apps, price: '免费'),
      filterCatalog(apps, coreIds: apps.map((a) => a.key).toSet()),
    ]) {
      expect(result.every((a) => a.isClient), isTrue);
    }
    expect(
      filterCatalog(apps, sort: CatalogSort.stars).map((a) => a.type),
      containsAll(ApplicationType.values.skip(1)),
    );
    expect(
      filterCatalog(apps.reversed.toList()).map((a) => a.type),
      ApplicationType.values,
    );
    final resource = CatalogApp(
      id: 'zero',
      name: 'Zero',
      url: 'https://huarun.win/rules/zero',
      type: ApplicationType.ruleConfig,
      stars7Days: 0,
    );
    expect(filterCatalog([resource], sort: CatalogSort.stars), [resource]);
  });

  test('resource detail versions, update dates and official actions preserve their meaning', () {
    final parser = SiteHtmlParser(), apps = mixedApps();
    final server = parser.detail(fixture('server'), apps[1]);
    final tool = parser.detail(fixture('tool'), apps[2]);
    final rule = parser.detail(fixture('rule'), apps[3]);
    expect(server.versionLabel, '稳定版');
    expect(server.updatedAt, '2026-10-14');
    expect(tool.versionLabel, 'Mac 版本');
    expect(tool.facts['iOS App Store 版本'], '1.0.29');
    expect(tool.officialActions.first.url, contains('apps.apple.com'));
    expect(tool.officialActions.any((a) => a.url.endsWith('.dmg')), isTrue);
    expect(rule.versionLabel, '配置快照');
    expect(rule.version, '933875d');
    expect(rule.updatedAt, '2026-10-15T20:55:51Z');
    expect(rule.facts['跟踪分支'], 'master');
    for (final detail in [server, tool, rule]) {
      expect(detail.downloads, isEmpty);
      expect(detail.officialActions, isNotEmpty);
      expect(detail.officialActions.every((a) => !a.isPackage), isTrue);
      expect(detail.app.platforms, isEmpty);
    }
    final missing = parser.detail(
      '''<article class="detail-page"><h1 id="detail-title">Missing</h1>
      <dl class="detail-release-list"><div><dt>资料核验</dt><dd><time datetime="2026-10-17">今日</time></dd></div></dl>
      <script type="application/ld+json">{"@type":"SoftwareApplication","dateModified":"2026-10-17"}</script></article>''',
      apps[1],
    );
    expect(missing.updatedAt, isNull);
    final snapshot = parser.detail(
      fixture('server').replaceAll('稳定版', '源码快照'),
      apps[1],
    );
    expect(snapshot.versionLabel, '源码快照');
  });

  test('same-slug detail caches and update dates remain isolated by type', () async {
    final folder = await Directory.systemTemp.createTemp('typed-cache');
    addTearDown(() => folder.delete(recursive: true));
    final adapter = HtmlAdapter('');
    final repo = CatalogRepository(
      folder,
      client: Dio()..httpClientAdapter = adapter,
    );
    final apps = [
      for (final type in ApplicationType.values)
        CatalogApp(
          id: 'shared',
          name: type.label,
          url: 'https://huarun.win/${type.route}/shared',
          type: type,
        ),
    ];
    for (final app in apps) {
      adapter.body =
          '<article class="detail-page"><h1 id="detail-title">${app.name}</h1></article>';
      expect((await repo.detail(app)).details.app.name, app.name);
    }
    adapter.body = '<h1>Unavailable</h1>';
    for (final app in apps) {
      expect(
        (await repo.detail(app, refresh: true)).details.app.name,
        app.name,
      );
      expect((await repo.detail(app)).cached, isTrue);
    }
    final calls = adapter.calls;
    await expectLater(
      repo.detail(CatalogApp(id: 'shared', name: 'Bad', url: apps[1].url)),
      throwsException,
    );
    expect(adapter.calls, calls);
    SharedPreferences.setMockInitialValues({});
    final controller = AppController(
      repo,
      await SharedPreferences.getInstance(),
    );
    await controller.loadUpdateDates(apps);
    expect(
      controller.updateDates.keys,
      unorderedEquals(apps.map((a) => a.key)),
    );
    expect(controller.updateDateFailures, isEmpty);
    controller.dispose();
    repo.client.close(force: true);
  });

  Future<(AppController, DownloadManager)> setup(
    WidgetTester tester,
    Size size, {
    CatalogRepository? repo,
    String? rememberedPlatform = '全部',
  }) async {
    final folder = Directory.systemTemp.createTempSync('typed-widgets');
    SharedPreferences.setMockInitialValues({
      'catalogPlatform': ?rememberedPlatform,
    });
    final repository = repo ?? TypedRepository(folder);
    final controller = AppController(
      repository,
      await SharedPreferences.getInstance(),
    );
    controller.snapshot = CatalogSnapshot(mixedApps(), DateTime.now());
    final downloads = DownloadManager(folder);
    addTearDown(() {
      controller.dispose();
      repository.client.close(force: true);
      downloads.client.close(force: true);
      downloads.macResolver.client.close(force: true);
      downloads.dispose();
      folder.deleteSync(recursive: true);
    });
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    return (controller, downloads);
  }

  for (final target in [TargetPlatform.macOS, TargetPlatform.android]) {
    testWidgets(
      'all-type search spans platforms without replacing browsing preferences on $target',
      (tester) async {
        final (controller, downloads) = await setup(
          tester,
          target == TargetPlatform.macOS
              ? const Size(1240, 900)
              : const Size(390, 844),
          rememberedPlatform: null,
        );
        final browsingPlatform = controller.catalogPlatform;
        controller.snapshot = CatalogSnapshot([
          ...mixedApps(),
          CatalogApp(
            id: 'other-platform',
            name: 'Other Platform Client',
            url: 'https://huarun.win/apps/other-platform',
            platforms: [browsingPlatform == 'macOS' ? 'Android' : 'macOS'],
          ),
        ], DateTime.now());
        await tester.pumpWidget(
          HuarunApp(controller: controller, downloads: downloads),
        );
        await tester.pumpAndSettle();
        expect(find.text('1 款应用'), findsOneWidget);
        expect(find.text('3x-ui'), findsNothing);
        for (final (keyword, name) in [
          ('3x', '3x-ui'),
          ('塔台', 'Tower'),
          ('规则 Mihomo', 'blackmatrix7 规则集'),
          ('Other Platform', 'Other Platform Client'),
        ]) {
          await tester.enterText(find.byType(TextField), keyword);
          await tester.pumpAndSettle();
          expect(find.text(name), findsOneWidget);
          expect(find.text('1 款应用'), findsOneWidget);
          expect(
            tester.widget<PageHeader>(find.byType(PageHeader)).title,
            '发现',
          );
          expect(find.text('搜索范围：所有类型与平台'), findsNothing);
          expect(
            find.byKey(const ValueKey('catalog-platform-menu')),
            findsNothing,
          );
          expect(
            tester
                .widget<EditableText>(find.byType(EditableText))
                .focusNode
                .hasFocus,
            isTrue,
          );
          expect(controller.catalogPlatform, browsingPlatform);
          expect(
            controller.preferences.containsKey('catalogPlatform'),
            isFalse,
          );
        }
        await tester.tap(find.byTooltip('清空搜索'));
        await tester.pumpAndSettle();
        expect(find.text('1 款应用'), findsOneWidget);
        expect(find.text('FlClash'), findsOneWidget);
        expect(find.text('Other Platform Client'), findsNothing);
        expect(
          find.byKey(const ValueKey('catalog-platform-menu')),
          findsOneWidget,
        );
        expect(find.text('搜索范围：所有类型与平台'), findsNothing);
        expect(controller.preferences.containsKey('catalogPlatform'), isFalse);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({target}),
    );
  }

  testWidgets(
    'global search suspends client filters and specific type searches remain scoped',
    (tester) async {
      final (controller, downloads) = await setup(
        tester,
        const Size(1240, 900),
        rememberedPlatform: 'macOS',
      );
      controller.coreCatalogs['Mihomo'] = CatalogSnapshot([
        mixedApps().first,
      ], DateTime.now());
      await tester.pumpWidget(
        HuarunApp(controller: controller, downloads: downloads),
      );
      await tester.pumpAndSettle();
      for (final (filter, value) in [
        ('内核', 'Mihomo'),
        ('代码状态', '开源'),
        ('价格', '免费'),
      ]) {
        await tester.tap(find.byKey(ValueKey('catalog-filter-$filter')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('filter-$filter-$value')));
        await tester.pumpAndSettle();
      }
      expect(find.text('1 款应用'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '3x');
      await tester.pumpAndSettle();
      expect(find.text('3x-ui'), findsOneWidget);
      expect(controller.preferences.getString('catalogPlatform'), 'macOS');
      await tester.tap(find.byTooltip('清空搜索'));
      await tester.pumpAndSettle();
      final filters = tester.widget<CatalogFilterControls>(
        find.byType(CatalogFilterControls),
      );
      expect(
        (filters.platform, filters.core, filters.source, filters.price),
        ('macOS', 'Mihomo', '开源', '免费'),
      );
      expect(find.text('FlClash'), findsOneWidget);
      for (final (type, keyword, name) in [
        (ApplicationType.server, '3x', '3x-ui'),
        (ApplicationType.subscriptionTool, '塔台', 'Tower'),
        (ApplicationType.ruleConfig, '规则 Mihomo', 'blackmatrix7 规则集'),
        (ApplicationType.client, 'flcl', 'FlClash'),
      ]) {
        await tester.tap(find.byKey(ValueKey('nav-type-${type.value}')));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(find.byType(TextField)).decoration!.hintText,
          '搜索${type.label}',
        );
        await tester.enterText(find.byType(TextField), keyword);
        await tester.pumpAndSettle();
        expect(find.text(name), findsOneWidget);
        expect(find.text('1 款应用'), findsOneWidget);
        expect(find.text('搜索范围：所有类型与平台'), findsNothing);
        await tester.enterText(
          find.byType(TextField),
          type == ApplicationType.server ? '塔台' : '3x-ui',
        );
        await tester.pumpAndSettle();
        expect(find.text('0 款应用'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop type selection clears client filters and opens resource details',
    (tester) async {
      final (controller, downloads) = await setup(
        tester,
        const Size(1240, 900),
      );
      await tester.pumpWidget(
        HuarunApp(controller: controller, downloads: downloads),
      );
      await tester.pumpAndSettle();
      for (final type in ApplicationType.values) {
        expect(find.byKey(ValueKey('nav-type-${type.value}')), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('catalog-type-menu')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('catalog-platform-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('platform-option-macOS')));
      await tester.pumpAndSettle();
      expect(find.text('Tower'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('nav-type-server')));
      await tester.pumpAndSettle();
      expect(find.text('3x-ui'), findsOneWidget);
      expect(find.text('FlClash'), findsNothing);
      expect(find.byKey(const ValueKey('catalog-platform-menu')), findsNothing);
      await tester.tap(find.text('3x-ui'));
      await tester.pumpAndSettle();
      expect(find.byType(DetailPage), findsOneWidget);
      expect(find.widgetWithText(FilledButton, '官方文档'), findsOneWidget);
      expect(find.byType(AppDownloadButton), findsNothing);
      expect(downloads.tasks, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-applications')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('catalog-platform-menu')),
        findsOneWidget,
      );
      expect(tester.widget<PageHeader>(find.byType(PageHeader)).title, '发现');
      expect(find.text('1 款应用'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'applications group starts open and toggles without changing filters',
    (tester) async {
      final (controller, downloads) = await setup(
        tester,
        const Size(1240, 900),
      );
      await tester.pumpWidget(
        HuarunApp(controller: controller, downloads: downloads),
      );
      await tester.pumpAndSettle();
      final group = find.byKey(const ValueKey('nav-group-applications'));
      bool expanded() => tester.widget<Semantics>(group).properties.expanded!;
      bool selected() => tester.widget<Semantics>(group).properties.selected!;
      expect(expanded(), isTrue);
      expect(find.byKey(const ValueKey('nav-applications')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('nav-type-client')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('catalog-platform-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('platform-option-macOS')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'FlClash');
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'FlClash',
      );
      final resultCard = find.byWidgetPredicate(
        (widget) => widget is Text && widget.data == 'FlClash',
      );
      final results = tester.getTopLeft(resultCard);
      await tester.tap(group);
      await tester.pumpAndSettle();
      expect(expanded(), isFalse);
      expect(selected(), isTrue);
      expect(find.byKey(const ValueKey('nav-type-client')), findsNothing);
      expect(tester.widget<PageHeader>(find.byType(PageHeader)).title, '客户端');
      expect(find.text('1 款应用'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'FlClash',
      );
      expect(tester.getTopLeft(resultCard), results);
      await tester.tap(group);
      await tester.pumpAndSettle();
      expect(expanded(), isTrue);
      expect(
        tester
            .widget<Semantics>(find.byKey(const ValueKey('nav-type-client')))
            .properties
            .selected,
        isTrue,
      );
      expect(tester.widget<PageHeader>(find.byType(PageHeader)).title, '客户端');
      await tester.tap(find.byTooltip('清空搜索'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-applications')));
      await tester.pumpAndSettle();
      expect(tester.widget<PageHeader>(find.byType(PageHeader)).title, '发现');
      expect(find.text('1 款应用'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'entering collapsed applications from another tab selects its first child',
    (tester) async {
      final (controller, downloads) = await setup(
        tester,
        const Size(1240, 900),
      );
      await tester.pumpWidget(
        HuarunApp(controller: controller, downloads: downloads),
      );
      await tester.pumpAndSettle();
      final group = find.byKey(const ValueKey('nav-group-applications'));
      for (final iconOnly in [false, true]) {
        await tester.tap(find.byKey(const ValueKey('nav-type-server')));
        await tester.pumpAndSettle();
        expect(find.text('1 款应用'), findsOneWidget);
        await tester.tap(group);
        await tester.pumpAndSettle();
        if (iconOnly) {
          await tester.tap(find.byTooltip('收起侧边栏'));
          await tester.pumpAndSettle();
        }
        await tester.tap(iconOnly ? find.byTooltip('偏好设置') : find.text('偏好设置'));
        await tester.pumpAndSettle();
        expect(find.text('外观'), findsOneWidget);
        await tester.tap(group);
        await tester.pumpAndSettle();
        expect(tester.widget<Semantics>(group).properties.expanded, isTrue);
        expect(
          tester
              .widget<Semantics>(find.byKey(const ValueKey('nav-applications')))
              .properties
              .selected,
          isTrue,
        );
        expect(find.text('4 款应用'), findsOneWidget);
        expect(find.text('FlClash'), findsOneWidget);
        expect(find.text('Tower'), findsOneWidget);
        expect(
          tester.getSize(find.byKey(const ValueKey('desktop-sidebar'))).width,
          220,
        );
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'sidebar types share the catalog and stay selected across navigation and resizing',
    (tester) async {
      final (controller, downloads) = await setup(
        tester,
        const Size(1240, 900),
      );
      await tester.pumpWidget(
        HuarunApp(controller: controller, downloads: downloads),
      );
      await tester.pumpAndSettle();
      bool selected(String key) => tester
          .widget<Semantics>(find.byKey(ValueKey(key)))
          .properties
          .selected!;
      expect(selected('nav-applications'), isTrue);
      final titles = ['FlClash', '3x-ui', 'Tower', 'blackmatrix7 规则集'];
      for (final (index, type) in ApplicationType.values.indexed) {
        await tester.tap(find.byKey(ValueKey('nav-type-${type.value}')));
        await tester.pumpAndSettle();
        expect(selected('nav-type-${type.value}'), isTrue);
        expect(selected('nav-applications'), isFalse);
        expect(find.text(titles[index]), findsOneWidget);
        for (final other in titles.where((title) => title != titles[index])) {
          expect(find.text(other), findsNothing);
        }
      }

      final sidebar = find.byKey(const ValueKey('desktop-sidebar'));
      expect(tester.getSize(sidebar).width, 220);
      expect(find.byTooltip('规则与配置'), findsNothing);
      await tester.tap(find.byTooltip('收起侧边栏'));
      await tester.pumpAndSettle();
      expect(tester.getSize(sidebar).width, 80);
      expect(find.byKey(const ValueKey('nav-type-rule-config')), findsNothing);
      expect(selected('nav-group-applications'), isTrue);
      expect(find.byTooltip('发现'), findsOneWidget);
      expect(controller.preferences.getBool('sidebarExpanded'), isFalse);
      expect(find.text('1 款应用'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('nav-group-applications')));
      await tester.pumpAndSettle();
      expect(tester.getSize(sidebar).width, 220);
      await tester.tap(find.byKey(const ValueKey('nav-type-client')));
      await tester.pumpAndSettle();
      expect(find.text('FlClash'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('nav-type-rule-config')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('收起侧边栏'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-group-applications')));
      await tester.pumpAndSettle();
      expect(tester.getSize(sidebar).width, 220);
      expect(controller.preferences.getBool('sidebarExpanded'), isTrue);
      expect(selected('nav-type-rule-config'), isTrue);
      expect(find.text('1 款应用'), findsOneWidget);

      await tester.tap(find.text('偏好设置'));
      await tester.pumpAndSettle();
      expect(selected('nav-group-applications'), isFalse);
      // Close the inactive group, then enter it from Settings.
      await tester.tap(find.byKey(const ValueKey('nav-group-applications')));
      await tester.pumpAndSettle();
      expect(find.text('外观'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('nav-group-applications')));
      await tester.pumpAndSettle();
      expect(selected('nav-applications'), isTrue);
      expect(find.text('4 款应用'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('nav-type-rule-config')));
      await tester.pumpAndSettle();
      expect(selected('nav-type-rule-config'), isTrue);
      expect(find.text('1 款应用'), findsOneWidget);

      tester.view.physicalSize = const Size(600, 900);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.byKey(const ValueKey('nav-type-rule-config')), findsNothing);
      expect(find.byTooltip('应用类型：规则与配置'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('catalog-type-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('type-client')));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(1240, 900);
      await tester.pumpAndSettle();
      expect(selected('nav-type-client'), isTrue);
      expect(find.byKey(const ValueKey('catalog-type-menu')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('catalog-platform-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('platform-option-macOS')));
      await tester.pumpAndSettle();
      expect(selected('nav-type-client'), isTrue);
      await tester.tap(find.text('重置筛选'));
      await tester.pumpAndSettle();
      expect(selected('nav-type-client'), isTrue);
      expect(
        find.byKey(const ValueKey('catalog-platform-menu')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('nav-applications')));
      await tester.pumpAndSettle();
      expect(selected('nav-applications'), isTrue);
      expect(find.text('4 款应用'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets('sidebar scrolls in short windows and keeps settings reachable', (
    tester,
  ) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final (controller, downloads) = await setup(tester, const Size(940, 600));
    await tester.pumpWidget(
      HuarunApp(controller: controller, downloads: downloads),
    );
    await tester.pumpAndSettle();
    expect(find.text('偏好设置').hitTestable(), findsOneWidget);
    expect(find.text('访问 huarun.win').hitTestable(), findsOneWidget);
    final sidebar = find.byKey(const PageStorageKey('sidebar-navigation'));
    await tester.drag(sidebar, const Offset(0, -1400));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('nav-site-/jichang')));
    await tester.pumpAndSettle();
    expect(find.text('机场').hitTestable(), findsOneWidget);
    expect(find.text('偏好设置').hitTestable(), findsOneWidget);
    await tester.drag(sidebar, const Offset(0, 1400));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('nav-group-applications')).hitTestable(),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Android type popup dismisses without applying and clears stale filters on selection',
    (tester) async {
      final (controller, downloads) = await setup(tester, const Size(390, 844));
      await tester.pumpWidget(
        HuarunApp(controller: controller, downloads: downloads),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('catalog-platform-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('platform-option-macOS')));
      await tester.pumpAndSettle();
      Future<void> chooseRule() async {
        await tester.tap(find.byKey(const ValueKey('catalog-type-menu')));
        await tester.pumpAndSettle();
      }

      await chooseRule();
      await tester.tapAt(const Offset(4, 40));
      await tester.pumpAndSettle();
      expect(find.text('FlClash'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('catalog-platform-menu')),
        findsOneWidget,
      );
      await chooseRule();
      await tester.tap(find.byKey(const ValueKey('type-rule-config')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('catalog-platform-menu')), findsNothing);
      expect(find.text('blackmatrix7 规则集'), findsOneWidget);
      expect(find.text('1 款应用'), findsOneWidget);
      expect(tester.widget<PageHeader>(find.byType(PageHeader)).title, '发现');
      tester.view.physicalSize = const Size(1240, 900);
      await tester.pumpAndSettle();
      expect(tester.widget<PageHeader>(find.byType(PageHeader)).title, '规则与配置');
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      expect(tester.widget<PageHeader>(find.byType(PageHeader)).title, '发现');
      expect(find.text('blackmatrix7 规则集'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );

  testWidgets(
    'resource links in native reading open typed details without a catalog summary',
    (tester) async {
      final repo = LinkedPages({
        'https://huarun.win/about': '<main><article class="legal-page"><h1>关于</h1><p><a href="/servers/3x-ui">打开服务端</a></p></article></main>',
      });
      final (controller, downloads) = await setup(
        tester,
        const Size(1240, 900),
        repo: repo,
      );
      controller.snapshot = null;
      await tester.pumpWidget(
        MaterialApp(
          home: SitePage(
            url: 'https://huarun.win/about',
            controller: controller,
            downloads: downloads,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('打开服务端'));
      await tester.pumpAndSettle();
      expect(repo.requested?.key, 'server:3x-ui');
      expect(find.byType(DetailPage), findsOneWidget);
      expect(find.byType(AppDownloadButton), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
