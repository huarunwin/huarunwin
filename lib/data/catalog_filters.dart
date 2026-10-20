import 'models.dart';

enum CatalogSort {
  comprehensive('综合'),
  updated('最近更新'),
  stars('开源热度'),
  ratings('评分数');

  const CatalogSort(this.label);
  final String label;

  String get notice => switch (this) {
    comprehensive => '',
    updated => '按版本或配置更新时间排序，未记录日期的应用排在末尾。',
    stars => catalogStarNotice(),
    ratings => '按公开的商店评分数排序，仅显示有数据的应用；不是评分高低或去重人数。',
  };
}

enum CatalogStarPeriod {
  today('今日'),
  week('7 日'),
  month('30 日');

  const CatalogStarPeriod(this.label);
  final String label;

  int? count(CatalogApp app) => switch (this) {
    today => app.starsToday,
    week => app.stars7Days,
    month => app.stars30Days,
  };
}

enum CatalogStarMetric {
  count('新增数'),
  share('新增比例');

  const CatalogStarMetric(this.label);
  final String label;
}

String catalogStarNotice({
  CatalogStarPeriod period = CatalogStarPeriod.week,
  CatalogStarMetric metric = CatalogStarMetric.count,
}) =>
    '按${period == CatalogStarPeriod.today ? '今日' : '近 ${period.label}'}新增 Star${metric == CatalogStarMetric.share ? '占总 Star 的比例' : '数'}排序，仅显示有所选周期精确数据的开源客户端和其他应用。'
    '${period == CatalogStarPeriod.today ? '今日指最近一次采集对应的 GitHub 日期，并非本地当天的实时统计。' : ''}'
    '${metric == CatalogStarMetric.share ? '新增比例按新增 Star ÷ 总 Star 计算，使用未四舍五入的比例。' : ''}';

const catalogCorePaths = {
  'Mihomo': 'mihomo',
  'sing-box': 'sing-box',
  '自研': 'unknown',
  'Xray': 'xray',
  'V2Ray': 'v2ray',
  'meow-rs': 'meow-rs',
  'clash-rs': 'clash-rs',
  '其他': 'native',
};
const catalogSources = ['全部', '开源', '源码不完整', '未公开'];
const catalogPrices = ['全部', '免费', '付费', '待核实'];
const catalogPlatforms = [
  '全部',
  'macOS',
  'Windows',
  'Android',
  'iOS',
  'Linux',
  'HarmonyOS',
  'Steam Deck',
  '路由器',
  'OpenWrt',
  'Asuswrt-Merlin',
];

DateTime? catalogDate(String? value) {
  if (value == null ||
      !RegExp(r'^\d{4}-\d{2}-\d{2}(?:$|T)').hasMatch(value) ||
      DateTime.tryParse(value) == null) {
    return null;
  }
  final date = DateTime.tryParse(value.substring(0, 10));
  return date != null &&
          date.toIso8601String().startsWith(value.substring(0, 10))
      ? date
      : null;
}

List<CatalogApp> filterCatalog(
  List<CatalogApp> apps, {
  ApplicationType? type,
  String platform = '全部',
  String source = '全部',
  String price = '全部',
  String query = '',
  Set<String>? coreIds,
  Set<String>? deviceIds,
  CatalogSort sort = CatalogSort.comprehensive,
  CatalogStarPeriod starPeriod = CatalogStarPeriod.week,
  CatalogStarMetric starMetric = CatalogStarMetric.count,
  Map<String, DateTime?> updateDates = const {},
}) {
  final words = query.trim().toLowerCase().split(RegExp(r'\s+'));
  final matches = apps.indexed.where((entry) {
    final app = entry.$2;
    final sourceType = app.sourceCategory ?? app.source;
    // Exact free labels remain useful for older in-memory summaries. Missing
    // prices and "免费下载" never imply that full functionality is free.
    final priceType = app.priceCategory ?? (app.price == '免费' ? '免费' : null);
    final text =
        '${app.name} ${app.alias} ${app.type.label} ${app.description} ${app.core} ${app.platforms.join(' ')} ${app.environments.join(' ')} ${app.badges.join(' ')} ${app.versionSummary}'
            .toLowerCase();
    final clientFilter =
        platform != '全部' ||
        coreIds != null ||
        deviceIds != null ||
        source != '全部' ||
        price != '全部';
    return (type == null || app.type == type) &&
        (!clientFilter || app.isClient) &&
        (coreIds == null || coreIds.contains(app.key)) &&
        (deviceIds == null || deviceIds.contains(app.key)) &&
        (platform == '全部' || app.platforms.contains(platform)) &&
        (source == '全部' || sourceType == source) &&
        (price == '全部' || priceType == price) &&
        words.every(text.contains) &&
        (sort != CatalogSort.stars ||
            ((!app.isClient || sourceType == '开源') &&
                starPeriod.count(app) != null &&
                starPeriod.count(app)! >= 0 &&
                (starMetric == CatalogStarMetric.count ||
                    app.starCount != null && app.starCount! > 0))) &&
        (sort != CatalogSort.ratings ||
            (app.ratingCount != null && app.ratingCount! >= 0));
  }).toList();
  matches.sort((left, right) {
    final a = left.$2, b = right.$2;
    final withdrawn = (a.withdrawn ? 1 : 0) - (b.withdrawn ? 1 : 0);
    if (withdrawn != 0) return withdrawn;
    final order = switch (sort) {
      CatalogSort.comprehensive => a.type.index.compareTo(b.type.index),
      CatalogSort.updated => _compareDates(
        updateDates[a.key],
        updateDates[b.key],
      ),
      CatalogSort.stars =>
        starMetric == CatalogStarMetric.count
            ? starPeriod.count(b)!.compareTo(starPeriod.count(a)!)
            : (starPeriod.count(b)! / b.starCount!).compareTo(
                starPeriod.count(a)! / a.starCount!,
              ),
      CatalogSort.ratings => b.ratingCount!.compareTo(a.ratingCount!),
    };
    return order != 0 ? order : left.$1.compareTo(right.$1);
  });
  return matches.map((entry) => entry.$2).toList();
}

int _compareDates(DateTime? a, DateTime? b) => a == null
    ? (b == null ? 0 : 1)
    : b == null
    ? -1
    : b.compareTo(a);
