import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/repository.dart';
import 'package:huarunwin/services/content_sources.dart';
import 'package:huarunwin/services/github_acceleration.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MirrorAdapter implements HttpClientAdapter {
  MirrorAdapter({this.successHost = 'cdn.jsdelivr.net'});

  final String successHost;
  final hosts = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    hosts.add(options.uri.host);
    final mirror = options.uri.host == successHost;
    return ResponseBody.fromString(
      mirror ? File('test/fixtures/catalog.html').readAsStringSync() : '',
      mirror ? 200 : 503,
      headers: {
        'content-type': ['text/plain; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences preferences;
  late ContentSources sources;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    sources = ContentSources()..restore(preferences);
  });

  tearDown(() => sources.dispose());

  Map<String, dynamic> savedState() =>
      jsonDecode(preferences.getString('contentSourceState')!)
          as Map<String, dynamic>;

  Future<void> restoreHold(DateTime startedAt) async {
    await preferences.setString(
      'contentSourceState',
      jsonEncode({
        'origin': 'jsdelivr',
        'fallbackStartedAt': startedAt.toUtc().toIso8601String(),
      }),
    );
    sources.restore(preferences);
  }

  test('automatic requests try the website and both mirrors in order', () {
    expect(sources.beginRequest().candidates, ContentOrigin.values);
    final page = Uri.parse('https://huarun.win/apps/flclash?view=all#download');
    expect(
      sources.pageUri(page, ContentOrigin.jsdelivr).toString(),
      'https://cdn.jsdelivr.net/gh/huarunwin/huarunwin-static@main/apps/flclash.html?view=all',
    );
    expect(sources.pageUri(page, ContentOrigin.website), page);
  });

  test('image fallback tries both GitHub routes before jsDelivr', () {
    final github = GitHubAcceleration()..restore(preferences);
    addTearDown(github.dispose);
    const original = 'https://huarun.win/app-icons/example.webp?v=2';
    final raw = sources.imageUrl(original, origin: ContentOrigin.github);
    expect(sources.imageUrls(original, github: github), [
      original,
      raw,
      '${GitHubAcceleration.proxyBase}$raw',
      sources.imageUrl(original, origin: ContentOrigin.jsdelivr),
    ]);
    expect(sources.imageUrls(original), [
      original,
      raw,
      sources.imageUrl(original, origin: ContentOrigin.jsdelivr),
    ]);
  });

  test('one content source selects the matching image route', () async {
    final github = GitHubAcceleration()..restore(preferences);
    addTearDown(github.dispose);
    const original = 'https://huarun.win/app-icons/example.webp';
    final raw = sources.imageUrl(original, origin: ContentOrigin.github);
    await sources.select(ContentSourceMode.ghproxy);
    expect(sources.imageUrls(original, github: github), [
      '${GitHubAcceleration.proxyBase}$raw',
    ]);
    expect(sources.imageUrls(original), [
      '${GitHubAcceleration.proxyBase}$raw',
    ]);
    await sources.select(ContentSourceMode.github);
    expect(sources.imageUrls(original, github: github), [raw]);
    await sources.select(ContentSourceMode.automatic);
    expect(sources.imageUrls(original, github: github), [
      original,
      raw,
      '${GitHubAcceleration.proxyBase}$raw',
      sources.imageUrl(original, origin: ContentOrigin.jsdelivr),
    ]);
    await sources.select(ContentSourceMode.website);
    expect(sources.imageUrls(original, github: github), [original]);
    await sources.select(ContentSourceMode.jsdelivr);
    expect(sources.imageUrls(original, github: github), [
      sources.imageUrl(original, origin: ContentOrigin.jsdelivr),
    ]);
  });

  test(
    'images follow Raw recovery without changing either hold period',
    () async {
      var now = DateTime.utc(2026, 10, 23, 12);
      final github = GitHubAcceleration(clock: () => now)..restore(preferences);
      addTearDown(github.dispose);
      const original = 'https://huarun.win/app-icons/example.webp';
      final raw = sources.imageUrl(original, origin: ContentOrigin.github);
      final page = sources.pageUri(
        Uri.parse('https://huarun.win/'),
        ContentOrigin.github,
      );
      await sources.succeeded(
        ContentOrigin.github,
        request: sources.beginRequest(),
      );
      await github.succeeded(
        github.begin(GitHubTraffic.raw, page),
        GitHubRoute.proxy,
      );
      final sourceState = preferences.getString('contentSourceState');
      final routeState = preferences.getString('githubAcceleration');
      now = now.add(const Duration(hours: 3));
      expect(sources.imageUrls(original, github: github), [
        '${GitHubAcceleration.proxyBase}$raw',
        raw,
        original,
        sources.imageUrl(original, origin: ContentOrigin.jsdelivr),
      ]);
      expect(preferences.getString('contentSourceState'), sourceState);
      expect(preferences.getString('githubAcceleration'), routeState);

      final retry = github.begin(GitHubTraffic.raw, page);
      expect(retry.routes.first, GitHubRoute.direct);
      await github.succeeded(retry, GitHubRoute.direct);
      expect(sources.imageUrls(original, github: github).first, raw);
      expect(preferences.getString('contentSourceState'), sourceState);
      expect(github.lastSuccessful(GitHubTraffic.download), isNull);
    },
  );

  test('external and non-image URLs never use the image proxy', () async {
    final github = GitHubAcceleration()..restore(preferences);
    addTearDown(github.dispose);
    await sources.select(ContentSourceMode.ghproxy);
    for (final original in [
      'https://images.example.test/icon.webp',
      'https://raw.githubusercontent.com/example/app/main/icon.webp',
      'https://huarun.win/apps/example',
      'https://user:secret@huarun.win/icon.webp',
      'http://huarun.win/icon.webp',
    ]) {
      expect(sources.imageUrls(original, github: github), [original]);
    }
  });

  test('a fallback persists its two-hour hold without extending it', () async {
    await sources.succeeded(
      ContentOrigin.jsdelivr,
      request: sources.beginRequest(),
    );
    expect(savedState()['origin'], 'jsdelivr');
    expect(savedState()['fallbackStartedAt'], isNotNull);

    final startedAt = DateTime.now().subtract(const Duration(hours: 1));
    await restoreHold(startedAt);
    expect(sources.beginRequest().candidates, [
      ContentOrigin.jsdelivr,
      ContentOrigin.website,
      ContentOrigin.github,
    ]);
    await sources.succeeded(
      ContentOrigin.jsdelivr,
      request: sources.beginRequest(),
    );
    expect(
      savedState()['fallbackStartedAt'],
      startedAt.toUtc().toIso8601String(),
    );

    final restarted = ContentSources()..restore(preferences);
    addTearDown(restarted.dispose);
    expect(restarted.beginRequest().candidates.first, ContentOrigin.jsdelivr);
  });

  for (final age in [const Duration(hours: 3), const Duration(hours: -1)]) {
    test('an expired or future hold retries the website: $age', () async {
      await restoreHold(DateTime.now().subtract(age));
      expect(sources.beginRequest().candidates, ContentOrigin.values);
      // Cached content and images retain their origin until HTML succeeds.
      expect(sources.active, ContentOrigin.jsdelivr);
      await sources.reload();
      expect(savedState()['fallbackStartedAt'], isNull);
    });
  }

  test('manual refresh rejects an older request and retries primary', () async {
    await restoreHold(DateTime.now().subtract(const Duration(minutes: 20)));
    final older = sources.beginRequest();
    sources.retryPrimary();
    await sources.succeeded(ContentOrigin.jsdelivr, request: older);
    expect(sources.beginRequest().candidates, ContentOrigin.values);
    await sources.succeeded(
      ContentOrigin.website,
      request: sources.beginRequest(),
    );
    await sources.reload();
    expect(sources.active, ContentOrigin.website);
    expect(savedState(), {'origin': 'website', 'fallbackStartedAt': null});
  });

  test('switching to a fixed source invalidates older results', () async {
    await restoreHold(DateTime.now().subtract(const Duration(minutes: 20)));
    final older = sources.beginRequest();
    await sources.select(ContentSourceMode.github);
    await sources.succeeded(ContentOrigin.website, request: older);
    sources.retryPrimary();
    expect(sources.beginRequest().candidates, [ContentOrigin.github]);
    await sources.reload();
    expect(sources.mode, ContentSourceMode.github);
    expect(savedState()['fallbackStartedAt'], isNull);
  });

  test(
    'refresh waits for queued state writes and preserves the last result',
    () async {
      final fallback = sources.succeeded(
        ContentOrigin.jsdelivr,
        request: sources.beginRequest(),
      );
      sources.retryPrimary();
      final primary = sources.succeeded(
        ContentOrigin.website,
        request: sources.beginRequest(),
      );
      await sources.reload();
      await Future.wait([fallback, primary]);
      expect(sources.active, ContentOrigin.website);
      expect(savedState(), {'origin': 'website', 'fallbackStartedAt': null});
    },
  );

  test('legacy preferences do not start an indefinite mirror hold', () async {
    await preferences.setString('lastContentOrigin', 'github');
    sources.restore(preferences);
    expect(sources.active, ContentOrigin.github);
    expect(sources.beginRequest().candidates, ContentOrigin.values);
  });

  for (final (legacy, expected) in [
    ('automatic', ContentSourceMode.ghproxy),
    ('github', ContentSourceMode.ghproxy),
    ('website', ContentSourceMode.website),
    ('jsdelivr', ContentSourceMode.jsdelivr),
  ]) {
    test('legacy $legacy plus proxy restores one source choice', () async {
      await preferences.setString('contentSource', legacy);
      await preferences.setString(
        'githubAcceleration',
        jsonEncode({'mode': 'proxy'}),
      );
      sources.restore(preferences);
      expect(sources.mode, expected);

      await sources.select(ContentSourceMode.github);
      final restarted = ContentSources()..restore(preferences);
      addTearDown(restarted.dispose);
      expect(restarted.mode, ContentSourceMode.github);
    });
  }

  test(
    'unified source controls HTML, downloads and restored routing',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'huarun-source-qa',
      );
      addTearDown(() => directory.delete(recursive: true));
      final github = GitHubAcceleration()..restore(preferences);
      addTearDown(github.dispose);
      final client = Dio();
      final repository = CatalogRepository(
        directory,
        sources: sources,
        github: github,
        client: client,
      );
      addTearDown(repository.dispose);
      final asset = Uri.parse(
        'https://github.com/example/app/releases/download/v1.0/app.apk',
      );

      await sources.select(ContentSourceMode.ghproxy);
      final proxy = MirrorAdapter(successHost: 'gh-proxy.com');
      client.httpClientAdapter = proxy;
      final catalog = await repository.catalog(refresh: true);
      expect(catalog.apps, isNotEmpty);
      expect(proxy.hosts, ['gh-proxy.com']);
      final previousDownload = github.begin(GitHubTraffic.download, asset);
      expect(previousDownload.routes, [GitHubRoute.proxy]);

      await sources.select(ContentSourceMode.github);
      final direct = MirrorAdapter(successHost: 'raw.githubusercontent.com');
      client.httpClientAdapter = direct;
      await repository.catalog(refresh: true);
      expect(direct.hosts, ['raw.githubusercontent.com']);
      await github.succeeded(previousDownload, GitHubRoute.proxy);
      expect(github.lastSuccessful(GitHubTraffic.download), isNull);
      expect(previousDownload.routes, [GitHubRoute.proxy]);
      await preferences.setString(
        'githubAcceleration',
        jsonEncode({'mode': 'proxy'}),
      );
      await github.reload();
      await sources.reload();
      expect(sources.mode, ContentSourceMode.github);
      expect(github.begin(GitHubTraffic.download, asset).routes, [
        GitHubRoute.direct,
      ]);

      await sources.select(ContentSourceMode.website);
      expect(github.begin(GitHubTraffic.download, asset).routes, [
        GitHubRoute.direct,
        GitHubRoute.proxy,
      ]);
    },
  );

  test(
    'repository falls back to jsDelivr and keeps original content URLs',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'huarun-mirror-qa',
      );
      addTearDown(() => directory.delete(recursive: true));
      final adapter = MirrorAdapter();
      final repository = CatalogRepository(
        directory,
        sources: sources,
        client: Dio()..httpClientAdapter = adapter,
      );
      addTearDown(() => repository.client.close(force: true));
      final catalog = await repository.catalog(refresh: true);
      expect(catalog.apps, isNotEmpty);
      expect(
        catalog.apps.every((app) => Uri.parse(app.url).host == 'huarun.win'),
        isTrue,
      );
      expect(adapter.hosts, [
        'huarun.win',
        'raw.githubusercontent.com',
        'cdn.jsdelivr.net',
      ]);
      adapter.hosts.clear();
      await repository.catalog(refresh: true);
      expect(adapter.hosts, ['cdn.jsdelivr.net']);
      adapter.hosts.clear();
      sources.retryPrimary();
      await repository.catalog(refresh: true);
      expect(adapter.hosts, [
        'huarun.win',
        'raw.githubusercontent.com',
        'cdn.jsdelivr.net',
      ]);
    },
  );
}
