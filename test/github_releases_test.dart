import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/models.dart';
import 'package:huarunwin/services/download_platform.dart';
import 'package:huarunwin/services/github_releases.dart';
import 'package:huarunwin/services/mac_downloads.dart';

import 'mac_downloads_test.dart' show ReleaseAdapter;

class LatestHtmlSource extends MacDownloadResolver {
  LatestHtmlSource(this.page, {this.error});
  final Uri page;
  final Object? error;
  final requests = <Uri>[];
  @override
  Future<(String, Uri)> readGitHubHtml(Uri uri) async {
    requests.add(uri);
    if (error != null) throw error!;
    return (
      '''<div><h1 data-view-component="true">Stable release</h1><span class="Label">Latest</span></div>
      <li><a href="/owner/repo/releases/download/v1%2Fstable/app-arm64.dmg">DMG</a></li>''',
      page,
    );
  }
}

void main() {
  final index = Uri.parse('https://github.com/chen08209/FlClash/releases');
  final listHtml = File('test/fixtures/github-flclash-releases.html')
      .readAsStringSync();
  final release = GitHubRelease(
    page: Uri.parse('https://github.com/owner/repo/releases/tag/v1%2Fstable'),
    tag: 'v1/stable',
    name: 'Version 1',
  );

  test('architecture markers recognize underscore-separated assets without matching unrelated words', () {
    for (final name in [
      'App_1.0_x64_setup.exe',
      'app-x86_64.apk',
      'app_x86-64.deb',
    ]) {
      expect(MacDownloadResolver.architecture(name), 'x64');
    }
    expect(MacDownloadResolver.architecture('app_x86_setup.exe'), 'x86');
    expect(MacDownloadResolver.architecture('app_arm64-v8a.apk'), 'arm64');
    expect(MacDownloadResolver.architecture('app-arm64-x64.dmg'), 'universal');
    expect(MacDownloadResolver.architecture('alarm64.apk'), isNull);
    expect(MacDownloadResolver.architecture('universalism.dmg'), isNull);
  });

  test('public release sections retain tags, stable status, dates and real pagination', () {
    final page = GitHubReleaseResolver.releasesFromHtml(listHtml, index);
    expect(page.releases.map((r) => r.tag), ['v0.9.1', 'v0.9.0']);
    expect(page.releases.first.latest, isTrue);
    expect(page.releases.first.prerelease, isFalse);
    expect(page.releases.last.latest, isFalse);
    expect(
      page.releases.first.publishedAt,
      DateTime.utc(2026, 10, 17, 10, 24, 48),
    );
    expect(page.next.toString(), '$index?page=2');
  });

  test('release badges belong to the header, not release notes or another repository', () {
    final page = GitHubReleaseResolver.releasesFromHtml('''
      <section data-release-anchor="v2">
        <div><span class="f1"><a href="/owner/repo/releases/tag/v2">Version two</a></span><span class="Label">Pre-release</span></div>
        <div class="markdown-body"><a href="/owner/repo/releases/tag/v1">Older</a><span class="Label">Latest</span></div>
      </section>
      <section data-release-anchor="wrong"><span class="f1"><a href="/other/repo/releases/tag/v3">Wrong repository</a></span></section>
      <a rel="next" href="https://github.com.evil.test/owner/repo/releases?page=2">Next</a>
      <a rel="next" href="/other/repo/releases?page=2">Next</a>
      <a rel="next" href="/owner/repo/releases?after=v2%2Fbeta&amp;expanded=true">Next</a>
      ''', Uri.parse('https://github.com/owner/repo/releases'));
    expect(page.releases, hasLength(1));
    expect(page.releases.single.name, 'Version two');
    expect(page.releases.single.prerelease, isTrue);
    expect(page.releases.single.latest, isFalse);
    expect(page.next!.queryParameters, {
      'after': 'v2/beta',
      'expanded': 'true',
    });
  });

  test('all published resources retain the chosen version, query and bound SHA-256', () {
    final digest = 'a' * 64;
    final resources = GitHubReleaseResolver.resourcesFromHtml('''
      <li><a href="/owner/repo/releases/download/v1%2Fstable/app-macos-arm64.dmg?download=1">Mac</a><clipboard-copy value="sha256:$digest"></clipboard-copy></li>
      <li><a href="/owner/repo/releases/download/v1%2Fstable/checksums.txt">Checksums</a></li>
      <li><a href="/owner/repo/releases/download/v1%2Fstable/app-debug-arm64.apk">Debug</a></li>
      <li><a href="/owner/repo/archive/refs/tags/v1%2Fstable.zip">Source code (zip)</a></li>
      <a href="/owner/repo/releases/download/v0/app.dmg">Other version</a>
      <a href="/other/repo/releases/download/v1%2Fstable/app.dmg">Other repository</a>
      <a href="https://user@github.com/owner/repo/releases/download/v1%2Fstable/app.dmg">Credentials</a>
      <a href="/owner/repo/archive/refs/tags/v0.zip">Other source</a>
      ''', release);
    expect(resources, hasLength(4));
    expect(resources.first.kind, 'dmg');
    expect(resources.first.platform, 'macOS');
    expect(resources.first.url, endsWith('?download=1'));
    expect(resources.first.sha256, digest);
    expect(resources.every((r) => r.version == 'v1/stable'), isTrue);
    expect(
      resources.every((r) => r.releaseUrl == release.page.toString()),
      isTrue,
    );
    expect(
      resources.skip(1).every((r) => r.kind == 'resource' && !r.isPackage),
      isTrue,
    );
    expect(resources.every((r) => r.isDownloadable), isTrue);
    expect(resources.skip(1).every((r) => r.sha256 == null), isTrue);
  });

  test('selected release uses cached section and its deferred asset fragment only', () async {
    const fragment =
        'https://github.com/chen08209/FlClash/releases/expanded_assets/v0.9.0';
    final adapter = ReleaseAdapter({
      index.toString(): listHtml,
      fragment: File('test/fixtures/github-flclash-release.html')
          .readAsStringSync(),
    });
    final client = Dio()..httpClientAdapter = adapter;
    addTearDown(() => client.close(force: true));
    final resolver = GitHubReleaseResolver(MacDownloadResolver(client: client));
    final page = await resolver.loadPage(index);
    final assets = await resolver.loadResources(page.releases.last);
    expect(assets, hasLength(10));
    expect(assets.every((r) => r.version == 'v0.9.0'), isTrue);
    expect(adapter.requests, [index.toString(), fragment]);
    expect(await resolver.loadResources(page.releases.last), same(assets));
    expect(adapter.requests, hasLength(2));
    expect(
      adapter.requests.every((url) => !url.contains('api.github.com')),
      isTrue,
    );
  });

  test(
    'deferred fragment cannot load assets from another tag or host',
    () async {
      final adapter = ReleaseAdapter({
        release.page.toString(): '''
        <include-fragment src="https://github.com/owner/repo/releases/expanded_assets/v0"></include-fragment>
        <include-fragment src="https://github.com.evil.test/owner/repo/releases/expanded_assets/v1%2Fstable"></include-fragment>
        <a href="/owner/repo/releases/download/v1%2Fstable/app.apk">APK</a>
      ''',
      });
      final client = Dio()..httpClientAdapter = adapter;
      addTearDown(() => client.close(force: true));
      final resources = await GitHubReleaseResolver(
        MacDownloadResolver(client: client),
      ).loadResources(release);
      expect(resources.single.kind, 'apk');
      expect(adapter.requests, [release.page.toString()]);
    },
  );

  test('latest redirect supplies a stable tag absent from the first page and caches its resources', () async {
    final source = LatestHtmlSource(release.page);
    addTearDown(() => source.client.close(force: true));
    final resolver = GitHubReleaseResolver(source);
    final latest = await resolver.loadLatest(
      Uri.parse('https://github.com/owner/repo/releases'),
    );
    expect(latest!.tag, 'v1/stable');
    expect(latest.latest, isTrue);
    expect(latest.name, 'Stable release');
    final assets = await resolver.loadResources(latest);
    expect(assets.single.version, 'v1/stable');
    expect(source.requests.map((u) => u.toString()), [
      'https://github.com/owner/repo/releases/latest',
    ]);
  });

  test('only a missing latest endpoint means no stable release; network failure remains retryable', () async {
    final request = RequestOptions(
      path: 'https://github.com/owner/repo/releases/latest',
    );
    for (final status in [404, 503]) {
      final source = LatestHtmlSource(
        release.page,
        error: DioException(
          requestOptions: request,
          response: Response(requestOptions: request, statusCode: status),
        ),
      );
      addTearDown(() => source.client.close(force: true));
      final future = GitHubReleaseResolver(source).loadLatest(release.page);
      if (status == 404) {
        expect(await future, isNull);
      } else {
        await expectLater(future, throwsA(isA<DioException>()));
      }
    }
  });

  test('latest redirect into another repository is rejected', () async {
    final source = LatestHtmlSource(
      Uri.parse('https://github.com/other/repo/releases/tag/v9'),
    );
    addTearDown(() => source.client.close(force: true));
    await expectLater(
      GitHubReleaseResolver(source).loadLatest(release.page),
      throwsFormatException,
    );
  });

  test('source follows platform-specific repository and preserves App Store routing', () {
    const app = CatalogApp(
      id: 'example',
      name: 'Example',
      url: 'https://huarun.win/apps/example',
      platforms: ['macOS', 'Android'],
    );
    expect(
      GitHubReleaseResolver.sourceFor(
        const AppDetails(
          app: app,
          releaseUrl: 'https://github.com/owner/desktop/releases/latest',
          downloads: [
            DownloadLink(
              url: 'https://github.com/owner/mobile/releases/download/v1/app.apk',
              label: 'APK',
              platform: 'Android',
              kind: 'apk',
            ),
          ],
        ),
        'Android',
      )!.path,
      '/owner/mobile/releases/tag/v1',
    );
    expect(
      GitHubReleaseResolver.sourceFor(
        const AppDetails(
          app: app,
          releaseUrl: 'https://github.com/owner/desktop',
          downloads: [
            DownloadLink(
              url: 'https://apps.apple.com/app/id123456',
              label: 'Store',
              platform: 'macOS',
            ),
          ],
        ),
        'macOS',
      ),
      isNull,
    );
    expect(
      GitHubReleaseResolver.sourceFor(const AppDetails(app: app), 'Windows'),
      isNull,
    );
  });

  DownloadLink asset(String name, String platform, String kind, String? arch) =>
      DownloadLink(
        url: 'https://example.com/$name',
        label: name,
        platform: platform,
        kind: kind,
        architecture: arch,
      );
  for (final platform in ['macOS', 'Android', 'Windows', 'Linux']) {
    test(
      '$platform prefers real native resources and retains ambiguous/unknown compatibility',
      () {
        final kind = switch (platform) {
          'macOS' => 'dmg',
          'Android' => 'apk',
          'Windows' => 'exe',
          _ => 'deb',
        };
        final native = asset('native', platform, kind, 'arm64');
        final universal = asset('universal', platform, kind, 'universal');
        final foreign = asset('foreign', platform, kind, 'x64');
        final preferences = ReleaseDownloadPreferences(
          platform: platform,
          running: platform,
          architecture: 'arm64',
          linuxPackageKind: 'deb',
        );
        expect(
          preferences.recommended([foreign, universal, native]),
          same(native),
        );
        expect(preferences.recommended([foreign, universal]), same(universal));
        expect(preferences.recommended([foreign]), isNull);
        expect(preferences.initialResource([foreign]), isNull);
        expect(preferences.hasSuitableResource([foreign]), isFalse);
        expect(
          preferences.recommended([
            native,
            asset('variant', platform, kind, 'arm64'),
          ]),
          isNull,
        );
        expect(
          ReleaseDownloadPreferences(
            platform: platform,
            running: platform,
          ).recommended([native]),
          isNull,
        );
      },
    );
  }

  test('format defaults prefer Mac DMG, Windows installer and Linux distro package', () {
    for (final platform in ['macOS', 'Windows', 'Linux']) {
      final kind = switch (platform) {
        'macOS' => 'dmg',
        'Windows' => 'exe',
        _ => 'deb',
      };
      final preferred = asset('installer', platform, kind, 'arm64');
      final zip = asset('archive', platform, 'zip', 'arm64');
      final preferences = ReleaseDownloadPreferences(
        platform: platform,
        running: platform,
        architecture: 'arm64',
        linuxPackageKind: 'deb',
      );
      expect(preferences.recommended([zip, preferred]), same(preferred));
    }
    final ubuntu = ReleaseDownloadPreferences(
      platform: 'Linux',
      running: 'Linux',
      architecture: 'x64',
      linuxPackageKind: 'deb',
    );
    expect(
      ubuntu.hasSuitableResource([asset('rpm', 'Linux', 'rpm', 'x64')]),
      isFalse,
    );
    expect(ubuntu.recommended([asset('rpm', 'Linux', 'rpm', 'x64')]), isNull);
  });
}
