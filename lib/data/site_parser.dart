import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

import 'html_parser.dart';
import 'models.dart';
import 'site_models.dart';

class SiteRoutes {
  static const origin = 'https://huarun.win';
  static const sections = <String, String>{
    '/vps': 'VPS',
    '/jichang': '机场',
    '/feed': '生态动态',
    '/people': '人物',
    '/history/apps': '应用纪事',
    '/history/cores': '内核纪事',
    '/history/protocols': '协议纪事',
    '/cores': '代理内核',
    '/protocols': '协议选型',
    '/servers': '服务端',
    '/subscription-tools': '订阅工具',
    '/rules': '规则与配置',
    '/articles': '独家文章',
    '/devices/steam-deck': 'Steam Deck',
    '/routers': '路由器工具',
    '/about': '关于网站',
    '/editorial-policy': '编辑与收录标准',
    '/privacy': '隐私政策',
    '/terms': '使用条款',
  };

  static const onlineLinks = <String, String>{
    '/corrections': '反馈',
    'https://t.me/hunrunwin': 'Telegram 群组',
    'https://t.me/huarunying': 'Telegram 频道',
  };

  static Iterable<MapEntry<String, String>> get contentSections =>
      sections.entries.where(
        (entry) =>
            !CatalogDevice.values.any((device) => entry.key == device.path) &&
            !ApplicationType.values.any(
              (type) => entry.key == '/${type.route}',
            ),
      );

  static bool isNative(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host == 'huarun.win' &&
      uri.userInfo.isEmpty &&
      !uri.hasPort &&
      !uri.pathSegments.contains('..') &&
      !uri.pathSegments.any((s) => s.contains('/')) &&
      !uri.path.endsWith('/buy') &&
      (uri.path == '/' ||
          const {
            'apps',
            'platform',
            'core',
            'free',
            'open-source',
            'incomplete-source',
            'closed-source',
            'history',
          }.contains(uri.pathSegments.firstOrNull) ||
          sections.keys.any(
            (p) => uri.path == p || uri.path.startsWith('$p/'),
          ));

  static bool isOnlineAction(Uri uri) =>
      uri.host == 'huarun.win' &&
      (uri.path.startsWith('/account') || uri.path.startsWith('/corrections'));

  static bool isCorrection(Uri uri) =>
      uri.scheme == 'https' &&
      uri.origin == origin &&
      uri.userInfo.isEmpty &&
      (uri.path == '/corrections' || uri.path.startsWith('/corrections/'));

  static SiteReadingKind? readingKind(Uri uri) =>
      switch (uri.pathSegments.firstOrNull) {
        'feed' => SiteReadingKind.feed,
        'people' =>
          uri.pathSegments.elementAtOrNull(2) == 'feed'
              ? SiteReadingKind.feed
              : SiteReadingKind.person,
        'articles' => SiteReadingKind.article,
        'history' => SiteReadingKind.history,
        'cores' => SiteReadingKind.core,
        'protocols' => SiteReadingKind.protocol,
        _ => null,
      };

  static bool readingDirectory(Uri uri) => switch (uri.pathSegments) {
    ['feed'] || ['feed', 'history' || 'releases'] => true,
    ['feed', 'page', _] || ['feed', 'history' || 'releases', 'page', _] => true,
    ['people'] ||
    ['people', 'pioneers' || 'contributors' || 'historical'] => true,
    ['people', _, 'feed'] || ['people', _, 'feed', 'page', _] => true,
    ['articles'] || ['cores'] || ['protocols'] => true,
    _ => false,
  };

  static bool vpsDirectory(Uri uri) => switch (uri.pathSegments) {
    ['vps'] => true,
    ['vps', 'locations' || 'topics', _] => true,
    ['vps', final provider] => !const {
      'guide',
      'locations',
      'topics',
      'page',
    }.contains(provider),
    ['vps', 'page', final page] ||
    ['vps', _, 'page', final page] ||
    [
      'vps',
      'locations' || 'topics',
      _,
      'page',
      final page,
    ] => (int.tryParse(page) ?? 0) > 0,
    _ => false,
  };
}

/// DOM selectors for all public sections live here, separate from Flutter UI.
class PublicSiteParser {
  static String _text(Element? e) => SiteHtmlParser.text(e);
  late Uri _base;
  late Document _document;
  bool _serviceDetail = false;
  bool _editorial = false;
  String? _url(String? value) => SiteHtmlParser.webUrl(value, _base);
  String? _href(Element? e) => _url(e?.attributes['href']);

