import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/models.dart';
import '../data/site_models.dart';
import '../data/site_parser.dart';
import '../services/app_controller.dart';
import '../services/app_library.dart';
import '../services/downloads.dart';
import 'airport_catalog.dart';
import 'content_image.dart';
import 'components.dart';
import 'detail.dart';
import 'detail_components.dart';
import 'app_library_page.dart';
import 'app_library_navigation.dart';
import 'mac_window.dart';
import 'page_components.dart';
import 'catalog_controls.dart';
import 'reading_catalog.dart';
import 'service_detail_components.dart';
import 'share_link_button.dart';
import 'theme.dart';
import 'site_reader.dart';
import 'vps_catalog.dart';

IconData siteIcon(String path) => switch (path.split('/').elementAtOrNull(1)) {
  'vps' => Icons.cloud_outlined,
  'jichang' => Icons.flight_rounded,
  'feed' => Icons.rss_feed_rounded,
  'people' => Icons.people_outline_rounded,
  'history' => Icons.history_edu_rounded,
  'cores' => Icons.memory_rounded,
  'protocols' => Icons.hub_outlined,
  'servers' => Icons.dns_outlined,
  'subscription-tools' => Icons.auto_fix_high_rounded,
  'rules' => Icons.rule_rounded,
  'articles' => Icons.menu_book_rounded,
  'routers' => Icons.router_outlined,
  'devices' => Icons.sports_esports_outlined,
  _ => Icons.info_outline_rounded,
};

class SitePage extends StatefulWidget {
  const SitePage({
    super.key,
    required this.url,
    required this.controller,
    required this.downloads,
    this.embedded = false,
    this.active = true,
    this.sectionNavigation,
  });
  final String url;
  final AppController controller;
  final DownloadManager downloads;
  final bool embedded;
  final bool active;
  final Widget? sectionNavigation;
  @override
  State<SitePage> createState() => _SitePageState();
}

class _SitePageState extends State<SitePage> {
  SiteSnapshot? snapshot;
  bool loading = true, collecting = false, allLoaded = false, listMode = false;
  String? error, loadMessage;
  String query = '', sort = 'original', next = '';
  bool serviceSearch = false;
  bool timelineDescending = false;
  bool referenceOpen = false;
  final selected = <String, String>{};
  double? minMemory, minTraffic, minPrice, maxPrice;
  List<SiteItem> items = [];
  final search = TextEditingController();
  final shortcutFocus = FocusNode();
  final anchors = <SiteBlock, GlobalKey>{};
  final expanded = <SiteBlock>{};
  final scroll = ScrollController();
  int generation = 0, collectedPages = 1;
  late int _sourceRevision;
  bool _sourcePending = false;
  SiteDocument? get document => snapshot?.document;
  String? catalogUrl;
  // A redirect or refresh updates the document without resetting its controls.
  // Only an explicit directory change creates a new catalog state.
  Object catalogIdentity = Object();
  String get pageUrl => catalogUrl ?? widget.url;
  bool get _usesInAppBrowser =>
      Platform.isAndroid &&
      const {
        'vps',
        'jichang',
      }.contains(Uri.parse(pageUrl).pathSegments.firstOrNull);

  @override
  void initState() {
    super.initState();
    _sourceRevision = widget.controller.sources.revision;
    widget.controller.sources.addListener(_sourceChanged);
    final cached = widget.controller.repository.cachedPage(pageUrl);
    if (cached == null) {
      _load();
    } else {
      _applySnapshot(cached);
      loading = false;
    }
  }

  void _sourceChanged() {
    if (!mounted || _sourceRevision == widget.controller.sources.revision) {
      return;
    }
    _sourceRevision = widget.controller.sources.revision;
    generation++;
    setState(() {
      snapshot = null;
      items = [];
      next = '';
      error = loadMessage = null;
      loading = collecting = allLoaded = false;
      _sourcePending = true;
      anchors.clear();
      expanded.clear();
    });
    if (widget.active) {
      _sourcePending = false;
      _load(refresh: true, retrySources: false);
    }
  }

