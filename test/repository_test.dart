import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:huarunwin/data/repository.dart';
import 'package:huarunwin/data/models.dart';

class HtmlAdapter implements HttpClientAdapter {
  String body;
  int calls = 0;
  final paths = <String>[];
  HtmlAdapter(this.body);
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    paths.add(options.uri.path);
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        'content-type': ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('failed detail refresh retains content but is not a successful update check', () async {
    final directory = await Directory.systemTemp.createTemp(
      'huarun-detail-fallback',
    );
    addTearDown(() => directory.delete(recursive: true));
    final html = File('test/fixtures/flclash.html').readAsStringSync();
    final adapter = HtmlAdapter(html);
    final repository = CatalogRepository(
      directory,
      client: Dio()..httpClientAdapter = adapter,
    );
    addTearDown(() => repository.client.close(force: true));
    const app = CatalogApp(
      id: 'flclash',
      name: 'FlClash',
      url: 'https://huarun.win/apps/flclash',
    );
    final first = await repository.detail(app);
    expect(first.refreshFailed, isFalse);
    expect((await repository.detail(app)).refreshFailed, isFalse);
    adapter.body = '<html>Unavailable</html>';
    final failed = await repository.detail(app, refresh: true);
    expect(failed.cached, isTrue);
    expect(failed.refreshFailed, isTrue);
    expect(failed.fetchedAt, first.fetchedAt);
    expect((await repository.detail(app)).refreshFailed, isTrue);
    adapter.body = html;
    expect(
      (await repository.detail(app, refresh: true)).refreshFailed,
      isFalse,
    );
  });
  test(
    'parsed pages are reused immediately and explicit refresh replaces them',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'huarun-page-memory',
      );
      addTearDown(() => directory.delete(recursive: true));
      final adapter = HtmlAdapter(
        File('test/fixtures/site/jichang.html').readAsStringSync(),
      );
      final repository = CatalogRepository(
        directory,
        client: Dio()..httpClientAdapter = adapter,
      );
      const url = 'https://huarun.win/jichang';
      expect(repository.cachedPage(url), isNull);
      final first = await repository.page(url);
      expect(
        repository.cachedPage('$url#plans')!.document,
        same(first.document),
      );
      expect(repository.cachedPage('$url?sort=name'), isNull);
      expect(repository.cachedPage('https://example.com/jichang'), isNull);

      // A warm navigation does not reread or reparse the disk cache.
      await Directory('${directory.path}/pages').delete(recursive: true);
      expect((await repository.page(url)).document, same(first.document));
      expect(adapter.calls, 1);
      adapter.body = '''<main><section class="catalog"><h1>机场目录</h1>
      <article class="vps-card"><h2><a class="vps-card-link" href="/jichang/refreshed">更新机场</a></h2></article>
      </section></main>''';
      await repository.page(url, refresh: true);
      expect(repository.cachedPage(url)!.document.items.single.title, '更新机场');
      expect(adapter.calls, 2);
      adapter.body = '<html>Unavailable</html>';
      final fallback = await repository.page(url, refresh: true);
      expect(fallback.warning, isNotNull);
      expect(repository.cachedPage(url)!.document.items.single.title, '更新机场');
      expect(repository.cachedPage(url)!.warning, fallback.warning);

      final cacheFile = await Directory('${directory.path}/pages')
          .list(recursive: true)
          .where((entry) => entry is File && entry.path.endsWith('.html-cache'))
          .cast<File>()
          .single;
      final stored =
          jsonDecode(await cacheFile.readAsString()) as Map<String, dynamic>;
      stored['at'] = DateTime.now()
          .subtract(const Duration(minutes: 31))
          .toIso8601String();
      await cacheFile.writeAsString(jsonEncode(stored));
      final restarted = CatalogRepository(
        directory,
        client: Dio()..httpClientAdapter = adapter,
      );
      final stale = await restarted.page(url);
      expect(stale.warning, isNotNull);
      expect(stale.document.items.single.title, '更新机场');
      // Old fallback content remains readable, but is not treated as fresh.
      expect(restarted.cachedPage(url), isNull);
    },
  );

  test(
    'core HTML has a separate cache and never replaces the main catalog',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'huarun-core-cache',
      );
      addTearDown(() => directory.delete(recursive: true));
      final adapter = HtmlAdapter(
        File('test/fixtures/catalog.html').readAsStringSync(),
      );
      final repository = CatalogRepository(
        directory,
        client: Dio()..httpClientAdapter = adapter,
      );
      final all = await repository.catalog();
      adapter.body = '<article class="app-card"><a href="/apps/multi"><h2>Multi</h2></a><span class="core">多内核</span></article>';
      final core = await repository.catalog(core: 'Mihomo');
      expect(core.apps.single.id, 'multi');
      expect(adapter.paths, ['/', '/core/mihomo']);
      expect((await repository.catalog()).apps.length, all.apps.length);
      adapter.body = '<h1>Unavailable</h1>';
      final fallback = await repository.catalog(core: 'Mihomo', refresh: true);
      expect(fallback.apps.single.id, 'multi');
      expect(fallback.warning, isNotNull);
      await expectLater(repository.catalog(core: '../bad'), throwsException);
      expect(adapter.calls, 3);
    },
  );

  test(
    'valid cache survives a malformed refresh and is reusable offline',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'huarun-cache-test',
      );
      addTearDown(() => directory.delete(recursive: true));
      final adapter = HtmlAdapter(
        File('test/fixtures/catalog.html').readAsStringSync(),
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final repository = CatalogRepository(directory, client: dio);
      final initial = await repository.catalog();
      expect(initial.apps, isNotEmpty);
      expect(initial.cached, isFalse);
      final cached = await repository.catalog();
      expect(cached.cached, isTrue);
      expect(adapter.calls, 1);
      adapter.body = '<html>Service unavailable</html>';
      final fallback = await repository.catalog(refresh: true);
      expect(fallback.apps.map((a) => a.id), initial.apps.map((a) => a.id));
      expect(fallback.warning, isNotNull);
      expect(fallback.fetchedAt, initial.fetchedAt);
    },
  );
}