  SiteDocument parse(String source, String url) {
    _base = Uri.parse(url);
    final doc = _document = html.parse(source);
    final root = doc.querySelector(
      'main .catalog, main .detail-page, main .feed-page, '
      'main .history-page, main .legal-page',
    );
    if (root == null || doc.querySelector('h1') == null) {
      throw const PageFormatException('暂时无法识别这个栏目的内容，请刷新或查看原网页。');
    }
    final title = _text(root.querySelector('h1'));
    final kind = SiteRoutes.readingKind(_base);
    _editorial = kind != null;
    final description =
        doc.querySelector('meta[name="description"]')?.attributes['content'] ??
        '';
    final directory =
        root.classes.contains('catalog') ||
        root.querySelector(
              '.people-directory, .article-index-list, '
              '.feed-directory',
            ) !=
            null ||
        (const ['/cores', '/protocols'].contains(_base.path) &&
            root.querySelector('.core-profile-grid') != null);
    _serviceDetail =
        !directory &&
        (root.classes.contains('vps-detail') ||
            root.classes.contains('airport-detail'));
    final service = _serviceDetail ? _service(root) : null;
    _serviceDetail = service != null;
    final groups = <SiteLinkGroup>[];
    final providers = <SiteLink>[];
    final groupKeys = <String>{};
    for (final nav in doc.querySelectorAll(
      _editorial
          ? '.people-tier-bar, .feed-filters'
          : 'aside.sidebar nav, .history-section-nav, .people-tier-bar, '
                '.feed-filters, .vps-topic-navigation, .vps-tag-filters, '
                '.vps-filter-location',
    )) {
      final clean = nav.clone(true);
      for (final count in clean.querySelectorAll(
        '.feed-filter-count, .people-tier-count, .people-tier-label-short, '
        '.nav-count',
      )) {
        count.remove();
      }
      final links = _links(clean).where((link) {
        if (!nav.classes.contains('vps-tag-filters')) return true;
        // Tags backed by published topic pages work without website scripts.
        // Query-only tag links do not change the server-rendered card scope.
        return switch (Uri.parse(link.url).pathSegments) {
          ['vps', 'topics', _] => true,
          _ => false,
        };
      }).toList();
      if (nav.parent?.classes.contains('vps-sidebar') ?? false) {
        providers.addAll(links);
      }
      final key = links.map((l) => l.url).join('|');
      if (links.isEmpty || !groupKeys.add(key)) continue;
      groups.add(
        SiteLinkGroup(
          nav.attributes['aria-label'] ?? _text(nav.querySelector('legend')),
          links,
        ),
      );
    }
    final catalogScope = [
      for (final node in doc.querySelectorAll(
        '.vps-filter-billing [aria-pressed="true"], '
        '.vps-filter-availability [aria-pressed="true"]',
      ))
        if (_text(node).isNotEmpty) _text(node),
    ];
    final pageNav = doc.querySelector(
      '.vps-pagination, .airport-pagination, .feed-pagination',
    );
    final pagination = pageNav == null
        ? <SiteLink>[]
        : _links(pageNav, keepLabels: true);
    final next = pagination
        .where((l) => l.label.contains('下一页'))
        .firstOrNull
        ?.url;
    final previous = pagination
        .where((l) => l.label.contains('上一页'))
        .firstOrNull
        ?.url;
    final items = <SiteItem>[];
    if (directory) {
      for (final card in root.querySelectorAll(
        'article.app-card, article.vps-card, article.person-card, '
        '.feed-preview-card, a.article-index-card, a.core-profile-card',
      )) {
        final item = _item(card);
        if (item != null) items.add(item);
        card.remove();
      }
      if (items.isEmpty &&
          root.querySelector(
                '.empty-state, .feed-empty, .people-empty-state',
              ) ==
              null &&
          root.querySelector('.article-index-list') == null) {
        throw const PageFormatException('目录内容结构已变化，请稍后重试。');
      }
    }
    final reading = !directory && kind != null
        ? _reading(root, kind, title)
        : null;
    if (_editorial && directory) {
      // Directory identity is rendered once by the native heading. Preserve
      // editorial notes while removing the now-empty website card partitions.
      for (final node in root.querySelectorAll(
        'h1, .people-page-heading, .directory-search-intent, '
        '.people-partitions-container, .feed-section-heading, '
        '.feed-sidebar, .feed-list-heading',
      )) {
        node.remove();
      }
    }
    // Shell, duplicated mobile controls and JS-only operations aren't article
    // content. Online account/correction/salute actions have explicit UI entry.
    for (final node in root.querySelectorAll(
      'script, style, noscript, svg, footer.site-footer, '
      '.topbar, .mobile-site-tabs, #article-site-header, '
      '.directory-controls, .directory-actions, .result-row, '
      '.active-filter-chips, .directory-compact-heading, '
      '.vps-pagination, .airport-pagination, .feed-pagination, '
      '.history-section-nav, .people-tier-bar, .people-category-bar, '
      '.feed-filters, .vps-topic-navigation, .vps-tag-filters, .feed-load-more, '
      '.person-salute-card, .detail-correction, .airport-mobile-view, '
      '.person-toc, .article-toc, '
      '.card-mobile-metrics, .airport-plan-filters, .protocol-scenario-filters, '
      '.core-lineage-controls, form, input, select, output',
    )) {
      node.remove();
    }
    if (_editorial) {
      for (final node in root.querySelectorAll(
        '.history-breadcrumb, .history-reading-controls, .history-year-navigation, '
        '.core-profile-nav, .article-return, .article-content nav.toc, '
        '.article-content dialog, .article-content .image-hint, '
        '.person-bottom-nav, .person-hero-salute-link, '
        '.history-lineage-toolbar, .history-lineage-map, '
        '.history-lineage-scroll-hint, .history-lineage-actions-row, '
        '.protocol-filter-status, .protocol-comparison-heading',
      )) {
        node.remove();
      }
    }
    final blocks = [
      if (service != null) service.overview,
      if (reading != null) reading.overview,
      ..._children(root),
    ];
    if (!directory && blocks.isEmpty) {
      throw const PageFormatException('页面没有可显示的公开内容。');
    }
    return SiteDocument(
      url: url,
      title: title.isEmpty ? SiteRoutes.sections[_base.path] ?? '华润赢' : title,
      description: description,
      directory: directory,
      items: items,
      groups: groups,
      providers: providers,
      catalogScope: catalogScope,
      pagination: pagination,
      nextUrl: next,
      previousUrl: previous,
      blocks: blocks,
      service: service,
      reading: reading,
    );
  }

