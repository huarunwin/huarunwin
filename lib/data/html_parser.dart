import 'dart:convert';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

import 'models.dart';

class PageFormatException implements Exception {
  const PageFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

class SiteHtmlParser {
  static final origin = Uri.parse('https://huarun.win');

  static String text(Element? element) =>
      element?.text.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '';

  static String? webUrl(String? value, Uri base) {
    if (value == null || value.trim().isEmpty) return null;
    try {
      final uri = base.resolve(value.trim());
      if (!['https', 'http'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        return null;
      }
      return uri.toString();
    } on FormatException {
      return null;
    }
  }

  List<CatalogApp> catalog(String source, {Uri? pageUrl}) {
    final base = pageUrl ?? origin;
    final doc = html.parse(source);
    final cards = doc.querySelectorAll(
      'article.app-card, [data-app-id][data-catalog-card]',
    );
    final apps = <String, CatalogApp>{};
    for (final card in cards) {
      final link = card.querySelector(
        '.app-card-detail, a[href^="/apps/"], a[href^="/servers/"], '
        'a[href^="/subscription-tools/"], a[href^="/rules/"]',
      );
      final href = webUrl(link?.attributes['href'], base);
      final name = text(card.querySelector('h2, [data-field="name"]'));
      if (href == null || name.isEmpty) continue;
      final uri = Uri.parse(href);
      final type = ApplicationType.fromUrl(uri);
      final declaredType = card.attributes['data-application-type'];
      if (type == null ||
          (declaredType != null && declaredType != type.value)) {
        continue;
      }
      final isClient = type == ApplicationType.client;
      final id = uri.pathSegments.last;
      final platformNode = card.querySelector('.platform-pills');
      final platformText =
          (isClient ? card.attributes['data-platforms'] : null) ??
          platformNode?.attributes['aria-label']?.replaceFirst(
            '${isClient ? '支持系统' : type.environmentLabel}：',
            '',
          ) ??
          '';
      final platforms = platformText
          .split(RegExp(r'[、,;]'))
          .map((v) => v.trim())
          .where((v) => v.isNotEmpty)
          .toList();
      if (platforms.isEmpty) {
        platforms.addAll(
          card
              .querySelectorAll('.platform-mini-pill')
              .map(
                (e) => isClient
                    ? (e.attributes['title'] ?? '').replaceFirst('支持 ', '')
                    : text(e),
              )
              .where((s) => s.isNotEmpty),
        );
      }
      final sourceNode = isClient ? card.querySelector('.source') : null;
      final priceNode = isClient ? card.querySelector('.price') : null;
      final price = text(priceNode);
      final priceNote = text(card.querySelector('.card-action-subtext'));
      final stars = card.querySelector('dl[aria-label="GitHub Star 统计"]');
      final ratings = card.querySelector(
        '.card-app-store-metrics, .card-mobile-store-metrics',
      );
      apps['${type.value}:$id'] = CatalogApp(
        id: id,
        type: type,
        alias: text(card.querySelector('.alias')),
        environments: isClient ? const [] : platforms,
        badges: isClient
            ? const []
            : card
                  .querySelectorAll('.badges .core, .badges .source')
                  .map(text)
                  .where((value) => value.isNotEmpty)
                  .toList(),
        versionSummary: text(card.querySelector('.card-decision-info')),
        name: name,
        url: href,
        description: text(
          card.querySelector('.description, [data-field="description"]'),
        ),
        icon: webUrl(card.querySelector('img')?.attributes['src'], base),
        platforms: isClient ? platforms : const [],
        core: isClient ? text(card.querySelector('.core')) : '',
        source: text(sourceNode),
        sourceCategory: sourceNode?.classes.contains('open') == true
            ? '开源'
            : sourceNode?.classes.contains('incomplete') == true
            ? '源码不完整'
            : sourceNode?.classes.contains('unpublished') == true
            ? '未公开'
            : null,
        price: price,
        priceCategory:
            priceNode?.classes.contains('free') == true || price == '免费'
            ? '免费'
            : priceNote == '待核实' ||
                  price.contains('费用待核实') ||
                  price == '免费下载' ||
                  price.startsWith('下载 ')
            ? '待核实'
            : RegExp(r'^(?:US)?\$\d').hasMatch(price)
            ? '付费'
            : null,
        starCount: _metricCount(stars, const ['总 Star', 'Star']),
        starsToday: _starPeriodCount(stars, 'today', const ['今日新增']),
        stars7Days: _starPeriodCount(stars, '7d', const [
          '7日',
          '7 日新增',
          '7日新增',
        ]),
        stars30Days: _starPeriodCount(stars, '30d', const [
          '30日',
          '30 日新增',
          '30日新增',
        ]),
        ratingCount: _metricCount(ratings, const ['评分数']),
        starNote: stars?.attributes['title'],
        ratingNote: ratings?.attributes['title'],
        withdrawn:
            card.classes.contains('app-card-withdrawn') ||
            card.attributes['data-withdrawn'] == 'true',
      );
    }
    if (apps.isEmpty) {
      throw const PageFormatException('网页未包含可识别的应用目录，请稍后刷新或打开网站。');
    }
    return apps.values.toList();
  }

  static int? _metricCount(Element? metrics, List<String> labels) {
    if (metrics == null) return null;
    for (final label in metrics.querySelectorAll('dt')) {
      if (!labels.contains(text(label))) continue;
      final value = label.parent?.querySelector('dd');
      if (value == null || value.attributes['data-missing'] == 'true') continue;
      final raw = text(value);
      // Read exact counts only: percentages, abbreviated values and missing
      // markers must never silently become a count or a zero.
      if (!RegExp(r'^\+?(?:\d+|\d{1,3}(?:,\d{3})+)$').hasMatch(raw)) continue;
      return int.tryParse(raw.replaceAll(',', '').replaceFirst('+', ''));
    }
    return null;
  }

  static int? _starPeriodCount(
    Element? metrics,
    String period,
    List<String> labels,
  ) {
    final raw = metrics?.attributes['data-stars-$period'];
    if (raw != null && RegExp(r'^\d+$').hasMatch(raw)) {
      final count = int.tryParse(raw);
      if (count != null) return count;
    }
    return _metricCount(metrics, labels);
  }

  AppDetails detail(String source, CatalogApp summary) {
    final base = Uri.parse(summary.url);
    final doc = html.parse(source);
    final title = text(doc.querySelector('#detail-title'));
    if (title.isEmpty || doc.querySelector('.detail-page') == null) {
      throw const PageFormatException('网页详情结构暂时无法识别，请打开原网页查看。');
    }
    final jsonLd = _softwareMetadata(doc);
    final withdrawn =
        summary.withdrawn ||
        doc.querySelector('.detail-withdrawn-actions') != null;
    final facts = <String, String>{};
    for (final row in doc.querySelectorAll('.detail-specs-row')) {
      final labelNode = row.querySelector('.detail-specs-label');
      final label = text(
        labelNode?.querySelector('.detail-specs-label-desktop') ?? labelNode,
      );
      final platforms = row
          .querySelectorAll('.detail-platform-links a')
          .map(text)
          .where((value) => value.isNotEmpty);
      final value = platforms.isNotEmpty
          ? platforms.join(' · ')
          : text(
              row.querySelector('.detail-specs-summary') ??
                  row.querySelector('.detail-specs-value'),
            );
      if (label.isNotEmpty && value.isNotEmpty) facts[label] = value;
    }
    final platformVersions = <String, String>{};
    const platformVersionLabels = {
      'Mac 版本': 'macOS',
      'macOS 版本': 'macOS',
      'Windows 版本': 'Windows',
      'Android 版本': 'Android',
      'iOS 版本': 'iOS',
      'Linux 版本': 'Linux',
    };
    for (final term in doc.querySelectorAll('.detail-release-list dt')) {
      final platform = platformVersionLabels[text(term)];
      final value = term.nextElementSibling;
      if (platform == null || value?.localName != 'dd') continue;
      final version = text(value);
      if (version.isNotEmpty) platformVersions[platform] = version;
    }
    String? resourceVersion, resourceDate;
    var versionLabel = '版本';
    final officialActions = <String, DownloadLink>{};
    if (!summary.isClient) {
      // Dates of verification/statistics are not application updates.
      const versionLabels = {'稳定版', '脚本稳定版', '源码快照', '核验版本', 'Mac 版本', '配置快照'};
      const dateLabels = {'发布日期', 'Mac 发布日期', 'iOS 发布日期', '内容更新', '提交日期'};
      for (final term in doc.querySelectorAll('.detail-release-list dt')) {
        final label = text(term);
        final value = term.nextElementSibling;
        if (value?.localName != 'dd') continue;
        final content = text(value);
        if (content.isNotEmpty) facts[label] = content;
        if (versionLabels.contains(label) &&
            resourceVersion == null &&
            content.isNotEmpty) {
          resourceVersion = content;
          versionLabel = label;
        }
        if (dateLabels.contains(label)) {
          final date = value!
              .querySelector('time[datetime]')
              ?.attributes['datetime'];
          if (date != null &&
              DateTime.tryParse(date) != null &&
              (resourceDate == null ||
                  DateTime.parse(date).isAfter(DateTime.parse(resourceDate)))) {
            resourceDate = date;
          }
        }
      }
      if (!withdrawn) {
        for (final anchor in doc.querySelectorAll(
          '.detail-primary-action[href], .server-detail-actions a[href], '
          '.detail-release-list a[href], .detail-specs-value a[href], '
          'section[aria-labelledby="distribution-title"] a[href]',
        )) {
          final url = webUrl(anchor.attributes['href'], base);
          if (url == null || Uri.parse(url).host == origin.host) continue;
          officialActions.putIfAbsent(
            url,
            () => DownloadLink(
              url: url,
              label: text(anchor.querySelector('strong') ?? anchor).isEmpty
                  ? '官方入口'
                  : text(anchor.querySelector('strong') ?? anchor),
            ),
          );
        }
      }
    }
    final platformLinks = doc.querySelectorAll('.detail-platform-links a');
    final platforms = (summary.isClient ? platformLinks : <Element>[])
        .map(text)
        .where((s) => s.isNotEmpty)
        .toList();
    if (platforms.isEmpty) platforms.addAll(summary.platforms);
    final app = CatalogApp(
      id: summary.id,
      type: summary.type,
      alias: text(doc.querySelector('.detail-alias')).isEmpty
          ? summary.alias
          : text(doc.querySelector('.detail-alias')),
      environments: summary.environments.isNotEmpty
          ? summary.environments
          : (facts[summary.type.environmentLabel] ?? facts['适配客户端'] ?? '')
                .split(RegExp(r'\s*[/、]\s*'))
                .where((value) => value.isNotEmpty)
                .toList(),
      badges: summary.badges,
      versionSummary: summary.versionSummary,
      name: title,
      url: summary.url,
      description: text(doc.querySelector('.detail-summary')),
      icon:
          webUrl(
            doc.querySelector('.detail-hero img')?.attributes['src'],
            base,
          ) ??
          summary.icon,
      platforms: platforms,
      core: summary.core,
      source: summary.source,
      price: summary.price,
      sourceCategory: summary.sourceCategory,
      priceCategory: summary.priceCategory,
      starCount: summary.starCount,
      starsToday: summary.starsToday,
      stars7Days: summary.stars7Days,
      stars30Days: summary.stars30Days,
      ratingCount: summary.ratingCount,
      starNote: summary.starNote,
      ratingNote: summary.ratingNote,
      withdrawn: withdrawn,
    );
    final selectedPlatform = text(doc.querySelector('.detail-platform-picker'));
    final currentPlatform = selectedPlatform.isNotEmpty
        ? selectedPlatform
        : platforms.length == 1
        ? platforms.single
        : null;
    final links = <String, DownloadLink>{};
    if (!withdrawn && summary.isClient) {
      for (final anchor in doc.querySelectorAll(
        '.detail-primary-action[href], .detail-download-option[href], a[data-platform][href]',
      )) {
        final uri = webUrl(anchor.attributes['href'], base);
        if (uri == null) continue;
        final label = text(anchor.querySelector('span') ?? anchor);
        final kind = _kind(uri, anchor.attributes['data-kind']);
        final declaredPlatform = anchor.attributes['data-platform'];
        final platform = declaredPlatform != null
            ? _platform(declaredPlatform)
            : currentPlatform;
        final architecture = _architecture(
          anchor.attributes['data-arch'],
          label,
          uri,
        );
        final candidate = DownloadLink(
          url: uri,
          label: label.isEmpty ? '官方下载' : label,
          kind: kind,
          platform: platform,
          architecture: architecture,
          sha256: normalizeSha256(anchor.attributes['data-sha256']),
          checksumSource: anchor.attributes['data-sha256'] == null
              ? null
              : base.toString(),
        );
        if (!links.containsKey(uri) || label != '下载') links[uri] = candidate;
      }
    }
    final screenshots = doc
        .querySelectorAll('.detail-screenshots img')
        .map((e) => webUrl(e.attributes['src'], base))
        .whereType<String>()
        .toSet()
        .toList();
    final description =
        doc.querySelector('.detail-intro') ??
        doc.querySelector('section[aria-labelledby="intro-title"]') ??
        doc.querySelector('section[aria-labelledby="about-title"]');
    final paragraphs = description
        ?.querySelectorAll('p')
        .map(text)
        .where((v) => v.isNotEmpty)
        .join('\n\n');
    String? metadataText(String key) {
      final value = jsonLd[key];
      return value is String && value.trim().isNotEmpty ? value : null;
    }

    final metadataDescription = metadataText('description');
    final fallbackRelease = links.values
        .where((l) => !l.isPackage)
        .firstOrNull
        ?.url;
    return AppDetails(
      app: app,
      version: summary.isClient
          ? metadataText('softwareVersion')
          : resourceVersion,
      versionLabel: versionLabel,
      platformVersions: platformVersions,
      updatedAt: summary.isClient ? metadataText('dateModified') : resourceDate,
      officialActions: officialActions.values.toList(),
      description: paragraphs?.isNotEmpty == true
          ? paragraphs!
          : metadataDescription ?? app.description,
      changelog:
          doc.querySelector('.detail-release-changelog-text')?.text.trim() ??
          '',
      screenshots: screenshots,
      downloads: links.values.toList(),
      facts: facts,
      notices: doc
          .querySelectorAll('.detail-notice')
          .map(text)
          .where((v) => v.isNotEmpty)
          .toList(),
      officialUrl: webUrl(
        doc.querySelector('.detail-official-link')?.attributes['href'],
        base,
      ),
      releaseUrl:
          webUrl(
            doc
                .querySelector('.detail-release-source-link')
                ?.attributes['href'],
            base,
          ) ??
          fallbackRelease,
    );
  }

  Map<String, dynamic> _softwareMetadata(Document document) {
    for (final script in document.querySelectorAll(
      'script[type="application/ld+json"]',
    )) {
      try {
        final decoded = jsonDecode(script.text);
        final items = decoded is List ? decoded : [decoded];
        for (final value in items) {
          if (value is Map<String, dynamic>) {
            if (value['@type'] == 'SoftwareApplication') return value;
            final graph = value['@graph'];
            for (final node in graph is List ? graph : const []) {
              if (node is Map<String, dynamic> &&
                  node['@type'] == 'SoftwareApplication') {
                return node;
              }
            }
          }
        }
      } on FormatException {
        /* Optional metadata; DOM remains authoritative. */
      }
    }
    return {};
  }

  List<CatalogRelease> releases(String source, CatalogApp app) {
    if (app.withdrawn || !app.isClient) return const [];
    final document = html.parse(source);
    final root = document.querySelector('[data-client-releases="1"]');
    if (root == null || root.attributes['data-app-slug'] != app.id) {
      throw const PageFormatException('版本信息页面无效，请稍后重试。');
    }
    final base = Uri.parse('${app.url}/releases');
    final releases = <Uri, CatalogRelease>{};
    for (final row
        in root.children
            .where(
              (element) => element.attributes.containsKey('data-release-url'),
            )
            .take(10)) {
      final page = Uri.tryParse(row.attributes['data-release-url'] ?? '');
      final tag = row.attributes['data-release-tag'];
      final published = DateTime.tryParse(
        row.attributes['data-published-at'] ?? '',
      );
      final collected = DateTime.tryParse(
        row.attributes['data-collected-at'] ?? '',
      );
      if (page == null ||
          page.scheme != 'https' ||
          page.host != 'github.com' ||
          page.userInfo.isNotEmpty ||
          page.hasQuery ||
          page.hasFragment ||
          page.pathSegments.length != 5 ||
          page.pathSegments[2] != 'releases' ||
          page.pathSegments[3] != 'tag' ||
          tag == null ||
          tag.isEmpty ||
          page.pathSegments[4] != tag ||
          published == null ||
          collected == null ||
          !['true', 'false'].contains(row.attributes['data-prerelease']) ||
          !['true', 'false'].contains(row.attributes['data-recommended'])) {
        continue;
      }
      final assets = <String, DownloadLink>{};
      for (final anchor
          in row
              .querySelectorAll('a[data-release-asset="true"][href]')
              .take(1000)) {
        final url = Uri.tryParse(anchor.attributes['href'] ?? '');
        final name = anchor.attributes['data-asset-name'];
        final size = int.tryParse(anchor.attributes['data-asset-size'] ?? '');
        if (url == null ||
            url.scheme != 'https' ||
            url.host != page.host ||
            url.userInfo.isNotEmpty ||
            url.hasQuery ||
            url.hasFragment ||
            url.pathSegments.length != 6 ||
            url.pathSegments.take(2).join('/').toLowerCase() !=
                page.pathSegments.take(2).join('/').toLowerCase() ||
            url.pathSegments[2] != 'releases' ||
            url.pathSegments[3] != 'download' ||
            url.pathSegments[4] != tag ||
            name == null ||
            name.isEmpty ||
            url.pathSegments[5] != name ||
            size == null ||
            size < 0) {
          continue;
        }
        final digest = normalizeSha256(anchor.attributes['data-sha256']);
        assets[url.toString()] = DownloadLink(
          url: url.toString(),
          label: name,
          kind: 'resource',
          version: tag,
          releaseUrl: page.toString(),
          sha256: digest,
          checksumSource: digest == null ? null : base.toString(),
          sizeLabel: size < 1024
              ? '$size B'
              : size < 1024 * 1024
              ? '${(size / 1024).toStringAsFixed(1)} KB'
              : '${(size / (1024 * 1024)).toStringAsFixed(1)} MB',
        );
      }
      releases[page] = CatalogRelease(
        page: page,
        tag: tag,
        name: row.attributes['data-release-name']?.trim().isNotEmpty == true
            ? row.attributes['data-release-name']!.trim()
            : tag,
        publishedAt: published,
        collectedAt: collected,
        prerelease: row.attributes['data-prerelease'] == 'true',
        recommended: row.attributes['data-recommended'] == 'true',
        assets: assets.values.toList(),
      );
    }
    return releases.values.toList();
  }

  String? _kind(String url, String? declared) {
    final path = Uri.parse(url).path.toLowerCase();
    const kinds = [
      'dmg',
      'zip',
      'pkg',
      'apk',
      'exe',
      'msi',
      'msix',
      'deb',
      'rpm',
      'appimage',
      'pkg.tar.zst',
    ];
    for (final kind in kinds) {
      if (path.endsWith('.$kind') &&
          (declared == null || declared.toLowerCase() == kind)) {
        return kind;
      }
    }
    return null;
  }

  String? _platform(String raw) => switch (raw.toLowerCase()) {
    'mac' || 'macos' => 'macOS',
    'windows' => 'Windows',
    'android' => 'Android',
    'ios' => 'iOS',
    'linux' => 'Linux',
    _ => null,
  };

  String? _architecture(String? explicit, String label, String url) {
    final value =
        '${explicit ?? ''} $label ${Uri.parse(url).pathSegments.lastOrNull ?? ''}'
            .toLowerCase();
    if (RegExp(r'universal|通用').hasMatch(value)) return 'universal';
    if (RegExp(r'arm64|aarch64|arm64-v8a|apple silicon').hasMatch(value)) {
      return 'arm64';
    }
    if (RegExp(r'x86_64|amd64|\bx64\b|intel').hasMatch(value)) return 'x64';
    if (RegExp(r'armv7|armeabi').hasMatch(value)) return 'armv7';
    if (RegExp(r'\bx86\b|i686').hasMatch(value)) return 'x86';
    return null;
  }
}
