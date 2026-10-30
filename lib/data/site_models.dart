/// Models derived from the site's public, rendered HTML. No website scripts
/// or private serialized application state are needed by the client.
class SiteLink {
  const SiteLink(this.label, this.url, {this.selected = false});
  final String label, url;
  final bool selected;
}

class SiteLinkGroup {
  const SiteLinkGroup(this.label, this.links);
  final String label;
  final List<SiteLink> links;
}

class SiteText {
  const SiteText(
    this.text, {
    this.url,
    this.bold = false,
    this.code = false,
    this.italic = false,
    this.struck = false,
  });
  final String text;
  final String? url;
  final bool bold, code, italic, struck;
}

enum BlockKind {
  text,
  heading,
  image,
  code,
  table,
  facts,
  offer,
  disclosure,
  panel,
  quote,
  event,
  timeline,
  related,
  gallery,
  reference,
  caption,
}

class SiteBlock {
  const SiteBlock({
    this.kind = BlockKind.text,
    this.id,
    this.runs = const [],
    this.children = const [],
    this.rows = const [],
    this.url,
    this.preview,
    this.level = 0,
    this.open = false,
    this.item,
  });
  final BlockKind kind;
  final String? id, url, preview;
  final List<SiteText> runs;
  final List<SiteBlock> children;
  final List<List<List<SiteText>>> rows;
  final int level;
  final bool open;
  final SiteItem? item;
  String get text => runs.map((r) => r.text).join();
  String get ownText => [
    text,
    if (item case final item?) ...[
      item.title,
      item.subtitle,
      item.summary,
      item.byline,
      item.date,
      ...item.badges,
      for (final fact in item.facts.entries) '${fact.key} ${fact.value}',
    ],
    for (final row in rows)
      for (final cell in row) cell.map((r) => r.text).join(),
  ].join(' ').trim();
  String get searchable =>
      [ownText, for (final child in children) child.searchable].join(' ');
  bool containsId(String target) =>
      id == target || children.any((b) => b.containsId(target));
}

class SiteItem {
  const SiteItem({
    required this.title,
    required this.url,
    this.subtitle = '',
    this.summary = '',
    this.image,
    this.badges = const [],
    this.facts = const {},
    this.facets = const {},
    this.actions = const [],
    this.price,
    this.memory,
    this.traffic,
    this.stars,
    this.byline = '',
    this.date = '',
    this.publishedAt,
  });
  final String title, url, subtitle, summary;
  final String? image;
  final List<String> badges;
  final Map<String, String> facts;
  final Map<String, List<String>> facets;
  final List<SiteLink> actions;
  // Only explicitly published numeric values are populated. Unknown is null.
  final double? price, memory, traffic, stars;
  final String byline, date;
  final DateTime? publishedAt;
  String get searchable =>
      '$title $subtitle $summary $byline $date ${badges.join(' ')} ${facts.entries.map((e) => '${e.key} ${e.value}').join(' ')}'
          .toLowerCase();
}

class SiteDocument {
  const SiteDocument({
    required this.url,
    required this.title,
    this.description = '',
    this.items = const [],
    this.groups = const [],
    this.providers = const [],
    this.catalogScope = const [],
    this.pagination = const [],
    this.blocks = const [],
    this.nextUrl,
    this.previousUrl,
    this.directory = false,
    this.service,
    this.reading,
  });
  final String url, title, description;
  final List<SiteItem> items;
  final List<SiteLinkGroup> groups;
  final List<SiteLink> providers;
  final List<String> catalogScope;
  final List<SiteLink> pagination;
  final List<SiteBlock> blocks;
  final String? nextUrl, previousUrl;
  final bool directory;
  final SiteServiceDetails? service;
  final SiteReadingDetails? reading;
}

enum SiteReadingKind { feed, person, article, history, core, protocol }