  SiteReadingDetails? _reading(
    Element root,
    SiteReadingKind kind,
    String title,
  ) {
    final hero = switch (kind) {
      SiteReadingKind.person => root.querySelector('.person-article-hero'),
      SiteReadingKind.article => root.querySelector(
        '.article-content article > header',
      ),
      SiteReadingKind.core ||
      SiteReadingKind.protocol => root.querySelector('.core-profile-hero'),
      SiteReadingKind.feed => root.querySelector('.feed-card'),
      SiteReadingKind.history => null,
    };
    final heading =
        hero?.querySelector('h1, .feed-card-title') ?? root.querySelector('h1');
    final readingTitle = kind == SiteReadingKind.history
        ? SiteRoutes.sections[_base.path] ?? title
        : _text(heading).isEmpty
        ? title
        : _text(heading);
    final metadata = <String>[];
    final summary = <SiteText>[];
    var eyebrow = switch (kind) {
      SiteReadingKind.person => '人物小传',
      SiteReadingKind.article => '独家文章',
      SiteReadingKind.feed => '生态动态',
      SiteReadingKind.history => '技术与纪事',
      SiteReadingKind.core => '代理内核',
      SiteReadingKind.protocol => '协议与传输',
    };
    final actions = <SiteLink>[];
    String? image;
    void meta(Element? node) {
      final value = _text(node);
      if (value.isNotEmpty) metadata.add(value);
    }

    switch (kind) {
      case SiteReadingKind.person:
        image = _url(hero?.querySelector('img')?.attributes['src']);
        meta(hero?.querySelector('.person-category-badge'));
        meta(hero?.querySelector('.person-profile-role'));
        meta(hero?.querySelector('.person-profile-aliases'));
        actions.addAll(
          _links(hero ?? Element.tag('div'))
              .where((link) => Uri.parse(link.url).fragment != 'salute'),
        );
      case SiteReadingKind.feed:
        image = _url(hero?.querySelector('.feed-avatar')?.attributes['src']);
        meta(hero?.querySelector('.feed-subject'));
        meta(hero?.querySelector('.feed-author-role'));
        final source = _text(hero?.querySelector('.feed-source-label'));
        final date = _text(hero?.querySelector('time'));
        final byline = [
          source,
          date,
        ].where((value) => value.isNotEmpty).join(' · ');
        if (byline.isNotEmpty) metadata.add(byline);
        final kinds = hero
            ?.querySelectorAll('.feed-kind')
            .map(_text)
            .where((text) => text.isNotEmpty)
            .join(' · ');
        if (kinds != null && kinds.isNotEmpty) eyebrow = kinds;
        final intro = hero?.querySelector('.feed-summary');
        if (intro != null) summary.addAll(_runs(intro));
        final author = hero?.querySelector('.feed-subject');
        if (_href(author) case final authorUrl?) {
          actions.add(SiteLink('查看${_text(author)}', authorUrl));
        }
        for (final node
            in hero?.querySelectorAll(
                  '.feed-card-heading, .feed-card-title, .feed-summary',
                ) ??
                <Element>[]) {
          node.remove();
        }
      case SiteReadingKind.article:
        meta(hero?.querySelector('.meta'));
        final label = _text(hero?.querySelector('.eyebrow'));
        if (label.isNotEmpty) eyebrow = label;
        for (final paragraph
            in hero?.querySelectorAll('p:not(.meta):not(.eyebrow)') ??
                <Element>[]) {
          if (summary.isNotEmpty) summary.add(const SiteText('\n'));
          summary.addAll(_runs(paragraph));
        }
      case SiteReadingKind.core || SiteReadingKind.protocol:
        meta(hero?.querySelector('.core-profile-alias'));
        final description =
            hero?.querySelectorAll(
              'p:not(.history-eyebrow):not(.core-profile-alias)',
            ) ??
            <Element>[];
        for (final paragraph in description) {
          summary.addAll(_runs(paragraph));
        }
        final links = root.children
            .where((node) => node.classes.contains('core-profile-links'))
            .firstOrNull;
        if (links != null) {
          actions.addAll(_links(links));
          for (final value in links.children.where(
            (node) => node.localName == 'span',
          )) {
            meta(value);
          }
          links.remove();
        }
      case SiteReadingKind.history:
        final intro = root.querySelector('.history-reading-intro');
        if (intro != null) {
          summary.addAll(_runs(intro));
          intro.remove();
        }
    }
    final overview = SiteBlock(
      id: heading?.id.isNotEmpty == true ? heading!.id : null,
      runs: [
        SiteText(readingTitle, bold: true),
        SiteText('\n$eyebrow'),
        for (final value in metadata) SiteText('\n$value'),
        if (summary.isNotEmpty) const SiteText('\n'),
        ...summary,
        for (final link in actions) SiteText('\n${link.label}', url: link.url),
      ],
    );
    if (kind == SiteReadingKind.feed) {
      heading?.remove();
    } else if (hero != null) {
      hero.remove();
    } else {
      heading?.remove();
    }
    return SiteReadingDetails(
      kind: kind,
      title: readingTitle,
      eyebrow: eyebrow,
      overview: overview,
      summary: summary,
      metadata: metadata,
      image: image,
      actions: actions,
    );
  }

