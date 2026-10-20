import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
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
import 'package:huarunwin/ui/site_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'repository_test.dart' show HtmlAdapter;

const apps = [
  CatalogApp(
    id: 'deck',
    name: 'Deck Plugin',
    url: 'https://huarun.win/apps/deck',
    platforms: ['Linux'],
  ),
  CatalogApp(
    id: 'linux',
    name: 'Desktop Linux',
    url: 'https://huarun.win/apps/linux',
    platforms: ['Linux'],
  ),
  CatalogApp(
    id: 'router',
    name: 'OpenWrt Plugin',
    url: 'https://huarun.win/apps/router',
    platforms: ['OpenWrt'],
  ),
  CatalogApp(
    id: 'merlin',
    name: 'Merlin Plugin',
    url: 'https://huarun.win/apps/merlin',
    platforms: ['Asuswrt-Merlin'],
  ),
];

class DeviceRepository extends CatalogRepository {
  DeviceRepository(super.directory);
  final calls = <CatalogDevice>[];
  Completer<CatalogSnapshot>? pending;
  @override
  Future<CatalogSnapshot> deviceCatalog(
    CatalogDevice device, {
    bool refresh = false,
  }) async {
    calls.add(device);
    if (pending != null) return pending!.future;
    return CatalogSnapshot(
      device == CatalogDevice.steamDeck ? [apps.first] : apps.skip(2).toList(),
      DateTime.now(),
    );
  }
}

