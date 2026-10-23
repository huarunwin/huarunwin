import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import '../services/html_client.dart';
import '../services/content_sources.dart';
import '../services/github_acceleration.dart';
import 'html_parser.dart';
import 'catalog_filters.dart';
import 'models.dart';
import 'site_models.dart';
import 'site_parser.dart';

List<CatalogApp> _parseCatalog(String html) => SiteHtmlParser().catalog(html);
AppDetails _parseDetail((String, CatalogApp) input) =>
    SiteHtmlParser().detail(input.$1, input.$2);
List<CatalogRelease> _parseReleases((String, CatalogApp) input) =>
    SiteHtmlParser().releases(input.$1, input.$2);
SiteDocument _parsePage((String, String) input) =>
    PublicSiteParser().parse(input.$1, input.$2);

typedef _ContentResponse = ({
  String html,
  Uri logicalUri,
  ContentOrigin origin,
  ContentSourceRequest request,
});

class CatalogRepository {
  CatalogRepository(
    this.directory, {
    Dio? client,
    ContentSources? sources,
    this.github,
  }) : client = client ?? createHtmlClient(),
       _ownsSources = sources == null,
       sources = sources ?? ContentSources() {
    _sourceRevision = this.sources.revision;
    this.sources.addListener(_sourceChanged);
    this.sources.onRetryPrimary = () => github?.retryPrimary();
    this.sources.onSelectionChanged = (reset) =>
        github?.configure(this.sources.githubMode, reset: reset);
    github?.configure(this.sources.githubMode);
  }
  final ContentSources sources;
  final GitHubAcceleration? github;
  final bool _ownsSources;
  bool _disposed = false;
  late int _sourceRevision;
  final _pendingRequests = <CancelToken>{};

  void _cancelPendingRequests(String reason) {
    for (final request in _pendingRequests) {
      request.cancel(reason);
    }
    _pendingRequests.clear();
  }

  void _sourceChanged() {
    if (_sourceRevision == sources.revision) return;
    _sourceRevision = sources.revision;
    _cancelPendingRequests('Content source changed');
    _siteRequests.clear();
    _siteSnapshots.clear();
    _failedDetailRefreshes.clear();
  }

  void _checkRevision(int revision) {
    if (_disposed || revision != sources.revision) {
      throw const PageFormatException('内容来源已切换，请重新加载。');
    }
  }

  File _cacheFile(ContentOrigin origin, List<String> parts) => File(
    path.joinAll([
      directory.path,
      if (origin != ContentOrigin.website) origin.name,
      ...parts,
    ]),
  );

  String _pageKey(Uri uri, ContentOrigin origin) => '${origin.name}|$uri';

  void dispose() {
    _disposed = true;
    sources.removeListener(_sourceChanged);
    sources.onRetryPrimary = null;
    sources.onSelectionChanged = null;
    _cancelPendingRequests('Repository disposed');
    client.close(force: true);
    if (_ownsSources) sources.dispose();
  }

  final Directory directory;
  final Dio client;
  static const maxPageBytes = 8 * 1024 * 1024;
  static const _contentConnectTimeout = Duration(seconds: 3);
  static const _contentRequestTimeout = Duration(seconds: 5);
  final Map<String, Future<SiteSnapshot>> _siteRequests = {};
  final Map<String, SiteSnapshot> _siteSnapshots = {};
  final Set<String> _failedDetailRefreshes = {};