  SiteServiceDetails? _service(Element root) {
    final isVps = root.classes.contains('vps-detail');
    final hero = root.querySelector(
      isVps ? '.vps-detail-hero' : '.airport-detail-hero',
    );
    if (hero == null) return null;
    final titleNode = hero.querySelector('h1');
    final title = _text(titleNode);
    if (title.isEmpty) return null;
    final subtitle = _text(hero.querySelector('p'));
    final image = _url(hero.querySelector('img')?.attributes['src']);
    final identity = <SiteText>[];
    for (final child
        in hero.querySelector('.vps-detail-identity')?.children ??
            <Element>[]) {
      if (identity.isNotEmpty) identity.add(const SiteText(' · '));
      identity.addAll(_runs(child));
    }
    final purchaseNode = root.querySelector(
      isVps
          ? '.vps-official-action'
          : '.airport-desktop-purchase .airport-purchase-link',
    );
    final purchaseUrl = _href(purchaseNode);
    final purchase = purchaseUrl == null
        ? null
        : SiteLink(_text(purchaseNode), purchaseUrl);
    final highlights = <String, String>{};
    String price = '', referencePrice = '', referenceNote = '';
    if (isVps) {
      final specs = root.querySelector('.vps-purchase-specs');
      for (final dt in specs?.querySelectorAll('dt') ?? <Element>[]) {
        final dd = dt.nextElementSibling;
        if (dd?.localName == 'dd' &&
            _text(dt).isNotEmpty &&
            _text(dd).isNotEmpty) {
          final value = dd!.clone(true);
          for (final note in value.querySelectorAll('.vps-traffic-period')) {
            note.text = ' · ${_text(note)}';
          }
          highlights[_text(dt)] = _text(value);
        }
      }
      // Only a single published quote can be promoted to the overview.
      // Multiple billing options remain together in their original section.
      final quotes = root.querySelectorAll(
        '.vps-price-panel > .vps-price-option',
      );
      if (quotes.length == 1) {
        final amount = quotes.single.querySelector('.vps-card-price');
        final reference = quotes.single.querySelector('.vps-reference-price');
        price = _text(amount);
        referencePrice = _text(reference);
        referenceNote = reference?.attributes['title'] ?? '';
        if (price.isNotEmpty) {
          amount?.remove();
          reference?.remove();
          root.querySelector('#price-title')?.text = '购买须知';
        }
      }
      specs?.remove();
    } else {
      final plans = root.querySelectorAll('.airport-product-card');
      if (plans.isNotEmpty) highlights['公开套餐'] = '${plans.length} 款';
      final periods = plans
          .map((plan) => _text(plan.querySelector('.airport-product-period')))
          .where((text) => text.isNotEmpty)
          .toSet();
      if (periods.isNotEmpty) {
        highlights['付款周期'] = periods
            .map((text) => text.replaceFirst(RegExp(r'^/\s*'), ''))
            .join(' · ');
      }
      // Keep plans near the purchase action; supporting material follows them.
      for (final section in root.querySelectorAll(
        '.airport-channel-section, .airport-contact-section',
      )) {
        section.remove();
        root.append(section);
      }
    }
    final overview = SiteBlock(
      id: titleNode?.id.isNotEmpty == true ? titleNode!.id : null,
      runs: [
        SiteText(title, bold: true),
        if (subtitle.isNotEmpty) SiteText('\n$subtitle'),
        if (identity.isNotEmpty) ...[const SiteText('\n'), ...identity],
        if (price.isNotEmpty) SiteText('\n$price'),
        if (referencePrice.isNotEmpty) SiteText('\n人民币参考价：$referencePrice'),
        if (referenceNote.isNotEmpty) SiteText('\n$referenceNote'),
        for (final fact in highlights.entries)
          SiteText('\n${fact.key}：${fact.value}'),
        if (purchase != null)
          SiteText('\n${purchase.label}', url: purchase.url),
      ],
    );
    hero.remove();
    purchaseNode?.remove();
    for (final node in root.querySelectorAll(
      '.detail-nav, .airport-desktop-purchase, .airport-mobile-purchase',
    )) {
      node.remove();
    }
    for (final section in root.querySelectorAll('section[aria-label]')) {
      if (section.querySelector('h2, h3') == null) {
        section.nodes.insert(
          0,
          Element.tag('h2')..text = section.attributes['aria-label']!,
        );
      }
    }
    return SiteServiceDetails(
      kind: isVps ? SiteServiceKind.vps : SiteServiceKind.airport,
      title: title,
      subtitle: subtitle,
      identity: identity,
      image: image,
      purchase: purchase,
      highlights: highlights,
      price: price,
      referencePrice: referencePrice,
      referenceNote: referenceNote,
      overview: overview,
    );
  }

  SiteBlock _airportOffer(Element e) {
    final facts = <String, String>{};
    final facets = <String, List<String>>{};
    final quotaValue = _text(e.querySelector('.airport-product-quota-value'));
    final quotaUnit = _text(e.querySelector('.airport-product-quota-unit'));
    final quota = quotaValue.isNotEmpty && quotaUnit.isNotEmpty
        ? '$quotaValue $quotaUnit'
        : _text(e.querySelector('.airport-product-quota'));
    if (quota.isNotEmpty) facts['流量'] = quota;
    for (final spec in e.querySelectorAll('.airport-product-specs > span')) {
      final label = spec.querySelector('.sr-only');
      final key = _text(label).replaceFirst(RegExp(r'[：:]\s*$'), '').trim();
      final valueNode = spec.clone(true);
      valueNode.querySelector('.sr-only')?.remove();
      final value = _text(valueNode);
      if (key.isNotEmpty && value.isNotEmpty) facts[key] = value;
    }
    final amount = _text(e.querySelector('.airport-product-amount'));
    final period = _text(e.querySelector('.airport-product-period'));
    final price = amount.isNotEmpty && period.isNotEmpty
        ? '$amount $period'
        : _text(e.querySelector('.airport-product-price'));
    if (price.isNotEmpty) facts['付款金额'] = price;
    final billing = _airportBillingPeriod(period);
    if (billing.isNotEmpty) facets['付款周期'] = [billing];
    final remainder = e.clone(true);
    for (final node in remainder.querySelectorAll(
      '.airport-product-name, .airport-product-quota, .airport-product-specs, '
      '.airport-product-price, .airport-product-monthly, .sr-only',
    )) {
      node.remove();
    }
    return SiteBlock(
      kind: BlockKind.offer,
      id: e.id.isEmpty ? null : e.id,
      item: SiteItem(
        title: _text(e.querySelector('.airport-product-name')),
        url: _base.toString(),
        facts: facts,
        facets: facets,
      ),
      children: _children(remainder),
    );
  }