void main() {
  test(
    'published device HTML distinguishes SteamOS plugins from other Linux apps',
    () {
      final parser = SiteHtmlParser();
      final steam = parser.catalog(
        File('test/fixtures/site/devices_steam-deck.html').readAsStringSync(),
      );
      final routers = parser.catalog(
        File('test/fixtures/site/routers.html').readAsStringSync(),
      );
      expect(steam.map((app) => app.key), contains('client:tomoon'));
      expect(steam.map((app) => app.key), isNot(contains('client:flclash')));
      expect(
        routers.map((app) => app.id),
        containsAll(['openclash', 'fancyss']),
      );
      final deviceIds = {'client:deck', 'server:deck'};
      expect(
        filterCatalog([
          ...apps,
          const CatalogApp(
            id: 'deck',
            type: ApplicationType.server,
            name: 'Server',
            url: 'https://huarun.win/servers/deck',
          ),
        ], deviceIds: deviceIds).map((app) => app.key),
        ['client:deck'],
      );
      expect(
        filterCatalog(apps, deviceIds: deviceIds, coreIds: {'client:router'}),
        isEmpty,
      );
    },
  );

  test('device HTML caches are independent and preserve membership after a failed refresh', () async {
    final folder = await Directory.systemTemp.createTemp('device-cache');
    addTearDown(() => folder.delete(recursive: true));
    final adapter = HtmlAdapter(
      File('test/fixtures/catalog.html').readAsStringSync(),
    );
    final repository = CatalogRepository(
      folder,
      client: Dio()..httpClientAdapter = adapter,
    );
    final all = await repository.catalog();
    adapter.body = File('test/fixtures/site/devices_steam-deck.html')
        .readAsStringSync();
    final steam = await repository.deviceCatalog(CatalogDevice.steamDeck);
    adapter.body = File('test/fixtures/site/routers.html').readAsStringSync();
    final routers = await repository.deviceCatalog(CatalogDevice.routers);
    expect(adapter.paths, ['/', '/devices/steam-deck', '/routers']);
    expect(
      (await repository.catalog()).apps.map((app) => app.key),
      all.apps.map((app) => app.key),
    );
    expect(
      (await repository.deviceCatalog(CatalogDevice.steamDeck)).apps
          .map((app) => app.key),
      steam.apps.map((app) => app.key),
    );
    expect(adapter.calls, 3);
    adapter.body = '<h1>Unavailable</h1>';
    final fallback = await repository.deviceCatalog(
      CatalogDevice.routers,
      refresh: true,
    );
    expect(
      fallback.apps.map((app) => app.key),
      routers.apps.map((app) => app.key),
    );
    expect(fallback.warning, isNotNull);
    repository.client.close(force: true);
  });

  for (final size in [const Size(1240, 900), const Size(390, 844)]) {
    testWidgets(
      'device filters replace navigation and preserve application/download semantics at $size',
      (tester) async {
        final folder = Directory.systemTemp.createTempSync('device-widgets');
        SharedPreferences.setMockInitialValues({});
        final repository = DeviceRepository(folder);
        final controller = AppController(
          repository,
          await SharedPreferences.getInstance(),
        );
        controller.snapshot = CatalogSnapshot(apps, DateTime.now());
        final downloads = DownloadManager(folder);
        addTearDown(() async {
          controller.dispose();
          repository.client.close(force: true);
          downloads.client.close(force: true);
          downloads.macResolver.client.close(force: true);
          downloads.dispose();
          await folder.delete(recursive: true);
        });
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          HuarunApp(controller: controller, downloads: downloads),
        );
        await tester.pumpAndSettle();
        expect(repository.calls, isEmpty);
        expect(find.text('路由器工具'), findsNothing);
        if (size.width >= 900) {
          expect(find.text('Steam Deck'), findsNothing);
          expect(
            find.byKey(const ValueKey('catalog-platform-menu')),
            findsOneWidget,
          );
        }
        Future<void> choose(String name) async {
          await tester.tap(find.byKey(const ValueKey('catalog-platform-menu')));
          await tester.pumpAndSettle();
          await tester.ensureVisible(
            find.byKey(ValueKey('platform-option-$name')),
          );
          await tester.tap(find.byKey(ValueKey('platform-option-$name')));
          await tester.pumpAndSettle();
        }

        await choose('Steam Deck');
        expect(tester.widget<PageHeader>(find.byType(PageHeader)).title, '应用');
        expect(find.text('Deck Plugin'), findsOneWidget);
        expect(find.text('Desktop Linux'), findsNothing);
        expect(repository.calls, [CatalogDevice.steamDeck]);
        expect(find.byTooltip('平台与设备：Steam Deck'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('catalog-platform-menu')),
            matching: find.text('Steam Deck'),
          ),
          findsOneWidget,
        );
        expect(
          tester
              .widget<AppDownloadButton>(find.byType(AppDownloadButton))
              .selectedPlatform,
          '全部',
        );
        expect(find.byType(SitePage), findsNothing);
        await choose('路由器');
        expect(find.text('OpenWrt Plugin'), findsOneWidget);
        expect(find.text('Merlin Plugin'), findsOneWidget);
        expect(find.text('Deck Plugin'), findsNothing);
        expect(repository.calls, [
          CatalogDevice.steamDeck,
          CatalogDevice.routers,
        ]);
        await choose('Linux');
        expect(find.text('Deck Plugin'), findsOneWidget);
        expect(find.text('Desktop Linux'), findsOneWidget);
        expect(find.text('OpenWrt Plugin'), findsNothing);
        await choose('全部');
        expect(find.text('4 款应用'), findsOneWidget);
        expect(downloads.tasks, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  test('concurrent device loads reuse one request without replacing the main catalog', () async {
    final folder = await Directory.systemTemp.createTemp('device-load');
    addTearDown(() => folder.delete(recursive: true));
    SharedPreferences.setMockInitialValues({});
    final repo = DeviceRepository(folder)
      ..pending = Completer<CatalogSnapshot>();
    final controller = AppController(
      repo,
      await SharedPreferences.getInstance(),
    );
    controller.snapshot = CatalogSnapshot(apps, DateTime.now());
    final first = controller.loadDevice(CatalogDevice.steamDeck);
    final second = controller.loadDevice(CatalogDevice.steamDeck);
    expect(repo.calls, [CatalogDevice.steamDeck]);
    expect(controller.loadingDevices, {CatalogDevice.steamDeck});
    repo.pending!.complete(CatalogSnapshot([apps.first], DateTime.now()));
    await Future.wait([first, second]);
    expect(controller.snapshot!.apps, apps);
    expect(controller.deviceCatalogs[CatalogDevice.steamDeck]!.apps, [
      apps.first,
    ]);
    expect(controller.loadingDevices, isEmpty);
    controller.dispose();
    repo.client.close(force: true);
  });
}
