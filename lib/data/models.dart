enum ApplicationType {
  client('client', '客户端', 'apps', '支持平台'),
  server('server', '服务端', 'servers', '运行环境'),
  subscriptionTool('subscription-tool', '订阅工具', 'subscription-tools', '运行方式'),
  ruleConfig('rule-config', '规则与配置', 'rules', '适配内核或软件');

  const ApplicationType(
    this.value,
    this.label,
    this.route,
    this.environmentLabel,
  );
  final String value, label, route, environmentLabel;

  static ApplicationType? fromValue(String? value) =>
      values.where((type) => type.value == value).firstOrNull;

  static ApplicationType? fromUrl(Uri uri) {
    if (uri.scheme != 'https' ||
        uri.host != 'huarun.win' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.pathSegments.length != 2 ||
        uri.pathSegments.last.isEmpty ||
        uri.pathSegments.any((part) => part == '..' || part.contains('/'))) {
      return null;
    }
    return values
        .where((type) => type.route == uri.pathSegments.first)
        .firstOrNull;
  }
}

enum CatalogDevice {
  steamDeck('Steam Deck', '/devices/steam-deck', 'steam-deck'),
  routers('路由器', '/routers', 'routers');

  const CatalogDevice(this.label, this.path, this.cacheKey);
  final String label, path, cacheKey;

  static CatalogDevice? fromLabel(String label) =>
      values.where((device) => device.label == label).firstOrNull;
}

class CatalogApp {
  const CatalogApp({
    required this.id,
    required this.name,
    required this.url,
    this.type = ApplicationType.client,
    this.alias = '',
    this.environments = const [],
    this.badges = const [],
    this.versionSummary = '',
    this.description = '',
    this.icon,
    this.platforms = const [],
    this.core = '',
    this.source = '',
    this.price = '',
    this.sourceCategory,
    this.priceCategory,
    this.starCount,
    this.starsToday,
    this.stars7Days,
    this.stars30Days,
    this.ratingCount,
    this.starNote,
    this.ratingNote,
    this.withdrawn = false,
  });

  final String id, name, url, description, core, source, price;
  final ApplicationType type;
  final String alias, versionSummary;
  final List<String> environments, badges;
  bool get isClient => type == ApplicationType.client;
  String get key => '${type.value}:$id';
  final String? icon;
  final String? sourceCategory, priceCategory, starNote, ratingNote;
  final int? starCount, starsToday, stars7Days, stars30Days, ratingCount;
  final List<String> platforms;
  final bool withdrawn;

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.value,
    'alias': alias,
    'environments': environments,
    'badges': badges,
    'versionSummary': versionSummary,
    'name': name,
    'url': url,
    'description': description,
    'icon': icon,
    'platforms': platforms,
    'core': core,
    'source': source,
    'price': price,
    'sourceCategory': sourceCategory,
    'priceCategory': priceCategory,
    'starCount': starCount,
    'starsToday': starsToday,
    'stars7Days': stars7Days,
    'stars30Days': stars30Days,
    'ratingCount': ratingCount,
    'starNote': starNote,
    'ratingNote': ratingNote,
    'withdrawn': withdrawn,
  };
  factory CatalogApp.fromJson(Map<String, dynamic> json) => CatalogApp(
    id: json['id'] as String,
    type:
        ApplicationType.fromValue(json['type'] as String?) ??
        ApplicationType.fromUrl(Uri.parse(json['url'] as String)) ??
        ApplicationType.client,
    alias: json['alias'] as String? ?? '',
    environments: List<String>.from(json['environments'] as List? ?? []),
    badges: List<String>.from(json['badges'] as List? ?? []),
    versionSummary: json['versionSummary'] as String? ?? '',
    name: json['name'] as String,
    url: json['url'] as String,
    description: json['description'] as String? ?? '',
    icon: json['icon'] as String?,
    platforms: List<String>.from(json['platforms'] as List? ?? []),
    core: json['core'] as String? ?? '',
    source: json['source'] as String? ?? '',
    price: json['price'] as String? ?? '',
    sourceCategory: json['sourceCategory'] as String?,
    priceCategory: json['priceCategory'] as String?,
    starCount: json['starCount'] as int?,
    starsToday: json['starsToday'] as int?,
    stars7Days: json['stars7Days'] as int?,
    stars30Days: json['stars30Days'] as int?,
    ratingCount: json['ratingCount'] as int?,
    starNote: json['starNote'] as String?,
    ratingNote: json['ratingNote'] as String?,
    withdrawn: json['withdrawn'] == true,
  );
}

class DownloadLink {
  const DownloadLink({
    required this.url,
    required this.label,
    this.platform,
    this.architecture,
    this.kind,
    this.sha256,
    this.checksumSource,
    this.version,
    this.releaseUrl,
    this.sizeLabel,
  });
  final String url, label;
  final String? platform, architecture, kind;
  final String? sha256, checksumSource;
  final String? version, releaseUrl;
  // Public HTML may publish only a rounded size, not an exact byte count.
  final String? sizeLabel;
  bool get isPackage => const [
    'dmg',
    'zip',
    'pkg',
    'apk',
    'exe',
    'msi',
    'msix',
    'deb',
    'rpm',
    'pkg.tar.zst',
    'appimage',
  ].contains(kind);
  bool get isDownloadable => isPackage || kind == 'resource';
}

String? normalizeSha256(String? value) {
  final digest = value?.trim().toLowerCase().replaceFirst(
    RegExp(r'^sha256:'),
    '',
  );
  return digest != null && RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)
      ? digest
      : null;
}

/// Public release and asset metadata embedded in the site's initial HTML.
class CatalogRelease {
  const CatalogRelease({
    required this.page,
    required this.tag,
    required this.name,
    required this.publishedAt,
    required this.collectedAt,
    required this.assets,
    this.prerelease = false,
    this.recommended = false,
  });
  final Uri page;
  final String tag, name;
  final DateTime publishedAt, collectedAt;
  final bool prerelease, recommended;
  final List<DownloadLink> assets;
}

class AppDetails {
  const AppDetails({
    required this.app,
    this.version,
    this.versionLabel = '版本',
    this.officialActions = const [],
    this.updatedAt,
    this.description = '',
    this.changelog = '',
    this.screenshots = const [],
    this.downloads = const [],
    this.facts = const {},
    this.notices = const [],
    this.officialUrl,
    this.releaseUrl,
    this.platformVersions = const {},
  });
  final CatalogApp app;
  final String versionLabel;
  // Resource actions retain their published labels and always open officially.
  final List<DownloadLink> officialActions;
  final String? version, updatedAt, officialUrl, releaseUrl;
  final String description, changelog;
  final List<String> screenshots, notices;
  final List<DownloadLink> downloads;
  final Map<String, String> facts;
  final Map<String, String> platformVersions;

  String? versionForPlatform(String platform) =>
      platformVersions.isEmpty ? version : platformVersions[platform];
}

class CatalogSnapshot {
  const CatalogSnapshot(
    this.apps,
    this.fetchedAt, {
    this.cached = false,
    this.warning,
  });
  final List<CatalogApp> apps;
  final DateTime fetchedAt;
  final bool cached;
  final String? warning;
}

class DetailSnapshot {
  const DetailSnapshot(
    this.details,
    this.fetchedAt, {
    this.cached = false,
    this.refreshFailed = false,
  });
  final AppDetails details;
  final DateTime fetchedAt;
  final bool cached;
  final bool refreshFailed;
}
