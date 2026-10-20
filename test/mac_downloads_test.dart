import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/html_parser.dart';
import 'package:huarunwin/data/models.dart';
import 'package:huarunwin/services/mac_downloads.dart';

class ReleaseAdapter implements HttpClientAdapter {
  ReleaseAdapter(this.pages);
  final Map<String, String> pages;
  final List<String> requests = [];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? body,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri.toString());
    final source = pages[options.uri.toString()];
    if (source == null) throw StateError('Unexpected request ${options.uri}');
    return ResponseBody.fromString(
      source,
      200,
      headers: {
        'content-type': ['text/html'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  const app = CatalogApp(
    id: 'flclash',
    name: 'FlClash',
    url: 'https://huarun.win/apps/flclash',
    platforms: ['macOS', 'Android'],
  );
  const release = 'https://github.com/chen08209/FlClash/releases/tag/v0.9.0';
  test(
    'real GitHub HTML supplies Mac packages absent from the website HTML',
    () async {
      final detail = SiteHtmlParser().detail(
        File('test/fixtures/flclash.html').readAsStringSync(),
        app,
      );
      expect(detail.downloads.where((p) => p.platform == 'macOS'), isEmpty);
      final adapter = ReleaseAdapter({
        release: File('test/fixtures/github-flclash-release.html')
            .readAsStringSync(),
      });
      final resolver = MacDownloadResolver(
        client: Dio()..httpClientAdapter = adapter,
      );
      final result = await resolver.resolve(detail);
      expect(result.packages, hasLength(2));
      expect(result.recommended('arm64')!.url, endsWith('macos-arm64.dmg'));
      expect(result.recommended('x64')!.url, endsWith('macos-amd64.dmg'));
      expect(result.recommended(null), isNull);
      expect(
        adapter.requests.every((u) => !u.contains('api.github.com')),
        isTrue,
      );
    },
  );

  test('collapsed assets are read as HTML and unrelated assets are excluded', () async {
    const fragment =
        'https://github.com/chen08209/FlClash/releases/expanded_assets/v0.9.0';
    final adapter = ReleaseAdapter({
      release:
          '<include-fragment src="$fragment"></include-fragment><include-fragment src="https://example.com/elsewhere"></include-fragment>',
      fragment: '''<a href="/chen08209/FlClash/releases/download/v0.9.0/app-macos-universal.zip">Mac</a>
        <a href="/chen08209/FlClash/releases/download/v0.9.0/app-windows.zip">Windows</a>
        <a href="/chen08209/FlClash/archive/refs/tags/v0.9.0.zip">Source</a>
        <a href="/other/repo/releases/download/v0.9.0/app.dmg">Other repository</a>
        <a href="/chen08209/FlClash/releases/download/v0.8.0/old.dmg">Old version</a>''',
    });
    final options = await MacDownloadResolver(
      client: Dio()..httpClientAdapter = adapter,
    ).resolve(const AppDetails(app: app, releaseUrl: release));
    expect(options.packages, hasLength(1));
    expect(options.recommended('arm64')!.architecture, 'universal');
    expect(adapter.requests, [release, fragment]);
  });

  test(
    'App Store goes directly to the system store with no GitHub request',
    () async {
      const store =
          'https://apps.apple.com/us/app/shadowrocket/id932747118?mt=12';
      final adapter = ReleaseAdapter({});
      final options =
          await MacDownloadResolver(
            client: Dio()..httpClientAdapter = adapter,
          ).resolve(
            const AppDetails(
              app: app,
              releaseUrl: store,
              downloads: [
                DownloadLink(
                  url: 'https://apps.apple.com/app/shadowrocket/id932747118',
                  label: '下载',
                  platform: 'iOS',
                ),
              ],
            ),
          );
      expect(options.stores, hasLength(1));
      expect(
        macAppStoreUri(options.stores.single).toString(),
        'macappstores://apps.apple.com/us/app/shadowrocket/id932747118?mt=12',
      );
      expect(adapter.requests, isEmpty);
      expect(
        isAppStoreUrl('https://apps.apple.com.evil.test/app/id123'),
        isFalse,
      );
      expect(isAppStoreUrl('https://github.com/apple/app'), isFalse);
    },
  );

  test(
    'Android asset identifies the same release, never a guessed Mac filename',
    () {
      expect(
        MacDownloadResolver.releasePage(
          'https://github.com/owner/repo/releases/download/v1%2Fbeta/app.apk',
        )!.toString(),
        'https://github.com/owner/repo/releases/tag/v1%2Fbeta',
      );
      expect(
        MacDownloadResolver.releasePage('https://github.com/owner/repo')!.path,
        '/owner/repo/releases/latest',
      );
      expect(
        MacDownloadResolver.releasePage(
          'https://github.com.evil.test/owner/repo',
        ),
        isNull,
      );
    },
  );

  test('Windows keeps published links when HTML checksums are unavailable', () async {
    final detail = SiteHtmlParser().detail(
      File('test/fixtures/clash-verge-rev.html').readAsStringSync(),
      const CatalogApp(
        id: 'clash-verge-rev',
        name: 'Clash Verge Rev',
        url: 'https://huarun.win/apps/clash-verge-rev',
      ),
    );
    final adapter = ReleaseAdapter({});
    final resolver = MacDownloadResolver(
      client: Dio()..httpClientAdapter = adapter,
    );
    final packages = await resolver.resolvePackages(detail, 'Windows');
    expect(packages, hasLength(2));
    expect(
      packages.every((p) => p.platform == 'Windows' && p.kind == 'exe'),
      isTrue,
    );
    expect(packages.map((p) => p.architecture), containsAll(['x64', 'arm64']));
    expect(adapter.requests, [
      'https://github.com/clash-verge-rev/clash-verge-rev/releases/tag/v2.5.8',
    ]);
    expect(packages.every((p) => p.sha256 == null), isTrue);
  });

  test('release assets stay within the chosen platform and preserve link queries', () async {
    const fragment =
        'https://github.com/chen08209/FlClash/releases/expanded_assets/v0.9.0';
    const windows =
        'https://github.com/chen08209/FlClash/releases/download/v0.9.0/app-windows-x64.zip?download=1';
    final adapter = ReleaseAdapter({
      release: '<include-fragment src="$fragment"></include-fragment>',
      fragment: '''<a href="$windows">Windows</a>
        <a href="/chen08209/FlClash/releases/download/v0.9.0/app-macos-arm64.dmg">Mac</a>
        <a href="/chen08209/FlClash/releases/download/v0.9.0/app-android-arm64.apk">Android</a>
        <a href="/chen08209/FlClash/releases/download/v0.9.0/app-linux-x64.deb">Linux</a>
        <a href="/chen08209/FlClash/releases/download/v0.9.0/source.zip">Unknown zip</a>
        <a href="/other/repo/releases/download/v0.9.0/app.exe">Other repository</a>
        <a href="/chen08209/FlClash/releases/download/v0.8.0/app.exe">Old version</a>''',
    });
    final resolver = MacDownloadResolver(
      client: Dio()..httpClientAdapter = adapter,
    );
    const detail = AppDetails(
      app: CatalogApp(
        id: 'flclash',
        name: 'FlClash',
        url: 'https://huarun.win/apps/flclash',
        platforms: ['Windows', 'macOS', 'Android', 'Linux'],
      ),
      releaseUrl: release,
    );
    final packages = await resolver.resolvePackages(detail, 'Windows');
    expect(packages.single.url, windows);
    expect(packages.single.platform, 'Windows');
    expect(
      (await resolver.resolvePackages(detail, 'Android')).single.kind,
      'apk',
    );
    expect(
      (await resolver.resolvePackages(detail, 'Linux')).single.kind,
      'deb',
    );
    expect(await resolver.resolvePackages(detail, 'iOS'), isEmpty);
    expect(
      adapter.requests.every((url) => !url.contains('api.github.com')),
      isTrue,
    );
  });

  test('Linux release HTML recognizes real Arch packages and not unrelated tar archives', () {
    final packages = MacDownloadResolver.packagesForPlatformFromHtml(
      '<a href="/owner/repo/releases/download/v1/app-linux-x64.pkg.tar.zst">Arch</a><a href="/owner/repo/releases/download/v1/app-linux-x64.tar.zst">Source</a>',
      Uri.parse('https://github.com/owner/repo/releases/tag/v1'),
      'Linux',
    );
    expect(packages.single.kind, 'pkg.tar.zst');
    expect(packages.single.architecture, 'x64');
  });
}
