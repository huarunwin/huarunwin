import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/repository.dart';
import 'package:huarunwin/services/content_sources.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MirrorAdapter implements HttpClientAdapter {
  final hosts = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    hosts.add(options.uri.host);
    final mirror = options.uri.host == 'cdn.jsdelivr.net';
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
