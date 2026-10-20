import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import 'html_parser.dart';
import 'catalog_filters.dart';
import 'models.dart';
import 'site_models.dart';
import 'site_parser.dart';

List<CatalogApp> _parseCatalog(String html) => SiteHtmlParser().catalog(html);
AppDetails _parseDetail((String, CatalogApp) input) =>
    SiteHtmlParser().detail(input.$1, input.$2);
SiteDocument _parsePage((String, String) input) =>
    PublicSiteParser().parse(input.$1, input.$2);

class CatalogRepository {
  CatalogRepository(this.directory, {Dio? client})
    : client =
          client ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 25),
              responseType: ResponseType.plain,
              headers: {
                'Accept': 'text/html',
                'User-Agent': 'HuarunWin/0.1 (+https://huarun.win)',
              },
            ),
          );
  final Directory directory;
  final Dio client;
  static const maxPageBytes = 8 * 1024 * 1024;
  final Map<String, Future<SiteSnapshot>> _siteRequests = {};
  final Map<String, SiteSnapshot> _siteSnapshots = {};
  final Set<String> _failedDetailRefreshes = {};

  // Reuse parsed HTML during this session; disk remains the persistent cache.
  SiteSnapshot? cachedPage(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !SiteRoutes.isNative(uri) || url.length > 1500) {
      return null;
    }
    final value = _siteSnapshots[uri.removeFragment().toString()];
    if (value == null ||
        DateTime.now().difference(value.at) >= const Duration(minutes: 30)) {
      return null;
    }
    return SiteSnapshot(
      value.document,
      value.at,
      cached: true,
      warning: value.warning,
    );
  }

  Future<SiteSnapshot> page(String url, {bool refresh = false}) async {
    final requested = Uri.tryParse(url);
    if (requested == null ||
        !SiteRoutes.isNative(requested) ||
        url.length > 1500) {
      throw const PageFormatException('这个地址需要通过系统浏览器打开。');
    }
    final uri = requested.removeFragment();
    if (!refresh) {
      final cached = cachedPage(url);
      if (cached != null) return cached;
    }
    final key = '${uri.toString()}|$refresh';
    final existing = _siteRequests[key];
    if (existing != null) return existing;
    final request = _page(uri, refresh: refresh);
    _siteRequests[key] = request;
    try {
      final value = await request;
      final pageKey = uri.toString();
      _siteSnapshots.remove(pageKey);
      _siteSnapshots[pageKey] = value;
      if (_siteSnapshots.length > 24) {
        _siteSnapshots.remove(_siteSnapshots.keys.first);
      }
      return value;
    } finally {
      _siteRequests.remove(key);
    }
  }

  Future<SiteSnapshot> _page(Uri uri, {required bool refresh}) async {
    // Split the encoded URL into short directory components for filesystem
    // limits, without dropping query parameters or risking hash collisions.
    final encoded = base64Url.encode(utf8.encode(uri.toString()));
    final components = [
      for (var i = 0; i < encoded.length; i += 120)
        encoded.substring(i, (i + 120).clamp(0, encoded.length)),
    ];
    final file = File(
      path.joinAll([
        directory.path,
        'pages',
        ...components,
        'document.html-cache',
      ]),
    );
    final cached = await _read(file);
    final cachedUri = Uri.tryParse(cached?.$3 ?? '');
    final sourceUri = cachedUri != null && SiteRoutes.isNative(cachedUri)
        ? cachedUri
        : uri;
    // Older page caches do not record the redirect target. Revalidate them
    // once, retaining their HTML as an offline fallback.
    if (!refresh &&
        cached != null &&
        cached.$3 != null &&
        DateTime.now().difference(cached.$2) < const Duration(minutes: 30)) {
      try {
        return SiteSnapshot(
          await compute(_parsePage, (cached.$1, sourceUri.toString())),
          cached.$2,
          cached: true,
        );
      } on PageFormatException {
        /* Retry with current HTML. */
      }
    }
    try {
      final response = await _getResponse(uri);
      final source = response.data!;
      final resolvedUri = response.realUri;
      if (!SiteRoutes.isNative(resolvedUri)) {
        throw const PageFormatException('这个地址需要通过系统浏览器打开。');
      }
      final document = await compute(_parsePage, (
        source,
        resolvedUri.toString(),
      ));
      final now = DateTime.now();
      await _write(file, source, now, sourceUrl: resolvedUri.toString());
      return SiteSnapshot(document, now);
    } catch (_) {
      if (cached != null) {
        return SiteSnapshot(
          await compute(_parsePage, (cached.$1, sourceUri.toString())),
          cached.$2,
          cached: true,
          warning: '暂时无法更新，正在显示上次保存的内容。',
        );
      }
      rethrow;
    }
  }

  Future<CatalogSnapshot> catalog({bool refresh = false, String? core}) async {
    final slug = core == null ? null : catalogCorePaths[core];
    if (core != null && slug == null) {
      throw const PageFormatException('无法识别这个内核分类。');
    }
    return _catalog(
      Uri.parse('https://huarun.win/${slug == null ? '' : 'core/$slug'}'),
      slug == null ? 'catalog.html-cache' : 'catalog-core-$slug.html-cache',
      refresh: refresh,
    );
  }

  Future<CatalogSnapshot> deviceCatalog(
    CatalogDevice device, {
    bool refresh = false,
  }) => _catalog(
    Uri.parse('https://huarun.win${device.path}'),
    'catalog-device-${device.cacheKey}.html-cache',
    refresh: refresh,
  );

  Future<CatalogSnapshot> _catalog(
    Uri uri,
    String cacheName, {
    required bool refresh,
  }) async {
    final file = File(path.join(directory.path, cacheName));
    final cached = await _read(file);
    if (!refresh &&
        cached != null &&
        DateTime.now().difference(cached.$2) < const Duration(minutes: 30)) {
      try {
        return CatalogSnapshot(
          await compute(_parseCatalog, cached.$1),
          cached.$2,
          cached: true,
        );
      } on PageFormatException {
        /* Fetch again if the cached schema changed. */
      }
    }
    try {
      final source = await _get(uri);
      final apps = await compute(_parseCatalog, source);
      final now = DateTime.now();
      await _write(file, source, now);
      return CatalogSnapshot(apps, now);
    } catch (error) {
      if (cached != null) {
        return CatalogSnapshot(
          await compute(_parseCatalog, cached.$1),
          cached.$2,
          cached: true,
          warning: '暂时无法更新，正在显示上次保存的内容。',
        );
      }
      rethrow;
    }
  }

  Future<DetailSnapshot> detail(CatalogApp app, {bool refresh = false}) async {
    final uri = Uri.parse(app.url);
    if (ApplicationType.fromUrl(uri) != app.type ||
        uri.pathSegments.last != app.id) {
      throw const PageFormatException('应用详情地址无效。');
    }
    final file = File(
      path.joinAll([
        directory.path,
        'details',
        if (!app.isClient) app.type.value,
        '${Uri.encodeComponent(app.id)}.html-cache',
      ]),
    );
    final cached = await _read(file);
    if (!refresh &&
        cached != null &&
        DateTime.now().difference(cached.$2) < const Duration(minutes: 30)) {
      try {
        return DetailSnapshot(
          await compute(_parseDetail, (cached.$1, app)),
          cached.$2,
          cached: true,
          refreshFailed: _failedDetailRefreshes.contains(app.key),
        );
      } on PageFormatException {
        /* Fetch a fresh document. */
      }
    }
    try {
      final source = await _get(uri);
      final result = await compute(_parseDetail, (source, app));
      final now = DateTime.now();
      await _write(file, source, now);
      _failedDetailRefreshes.remove(app.key);
      return DetailSnapshot(result, now);
    } catch (_) {
      _failedDetailRefreshes.add(app.key);
      if (cached != null) {
        return DetailSnapshot(
          await compute(_parseDetail, (cached.$1, app)),
          cached.$2,
          cached: true,
          refreshFailed: true,
        );
      }
      rethrow;
    }
  }

  Future<String> _get(Uri uri) async => (await _getResponse(uri)).data!;

  Future<Response<String>> _getResponse(Uri uri) async {
    final response = await client.getUri<String>(uri);
    final data = response.data;
    if (response.realUri.host != 'huarun.win' ||
        response.realUri.scheme != 'https' ||
        data == null ||
        data.length > maxPageBytes ||
        !(response.headers.value('content-type') ?? '').contains('text/html')) {
      throw const PageFormatException('网站返回了非预期的页面，请稍后重试。');
    }
    return response;
  }

  Future<(String, DateTime, String?)?> _read(File file) async {
    try {
      if (!await file.exists() || await file.length() > maxPageBytes * 2) {
        return null;
      }
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return (
        data['html'] as String,
        DateTime.parse(data['at'] as String),
        data['sourceUrl'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(
    File file,
    String html,
    DateTime at, {
    String? sourceUrl,
  }) async {
    try {
      await file.parent.create(recursive: true);
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(
        jsonEncode({
          'html': html,
          'at': at.toIso8601String(),
          'sourceUrl': ?sourceUrl,
        }),
        flush: true,
      );
      await temp.rename(file.path);
    } on FileSystemException {
      /* Cache is optional; network content remains usable. */
    }
  }
}