  String _airportBillingPeriod(String value) {
    final clean = value.replaceFirst(RegExp(r'^/\s*'), '').trim();
    return switch (clean) {
      '月' => '月付',
      '半年' => '半年付',
      '年' => '年付',
      _ => clean,
    };
  }

  List<SiteLink> _links(Element root, {bool keepLabels = false}) {
    final seen = <String>{};
    return [
      for (final a in root.querySelectorAll('a[href]'))
        if (_href(a) case final String url)
          if (_text(a).isNotEmpty &&
              seen.add(keepLabels ? '$url|${_text(a)}' : url))
            SiteLink(
              _text(a).isNotEmpty ? _text(a) : a.attributes['aria-label'] ?? '',
              url,
              selected: a.attributes['aria-current'] == 'page',
            ),
    ];
  }

  SiteItem? _item(Element card) {
    final link = card.localName == 'a' && card.attributes.containsKey('href')
        ? card
        : card.querySelector(
            '.app-card-detail, .vps-card-link, .feed-detail-link, '
            '.person-card-name a',
          );
    final url = _href(link);
    final title = _text(card.querySelector('h2, h3'));
    if (url == null || title.isEmpty) return null;
    final facts = <String, String>{};
    for (final dl in card.querySelectorAll('dl:not(.card-mobile-metrics)')) {
      for (final dt in dl.querySelectorAll('dt')) {
        final dd = dt.nextElementSibling;
        if (dd?.localName != 'dd') continue;
        final key = _text(dt), value = _text(dd);
        if (key.isNotEmpty && value.isNotEmpty) facts[key] = value;
      }
    }
    final facets = <String, List<String>>{};
    final badges = card
        .querySelectorAll(
          '.badges > span, .platform-pills > span, .vps-network-badge, '
          '.person-card-category-badge, .person-card-years-badge, '
          '.feed-kind, .feed-author-role',
        )
        .map(_text)
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();
    void facet(String label, Iterable<String> values) {
      final clean = values.where((v) => v.isNotEmpty).toSet().toList();
      if (clean.isNotEmpty) facets[label] = clean;
    }

    facet(
      '适配环境',
      card
          .querySelectorAll('.platform-pills > span')
          .map(
            (n) => n.attributes['title']?.replaceFirst('支持 ', '') ?? _text(n),
          ),
    );
    facet('内核', [_text(card.querySelector('.core'))]);
    facet('许可 / 代码', [_text(card.querySelector('.source'))]);
    facet('技术领域', [_text(card.querySelector('.person-card-category-badge'))]);
    facet('动态分类', card.querySelectorAll('.feed-kind').map(_text));
    if (card.classes.contains('person-card')) {
      Element? partition = card.parent;
      while (partition != null &&
          !partition.classes.contains('people-partition')) {
        partition = partition.parent;
      }
      facet('群体', [_text(partition?.querySelector('.people-partition-title'))]);
      badges.addAll(
        card
            .querySelectorAll('.person-project-tag')
            .map(_text)
            .where((value) => value.isNotEmpty),
      );
    }
    if (_base.path == '/protocols' &&
        card.classes.contains('core-profile-card')) {
      final slug = Uri.parse(url).pathSegments.last;
      final recommendation = _document
          .getElementById('recommend-title-$slug')
          ?.parent
          ?.parent;
      if (recommendation != null) {
        final score = _text(
          recommendation.querySelector('.protocol-score-value'),
        );
        if (score.isNotEmpty) facts['编辑推荐'] = score;
        final requirements = recommendation.querySelectorAll(
          '.protocol-requirements > p',
        );
        if (requirements.isNotEmpty) facts['使用前提'] = _text(requirements.first);
        if (requirements.length > 1) {
          facts['限制'] = requirements.skip(1).map(_text).join(' ');
        }
      }
    }
    double? price;
    double? memory;
    double? traffic;
    final priceNode = card.querySelector('.vps-reference-price');
    final airportPrice = card.querySelector('.airport-product-price');
    if (priceNode != null) {
      facts['人民币参考价'] = _text(priceNode);
      price = _number(_text(priceNode));
    } else if (airportPrice != null) {
      facts['付款金额'] = _text(airportPrice);
      // Only an explicit CNY/¥ quote is comparable; never assume a currency.
      if (_text(airportPrice).contains('¥') ||
          _text(airportPrice).contains('CNY')) {
        price = _number(_text(airportPrice));
      }
    }
    final quote = _text(card.querySelector('.vps-card-price'));
    if (quote.isNotEmpty) facts['官方报价'] = quote;
    final period = _text(card.querySelector('.airport-product-period'));
    if (period.isNotEmpty) facet('付款周期', [period]);
    final monthly = _text(card.querySelector('.vps-monthly'));
    final quotedPeriod = _text(card.querySelector('.vps-price-period'))
        .replaceFirst(RegExp(r'^/\s*'), '');
    if (monthly.isNotEmpty || quotedPeriod.isNotEmpty) {
      final billing = switch (quotedPeriod) {
        '月' => '按月付款',
        '年' => '按年付款',
        '季' => '按季付款',
        '半年' => '按半年付款',
        _ =>
          quotedPeriod.isNotEmpty
              ? '按$quotedPeriod付款'
              : monthly.contains('折算')
              ? ''
              : monthly,
      };
      facet('付款周期', [billing]);
      if (monthly.isNotEmpty && monthly != billing) facts['付款说明'] = monthly;
    }
    final path = Uri.parse(url).pathSegments;
    if (path.firstOrNull == 'vps' && path.length >= 3) {
      facet('厂商', [title.split(' · ').first]);
      facet('地区', title.split(' · ').skip(1));
      facet('网络', card.querySelectorAll('.vps-network-badge').map(_text));
      memory = _sizeGb(facts['内存']);
    }
    final trafficLabel = facts.keys.where((k) => k.contains('月流量')).firstOrNull;
    if (trafficLabel != null) traffic = _sizeGb(facts[trafficLabel]);
    final summary = _text(
      card.querySelector('.description, .feed-summary, .person-card-summary') ??
          (card.localName == 'a' ? card.querySelector('p') : null),
    );
    final subtitle = [
      _text(
        card.querySelector(
          '.vps-card-subtitle, .person-card-role, '
          '.feed-subject, time',
        ),
      ),
      _text(card.querySelector('.card-decision-info, .feed-meta')),
    ].where((s) => s.isNotEmpty).join(' · ');
    return SiteItem(
      title: title.replaceFirst(RegExp(r'\s*→$'), ''),
      url: url,
      subtitle: subtitle,
      summary: summary,
      image: _url(card.querySelector('img')?.attributes['src']),
      badges: badges,
      facts: facts,
      facets: facets,
      actions: _links(card).where((l) => l.url != url).toList(),
      price: price,
      memory: memory,
      traffic: traffic,
      stars: _number(facts['总 Star'] ?? facts['Star'] ?? ''),
      byline: _text(card.querySelector('.feed-subject')),
      date: _text(card.querySelector('time')),
      publishedAt: DateTime.tryParse(
        card.querySelector('time')?.attributes['datetime'] ?? '',
      ),
    );
  }

