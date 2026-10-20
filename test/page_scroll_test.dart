import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/models.dart';
import 'package:huarunwin/data/repository.dart';
import 'package:huarunwin/data/site_models.dart';
import 'package:huarunwin/main.dart';
import 'package:huarunwin/services/app_controller.dart';
import 'package:huarunwin/services/downloads.dart';
import 'package:huarunwin/ui/downloads_page.dart';
import 'package:huarunwin/ui/licenses_page.dart';
import 'package:huarunwin/ui/page_components.dart';
import 'package:huarunwin/ui/settings.dart';
import 'package:huarunwin/ui/site_page.dart';
import 'package:huarunwin/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

const app = CatalogApp(
  id: 'scroll-example',
  name: '滚动示例应用',
  url: 'https://huarun.win/apps/scroll-example',
  platforms: ['macOS'],
);

class ScrollPages extends CatalogRepository {
  ScrollPages(super.directory);
  late SiteDocument document;

  @override
  Future<SiteSnapshot> page(String url, {bool refresh = false}) async =>
      SiteSnapshot(document, DateTime.now());

  @override
  Future<DetailSnapshot> detail(CatalogApp app, {bool refresh = false}) async =>
      DetailSnapshot(
        AppDetails(
          app: app,
          description: '应用详情介绍',
          facts: {
            for (var index = 0; index < 30; index++) '资料 $index': '公开信息 $index',
          },
        ),
        DateTime.now(),
      );
}

class ScrollDownloads extends DownloadManager {
  ScrollDownloads(super.directory);
  // These tests cover scrolling; filesystem refresh is tested separately.
  @override
  Future<void> refresh() async {}
}

