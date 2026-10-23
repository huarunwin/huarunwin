import 'dart:async';

import 'package:dio/dio.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import '../data/html_parser.dart';
import '../data/models.dart';
import 'github_debug.dart';
import 'mac_downloads.dart';

String githubReleaseErrorMessage(Object error) {
  if (error is FormatException) return error.message;
  if (error is TimeoutException) return '读取 GitHub 超时，请检查网络后重试。';
  if (error is DioException) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return '连接或读取 GitHub 超时，请检查网络后重试。';
      case DioExceptionType.connectionError:
        return '无法连接 GitHub，请检查网络或代理设置后重试。';
      case DioExceptionType.badCertificate:
        return 'GitHub 安全连接校验失败，请检查设备时间和网络设置。';
      case DioExceptionType.badResponse:
        final status = error.response?.statusCode;
        return switch (status) {
          403 => 'GitHub 拒绝了这次请求（HTTP 403），请稍后重试或使用网站提供的下载入口。',
          404 => 'GitHub 发布页或资源暂不可访问（HTTP 404），请重试或使用网站提供的下载入口。',
          429 => 'GitHub 请求过于频繁（HTTP 429），请稍后重试。',
          final int code when code >= 500 => 'GitHub 暂时无法响应（HTTP $code），请稍后重试。',
          final int code => 'GitHub 请求失败（HTTP $code），请重试。',
          _ => 'GitHub 返回了异常响应，请稍后重试。',
        };
      case DioExceptionType.cancel:
        return '已取消 GitHub 内容加载。';
      case DioExceptionType.unknown:
        break;
    }
  }
  return '无法读取 GitHub 版本或资源，请重试或使用网站提供的下载入口。';
}

class GitHubRelease {
  const GitHubRelease({
    required this.page,
    required this.tag,
    required this.name,
    this.prerelease = false,
    this.latest = false,
    this.publishedAt,
  });

  final Uri page;
  final String tag, name;
  final bool prerelease, latest;
  final DateTime? publishedAt;
}

class GitHubReleasePage {
  const GitHubReleasePage(this.releases, {this.next, this.fromCatalog = false});
  final List<GitHubRelease> releases;
  final Uri? next;
  final bool fromCatalog;
}

/// Version and asset URLs come from public HTML. Only the repository's release
/// index and latest routes are derived from a published repository/release URL.
class GitHubReleaseResolver {
  GitHubReleaseResolver(
    this.source, {
    this.catalog = const [],
    this.loadCatalog,
    this.platforms = const ['macOS', 'Android', 'Windows', 'Linux'],
  });
  final MacDownloadResolver source;
  final List<CatalogRelease> catalog;
  final Future<List<CatalogRelease>> Function()? loadCatalog;
  final List<String> platforms;
  final _releaseHtml = <Uri, String>{};
  final _resources = <Uri, List<DownloadLink>>{};

  Future<GitHubReleasePage> loadInitialPage(Uri repository) async {
    var entries = catalog;
    if (loadCatalog != null) {
      try {
        entries = await loadCatalog!();
      } catch (error) {
        githubDebugLog(
          'releases.catalog.failed',
          uri: repository,
          error: error,
        );
        // Older deployments and mirrors can lack the separate version page.
      }
    }
    final releases = <GitHubRelease>[];
    for (final entry in entries) {
      if (!_sameRepository(repository, entry.page)) continue;
      final release = GitHubRelease(
        page: entry.page,
        tag: entry.tag,
        name: entry.name,
        prerelease: entry.prerelease,
        latest: entry.recommended && !entry.prerelease,
        publishedAt: entry.publishedAt,
      );
      releases.add(release);
      _resources[entry.page] = entry.assets.map((asset) {
        String? platform, kind;
        if (!RegExp(r'(^|[._ -])(symbols|debug)([._ -]|$)')
            .hasMatch(asset.label.toLowerCase())) {
          for (final candidate in platforms) {
            kind = MacDownloadResolver.packageKind(asset.label, candidate);
            if (kind != null) {
              platform = candidate;
              break;
            }
          }
        }
        return DownloadLink(
          url: asset.url,
          label: asset.label,
          platform: platform,
          kind: kind ?? 'resource',
          architecture: MacDownloadResolver.architecture(asset.label),
          sha256: asset.sha256,
          checksumSource: asset.checksumSource,
          version: entry.tag,
          releaseUrl: entry.page.toString(),
          sizeLabel: asset.sizeLabel,
        );
      }).toList();
    }
    if (releases.isEmpty) return loadPage(indexFor(repository));
    githubDebugLog(
      'releases.catalog',
      uri: repository,
      fields: {'releases': releases.length},
    );
    // Only the user's explicit request for more versions accesses GitHub HTML.
    return GitHubReleasePage(
      releases,
      next: indexFor(repository),
      fromCatalog: true,
    );
  }