  // Reuse parsed HTML during this session; disk remains the persistent cache.
  SiteSnapshot? cachedPage(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !SiteRoutes.isNative(uri) || url.length > 1500) {
      return null;
    }
    final value =
        _siteSnapshots[_pageKey(uri.removeFragment(), sources.active)];
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
    final revision = sources.revision;
    final key = '$revision|${_pageKey(uri, sources.active)}|$refresh';
    final existing = _siteRequests[key];
    if (existing != null) return existing;
    final request = _page(uri, refresh: refresh).then((result) {
      _checkRevision(revision);
      final pageKey = _pageKey(uri, result.$2);
      _siteSnapshots.remove(pageKey);
      _siteSnapshots[pageKey] = result.$1;
      if (_siteSnapshots.length > 24) {
        _siteSnapshots.remove(_siteSnapshots.keys.first);
      }
      return result.$1;
    });
    _siteRequests[key] = request;
    try {
      return await request;
    } finally {
      _siteRequests.remove(key);
    }
  }

  Future<(SiteSnapshot, ContentOrigin)> _page(
    Uri uri, {
    required bool refresh,
  }) async {
    final revision = sources.revision;
    final preferred = sources.active;
    // Split the encoded URL into short directory components for filesystem
    // limits, without dropping query parameters or risking hash collisions.
    final encoded = base64Url.encode(utf8.encode(uri.toString()));
    final components = [
      for (var i = 0; i < encoded.length; i += 120)
        encoded.substring(i, (i + 120).clamp(0, encoded.length)),
    ];
    final cacheParts = ['pages', ...components, 'document.html-cache'];
    final file = _cacheFile(preferred, cacheParts);
    final cached = await _read(file);
    _checkRevision(revision);
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
        final document = await compute(_parsePage, (
          cached.$1,
          sourceUri.toString(),
        ));
        _checkRevision(revision);
        return (SiteSnapshot(document, cached.$2, cached: true), preferred);
      } on PageFormatException {
        /* Retry with current HTML. */
      }
    }
    try {
      final response = await _getResponse(uri, revision: revision);
      final source = response.html;
      final resolvedUri = response.logicalUri;
      if (!SiteRoutes.isNative(resolvedUri)) {
        throw const PageFormatException('这个地址需要通过系统浏览器打开。');
      }
      final document = await compute(_parsePage, (
        source,
        resolvedUri.toString(),
      ));
      final now = DateTime.now();
      _checkRevision(revision);
      await _write(
        _cacheFile(response.origin, cacheParts),
        source,
        now,
        revision: revision,
        sourceUrl: resolvedUri.toString(),
      );
      await _accept(response, revision);
      return (SiteSnapshot(document, now), response.origin);
    } catch (_) {
      _checkRevision(revision);
      if (cached != null) {
        final document = await compute(_parsePage, (
          cached.$1,
          sourceUri.toString(),
        ));
        _checkRevision(revision);
        return (
          SiteSnapshot(
            document,
            cached.$2,
            cached: true,
            warning: '暂时无法更新，正在显示上次保存的内容。',
          ),
          preferred,
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
    final revision = sources.revision;
    final preferred = sources.active;
    final file = _cacheFile(preferred, [cacheName]);
    final cached = await _read(file);
    _checkRevision(revision);
    if (!refresh &&
        cached != null &&
        DateTime.now().difference(cached.$2) < const Duration(minutes: 30)) {
      try {
        final apps = await compute(_parseCatalog, cached.$1);
        _checkRevision(revision);
        return CatalogSnapshot(apps, cached.$2, cached: true);
      } on PageFormatException {
        /* Fetch again if the cached schema changed. */
      }
    }
    try {
      final response = await _getResponse(uri, revision: revision);
      final apps = await compute(_parseCatalog, response.html);
      _checkRevision(revision);
      final now = DateTime.now();
      await _write(
        _cacheFile(response.origin, [cacheName]),
        response.html,
        now,
        revision: revision,
      );
      await _accept(response, revision);
      return CatalogSnapshot(apps, now);
    } catch (error) {
      _checkRevision(revision);
      if (cached != null) {
        final apps = await compute(_parseCatalog, cached.$1);
        _checkRevision(revision);
        return CatalogSnapshot(
          apps,
          cached.$2,
          cached: true,
          warning: '暂时无法更新，正在显示上次保存的内容。',
        );
      }
      rethrow;
    }
  }

  Future<DetailSnapshot> detail(CatalogApp app, {bool refresh = false}) async {
    final revision = sources.revision;
    final preferred = sources.active;
    final uri = Uri.parse(app.url);
    if (ApplicationType.fromUrl(uri) != app.type ||
        uri.pathSegments.last != app.id) {
      throw const PageFormatException('应用详情地址无效。');
    }
    final cacheParts = [
      'details',
      if (!app.isClient) app.type.value,
      '${Uri.encodeComponent(app.id)}.html-cache',
    ];
    final file = _cacheFile(preferred, cacheParts);
    final cached = await _read(file);
    _checkRevision(revision);
    final failureKey = '${preferred.name}|${app.key}';
    if (!refresh &&
        cached != null &&
        DateTime.now().difference(cached.$2) < const Duration(minutes: 30)) {
      try {
        final detail = await compute(_parseDetail, (cached.$1, app));
        _checkRevision(revision);
        return DetailSnapshot(
          detail,
          cached.$2,
          cached: true,
          refreshFailed: _failedDetailRefreshes.contains(failureKey),
        );
      } on PageFormatException {
        /* Fetch a fresh document. */
      }
    }
    try {
      final response = await _getResponse(uri, revision: revision);
      final result = await compute(_parseDetail, (response.html, app));
      _checkRevision(revision);
      final now = DateTime.now();
      await _write(
        _cacheFile(response.origin, cacheParts),
        response.html,
        now,
        revision: revision,
      );
      await _accept(response, revision);
      _failedDetailRefreshes.remove('${response.origin.name}|${app.key}');
      return DetailSnapshot(result, now);
    } catch (_) {
      _checkRevision(revision);
      _failedDetailRefreshes.add(failureKey);
      if (cached != null) {
        final detail = await compute(_parseDetail, (cached.$1, app));
        _checkRevision(revision);
        return DetailSnapshot(
          detail,
          cached.$2,
          cached: true,
          refreshFailed: true,
        );
      }
      rethrow;
    }
  }

  /// Version documents are fetched only when the user opens download choices.
  Future<List<CatalogRelease>> releases(
    CatalogApp app, {
    bool refresh = false,
  }) async {
    if (!app.isClient || app.withdrawn) return const [];
    final uri = Uri.parse(app.url);
    if (uri.scheme != 'https' ||
        uri.host != 'huarun.win' ||
        uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.pathSegments.length != 2 ||
        uri.pathSegments.first != 'apps' ||
        uri.pathSegments.last != app.id) {
      throw const PageFormatException('应用版本地址无效。');
    }
    final revision = sources.revision;
    final parts = ['releases', '${Uri.encodeComponent(app.id)}.html-cache'];
    final cached = await _read(_cacheFile(sources.active, parts));
    _checkRevision(revision);
    if (!refresh &&
        cached != null &&
        DateTime.now().difference(cached.$2) < const Duration(minutes: 30)) {
      try {
        final releases = await compute(_parseReleases, (cached.$1, app));
        _checkRevision(revision);
        return releases;
      } on PageFormatException {
        // A changed document format must be read again.
      }
    }
    try {
      final response = await _getResponse(
        uri.replace(path: '${uri.path}/releases'),
        revision: revision,
      );
      final releases = await compute(_parseReleases, (response.html, app));
      _checkRevision(revision);
      await _write(
        _cacheFile(response.origin, parts),
        response.html,
        DateTime.now(),
        revision: revision,
      );
      await _accept(response, revision);
      return releases;
    } catch (_) {
      _checkRevision(revision);
      if (cached != null) {
        final releases = await compute(_parseReleases, (cached.$1, app));
        _checkRevision(revision);
        return releases;
      }
      rethrow;
    }
  }

  Future<_ContentResponse> _getResponse(
    Uri uri, {
    required int revision,
  }) async {
    final request = sources.beginRequest();
    final candidates = request.candidates;
    for (final origin in candidates) {
      _checkRevision(revision);
      final transport = sources.pageUri(uri, origin);
      final cancellation = CancelToken();
      _pendingRequests.add(cancellation);
      try {
        // Bound the whole attempt, including request preparation and redirects.
        // Its timeout must not cancel other pages or the next content source.
        final response =
            await (origin == ContentOrigin.github && github != null
                    ? github!.readRaw<Response<String>>(
                        client,
                        transport,
                        cancelToken: cancellation,
                        maxBytes: maxPageBytes,
                        timeout: _contentRequestTimeout,
                        connectTimeout: _contentConnectTimeout,
                        decode: (response) => response,
                      )
                    : client.getUri<String>(
                        transport,
                        cancelToken: cancellation,
                        options: Options(
                          responseType: ResponseType.plain,
                          connectTimeout: _contentConnectTimeout,
                          sendTimeout: _contentConnectTimeout,
                          receiveTimeout: _contentRequestTimeout,
                        ),
                      ))
                .timeout(
                  _contentRequestTimeout,
                  onTimeout: () {
                    cancellation.cancel('Content source request timed out');
                    throw TimeoutException(
                      'Content source request timed out',
                      _contentRequestTimeout,
                    );
                  },
                );
        _checkRevision(revision);
        final data = response.data;
        final type = response.headers.value('content-type') ?? '';
        final validLocation = origin == ContentOrigin.website
            ? SiteRoutes.isNative(response.realUri)
            : (origin == ContentOrigin.github && github != null
                          ? GitHubAcceleration.originalUri(response.realUri)
                          : response.realUri)
                      .removeFragment() ==
                  transport.removeFragment();
        if (!validLocation ||
            data == null ||
            utf8.encode(data).length > maxPageBytes ||
            !(type.contains('text/html') ||
                origin != ContentOrigin.website &&
                    type.contains('text/plain'))) {
          throw const PageFormatException('内容来源返回了非预期的页面，请稍后重试。');
        }
        return (
          html: data,
          logicalUri: origin == ContentOrigin.website ? response.realUri : uri,
          origin: origin,
          request: request,
        );
      } on TimeoutException {
        _checkRevision(revision);
        if (origin == candidates.last) rethrow;
      } on GitHubTransportException {
        _checkRevision(revision);
        if (origin == candidates.last) rethrow;
      } on DioException catch (error) {
        _checkRevision(revision);
        final status = error.response?.statusCode;
        final retryable = origin == ContentOrigin.github && github != null
            ? GitHubAcceleration.retryable(error)
            : switch (error.type) {
                DioExceptionType.connectionTimeout ||
                DioExceptionType.sendTimeout ||
                DioExceptionType.receiveTimeout ||
                DioExceptionType.transformTimeout ||
                DioExceptionType.connectionError => true,
                // Dart reports a peer disconnect during TLS setup as a handshake
                // error, which Dio wraps as unknown rather than connectionError.
                // Match that disconnect only; certificate/TLS failures stay fatal.
                DioExceptionType.unknown => switch (error.error) {
                  HandshakeException(
                    message: 'Connection terminated during handshake',
                    osError: null,
                  ) =>
                    true,
                  _ => false,
                },
                DioExceptionType.badResponse =>
                  status == 429 || status != null && status >= 500,
                _ => false,
              };
        if (origin == candidates.last || !retryable) rethrow;
      } finally {
        _pendingRequests.remove(cancellation);
      }
    }
    throw const PageFormatException('暂时无法读取内容，请稍后重试。');
  }

  Future<void> _accept(_ContentResponse response, int revision) async {
    _checkRevision(revision);
    await sources.succeeded(response.origin, request: response.request);
    _checkRevision(revision);
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
    required int revision,
    String? sourceUrl,
  }) async {
    Directory? temporary;
    try {
      await file.parent.create(recursive: true);
      temporary = await file.parent.createTemp('.content-');
      final temp = File(path.join(temporary.path, 'document.html-cache'));
      await temp.writeAsString(
        jsonEncode({
          'html': html,
          'at': at.toIso8601String(),
          'sourceUrl': ?sourceUrl,
        }),
        flush: true,
      );
      _checkRevision(revision);
      await temp.rename(file.path);
    } on FileSystemException {
      /* Cache is optional; network content remains usable. */
    } finally {
      if (temporary != null) {
        try {
          await temporary.delete(recursive: true);
        } on FileSystemException {
          /* A temporary cache directory may already have been removed. */
        }
      }
    }
  }
}