void main() {
  late Directory directory;
  late ScrollPages repository;
  late AppController controller;
  late DownloadManager downloads;

  setUp(() async {
    directory = Directory.systemTemp.createTempSync('huarun-page-scroll');
    repository = ScrollPages(directory);
    SharedPreferences.setMockInitialValues({'catalogPlatform': '全部'});
    controller = AppController(
      repository,
      await SharedPreferences.getInstance(),
    );
    controller.snapshot = CatalogSnapshot(const [app], DateTime.now());
    downloads = ScrollDownloads(directory);
  });

  tearDown(() {
    controller.dispose();
    repository.client.close(force: true);
    downloads.client.close(force: true);
    downloads.macResolver.client.close(force: true);
    downloads.dispose();
    directory.deleteSync(recursive: true);
  });

  void viewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> scrollDown(WidgetTester tester, Size size) async {
    await tester.dragFrom(
      Offset(size.width * .7, size.height - 120),
      const Offset(0, -750),
    );
    await tester.pumpAndSettle();
  }

  for (final size in [const Size(1240, 900), const Size(390, 844)]) {
    for (final isDirectory in [true, false]) {
      testWidgets(
        'site ${isDirectory ? 'directory' : 'reader'} header and controls scroll away at $size',
        (tester) async {
          viewport(tester, size);
          repository.document = SiteDocument(
            url: isDirectory
                ? 'https://huarun.win/feed'
                : 'https://huarun.win/about',
            title: '滚动页面',
            directory: isDirectory,
            groups: const [
              SiteLinkGroup('分区导航', [
                SiteLink('当前分区', 'https://huarun.win/feed', selected: true),
              ]),
            ],
            items: [
              if (isDirectory)
                for (var index = 0; index < 60; index++)
                  SiteItem(
                    title: '条目 $index',
                    url: 'https://huarun.win/feed/$index',
                    summary: '公开条目简介',
                  ),
            ],
            blocks: [
              if (!isDirectory)
                for (var index = 0; index < 60; index++)
                  SiteBlock(runs: [SiteText('正文段落 $index，保留完整阅读内容与链接。')]),
            ],
          );
          await tester.pumpWidget(
            MaterialApp(
              theme: appTheme(Brightness.light),
              home: SitePage(
                url: repository.document.url,
                controller: controller,
                downloads: downloads,
              ),
            ),
          );
          await tester.pumpAndSettle();
          final title = isDirectory ? '生态动态' : '滚动页面';
          final group = isDirectory ? '当前分区' : '分区导航';
          final titleFinder = find.descendant(
            of: find.byType(PageHeader),
            matching: find.text(title),
          );
          expect(titleFinder.hitTestable(), findsOneWidget);
          expect(find.byType(TextField).hitTestable(), findsOneWidget);
          expect(find.text(group).hitTestable(), findsOneWidget);
          expect(find.byType(AppBar), findsNothing);
          if (isDirectory) expect(find.text('条目 59'), findsNothing);

          await scrollDown(tester, size);
          expect(titleFinder.hitTestable(), findsNothing);
          expect(find.byType(TextField).hitTestable(), findsNothing);
          expect(find.text(group).hitTestable(), findsNothing);
          expect(find.byTooltip('刷新内容').hitTestable(), findsNothing);
          if (isDirectory) expect(find.text('筛选').hitTestable(), findsNothing);
          expect(tester.takeException(), isNull);

          await tester.dragFrom(
            Offset(size.width * .7, 300),
            const Offset(0, 1600),
          );
          await tester.pumpAndSettle();
          expect(find.byType(TextField).hitTestable(), findsOneWidget);
          await tester.enterText(
            find.byType(TextField),
            isDirectory ? '条目 10' : '正文段落 10',
          );
          await tester.pumpAndSettle();
          expect(
            find.byWidgetPredicate(
              (widget) =>
                  widget is Text &&
                  widget.data == (isDirectory ? '条目 10' : '1 处匹配'),
            ),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      'detail actions scroll away and keyboard back still works at $size',
      (tester) async {
        viewport(tester, size);
        await tester.pumpWidget(
          HuarunApp(controller: controller, downloads: downloads),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(app.name));
        await tester.pumpAndSettle();
        expect(
          find.byTooltip('刷新详情').hitTestable(),
          size.width < 600 ? findsNothing : findsOneWidget,
        );
        expect(
          find.byTooltip(RegExp(r'^(返回|Back)$')).hitTestable(),
          findsOneWidget,
        );
        await scrollDown(tester, size);
        expect(find.byTooltip('刷新详情').hitTestable(), findsNothing);
        expect(find.byTooltip('在网站查看').hitTestable(), findsNothing);
        expect(
          find.byTooltip(RegExp(r'^(返回|Back)$')).hitTestable(),
          findsNothing,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text(app.name).hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant({
        TargetPlatform.macOS,
        TargetPlatform.windows,
      }),
    );

    testWidgets('downloads title scrolls with tasks at $size', (tester) async {
      viewport(tester, size);
      downloads.tasks.addAll([
        for (var index = 0; index < 30; index++)
          DownloadTask(
            id: '$index',
            appName: '下载任务 $index',
            url: 'https://example.com/$index.zip',
            filePath: '${directory.path}/$index.zip',
            kind: 'zip',
            createdAt: DateTime.now(),
            state: DownloadState.cancelled,
          ),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: Scaffold(body: DownloadsPage(manager: downloads)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('安装包与资源').hitTestable(), findsOneWidget);
      expect(
        find.byTooltip('刷新下载状态').hitTestable(),
        size.width < 600 ? findsNothing : findsOneWidget,
      );
      await scrollDown(tester, size);
      expect(find.text('安装包与资源').hitTestable(), findsNothing);
      expect(find.byTooltip('刷新下载状态').hitTestable(), findsNothing);
      expect(find.byTooltip('安装本地 DMG / ZIP').hitTestable(), findsNothing);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  }

  testWidgets('settings title scrolls with its content', (tester) async {
    viewport(tester, const Size(390, 844));
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Scaffold(
          body: SettingsPage(controller: controller, downloads: downloads),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('设置').hitTestable(), findsOneWidget);
    await scrollDown(tester, const Size(390, 844));
    expect(find.text('设置').hitTestable(), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'license list and full license text use scrolling headers and preserve back navigation',
    (tester) async {
      viewport(tester, const Size(390, 844));
      LicenseRegistry.addLicense(() async* {
        yield LicenseEntryWithLineBreaks(
          [
            for (var index = 0; index < 30; index++)
              'scroll_package_${index.toString().padLeft(2, '0')}',
          ],
          [for (var index = 0; index < 60; index++) '测试许可段落 $index：完整的软件许可内容。']
              .join('\n\n'),
        );
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: const LicensesPage(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('软件许可').hitTestable(), findsOneWidget);
      await scrollDown(tester, const Size(390, 844));
      expect(find.text('软件许可').hitTestable(), findsNothing);
      final package = find.text('scroll_package_00');
      await tester.scrollUntilVisible(package, -300);
      await tester.pumpAndSettle();
      await tester.tap(package);
      await tester.pumpAndSettle();
      expect(find.byType(ContentPage), findsOneWidget);
      expect(
        find.byTooltip(RegExp(r'^(返回|Back)$')).hitTestable(),
        findsOneWidget,
      );
      await scrollDown(tester, const Size(390, 844));
      expect(
        find.byTooltip(RegExp(r'^(返回|Back)$')).hitTestable(),
        findsNothing,
      );
      await tester.scrollUntilVisible(
        find.byTooltip(RegExp(r'^(返回|Back)$')),
        -300,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(RegExp(r'^(返回|Back)$')));
      await tester.pumpAndSettle();
      expect(package.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
