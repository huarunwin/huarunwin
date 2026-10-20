import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/html_parser.dart';
import 'package:huarunwin/data/models.dart';

void main() {
  final parser = SiteHtmlParser();
  String fixture(String name) =>
      File('test/fixtures/$name.html').readAsStringSync();
  final apps = parser.catalog(fixture('catalog'));
  test('parses real static cards without JavaScript', () {
    expect(
      apps.map((a) => a.name),
      containsAll(['Shadowrocket', 'FlClash', 'Clash Verge Rev']),
    );
    final flclash = apps.firstWhere((a) => a.id == 'flclash');
    expect(flclash.platforms, contains('macOS'));
    expect(flclash.icon, startsWith('https://huarun.win/'));
    expect(flclash.url, 'https://huarun.win/apps/flclash');
    expect(flclash.description, isNotEmpty);
  });
  test('default platform downloads never become guessed macOS packages', () {
    final detail = parser.detail(
      fixture('flclash'),
      apps.firstWhere((a) => a.id == 'flclash'),
    );
    expect(detail.app.name, 'FlClash');
    expect(detail.downloads.where((d) => d.kind == 'apk'), isNotEmpty);
    expect(
      detail.downloads
          .where((d) => d.kind == 'apk')
          .every((d) => d.platform == 'Android'),
      isTrue,
    );
    expect(detail.downloads.where((d) => d.kind == 'dmg'), isEmpty);
    expect(detail.releaseUrl, contains('/releases/tag/'));
    expect(detail.changelog, isNotEmpty);
  });
  test('semantic attributes identify a package, release page stays a page', () {
    const app = CatalogApp(
      id: 'example',
      name: 'Example',
      url: 'https://huarun.win/apps/example',
    );
    final detail = parser.detail(
      '''<article class="detail-page"><h1 id="detail-title">Example</h1>
    <a data-platform="macos" data-arch="arm64" data-kind="dmg" href="https://example.com/v1-arm64.dmg">Mac</a>
    <a class="detail-primary-action" href="https://github.com/example/app/releases">下载</a>
    <a data-platform="macos" href="javascript:alert(1)">bad</a></article>''',
      app,
    );
    expect(detail.downloads, hasLength(2));
    final package = detail.downloads.first;
    expect(package.platform, 'macOS');
    expect(package.architecture, 'arm64');
    expect(package.isPackage, isTrue);
    expect(detail.downloads.last.isPackage, isFalse);
  });
  test('withdrawn pages suppress all downloads', () {
    const app = CatalogApp(
      id: 'gone',
      name: 'Gone',
      url: 'https://huarun.win/apps/gone',
    );
    final detail = parser.detail(
      '''<article class="detail-page"><h1 id="detail-title">Gone</h1>
      <div class="detail-withdrawn-actions">已下架</div><a data-platform="macos" href="https://example.com/gone.dmg">下载</a></article>''',
      app,
    );
    expect(detail.app.withdrawn, isTrue);
    expect(detail.downloads, isEmpty);
  });
  test('optional metadata and malformed links do not break DOM details', () {
    final detail = parser.detail('''
      <script type="application/ld+json">{"@graph":false}</script>
      <script type="application/ld+json">{"@type":"SoftwareApplication","softwareVersion":"1.2.3","dateModified":"2026-10-16","description":42}</script>
      <article class="detail-page"><h1 id="detail-title">Example</h1>
      <p class="detail-summary">DOM summary</p>
      <a class="detail-primary-action" href="https://example.com">Homepage</a>
      <a data-platform="macos" href="https://[invalid">Invalid</a></article>
      ''', apps.first);
    expect(detail.version, '1.2.3');
    expect(detail.updatedAt, '2026-10-16');
    expect(detail.description, 'DOM summary');
    expect(detail.downloads.single.isPackage, isFalse);
    expect(detail.downloads.single.architecture, isNull);
  });
  test('invalid pages do not silently replace the catalog with zero apps', () {
    expect(
      () => parser.catalog('<html>Cloudflare challenge</html>'),
      throwsA(isA<PageFormatException>()),
    );
    expect(
      () => parser.detail('<h1>Not found</h1>', apps.first),
      throwsA(isA<PageFormatException>()),
    );
  });
  test('unknown fields stay unknown and relative URLs resolve correctly', () {
    final list = parser.catalog(
      '<article class="app-card"><a class="app-card-detail" href="/apps/minimal"><h2>Minimal</h2></a></article>',
    );
    expect(list.single.price, isEmpty);
    expect(list.single.platforms, isEmpty);
    expect(
      SiteHtmlParser.webUrl(
        '/image.webp',
        Uri.parse('https://huarun.win/apps/example'),
      ),
      'https://huarun.win/image.webp',
    );
    expect(
      SiteHtmlParser.webUrl(
        'file:///etc/passwd',
        Uri.parse('https://huarun.win'),
      ),
      isNull,
    );
  });
}