/// Identity extracted from visible article headers. The overview remains in the
/// block tree, keeping every header field available to search and deep links.
class SiteReadingDetails {
  const SiteReadingDetails({
    required this.kind,
    required this.title,
    required this.overview,
    this.eyebrow = '',
    this.summary = const [],
    this.metadata = const [],
    this.image,
    this.actions = const [],
  });
  final SiteReadingKind kind;
  final String title, eyebrow;
  final SiteBlock overview;
  final List<SiteText> summary;
  final List<String> metadata;
  final String? image;
  final List<SiteLink> actions;
}

enum SiteServiceKind { vps, airport }

/// Public service identity, separated from the reading content for native detail UI.
class SiteServiceDetails {
  const SiteServiceDetails({
    required this.kind,
    required this.title,
    required this.overview,
    this.subtitle = '',
    this.identity = const [],
    this.image,
    this.purchase,
    this.communityLinks = const [],
    this.highlights = const {},
    this.price = '',
    this.referencePrice = '',
    this.referenceNote = '',
  });

  final SiteServiceKind kind;
  final String title, subtitle, price, referencePrice, referenceNote;
  final List<SiteText> identity;
  final String? image;
  final SiteLink? purchase;
  final List<SiteLink> communityLinks;
  final Map<String, String> highlights;
  // Kept in the document's block tree so search, anchors and link sharing work.
  final SiteBlock overview;
}

class SiteSnapshot {
  const SiteSnapshot(
    this.document,
    this.at, {
    this.cached = false,
    this.warning,
  });
  final SiteDocument document;
  final DateTime at;
  final bool cached;
  final String? warning;
}

/// Filtering is scoped to fetched HTML pages, never to an unseen JSON catalog.
class SiteQuery {
  const SiteQuery({
    this.text = '',
    this.facets = const {},
    this.sort = 'original',
    this.minimumMemory,
    this.minimumTraffic,
    this.minimumPrice,
    this.maximumPrice,
  });
  final String text, sort;
  final Map<String, String> facets;
  final double? minimumMemory, minimumTraffic, minimumPrice, maximumPrice;

  List<SiteItem> apply(Iterable<SiteItem> items) {
    final words = text.trim().toLowerCase().split(RegExp(r'\s+'));
    final result = items.where((item) {
      if (!words.every((word) => item.searchable.contains(word))) return false;
      for (final entry in facets.entries) {
        if (entry.value.isNotEmpty &&
            !(item.facets[entry.key]?.contains(entry.value) ?? false)) {
          return false;
        }
      }
      if (minimumMemory != null &&
          (item.memory == null || item.memory! < minimumMemory!)) {
        return false;
      }
      if (minimumTraffic != null &&
          (item.traffic == null || item.traffic! < minimumTraffic!)) {
        return false;
      }
      if (minimumPrice != null &&
          (item.price == null || item.price! <= minimumPrice!)) {
        return false;
      }
      if (maximumPrice != null &&
          (item.price == null || item.price! > maximumPrice!)) {
        return false;
      }
      return true;
    }).toList();
    int number(double? a, double? b, {bool descending = false}) {
      if (a == null) return b == null ? 0 : 1;
      if (b == null) return -1;
      return descending ? b.compareTo(a) : a.compareTo(b);
    }

    // Keep original order for ties, including unknown values.
    final positions = {for (var i = 0; i < result.length; i++) result[i]: i};
    if (sort != 'original') {
      result.sort((a, b) {
        final order = switch (sort) {
          'name' => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
          'price' => number(a.price, b.price),
          'priceDesc' => number(a.price, b.price, descending: true),
          'memory' => number(a.memory, b.memory, descending: true),
          'stars' => number(a.stars, b.stars, descending: true),
          'newest' || 'oldest' => number(
            a.publishedAt?.millisecondsSinceEpoch.toDouble(),
            b.publishedAt?.millisecondsSinceEpoch.toDouble(),
            descending: sort == 'newest',
          ),
          _ => 0,
        };
        return order == 0 ? positions[a]!.compareTo(positions[b]!) : order;
      });
    }
    return result;
  }
}