  double? _number(String value) => double.tryParse(
    RegExp(r'\d[\d,]*(?:\.\d+)?')
            .firstMatch(value)
            ?.group(0)
            ?.replaceAll(',', '') ??
        '',
  );
  double? _sizeGb(String? value) {
    if (value == null ||
        !RegExp(r'[GMT]B\b', caseSensitive: false).hasMatch(value)) {
      return null;
    }
    final n = _number(value);
    if (n == null) return null;
    if (value.toUpperCase().contains('TB')) return n * 1024;
    if (value.toUpperCase().contains('MB')) return n / 1024;
    return n;
  }

  List<SiteText> _runs(
    Node node, {
    String? link,
    bool bold = false,
    bool code = false,
    bool italic = false,
    bool struck = false,
  }) {
    if (link == null) {
      for (
        var parent = node.parent;
        parent is Element;
        parent = parent.parent
      ) {
        if (parent.localName == 'a') {
          link = _href(parent);
          break;
        }
      }
    }
    if (node is Text) {
      return [
        SiteText(
          node.data.replaceAll(RegExp(r'\s+'), ' '),
          url: link,
          bold: bold,
          code: code,
          italic: italic,
          struck: struck,
        ),
      ];
    }
    if (node is! Element) return [];
    if (_ignored(node)) return [];
    if (node.localName == 'br') return [const SiteText('\n')];
    if (node.localName == 'img') {
      final alt = node.attributes['alt'] ?? '';
      return alt.isEmpty ? [] : [SiteText(alt, url: link)];
    }
    return [
      for (final child in node.nodes)
        ..._runs(
          child,
          link: node.localName == 'a' ? _href(node) : link,
          bold: bold || const {'strong', 'b', 'dt'}.contains(node.localName),
          code: code || node.localName == 'code',
          italic: italic || const {'em', 'i'}.contains(node.localName),
          struck: struck || const {'s', 'del'}.contains(node.localName),
        ),
    ];
  }

  bool _ignored(Element n) =>
      const {
        'script',
        'style',
        'svg',
        'noscript',
        'input',
        'select',
        'form',
        'output',
      }.contains(n.localName) ||
      n.attributes.containsKey('hidden') ||
      (n.classes.contains('sr-only') && n.localName != 'h1') ||
      n.attributes['aria-hidden'] == 'true' && n.localName != 'img';

  List<SiteBlock> _children(Element element) {
    final result = <SiteBlock>[];
    var inline = <SiteText>[];
    void flush() {
      if (inline.any((r) => r.text.trim().isNotEmpty)) {
        result.add(SiteBlock(runs: inline));
      }
      inline = [];
    }

    const inlineTags = {
      'a',
      'span',
      'strong',
      'b',
      'em',
      'i',
      'small',
      'time',
      'code',
      'br',
      'sup',
      'sub',
      'label',
      'kbd',
      's',
      'del',
    };
    for (final node in element.nodes) {
      if (node is Text) {
        inline.addAll(_runs(node));
      } else if (node is Element && !_ignored(node)) {
        if (inlineTags.contains(node.localName) &&
            node.querySelector('h1,h2,h3,h4,p,div,section,img') == null) {
          if (node.localName == 'a' &&
              inline.isNotEmpty &&
              inline.last.url != null &&
              inline.last.url != _href(node)) {
            inline.add(const SiteText('   '));
          }
          inline.addAll(_runs(node));
        } else {
          flush();
          result.addAll(_blocks(node));
        }
      }
    }
    flush();
    return result;
  }