  static Uri? sourceFor(AppDetails detail, String platform) {
    if (detail.app.withdrawn ||
        !detail.app.platforms.contains(platform) ||
        !['macOS', 'Windows', 'Linux', 'Android'].contains(platform)) {
      return null;
    }
    final explicit = detail.downloads.where((d) => d.platform == platform);
    final hasGitHubPackage = explicit.any(
      (d) => d.isPackage && MacDownloadResolver.releasePage(d.url) != null,
    );
    if (platform == 'macOS' &&
        !hasGitHubPackage &&
        (explicit.any((d) => isAppStoreUrl(d.url)) ||
            explicit.isEmpty &&
                [
                  detail.releaseUrl,
                  detail.officialUrl,
                ].whereType<String>().any(isAppStoreUrl))) {
      return null;
    }
    // A platform-specific repository takes priority over the general homepage.
    final urls = [
      ...explicit.map((d) => d.url),
      ?detail.releaseUrl,
      ...detail.downloads.map((d) => d.url),
      ?detail.officialUrl,
    ];
    return urls
        .map(MacDownloadResolver.releasePage)
        .whereType<Uri>()
        .firstOrNull;
  }

  static bool _sameRepository(Uri a, Uri b) =>
      b.scheme == 'https' &&
      b.host == 'github.com' &&
      b.userInfo.isEmpty &&
      a.pathSegments.length >= 2 &&
      b.pathSegments.length >= 2 &&
      a.pathSegments.take(2).join('/').toLowerCase() ==
          b.pathSegments.take(2).join('/').toLowerCase();

  static Uri indexFor(Uri source) => Uri(
    scheme: 'https',
    host: 'github.com',
    pathSegments: [...source.pathSegments.take(2), 'releases'],
  );

  static Uri? _tagLink(dom.Element anchor, Uri page) {
    final url = SiteHtmlParser.webUrl(anchor.attributes['href'], page);
    final link = url == null ? null : Uri.tryParse(url);
    if (link == null || !_sameRepository(page, link)) return null;
    final parts = link.pathSegments;
    return parts.length >= 5 && parts[2] == 'releases' && parts[3] == 'tag'
        ? link.replace(fragment: '')
        : null;
  }

  static GitHubRelease _release(dom.Element heading, Uri link) {
    final header = heading.parent?.parent ?? heading;
    final labels = header
        .querySelectorAll('.Label')
        .map((e) => e.text.trim().toLowerCase())
        .toSet();
    return GitHubRelease(
      page: link,
      tag: link.pathSegments.skip(4).join('/'),
      name: heading.text.trim(),
      prerelease: labels.contains('pre-release'),
      latest: labels.contains('latest'),
    );
  }

  static GitHubReleasePage releasesFromHtml(String source, Uri page) {
    final document = html.parse(source);
    final releases = <Uri, GitHubRelease>{};
    for (final row in document.querySelectorAll(
      'section[data-release-anchor], .release-entry',
    )) {
      for (final anchor in row.querySelectorAll(
        '.f1 a[href], h1 a[href], h2 a[href]',
      )) {
        final link = _tagLink(anchor, page);
        if (link == null) continue;
        final release = _release(anchor, link);
        releases.putIfAbsent(
          link,
          () => GitHubRelease(
            page: release.page,
            tag: release.tag,
            name: release.name,
            prerelease: release.prerelease,
            latest: release.latest,
            publishedAt: DateTime.tryParse(
              row
                      .querySelector('relative-time[datetime]')
                      ?.attributes['datetime'] ??
                  '',
            ),
          ),
        );
        break;
      }
    }
    Uri? next;
    for (final anchor in document.querySelectorAll(
      'a[rel~="next"][href], a.next_page[href]',
    )) {
      final url = SiteHtmlParser.webUrl(anchor.attributes['href'], page);
      final candidate = url == null ? null : Uri.tryParse(url);
      if (candidate != null &&
          _sameRepository(page, candidate) &&
          candidate.path == indexFor(page).path &&
          candidate.fragment.isEmpty &&
          candidate != page) {
        next = candidate;
        break;
      }
    }
    return GitHubReleasePage(releases.values.toList(), next: next);
  }

