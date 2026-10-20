import 'package:dio/dio.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;

import '../data/html_parser.dart';
import '../data/models.dart';

bool isAppStoreUrl(String url) {
  final uri = Uri.tryParse(url);
  return uri != null &&
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      const ['apps.apple.com', 'itunes.apple.com'].contains(uri.host) &&
      uri.pathSegments.any((s) => RegExp(r'^id\d+$').hasMatch(s));
}

Uri macAppStoreUri(String url) {
  if (!isAppStoreUrl(url)) throw const FormatException('App Store 地址无效。');
  return Uri.parse(url).replace(scheme: 'macappstores');
}

class MacDownloadOptions {
  const MacDownloadOptions({this.packages = const [], this.stores = const []});
  final List<DownloadLink> packages;
  final List<String> stores;

  DownloadLink? recommended(String? architecture) {
    if (architecture == null || stores.isNotEmpty) return null;
    for (final arch in [architecture, 'universal']) {
      final matching = packages.where((p) => p.architecture == arch).toList();
      for (final kind in ['dmg', 'zip', 'pkg']) {
        final candidates = matching.where((p) => p.kind == kind).toList();
        if (candidates.length == 1) return candidates.single;
        if (candidates.length > 1) return null;
      }
    }
    return null;
  }
}

/// Reads public release HTML, including GitHub's HTML asset fragment. No JSON API.
class MacDownloadResolver {
  MacDownloadResolver({Dio? client})
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
  final Dio client;