  List<SiteBlock> _blocks(Element e) {
    if (_ignored(e)) return [];
    final id = e.id.isEmpty ? null : e.id;
    final tag = e.localName;
    if (_editorial) {
      if (e.classes.contains('protocol-timeline-intro')) {
        // The native controls own order and expansion; retain the historical
        // date qualification without the website's interaction instructions.
        return [
          SiteBlock(
            id: id,
            runs: [
              SiteText(
                _text(e)
                    .replaceFirst('默认最新在上。', '')
                    .replaceFirst('；点击条目查看完整说明、背景与来源。', '。'),
              ),
            ],
          ),
        ];
      }
      if (e.classes.contains('protocol-guide') &&
          _base.path == '/history/protocols') {
        return [
          SiteBlock(
            kind: BlockKind.disclosure,
            id: id,
            runs: const [SiteText('当前选型与评分说明')],
            children: _children(e),
          ),
        ];
      }
      if (tag == 'header' &&
          e.parent?.classes.contains('client-history-stage') == true) {
        return [
          SiteBlock(
            id: id,
            runs: [
              for (final (index, child) in e.children.indexed) ...[
                if (index > 0) const SiteText(' · '),
                ..._runs(child),
              ],
            ],
          ),
        ];
      }
      if (e.classes.contains('history-lineage-compact-node-wrap')) {
        final node = e.querySelector('.history-lineage-compact-node');
        if (node != null) {
          return [
            SiteBlock(
              kind: BlockKind.related,
              id: node.id.isEmpty ? id : node.id,
              item: SiteItem(
                title: _text(node.querySelector('strong')),
                url:
                    _href(e.querySelector('a.history-lineage-detail-link')) ??
                    '',
                subtitle: _text(node.querySelector('small')),
                summary: _text(node.querySelector('em')),
                date: _text(node.querySelector('time')),
              ),
            ),
          ];
        }
      }
      if (tag == 'figcaption') {
        return [SiteBlock(kind: BlockKind.caption, id: id, runs: _runs(e))];
      }
      if (e.classes.contains('feed-quote-heading')) {
        final label = e.querySelector('.feed-quote-label');
        final account = e.querySelector('.feed-quote-account');
        return [
          SiteBlock(
            id: id,
            runs: [
              if (label != null) ..._runs(label),
              if (label != null && account != null) const SiteText(' · '),
              if (account != null) ..._runs(account),
            ],
          ),
        ];
      }
      if (e.classes.contains('person-source-card')) {
        final link = e.querySelector('.person-source-link');
        if (_href(link) case final url?) {
          return [
            SiteBlock(
              kind: BlockKind.reference,
              id: id,
              item: SiteItem(
                title: _text(link),
                url: url,
                summary: _text(e.querySelector('.person-source-note')),
                subtitle: _text(e.querySelector('.person-source-url')),
                badges: [_text(e.querySelector('.person-source-num'))],
              ),
            ),
          ];
        }
      }
      if (e.classes.contains('history-event') ||
          e.classes.contains('person-timeline-item')) {
        return [_event(e)];
      }
      if (e.classes.contains('history-reader-content')) {
        return [
          SiteBlock(kind: BlockKind.timeline, id: id, children: _children(e)),
        ];
      }
      if (e.classes.contains('gallery')) {
        return [
          SiteBlock(kind: BlockKind.gallery, id: id, children: _children(e)),
        ];
      }
      if (e.classes.contains('core-profile-card') ||
          tag == 'a' &&
              (e.classes.contains('person-related-app-card') ||
                  e.classes.contains('history-tool-app'))) {
        final url = _href(tag == 'a' ? e : e.querySelector('h2 a, h3 a'));
        final title = _text(e.querySelector('h2, h3, strong'));
        if (url != null && title.isNotEmpty) {
          final historyCopy = e
              .querySelector('.client-history-app-copy')
              ?.clone(true);
          historyCopy?.querySelector('strong')?.remove();
          return [
            SiteBlock(
              kind: BlockKind.related,
              id: id,
              item: SiteItem(
                title: title.replaceFirst(RegExp(r'\s*→$'), ''),
                url: url,
                image: _url(e.querySelector('img')?.attributes['src']),
                summary: _text(
                  e.querySelector('p, .person-related-app-info > span'),
                ),
                subtitle: _text(historyCopy ?? e.querySelector('small')),
                actions: tag == 'a'
                    ? const []
                    : _links(e).where((link) => link.url != url).toList(),
              ),
            ),
          ];
        }
      }
    }
    if (_serviceDetail && e.classes.contains('airport-product-card')) {
      return [_airportOffer(e)];
    }
    if (_serviceDetail && e.classes.contains('vps-card')) {
      final item = _item(e);
      if (item != null) {
        return [SiteBlock(kind: BlockKind.offer, id: id, item: item)];
      }
    }
    if (const {'h1', 'h2', 'h3', 'h4', 'h5', 'h6'}.contains(tag)) {
      if (_text(e).isEmpty) return [];
      return [
        SiteBlock(
          kind: BlockKind.heading,
          id: id,
          runs: _editorial && e.classes.contains('history-year-heading')
              ? [
                  for (final node in e.nodes) ...[
                    if (node is Element && !_ignored(node))
                      const SiteText(' · '),
                    ..._runs(node),
                  ],
                ]
              : _runs(e),
          level: int.parse(tag!.substring(1)),
        ),
      ];
    }
    if (tag == 'img') {
      final src = _url(e.attributes['src']);
      return src == null
          ? []
          : [
              SiteBlock(
                kind: BlockKind.image,
                id: id,
                url: src,
                runs: [SiteText(e.attributes['alt'] ?? '')],
                level: int.tryParse(e.attributes['width'] ?? '') ?? 0,
              ),
            ];
    }
    if (tag == 'pre') {
      return [
        SiteBlock(kind: BlockKind.code, id: id, runs: [SiteText(e.text)]),
      ];
    }
    if (tag == 'table') {
      return [
        SiteBlock(
          kind: BlockKind.table,
          id: id,
          rows: [
            for (final row in e.querySelectorAll('tr'))
              [
                for (final cell in row.children.where(
                  (c) => c.localName == 'td' || c.localName == 'th',
                ))
                  _runs(cell, bold: cell.localName == 'th'),
              ],
          ],
        ),
      ];
    }
    if (tag == 'dl') {
      final rows = <List<List<SiteText>>>[];
      for (final dt in e.querySelectorAll('dt')) {
        final dd = dt.nextElementSibling;
        if (dd?.localName == 'dd') {
          rows.add([_runs(dt, bold: true), _runs(dd!)]);
        }
      }
      return rows.isEmpty
          ? []
          : [
              SiteBlock(
                kind: _serviceDetail || _editorial
                    ? BlockKind.facts
                    : BlockKind.table,
                id: id,
                rows: rows,
              ),
            ];
    }
    if (tag == 'details') {
      final summary = e.querySelector('summary');
      final runs = summary == null ? [const SiteText('展开阅读')] : _runs(summary);
      summary?.remove();
      return [
        SiteBlock(
          kind: BlockKind.disclosure,
          id: id,
          runs: runs,
          children: _children(e),
          open:
              e.attributes.containsKey('open') &&
              !(_editorial && e.classes.contains('history-disclosure')),
        ),
      ];
    }
    if (tag == 'ul' || tag == 'ol') {
      final result = <SiteBlock>[];
      var index = 0;
      for (final child in e.children) {
        if (child.localName != 'li') continue;
        index++;
        if (_editorial &&
            child.querySelector('h2,h3,h4,p,div,section,details,ul,ol') !=
                null) {
          if (child.classes.contains('history-event') ||
              child.classes.contains('person-source-card')) {
            result.addAll(_blocks(child));
          } else {
            result.add(
              SiteBlock(
                kind: BlockKind.panel,
                id: child.id.isEmpty ? null : child.id,
                children: _children(child),
              ),
            );
          }
          continue;
        }
        result.add(
          SiteBlock(
            id: child.id.isEmpty ? null : child.id,
            runs: [SiteText(tag == 'ol' ? '$index. ' : '• '), ..._runs(child)],
          ),
        );
        // Preserve nested formatted material, e.g. code and reference tables.
        for (final nested in child.querySelectorAll('pre, table')) {
          result.addAll(_blocks(nested));
        }
      }
      return id == null
          ? result
          : [SiteBlock(kind: BlockKind.panel, id: id, children: result)];
    }
    if (tag == 'button') {
      final preview = e.querySelector('.airport-channel-preview');
      return preview == null
          ? []
          : [
              SiteBlock(
                kind: BlockKind.quote,
                runs: [SiteText(preview.text.trim())],
              ),
            ];
    }
    if (tag == 'nav' || e.classes.contains('vps-detail-identity')) {
      return [
        SiteBlock(
          id: id,
          runs: [
            for (final child in e.children) ...[
              ..._runs(child),
              const SiteText('   '),
            ],
          ],
        ),
      ];
    }
    if (tag == 'p' || tag == 'dt' || tag == 'dd' || tag == 'figcaption') {
      final runs = _runs(e);
      final images = e.querySelectorAll('img').expand(_blocks).toList();
      return [
        if (runs.any((r) => r.text.trim().isNotEmpty))
          SiteBlock(id: id, runs: runs),
        ...images,
      ];
    }
    final children = _children(e);
    if (children.isEmpty) return [];
    if (tag == 'blockquote') {
      return [SiteBlock(kind: BlockKind.quote, id: id, children: children)];
    }
    if (tag == 'article' ||
        tag == 'section' ||
        id != null ||
        e.classes.contains('detail-notice')) {
      return [SiteBlock(kind: BlockKind.panel, id: id, children: children)];
    }
    return children;
  }