  Future<GitHubReleasePage> loadPage(Uri page) async {
    githubDebugLog('releases.load', uri: page);
    if (MacDownloadResolver.releasePage(page.toString()) == null &&
        page.path != indexFor(page).path) {
      throw const FormatException('GitHub 版本列表地址无效。');
    }
    final (body, actual) = await source.readGitHubHtml(page);
    if (!_sameRepository(page, actual) || actual.path != indexFor(page).path) {
      throw const FormatException('GitHub 版本列表地址已变化，请打开官方页面。');
    }
    final parsed = releasesFromHtml(body, actual);
    githubDebugLog(
      'releases.parsed',
      uri: actual,
      fields: {
        'releases': parsed.releases.length,
        'hasNextPage': parsed.next != null,
      },
    );
    if (parsed.releases.isEmpty) {
      throw const FormatException('暂未读取到公开版本，请重试或使用官方渠道。');
    }
    final document = html.parse(body);
    for (final row in document.querySelectorAll(
      'section[data-release-anchor], .release-entry',
    )) {
      for (final anchor in row.querySelectorAll(
        '.f1 a[href], h1 a[href], h2 a[href]',
      )) {
        final link = _tagLink(anchor, actual);
        if (link == null) continue;
        _releaseHtml[link] = row.outerHtml;
        break;
      }
    }
    return parsed;
  }

  /// GitHub's stable release may sit behind several pages of prereleases.
  /// The redirect supplies its real tag; no version or asset URL is guessed.
  Future<GitHubRelease?> loadLatest(Uri repository) async {
    final index = indexFor(repository);
    final latest = index.replace(
      pathSegments: [...index.pathSegments, 'latest'],
    );
    githubDebugLog('latest.load', uri: latest);
    try {
      final (body, actual) = await source.readGitHubHtml(latest);
      if (!_sameRepository(index, actual) ||
          actual.pathSegments.length < 5 ||
          actual.pathSegments[2] != 'releases' ||
          actual.pathSegments[3] != 'tag') {
        throw const FormatException('暂未确认最新稳定版，请重试或选择已公开的版本。');
      }
      final heading = html.parse(body).querySelector('h1[data-view-component]');
      if (heading == null) {
        throw const FormatException('暂未读取到最新稳定版，请重试。');
      }
      final parsed = _release(heading, actual);
      githubDebugLog(
        'latest.parsed',
        uri: actual,
        fields: {'prerelease': parsed.prerelease},
      );
      if (parsed.prerelease) return null;
      _releaseHtml[actual] = body;
      return GitHubRelease(
        page: actual,
        tag: parsed.tag,
        name: parsed.name,
        latest: true,
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) {
        githubDebugLog('latest.notFound', uri: latest);
        return null;
      }
      rethrow;
    }
  }

  static List<DownloadLink> resourcesFromHtml(
    String source,
    GitHubRelease release,
  ) {
    final recognized = <String, DownloadLink>{};
    for (final platform in ['macOS', 'Android', 'Windows', 'Linux']) {
      for (final asset in MacDownloadResolver.packagesForPlatformFromHtml(
        source,
        release.page,
        platform,
      )) {
        recognized[asset.url] = asset;
      }
    }
    final resources = <String, DownloadLink>{};
    for (final anchor in html.parse(source).querySelectorAll('a[href]')) {
      final url = SiteHtmlParser.webUrl(
        anchor.attributes['href'],
        release.page,
      );
      final link = url == null ? null : Uri.tryParse(url);
      if (link == null || !_sameRepository(release.page, link)) continue;
      final parts = link.pathSegments;
      final uploaded =
          parts.length == 6 &&
          parts[2] == 'releases' &&
          parts[3] == 'download' &&
          parts[4] == release.tag;
      final archive =
          parts.length >= 6 &&
          parts[2] == 'archive' &&
          parts[3] == 'refs' &&
          parts[4] == 'tags' &&
          [
            '${release.tag}.zip',
            '${release.tag}.tar.gz',
          ].contains(parts.skip(5).join('/'));
      if (!uploaded && !archive) continue;
      final package = recognized[url];
      resources[url!] = DownloadLink(
        url: url,
        label: uploaded ? parts.last : 'Source code (${parts.last})',
        platform: package?.platform,
        kind: package?.kind ?? 'resource',
        architecture: package?.architecture,
        sha256: uploaded ? _digest(anchor) : null,
        checksumSource: release.page.toString(),
        version: release.tag,
        releaseUrl: release.page.toString(),
        sizeLabel: _sizeLabel(anchor),
      );
    }
    return resources.values.toList();
  }