  @override
  void didUpdateWidget(covariant SitePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active && !widget.active && collecting) {
      generation++;
      collecting = false;
      loadMessage = '已停止加载，保留已载入的内容。';
    }
    if (widget.active && _sourcePending) {
      _sourcePending = false;
      _load(refresh: true, retrySources: false);
    }
  }

  @override
  void dispose() {
    generation++;
    widget.controller.sources.removeListener(_sourceChanged);
    search.dispose();
    shortcutFocus.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool refresh = false, bool retrySources = true}) async {
    if (refresh && loading) return;
    if (refresh && retrySources) widget.controller.sources.retryPrimary();
    final token = ++generation;
    setState(() {
      loading = true;
      error = null;
      collecting = false;
    });
    try {
      final value = await widget.controller.repository.page(
        pageUrl,
        refresh: refresh,
      );
      if (!mounted || token != generation) return;
      setState(() => _applySnapshot(value));
    } catch (e) {
      if (mounted && token == generation) setState(() => error = e.toString());
    } finally {
      if (mounted && token == generation) setState(() => loading = false);
    }
  }

  void _applySnapshot(SiteSnapshot value) {
    final fragment = Uri.parse(pageUrl).fragment;
    catalogUrl = fragment.isEmpty
        ? value.document.url
        : Uri.parse(value.document.url).replace(fragment: fragment).toString();
    snapshot = value;
    items = [...value.document.items];
    next = value.document.nextUrl ?? '';
    // A middle/last page can still have previous pages not loaded.
    allLoaded = next.isEmpty && value.document.previousUrl == null;
    collectedPages = 1;
    loadMessage = null;
    anchors.clear();
    expanded.clear();
    referenceOpen = false;
    void initialize(Iterable<SiteBlock> blocks) {
      for (final b in blocks) {
        if (b.open) expanded.add(b);
        initialize(b.children);
      }
    }

    initialize(value.document.blocks);
    if (fragment.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _jumpId(fragment);
      });
    }
  }

  Future<void> _collectPages() async {
    if (!widget.active || collecting || document == null) return;
    final token = generation;
    setState(() {
      collecting = true;
      loadMessage = null;
    });
    final seen = <String>{document!.url};
    final collected = {for (final item in items) item.url: item};
    // Begin at the collection's first published HTML page, including when
    // invoked from a later page. Follow only that collection's pagination.
    final current = Uri.parse(document!.url);
    String basePath(String p) => p.replaceFirst(RegExp(r'/page/\d+/?$'), '');
    final first = current
        .replace(path: basePath(current.path))
        .removeFragment()
        .toString();
    var target = first == document!.url ? next : first;
    try {
      var attempts = 0;
      while (target.isNotEmpty) {
        if (!mounted || token != generation) return;
        if (++attempts > 100) throw StateError('本次已达到 100 页，请缩小栏目范围。');
        final uri = Uri.parse(target);
        if (!SiteRoutes.isNative(uri) ||
            basePath(uri.path) != basePath(current.path)) {
          throw StateError('分页链接不属于当前栏目。');
        }
        if (!seen.add(target)) {
          // The initially loaded page may be revisited while starting at page 1.
          if (target == document!.url) {
            target = document!.nextUrl ?? '';
            continue;
          }
          throw StateError('网站分页链接出现循环。');
        }
        final page = await widget.controller.repository.page(target);
        if (!mounted || token != generation) return;
        if (!page.document.directory) throw StateError('分页没有返回可识别的目录。');
        for (final item in page.document.items) {
          collected[item.url] = item;
        }
        setState(() {
          items = collected.values.toList();
          collectedPages = seen.length;
          loadMessage = page.warning;
        });
        target = page.document.nextUrl ?? '';
      }
      if (mounted && token == generation) setState(() => allLoaded = true);
    } catch (e) {
      if (mounted && token == generation) {
        setState(() => loadMessage = '部分页面未载入，可重试。$e');
      }
    } finally {
      if (mounted && token == generation) setState(() => collecting = false);
    }
  }

  Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final here = Uri.parse(pageUrl);
    final sameReadingDirectory =
        SiteRoutes.readingDirectory(uri) &&
        SiteRoutes.readingKind(uri) == SiteRoutes.readingKind(here);
    final sameVpsDirectory =
        SiteRoutes.vpsDirectory(here) && SiteRoutes.vpsDirectory(uri);
    if (document?.directory == true &&
        SiteRoutes.isNative(uri) &&
        (sameReadingDirectory || sameVpsDirectory) &&
        uri.removeFragment() != here.removeFragment()) {
      final cached = widget.controller.repository.cachedPage(url);
      setState(() {
        catalogIdentity = Object();
        catalogUrl = url;
        snapshot = null;
        items = [];
        query = '';
        search.clear();
        selected.clear();
        error = null;
        loadMessage = null;
        if (cached != null) {
          generation++;
          collecting = false;
          _applySnapshot(cached);
          loading = false;
        }
      });
      if (scroll.hasClients) scroll.jumpTo(0);
      if (cached == null) await _load();
      return;
    }
    if (uri.host == here.host &&
        uri.path == here.path &&
        uri.query == here.query &&
        uri.fragment.isNotEmpty) {
      _jumpId(uri.fragment);
      return;
    }
    if (SiteRoutes.isNative(uri)) {
      final type = ApplicationType.fromUrl(uri);
      if (type != null) {
        final id = uri.pathSegments.last;
        final app =
            widget.controller.snapshot?.apps
                .where((a) => a.id == id && a.type == type)
                .firstOrNull ??
            CatalogApp(id: id, type: type, name: id, url: url);
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => DetailPage(
              app: app,
              controller: widget.controller,
              downloads: widget.downloads,
            ),
          ),
        );
      } else {
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => SitePage(
              url: url,
              controller: widget.controller,
              downloads: widget.downloads,
            ),
          ),
        );
      }
      return;
    }
    final kind = const [
      'dmg',
      'pkg',
      'zip',
      'apk',
    ].where((k) => uri.path.toLowerCase().endsWith('.$k')).firstOrNull;
    final androidPackage = Platform.isAndroid && kind == 'apk';
    final macPackage =
        Platform.isMacOS &&
        kind != 'apk' &&
        (kind != 'zip' ||
            RegExp(
              r'macos|darwin|mac[-_.]',
              caseSensitive: false,
            ).hasMatch(uri.path));
    if (kind != null &&
        (androidPackage || macPackage) &&
        uri.scheme == 'https' &&
        uri.host == 'github.com' &&
        uri.path.contains('/releases/download/')) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('下载安装包'),
          content: SelectableText(uri.pathSegments.last),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              style: downloadButtonStyle(context),
              child: const Text('下载'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      try {
        await widget.downloads.download(
          CatalogApp(
            id: here.path,
            name: document?.title ?? '安装包',
            url: here.toString(),
            description: '',
          ),
          DownloadLink(
            url: url,
            label: uri.pathSegments.last,
            kind: kind,
            platform: androidPackage ? 'Android' : 'macOS',
          ),
        );
        if (mounted) {
          if (AppLibraryNavigation.showDownloads(context)) return;
          Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => Scaffold(
                body: PageSafeArea(
                  child: AppLibraryPage(
                    controller: widget.controller,
                    manager: widget.downloads,
                    showBackButton: true,
                    initialSection: LibrarySection.downloads,
                  ),
                ),
              ),
            ),
          );
        }
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('暂时无法下载，请重试。')));
        }
      }
      return;
    }
    await _visit(url);
  }

  Future<void> _visit(String url) =>
      openLink(context, url, inApp: _usesInAppBrowser);

  Iterable<SiteBlock> _walk(Iterable<SiteBlock> blocks) sync* {
    for (final block in blocks) {
      yield block;
      yield* _walk(block.children);
    }
  }

  void _jumpId(String id) {
    final target = _walk(document?.blocks ?? [])
        .where((b) => b.id == id)
        .firstOrNull;
    if (target != null) {
      _jump(target);
    } else if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('未找到这个段落，可在原网页查看。')));
    }
  }

  void _jump(SiteBlock target) {
    // Search results move away from the editor; restore the page shortcuts.
    shortcutFocus.requestFocus();
    bool contains(SiteBlock b) => b == target || b.children.any(contains);
    setState(() {
      search.clear();
      query = '';
      if (document!.directory) referenceOpen = true;
      for (final block in _walk(document!.blocks)) {
        if (block.kind == BlockKind.disclosure && contains(block)) {
          expanded.add(block);
        }
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final targetContext = anchors[target]?.currentContext;
      if (targetContext != null) {
        Scrollable.ensureVisible(
          targetContext,
          duration: const Duration(milliseconds: 300),
          alignment: 0,
        );
      }
    });
  }

  void _outline() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .65,
        child: ListView(
          children: [
            const ListTile(title: Text('阅读目录')),
            for (final block in _walk(
              document!.blocks,
            ).where((b) => b.kind == BlockKind.heading && b.level <= 3))
              ListTile(
                title: Text(block.text),
                contentPadding: EdgeInsets.only(
                  left: block.level <= 2 ? 20 : 36,
                  right: 20,
                ),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _jump(block);
                },
              ),
          ],
        ),
      ),
    ),
  );

  Future<void> _copyLink(String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已复制链接')));
    }
  }

  void _linkSheet() {
    final links = <String, String>{};
    for (final block in _walk(document?.blocks ?? [])) {
      final runs = [
        ...block.runs,
        for (final row in block.rows)
          for (final cell in row) ...cell,
      ];
      for (final run in runs) {
        if (run.url != null && run.text.trim().isNotEmpty) {
          links.update(
            run.url!,
            (label) => '$label${run.text}',
            ifAbsent: () => run.text.trim(),
          );
        }
      }
      if (block.item case final item?) {
        if (item.url.isNotEmpty) links.putIfAbsent(item.url, () => item.title);
        for (final action in item.actions) {
          links.putIfAbsent(action.url, () => action.label);
        }
      }
    }
    for (final item in items) {
      links.putIfAbsent(item.url, () => item.title);
      for (final action in item.actions) {
        links.putIfAbsent(action.url, () => action.label);
      }
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .7,
          child: ListView(
            children: [
              const ListTile(title: Text('资料链接')),
              for (final link in links.entries)
                ListTile(
                  title: Text(
                    link.value,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    link.key,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: IconButton(
                    tooltip: '复制链接',
                    onPressed: () => _copyLink(link.key),
                    icon: const Icon(Icons.copy_rounded),
                  ),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _open(link.key);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _pageActions(
    SiteDocument? doc, {
    bool service = false,
    bool showMenu = true,
  }) => [
    if (service && doc != null && doc.service == null)
      IconButton(
        tooltip: '查找正文',
        onPressed: () => setState(() {
          serviceSearch = !serviceSearch;
          if (!serviceSearch) {
            search.clear();
            query = '';
          }
        }),
        icon: const Icon(Icons.search_rounded),
      ),
    if (service && doc?.reading != null)
      IconButton(
        tooltip: '阅读目录',
        onPressed: _outline,
        icon: const Icon(Icons.toc_rounded),
      ),
    if (!service && doc != null && !doc.directory)
      IconButton(
        tooltip: '阅读目录',
        onPressed: _outline,
        icon: const Icon(Icons.toc_rounded),
      ),
    RefreshIconButton(loading: loading, onPressed: () => _load(refresh: true)),
    if (service || doc?.directory == false)
      ShareLinkButton(url: pageUrl, title: doc?.title ?? '华润赢'),
    if (showMenu)
      PopupMenuButton<VoidCallback>(
        tooltip: '页面操作',
        onSelected: (action) => action(),
        itemBuilder: (_) => [
          if (service && doc != null)
            PopupMenuItem(value: _outline, child: const Text('阅读目录')),
          if (service && MediaQuery.sizeOf(context).width < 600)
            PopupMenuItem(
              value: () => _visit(pageUrl),
              child: const Text('在网站查看'),
            ),
          PopupMenuItem(
            value: () => _copyLink(pageUrl),
            child: const Text('复制链接'),
          ),
          PopupMenuItem(value: _linkSheet, child: const Text('查看 / 复制资料链接')),
          if (!service)
            PopupMenuItem(
              value: () => _visit(pageUrl),
              child: Text(_usesInAppBrowser ? '在网站查看' : '在浏览器查看'),
            ),
          PopupMenuItem(
            value: () => openLink(context, '${SiteRoutes.origin}/corrections'),
            child: const Text('反馈'),
          ),
        ],
      ),
  ];

  @override
  Widget build(BuildContext context) {
    final doc = document;
    final uri = Uri.parse(pageUrl);
    final readingKind = SiteRoutes.readingKind(uri);
    if (readingKind != null &&
        (doc?.directory ?? SiteRoutes.readingDirectory(uri))) {
      return ReadingCatalog(
        key: ObjectKey(catalogIdentity),
        kind: readingKind,
        document:
            doc ??
            SiteDocument(
              url: pageUrl,
              title: SiteRoutes.sections[uri.path] ?? '生态与阅读',
              directory: true,
            ),
        items: items,
        embedded: widget.embedded,
        loading: loading,
        collecting: collecting,
        allLoaded: doc == null || allLoaded,
        actions: _pageActions(doc),
        sectionNavigation: widget.sectionNavigation,
        onRefresh: () => _load(refresh: true),
        onOpen: _open,
        onCollect: _collectPages,
        onStop: () => setState(() {
          generation++;
          collecting = false;
          loadMessage = '已停止加载，保留已载入的内容。';
        }),
        message: [
          if (doc != null && error != null) '刷新失败，保留当前内容。',
          ?snapshot?.warning,
          ?loadMessage,
        ].where((value) => value.isNotEmpty).join('\n'),
        initialError: doc == null ? error : null,
        reference: doc == null || doc.blocks.isEmpty
            ? null
            : SelectionArea(child: _blocks(doc.blocks, flat: true)),
        referenceExpanded: referenceOpen,
        onReferenceExpansion: (value) => setState(() => referenceOpen = value),
        footer: doc == null ? null : _footer(),
      );
    }
    final serviceDirectory = doc != null
        ? doc.directory &&
              const {
                'vps',
                'jichang',
              }.contains(Uri.parse(doc.url).pathSegments.firstOrNull)
        : SiteRoutes.vpsDirectory(uri) ||
              switch (uri.pathSegments) {
                ['jichang'] => true,
                ['jichang', 'page', final page] =>
                  (int.tryParse(page) ?? 0) > 0,
                _ => false,
              };
    if (serviceDirectory) {
      final isVps = uri.pathSegments.firstOrNull == 'vps';
      final catalog = isVps ? VpsCatalog.new : AirportCatalog.new;
      return catalog(
        key: ObjectKey(catalogIdentity),
        document:
            doc ??
            SiteDocument(
              url: uri.removeFragment().toString(),
              title: isVps ? 'VPS' : '机场',
              directory: true,
            ),
        items: items,
        embedded: widget.embedded,
        loading: loading,
        collecting: collecting,
        allLoaded: doc == null || allLoaded,
        initialError: doc == null ? error : null,
        onRefresh: () => _load(refresh: true),
        onCollect: _collectPages,
        onStop: () => setState(() {
          generation++;
          collecting = false;
          loadMessage = '已停止加载，保留已载入的条目。';
        }),
        onOpen: _open,
        actions: _pageActions(doc, showMenu: !widget.embedded),
        footer: doc == null ? const SizedBox.shrink() : _footer(),
        hasSnapshot: doc != null,
        message: [
          if (doc != null && error != null) '刷新失败，保留当前内容。',
          ?snapshot?.warning,
          ?loadMessage,
        ].where((value) => value.isNotEmpty).join('\n'),
        reference: doc == null || doc.blocks.isEmpty
            ? null
            : ExpansionTile(
                title: const Text('栏目说明与参考'),
                children: [SelectionArea(child: _blocks(doc.blocks))],
              ),
      );
    }
    final serviceDetail =
        doc?.service != null ||
        (doc == null &&
            switch (uri.pathSegments) {
              ['vps', final vendor, _] =>
                vendor != 'topics' && vendor != 'page',
              ['jichang', final slug] => slug != 'page',
              _ => false,
            });
    if (serviceDetail || readingKind != null) return _servicePage(doc);
    return Scaffold(
      resizeToAvoidBottomInset: !widget.embedded,
      body: PageSafeArea(
        child: LayoutBuilder(
          builder: (context, size) {
            final inset = size.maxWidth >= 900 ? 32.0 : 20.0;
            return PageRefreshIndicator(
              onRefresh: () => _load(refresh: true),
              child: CustomScrollView(
                key: const ValueKey('site-content-scroll'),
                controller: scroll,
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      inset,
                      28 + PageSafeArea.topInsetOf(context),
                      inset,
                      8,
                    ),
                    sliver: SliverToBoxAdapter(child: _header(doc)),
                  ),
                  if (doc == null)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: loading
                          ? const Center(child: CircularProgressIndicator())
                          : EmptyState(
                              icon: Icons.cloud_off_rounded,
                              title: '暂时无法加载',
                              message: error ?? '请检查网络后重试。',
                              action: Wrap(
                                spacing: 12,
                                children: [
                                  FilledButton(
                                    onPressed: () => _load(refresh: true),
                                    child: const Text('重试'),
                                  ),
                                  TextButton(
                                    onPressed: () => _visit(pageUrl),
                                    child: const Text('查看网页'),
                                  ),
                                ],
                              ),
                            ),
                    )
                  else if (doc.directory)
                    ..._directory(doc, size.maxWidth, inset)
                  else
                    ..._reader(doc, inset),
                  SliverToBoxAdapter(
                    child: SizedBox(height: PageBottomInset.of(context)),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _servicePage(SiteDocument? doc) {
    final reading = SiteRoutes.readingKind(Uri.parse(pageUrl)) != null;
    void back() {
      if (ModalRoute.isCurrentOf(context) == true) {
        Navigator.of(context).maybePop();
      }
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): back,
        if (hasMacWindowControls)
          const SingleActivator(LogicalKeyboardKey.bracketLeft, meta: true):
              back,
      },
      child: Actions(
        // SelectableRegion handles Escape before the outer shortcuts. Once its
        // selection toolbar is closed, it forwards DismissIntent to this action.
        actions: {
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              back();
              return null;
            },
          ),
        },
        child: Focus(
          focusNode: shortcutFocus,
          autofocus: true,
          child: Scaffold(
            resizeToAvoidBottomInset: !widget.embedded,
            backgroundColor: Theme.of(context).colorScheme.surfaceContainerLow,
            body: PageSafeArea(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: reading ? 960 : 1120),
                  child: LayoutBuilder(
                    builder: (context, size) {
                      final compact = size.maxWidth < 600;
                      final inset = compact ? (reading ? 20.0 : 16.0) : 40.0;
                      return PageRefreshIndicator(
                        onRefresh: () => _load(refresh: true),
                        child: CustomScrollView(
                          key: const ValueKey('site-content-scroll'),
                          controller: scroll,
                          physics: const AlwaysScrollableScrollPhysics(),
                          slivers: [
                            SliverPadding(
                              padding: EdgeInsets.fromLTRB(
                                12,
                                8 + PageSafeArea.topInsetOf(context),
                                12,
                                0,
                              ),
                              sliver: SliverToBoxAdapter(
                                child: PageHeader(
                                  title: '',
                                  showBackButton: !widget.embedded,
                                  actions: _pageActions(doc, service: true),
                                ),
                              ),
                            ),
                            if (widget.sectionNavigation != null)
                              SliverPadding(
                                padding: EdgeInsets.fromLTRB(
                                  inset,
                                  0,
                                  inset,
                                  16,
                                ),
                                sliver: SliverToBoxAdapter(
                                  child: widget.sectionNavigation,
                                ),
                              ),
                            if (doc == null)
                              SliverFillRemaining(
                                hasScrollBody: false,
                                child: loading
                                    ? const Center(
                                        child: CircularProgressIndicator(),
                                      )
                                    : EmptyState(
                                        icon: Icons.cloud_off_rounded,
                                        title: '详情暂时不可用',
                                        message: '请检查网络后重试，或前往网站查看。',
                                        action: FilledButton(
                                          onPressed: () => _load(refresh: true),
                                          child: const Text('重试'),
                                        ),
                                      ),
                              )
                            else ...[
                              if (error != null || snapshot?.warning != null)
                                SliverPadding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: inset,
                                    vertical: 8,
                                  ),
                                  sliver: SliverToBoxAdapter(
                                    child: Text(
                                      snapshot?.warning ?? '刷新失败，保留当前内容。',
                                      style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .error,
                                      ),
                                    ),
                                  ),
                                ),
                              if (serviceSearch)
                                SliverPadding(
                                  padding: EdgeInsets.fromLTRB(
                                    inset,
                                    0,
                                    inset,
                                    8,
                                  ),
                                  sliver: SliverToBoxAdapter(
                                    child: TextField(
                                      controller: search,
                                      autofocus: true,
                                      onChanged: (value) =>
                                          setState(() => query = value),
                                      decoration: const InputDecoration(
                                        hintText: '查找正文',
                                        prefixIcon: Icon(Icons.search_rounded),
                                      ),
                                    ),
                                  ),
                                ),
                              ..._reader(doc, inset, compactService: compact),
                            ],
                            SliverToBoxAdapter(
                              child: SizedBox(
                                height: PageBottomInset.of(context),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(SiteDocument? doc) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      PageHeader(
        title:
            doc?.title ?? SiteRoutes.sections[Uri.parse(pageUrl).path] ?? '华润赢',
        showBackButton: !widget.embedded,
        actions: _pageActions(doc),
      ),
      if (doc != null) ...[
        if (collecting) const LinearProgressIndicator(minHeight: 2),
        if (error != null || snapshot!.warning != null || loadMessage != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              loadMessage ?? snapshot!.warning ?? '刷新失败，保留当前内容。',
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextField(
            controller: search,
            onChanged: (value) => setState(() => query = value),
            decoration: InputDecoration(
              hintText: doc.directory ? '搜索已载入的条目' : '查找正文',
              prefixIcon: const Icon(Icons.search_rounded),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清空搜索',
                      onPressed: () => setState(() {
                        search.clear();
                        query = '';
                      }),
                      icon: const Icon(Icons.close_rounded),
                    ),
            ),
          ),
        ),
        if (doc.groups.isNotEmpty)
          SizedBox(
            height: 46,
            child: ListView(
              padding: EdgeInsets.zero,
              scrollDirection: Axis.horizontal,
              children: [
                for (final group in doc.groups)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: PopupMenuButton<String>(
                      tooltip: group.label.isEmpty ? '分类导航' : group.label,
                      onSelected: _open,
                      itemBuilder: (_) => [
                        for (final link in group.links)
                          PopupMenuItem(
                            value: link.url,
                            child: Row(
                              children: [
                                Expanded(child: Text(link.label)),
                                if (link.selected) ...[
                                  const SizedBox(width: 12),
                                  Icon(
                                    Icons.check_rounded,
                                    size: 18,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary,
                                  ),
                                ],
                              ],
                            ),
                          ),
                      ],
                      child: Chip(
                        label: Text(group.label.isEmpty ? '分类导航' : group.label),
                        avatar: const Icon(Icons.expand_more_rounded, size: 18),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        if (doc.directory) _directoryTools(),
      ],
    ],
  );

  Widget _directoryTools() {
    final filtered = _filtered;
    final active =
        selected.values.where((v) => v.isNotEmpty).length +
        [minMemory, minTraffic, minPrice, maxPrice].whereType<double>().length;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: PopupMenuButton<String>(
                    tooltip: '排序',
                    initialValue: sort,
                    onSelected: (v) => setState(() => sort = v),
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'original',
                        child: Text('网站顺序'),
                      ),
                      const PopupMenuItem(value: 'name', child: Text('按名称')),
                      if (items.any((i) => i.price != null)) ...const [
                        PopupMenuItem(value: 'price', child: Text('人民币报价从低到高')),
                        PopupMenuItem(
                          value: 'priceDesc',
                          child: Text('人民币报价从高到低'),
                        ),
                      ],
                      if (items.any((i) => i.memory != null))
                        const PopupMenuItem(
                          value: 'memory',
                          child: Text('内存从高到低'),
                        ),
                      if (items.any((i) => i.stars != null))
                        const PopupMenuItem(
                          value: 'stars',
                          child: Text('GitHub Star'),
                        ),
                    ],
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.sort_rounded, size: 18),
                          SizedBox(width: 6),
                          Text('排序'),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${filtered.length} / ${items.length} 条 · ${allLoaded ? '全部已载入' : '已载入 $collectedPages 页'}',
                  textAlign: TextAlign.end,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              const SizedBox(width: 10),
              IconButton(
                tooltip: listMode ? '网格查看' : '列表查看',
                onPressed: () => setState(() => listMode = !listMode),
                icon: Icon(
                  listMode ? Icons.grid_view_rounded : Icons.view_list_rounded,
                  size: 20,
                ),
              ),
            ],
          ),
          Wrap(
            spacing: 10,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton.icon(
                onPressed: _filters,
                icon: const Icon(Icons.filter_list_rounded, size: 18),
                label: Text(active == 0 ? '筛选' : '筛选 $active'),
              ),
              if (!allLoaded)
                TextButton.icon(
                  onPressed: collecting
                      ? () => setState(() {
                          generation++;
                          collecting = false;
                          loadMessage = '已停止加载，保留已载入的条目。';
                        })
                      : _collectPages,
                  icon: Icon(
                    collecting
                        ? Icons.stop_circle_outlined
                        : Icons.download_rounded,
                    size: 17,
                  ),
                  label: Text(collecting ? '停止加载' : '载入全部页'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  List<SiteItem> get _filtered => SiteQuery(
    text: query,
    facets: selected,
    sort: sort,
    minimumMemory: minMemory,
    minimumTraffic: minTraffic,
    minimumPrice: minPrice,
    maximumPrice: maxPrice,
  ).apply(items);

  Future<void> _filters() async {
    final draftSelected = Map<String, String>.of(selected);
    var draftMemory = minMemory, draftTraffic = minTraffic;
    var draftMinPrice = minPrice, draftMaxPrice = maxPrice;
    var resetVersion = 0;
    final available = <String, Set<String>>{};
    for (final item in items) {
      for (final entry in item.facets.entries) {
        available.putIfAbsent(entry.key, () => {}).addAll(entry.value);
      }
    }
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, update) {
          void change(VoidCallback action) => update(action);

          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .8,
              ),
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.all(24),
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '筛选已载入的条目',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      TextButton(
                        onPressed: () => change(() {
                          resetVersion++;
                          draftSelected.clear();
                          draftMemory = null;
                          draftTraffic = null;
                          draftMinPrice = null;
                          draftMaxPrice = null;
                        }),
                        child: const Text('重置'),
                      ),
                    ],
                  ),
                  for (final entry in available.entries) ...[
                    Padding(
                      padding: const EdgeInsets.only(top: 16, bottom: 8),
                      child: Text(entry.key),
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ChoiceChip(
                          label: const Text('全部'),
                          selected: (draftSelected[entry.key] ?? '').isEmpty,
                          onSelected: (_) =>
                              change(() => draftSelected.remove(entry.key)),
                        ),
                        for (final value in entry.value)
                          ChoiceChip(
                            label: Text(value),
                            selected: draftSelected[entry.key] == value,
                            onSelected: (_) =>
                                change(() => draftSelected[entry.key] = value),
                          ),
                      ],
                    ),
                  ],
                  if (items.any((i) => i.memory != null)) ...[
                    const Padding(
                      padding: EdgeInsets.only(top: 20, bottom: 8),
                      child: Text('最低内存'),
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final n in [null, 1.0, 2.0, 4.0, 8.0, 16.0])
                          ChoiceChip(
                            label: Text(n == null ? '不限' : '${n.toInt()} GB'),
                            selected: draftMemory == n,
                            onSelected: (_) => change(() => draftMemory = n),
                          ),
                      ],
                    ),
                  ],
                  if (items.any((i) => i.traffic != null)) ...[
                    const Padding(
                      padding: EdgeInsets.only(top: 20, bottom: 8),
                      child: Text('明确月流量下限'),
                    ),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final n in [null, 100.0, 200.0, 500.0, 1000.0])
                          ChoiceChip(
                            label: Text(
                              n == null ? '不限' : '${n.toInt()} GB / 月',
                            ),
                            selected: draftTraffic == n,
                            onSelected: (_) => change(() => draftTraffic = n),
                          ),
                      ],
                    ),
                  ],
                  if (items.any((i) => i.price != null)) ...[
                    const Padding(
                      padding: EdgeInsets.only(top: 20, bottom: 8),
                      child: Text('人民币付款金额区间'),
                    ),
                    Row(
                      children: [
                        for (final lower in [true, false])
                          Expanded(
                            child: Padding(
                              padding: EdgeInsets.only(right: lower ? 12 : 0),
                              child: TextFormField(
                                key: ValueKey((lower, resetVersion)),
                                initialValue:
                                    (lower ? draftMinPrice : draftMaxPrice)
                                        ?.toString() ??
                                    '',
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                decoration: InputDecoration(
                                  labelText: lower ? '下限（不含）' : '上限（含）',
                                ),
                                onChanged: (value) {
                                  final number = double.tryParse(value);
                                  change(() {
                                    final valid =
                                        number != null &&
                                            number.isFinite &&
                                            number >= 0
                                        ? number
                                        : null;
                                    if (lower) {
                                      draftMinPrice = valid;
                                    } else {
                                      draftMaxPrice = valid;
                                    }
                                  });
                                },
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 24),
                  DialogActionsRow(
                    confirmLabel: '确认',
                    onCancel: () => Navigator.pop(sheetContext, false),
                    onConfirm: () => Navigator.pop(sheetContext, true),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      selected
        ..clear()
        ..addAll(draftSelected);
      minMemory = draftMemory;
      minTraffic = draftTraffic;
      minPrice = draftMinPrice;
      maxPrice = draftMaxPrice;
    });
  }

  List<Widget> _directory(SiteDocument doc, double width, double inset) {
    final data = _filtered;
    final columns = listMode ? 1 : (width / 360).floor().clamp(1, 3);
    final rows = (data.length / columns).ceil();
    return [
      if (data.isEmpty)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(28),
            child: Text('没有匹配的条目。可以调整筛选，或载入其他页。'),
          ),
        ),
      SliverPadding(
        padding: EdgeInsets.symmetric(horizontal: inset, vertical: 10),
        sliver: SliverList.builder(
          itemCount: rows,
          itemBuilder: (context, index) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var col = 0; col < columns; col++) ...[
                    if (col > 0) const SizedBox(width: 12),
                    Expanded(
                      child: index * columns + col < data.length
                          ? _card(data[index * columns + col])
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
      if (!allLoaded && doc.pagination.isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final link in doc.pagination)
                  OutlinedButton(
                    onPressed: () => _open(link.url),
                    child: Text(link.label),
                  ),
              ],
            ),
          ),
        ),
      if (doc.blocks.isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: ExpansionTile(
              title: Text(
                Uri.parse(doc.url).path == '/protocols'
                    ? '协议推荐、评分与使用条件'
                    : '栏目说明与参考',
              ),
              initiallyExpanded: Uri.parse(doc.url).path == '/protocols',
              children: [SelectionArea(child: _blocks(doc.blocks))],
            ),
          ),
        ),
      SliverToBoxAdapter(child: _footer()),
    ];
  }

  Widget _card(SiteItem item) => Card(
    margin: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: () => _open(item.url),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (item.image != null) ...[
                  ClipPath.shape(
                    shape: surfaceShape(12),
                    child: ContentImage(
                      imageUrl: item.image!,
                      width: 44,
                      height: 44,
                      fit: BoxFit.cover,
                      errorWidget: (_, _, _) =>
                          Icon(siteIcon(Uri.parse(item.url).path)),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Text(
                    item.title,
                    style: Theme.of(context).textTheme.titleMedium,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(Icons.chevron_right_rounded, size: 18),
              ],
            ),
            if (item.subtitle.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  item.subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (item.summary.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  item.summary,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(height: 1.6, fontSize: 13),
                ),
              ),
            if (item.facts.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Wrap(
                  spacing: 14,
                  runSpacing: 8,
                  children: [
                    for (final fact in item.facts.entries.take(7))
                      Text(
                        '${fact.key}  ${fact.value}',
                        style: const TextStyle(fontSize: 12),
                      ),
                  ],
                ),
              ),
            if (item.badges.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final badge in item.badges.take(6)) Pill(badge),
                  ],
                ),
              ),
            if (item.actions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final action in item.actions.take(3))
                      TextButton(
                        onPressed: () => _open(action.url),
                        child: Text(
                          action.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    ),
  );

  List<Widget> _reader(
    SiteDocument doc,
    double inset, {
    bool compactService = false,
  }) {
    if (query.trim().isNotEmpty) {
      final results = _walk(doc.blocks)
          .where(
            (b) =>
                b.ownText.isNotEmpty &&
                b.ownText.toLowerCase().contains(query.trim().toLowerCase()),
          )
          .toList();
      return [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(inset, 12, inset, 20),
          sliver: SliverList.list(
            children: [
              Text('${results.length} 处匹配'),
              for (final block in results)
                ListTile(
                  title: Text(
                    block.ownText,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.arrow_forward_rounded, size: 18),
                  onTap: () => _jump(block),
                ),
            ],
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: EdgeInsets.fromLTRB(
          inset,
          doc.service == null ? 12 : 0,
          inset,
          doc.service == null ? 20 : 40,
        ),
        sliver: SliverToBoxAdapter(
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: doc.service == null ? 1000 : 1120,
              ),
              child: SelectionArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (doc.service case final service?)
                      _serviceContent(doc, service, compact: compactService)
                    else if (doc.reading case final reading?) ...[
                      Padding(
                        key: anchors.putIfAbsent(
                          reading.overview,
                          GlobalKey.new,
                        ),
                        padding: const EdgeInsets.only(bottom: 28),
                        child: _readingHero(reading),
                      ),
                      if (reading.kind == SiteReadingKind.history)
                        _timelineTools(doc),
                      _blocks(
                        doc.blocks
                            .where((block) => block != reading.overview)
                            .toList(),
                        flat: true,
                      ),
                    ] else
                      _blocks(doc.blocks),
                    if (Uri.parse(doc.url).path.startsWith('/people/'))
                      OutlinedButton.icon(
                        onPressed: () => openLink(
                          context,
                          '${doc.url.split('#').first}#salute',
                        ),
                        icon: const Icon(Icons.favorite_outline_rounded),
                        label: const Text('在网站致敬作者'),
                      ),
                    _footer(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ];
  }

  Widget _serviceContent(
    SiteDocument doc,
    SiteServiceDetails service, {
    required bool compact,
  }) {
    final overview = ServiceDetailOverview(detail: service);
    final blocks = doc.blocks
        .where((block) => block != service.overview)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ServiceDetailHero(
          key: anchors.putIfAbsent(service.overview, GlobalKey.new),
          detail: service,
          compact: compact,
          onOpen: _open,
        ),
        SizedBox(height: compact ? 20 : 26),
        if (service.highlights.isNotEmpty) ...[
          DetailMetadata(values: service.highlights, compact: compact),
          SizedBox(height: compact ? 12 : 24),
        ],
        if (overview.hasContent) ...[
          overview,
          if (blocks.isNotEmpty) const DetailSectionDivider(),
        ],
        _blocks(blocks, flat: true, appDetailStyle: true),
      ],
    );
  }

  Widget _blocks(
    List<SiteBlock> blocks, {
    bool flat = false,
    bool appDetailStyle = false,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final (index, block) in blocks.indexed)
        SiteBlockView(
          block: block,
          onLink: _open,
          anchors: anchors,
          expanded: expanded,
          onExpansion: (block, value) => setState(() {
            value ? expanded.add(block) : expanded.remove(block);
          }),
          flat: flat,
          appDetailStyle: appDetailStyle,
          sectionDivider: index > 0,
          timelineDescending: timelineDescending,
          imageGallery: _walk(document?.blocks ?? [])
              .where((block) => block.kind == BlockKind.image)
              .toList(),
        ),
    ],
  );

  Widget _readingHero(SiteReadingDetails reading) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          reading.eyebrow,
          style: theme.textTheme.labelLarge?.copyWith(color: colors.primary),
        ),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (reading.image != null ||
                reading.kind == SiteReadingKind.person) ...[
              ReadingAvatar(url: reading.image, kind: reading.kind, size: 64),
              const SizedBox(width: 18),
            ],
            Expanded(
              child: Text(
                reading.title,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
        if (reading.metadata.isNotEmpty) ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 18,
            runSpacing: 8,
            children: [
              for (final value in reading.metadata)
                Text(
                  value,
                  style: theme.textTheme.bodySmall?.copyWith(
                    height: 1.6,
                    color: colors.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ],
        if (reading.summary.isNotEmpty) ...[
          const SizedBox(height: 22),
          SiteRichText(
            reading.summary,
            onLink: _open,
            style: theme.textTheme.bodyLarge?.copyWith(
              height: 1.9,
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
        if (reading.actions.isNotEmpty) ...[
          const SizedBox(height: 18),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final link in reading.actions)
                TextButton.icon(
                  onPressed: () => _open(link.url),
                  icon: Icon(
                    SiteRoutes.isNative(Uri.parse(link.url))
                        ? Icons.arrow_forward_rounded
                        : Icons.north_east_rounded,
                    size: 16,
                  ),
                  label: Text(link.label),
                ),
            ],
          ),
        ],
        const SizedBox(height: 20),
        Divider(color: colors.outlineVariant.withValues(alpha: .5)),
      ],
    );
  }

  Widget _timelineTools(SiteDocument doc) {
    final events = _walk(doc.blocks)
        .where((block) => block.kind == BlockKind.event)
        .length;
    final years = _walk(doc.blocks)
        .where(
          (block) =>
              block.id?.startsWith('history-year-') == true &&
              block.kind == BlockKind.panel,
        )
        .toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Row(
        children: [
          Expanded(
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                CatalogMenu<bool>(
                  label: timelineDescending ? '最新优先' : '从起源阅读',
                  tooltip: '时间阅读顺序',
                  selected: timelineDescending,
                  values: const [false, true],
                  labelFor: (value) => value ? '最新优先' : '从起源阅读',
                  onSelected: (value) =>
                      setState(() => timelineDescending = value),
                  icon: Icons.sort_rounded,
                ),
                if (years.isNotEmpty)
                  CatalogMenu<SiteBlock?>(
                    label: '跳至年份',
                    tooltip: '跳至年份',
                    selected: null,
                    values: years,
                    labelFor: (block) =>
                        block?.id?.replaceFirst('history-year-', '') ?? '',
                    onSelected: (block) {
                      if (block != null) _jump(block);
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '$events 个历史节点',
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _footer() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
    child: Text(
      'huarun.win · ${snapshot!.at.toLocal().toString().substring(0, 16)}${snapshot!.cached ? ' · 已缓存' : ''}',
      style: Theme.of(context).textTheme.bodySmall,
    ),
  );
}