  SiteBlock _event(Element element) {
    final content = element.clone(true);
    final title = content.querySelector(
      '.protocol-event-title, .person-timeline-title, h4, h3',
    );
    final time = content.querySelector('time');
    final brief = content.querySelector('.protocol-event-brief');
    final category = _text(
      content.querySelector('.history-category, .protocol-event-meta > span'),
    );
    final item = SiteItem(
      title: _text(title),
      url: _base.replace(fragment: element.id).toString(),
      date: _text(time),
      publishedAt: DateTime.tryParse(time?.attributes['datetime'] ?? ''),
      summary: _text(brief),
      badges: category.isEmpty ? const [] : [category],
    );
    final titleId = title?.id;
    title?.remove();
    time?.remove();
    brief?.remove();
    for (final node in content.querySelectorAll(
      '.history-category, .protocol-event-meta, .history-event-marker, '
      '.person-timeline-marker, .history-event-permalink',
    )) {
      node.remove();
    }
    final protocol = content.querySelector('details.protocol-history-event');
    if (protocol != null) {
      protocol.querySelector('summary')?.remove();
      final replacement = Element.tag('div')
        ..nodes.addAll(protocol.nodes.toList());
      protocol.replaceWith(replacement);
    }
    return SiteBlock(
      kind: BlockKind.event,
      id: element.id.isEmpty ? null : element.id,
      item: item,
      children: [
        if (titleId != null && titleId.isNotEmpty) SiteBlock(id: titleId),
        ..._children(content),
      ],
    );
  }
}