  static String? _sizeLabel(dom.Element anchor) {
    dom.Element? row = anchor.parent;
    while (row != null && row.localName != 'li') {
      row = row.parent;
    }
    // Bind the published size to one resource, never a neighbouring asset.
    if (row == null ||
        row.querySelectorAll('a[href]').where((a) {
              final path = Uri.tryParse(a.attributes['href'] ?? '')?.path ?? '';
              return path.contains('/releases/download/') ||
                  path.contains('/archive/refs/tags/');
            }).length !=
            1) {
      return null;
    }
    final pattern = RegExp(
      r'^(\d+(?:\.\d+)?)\s*(B|Bytes?|[KMGTP]i?B)$',
      caseSensitive: false,
    );
    const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    final labels = <String>{};
    for (final element in row.querySelectorAll('span')) {
      if (element.children.isNotEmpty) continue;
      final match = pattern.firstMatch(element.text.trim());
      if (match == null) continue;
      final publishedSize = double.tryParse(match[1]!);
      if (publishedSize == null || !publishedSize.isFinite) continue;
      var size = publishedSize;
      final unit = match[2]!.toUpperCase().replaceFirst('I', '');
      var index = size == 0 || unit.startsWith('B') ? 0 : units.indexOf(unit);
      while (size >= 1024 && index < units.length - 1) {
        size /= 1024;
        index++;
      }
      while (size > 0 && size < 1 && index > 0) {
        size *= 1024;
        index--;
      }
      labels.add('${size.toStringAsFixed(index == 0 ? 0 : 1)} ${units[index]}');
    }
    return labels.length == 1 ? labels.single : null;
  }

  static String? _digest(dom.Element anchor) {
    dom.Element? row = anchor.parent;
    while (row != null && row.localName != 'li') {
      row = row.parent;
    }
    if (row == null ||
        row.querySelectorAll('a[href*="/releases/download/"]').length != 1) {
      return null;
    }
    final digests = row
        .querySelectorAll('clipboard-copy[value]')
        .map((e) => normalizeSha256(e.attributes['value']))
        .whereType<String>()
        .toSet();
    return digests.length == 1 ? digests.single : null;
  }

  Future<List<DownloadLink>> loadResources(GitHubRelease release) async {
    final cached = _resources[release.page];
    if (cached != null) {
      githubDebugLog(
        'assets.cacheHit',
        uri: release.page,
        fields: {'resources': cached.length},
      );
      return cached;
    }
    var body = _releaseHtml[release.page];
    githubDebugLog(
      'assets.load',
      uri: release.page,
      fields: {'htmlCached': body != null},
    );
    if (body == null) {
      final (sourceHtml, actual) = await source.readGitHubHtml(release.page);
      if (!_sameRepository(release.page, actual) ||
          actual.path != release.page.path) {
        throw const FormatException('版本地址已变化，请重新选择版本。');
      }
      body = sourceHtml;
    }
    final resources = <String, DownloadLink>{
      for (final resource in resourcesFromHtml(body, release))
        resource.url: resource,
    };
    final fragments = <Uri>{};
    for (final fragment
        in html.parse(body).querySelectorAll('include-fragment')) {
      final url = SiteHtmlParser.webUrl(
        fragment.attributes['src'] ?? fragment.attributes['data-deferred-src'],
        release.page,
      );
      final link = url == null ? null : Uri.tryParse(url);
      if (link == null || !_sameRepository(release.page, link)) continue;
      final parts = link.pathSegments;
      if (parts.length >= 5 &&
          parts[2] == 'releases' &&
          parts[3] == 'expanded_assets' &&
          parts.skip(4).join('/') == release.tag) {
        fragments.add(link);
      }
    }
    githubDebugLog(
      'assets.fragments',
      uri: release.page,
      fields: {
        'fragments': fragments.length,
        'inlineResources': resources.length,
      },
    );
    for (final fragment in fragments.take(1)) {
      final (assets, actual) = await source.readGitHubHtml(fragment);
      if (!_sameRepository(release.page, actual) ||
          actual.path != fragment.path) {
        throw const FormatException('资源地址已变化，请重新选择版本。');
      }
      for (final resource in resourcesFromHtml(assets, release)) {
        resources[resource.url] = resource;
      }
    }
    githubDebugLog(
      'assets.parsed',
      uri: release.page,
      fields: {'resources': resources.length},
    );
    return _resources[release.page] = resources.values.toList();
  }
}