  static Uri? releasePage(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        uri.userInfo.isNotEmpty) {
      return null;
    }
    final parts = uri.pathSegments;
    if (parts.length < 2 || parts[0].isEmpty || parts[1].isEmpty) return null;
    final repo = parts.take(2).toList();
    if (parts.length >= 5 && parts[2] == 'releases' && parts[3] == 'download') {
      return Uri(
        scheme: 'https',
        host: 'github.com',
        pathSegments: [...repo, 'releases', 'tag', parts[4]],
      );
    }
    if (parts.length >= 5 && parts[2] == 'releases' && parts[3] == 'tag') {
      return Uri(scheme: 'https', host: 'github.com', pathSegments: parts);
    }
    if (parts.length == 2 ||
        (parts.length == 3 && parts[2] == 'releases') ||
        (parts.length == 4 && parts[2] == 'releases' && parts[3] == 'latest')) {
      return Uri.https('github.com', '/${repo.join('/')}/releases/latest');
    }
    return null;
  }

  static String? architecture(String name) {
    final value = name.toLowerCase();
    bool token(String pattern) =>
        RegExp('(^|[^a-z0-9])(?:$pattern)(?=[^a-z0-9]|\$)').hasMatch(value);
    final arm64 = token(r'arm64|aarch64|apple[._ -]?silicon');
    final x64 = token(r'amd64|x86[_-]64|x64|intel');
    if (token('universal') || arm64 && x64) {
      return 'universal';
    }
    if (arm64) return 'arm64';
    if (x64) return 'x64';
    if (token(r'armv7|armeabi')) return 'armv7';
    if (token(r'x86|i686')) return 'x86';
    return null;
  }

  static List<DownloadLink> packagesFromHtml(String source, Uri page) =>
      packagesForPlatformFromHtml(source, page, 'macOS');

  static String? _packageKind(String name, String platform) {
    final kinds = switch (platform) {
      'macOS' => ['dmg', 'pkg'],
      'Windows' => ['exe', 'msi', 'msix'],
      'Android' => ['apk'],
      'Linux' => ['deb', 'rpm', 'pkg.tar.zst', 'appimage'],
      _ => <String>[],
    };
    for (final kind in kinds) {
      if (name.endsWith('.$kind')) return kind;
    }
    final marker = switch (platform) {
      'macOS' => r'(^|[._ -])(macos|mac|darwin|osx)([._ -]|$)',
      'Windows' => r'(^|[._ -])(windows|win32|win64|win)([._ -]|$)',
      'Linux' => r'(^|[._ -])linux([._ -]|$)',
      _ => null,
    };
    if (name.endsWith('.zip') &&
        ((marker != null && RegExp(marker).hasMatch(name)) ||
            (platform == 'macOS' && name.endsWith('.app.zip')))) {
      return 'zip';
    }
    return null;
  }

  static String? packageKind(String name, String platform) =>
      _packageKind(name.toLowerCase(), platform);

  static List<DownloadLink> packagesForPlatformFromHtml(
    String source,
    Uri page,
    String platform,
  ) {
    final prefix = '/${page.pathSegments.take(2).join('/')}/releases/download/';
    final expectedTag =
        page.pathSegments.length >= 5 && page.pathSegments[3] == 'tag'
        ? page.pathSegments.skip(4).join('/')
        : null;
    final links = <String, DownloadLink>{};
    for (final anchor in html.parse(source).querySelectorAll('a[href]')) {
      final url = SiteHtmlParser.webUrl(anchor.attributes['href'], page);
      if (url == null) continue;
      final uri = Uri.parse(url);
      if (uri.scheme != 'https' ||
          uri.host != 'github.com' ||
          !uri.path.startsWith(prefix)) {
        continue;
      }
      final name = uri.pathSegments.last;
      if (uri.pathSegments.length != 6 ||
          (expectedTag != null && uri.pathSegments[4] != expectedTag)) {
        continue;
      }
      final lower = name.toLowerCase();
      final kind = _packageKind(lower, platform);
      if (kind == null ||
          RegExp(r'(^|[._ -])(symbols|debug)([._ -]|$)').hasMatch(lower)) {
        continue;
      }
      links[url] = DownloadLink(
        url: url,
        label: name,
        platform: platform,
        kind: kind,
        architecture: architecture(name),
        sha256: _assetDigest(anchor),
        checksumSource: page.toString(),
      );
    }
    return links.values.toList();
  }

  static String? _assetDigest(dom.Element anchor) {
    // The nearest asset row binds the digest to this file, never a neighbour.
    dom.Element? row = anchor.parent;
    while (row != null && row.localName != 'li') {
      row = row.parent;
    }
    if (row == null ||
        row.querySelectorAll('a[href*="/releases/download/"]').length != 1) {
      return null;
    }
    final values = <String>{
      for (final element in row.querySelectorAll('clipboard-copy[value]'))
        ?normalizeSha256(element.attributes['value']),
    };
    return values.length == 1 ? values.single : null;
  }

  Future<List<DownloadLink>> _withChecksums(
    List<DownloadLink> packages, {
    String platform = 'macOS',
  }) async {
    final releases = <Uri, Future<List<DownloadLink>>>{};
    final result = <DownloadLink>[];
    for (final package in packages) {
      if (package.sha256 != null) {
        result.add(package);
        continue;
      }
      final release = releasePage(package.url);
      DownloadLink? published;
      if (release != null &&
          (releases.containsKey(release) || releases.length < 3)) {
        try {
          final assets = await releases.putIfAbsent(
            release,
            () => _release(release, platform: platform),
          );
          final path = Uri.parse(package.url).path;
          published = assets
              .where((asset) => Uri.parse(asset.url).path == path)
              .firstOrNull;
        } catch (_) {
          // Missing metadata must not replace a valid official download link.
        }
      }
      result.add(
        DownloadLink(
          url: package.url,
          label: package.label,
          platform: package.platform,
          architecture: package.architecture,
          kind: package.kind,
          version: package.version,
          releaseUrl: package.releaseUrl,
          sha256: published?.sha256,
          checksumSource: published?.sha256 == null
              ? null
              : published?.checksumSource,
        ),
      );
    }
    return result;
  }

  Future<(String, Uri)> readGitHubHtml(Uri uri) async {
    if (uri.scheme != 'https' ||
        uri.host != 'github.com' ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('GitHub 发布页地址无效。');
    }
    final response = await client.getUri<String>(
      uri,
      options: Options(
        responseType: ResponseType.plain,
        maxRedirects: 5,
        headers: {'Accept': 'text/html', 'Accept-Language': 'en'},
      ),
    );
    if (response.realUri.host != 'github.com' ||
        response.realUri.scheme != 'https' ||
        response.realUri.userInfo.isNotEmpty ||
        response.statusCode != 200 ||
        !(response.headers.value('content-type') ?? '').contains('text/html') ||
        response.data == null ||
        response.data!.length > 8 * 1024 * 1024) {
      throw const FormatException('GitHub 发布页暂时无法读取，请稍后重试。');
    }
    return (response.data!, response.realUri);
  }

  Future<List<DownloadLink>> _release(
    Uri release, {
    String platform = 'macOS',
  }) async {
    final (source, page) = await readGitHubHtml(release);
    final packages = <String, DownloadLink>{
      for (final p in packagesForPlatformFromHtml(source, page, platform))
        p.url: p,
    };
    final prefix =
        '/${page.pathSegments.take(2).join('/')}/releases/expanded_assets/';
    final fragments = html
        .parse(source)
        .querySelectorAll('include-fragment[src]')
        .map((e) => SiteHtmlParser.webUrl(e.attributes['src'], page))
        .whereType<String>()
        .map(Uri.parse)
        .where(
          (u) =>
              u.scheme == 'https' &&
              u.host == 'github.com' &&
              u.path.startsWith(prefix),
        )
        .toSet();
    for (final fragment in fragments.take(1)) {
      try {
        final (assets, _) = await readGitHubHtml(fragment);
        for (final p in packagesForPlatformFromHtml(assets, page, platform)) {
          packages[p.url] = p;
        }
      } catch (_) {
        if (packages.isEmpty) rethrow;
      }
    }
    return packages.values.toList();
  }

  Future<List<DownloadLink>> resolvePackages(
    AppDetails detail,
    String platform,
  ) async {
    if (detail.app.withdrawn || !detail.app.platforms.contains(platform)) {
      return [];
    }
    final kinds = switch (platform) {
      'macOS' => ['dmg', 'zip', 'pkg'],
      'Windows' => ['exe', 'msi', 'msix', 'zip'],
      'Android' => ['apk'],
      'Linux' => ['deb', 'rpm', 'pkg.tar.zst', 'appimage', 'zip'],
      _ => <String>[],
    };
    if (kinds.isEmpty) return [];
    final packages = detail.downloads
        .where((p) => p.platform == platform && kinds.contains(p.kind))
        .toList();
    if (packages.isNotEmpty) {
      return ['macOS', 'Android', 'Windows', 'Linux'].contains(platform)
          ? _withChecksums(packages, platform: platform)
          : packages;
    }
    final release = [
      if (detail.releaseUrl != null) detail.releaseUrl!,
      ...detail.downloads.map((d) => d.url),
      if (detail.officialUrl != null) detail.officialUrl!,
    ].map(releasePage).whereType<Uri>().firstOrNull;
    return release == null ? [] : _release(release, platform: platform);
  }

  Future<MacDownloadOptions> resolve(AppDetails detail) async {
    if (detail.app.withdrawn || !detail.app.platforms.contains('macOS')) {
      return const MacDownloadOptions();
    }
    final packages = detail.downloads
        .where(
          (p) =>
              p.platform == 'macOS' && ['dmg', 'zip', 'pkg'].contains(p.kind),
        )
        .toList();
    final explicitStores = detail.downloads
        .where((p) => p.platform == 'macOS' && isAppStoreUrl(p.url))
        .map((p) => p.url)
        .toSet();
    final urls = [
      if (detail.releaseUrl != null) detail.releaseUrl!,
      ...detail.downloads.map((d) => d.url),
      if (detail.officialUrl != null) detail.officialUrl!,
    ];
    final release = urls.map(releasePage).whereType<Uri>().firstOrNull;
    if (packages.isNotEmpty || explicitStores.isNotEmpty) {
      return MacDownloadOptions(
        packages: packages.isEmpty ? packages : await _withChecksums(packages),
        stores: explicitStores.toList(),
      );
    }
    if (release != null) {
      final assets = await _release(release);
      if (assets.isNotEmpty) return MacDownloadOptions(packages: assets);
    }
    final stores = <String, String>{};
    for (final url in urls.where(isAppStoreUrl)) {
      final id = Uri.parse(url).pathSegments
          .firstWhere((s) => RegExp(r'^id\d+$').hasMatch(s));
      stores.putIfAbsent(id, () => url);
    }
    return MacDownloadOptions(stores: stores.values.toList());
  }
}
