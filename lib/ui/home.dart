import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/catalog_filters.dart';
import '../data/site_parser.dart';
import '../services/app_controller.dart';
import '../services/app_library.dart';
import '../services/download_platform.dart';
import '../services/downloads.dart';
import 'components.dart';
import 'catalog_controls.dart';
import 'detail.dart';
import 'app_library_page.dart';
import 'settings.dart';
import 'theme.dart';
import 'app_download_button.dart';
import 'mac_window.dart';
import 'site_page.dart';
import 'sidebar.dart';
import 'compact_navigation.dart';
import 'page_components.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.controller,
    required this.downloads,
    this.libraryRequests,
  });
  final AppController controller;
  final DownloadManager downloads;
  final Listenable? libraryRequests;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int section = 0;
  String sitePath = '/vps';
  String query = '', source = '全部';
  String core = '全部', price = '全部';
  ApplicationType? applicationType;
  bool get _searchesAllApplications =>
      applicationType == null && query.trim().isNotEmpty;
  bool get _usesClientFilters =>
      !_searchesAllApplications &&
      (applicationType == null || applicationType == ApplicationType.client);
  CatalogDevice? get device => _usesClientFilters
      ? CatalogDevice.fromLabel(widget.controller.catalogPlatform)
      : null;
  String get platform => _usesClientFilters && device == null
      ? widget.controller.catalogPlatform
      : '全部';
  CatalogSort sort = CatalogSort.comprehensive;
  CatalogStarPeriod starPeriod = CatalogStarPeriod.week;
  CatalogStarMetric starMetric = CatalogStarMetric.count;
  String get _sortNotice => sort == CatalogSort.stars
      ? catalogStarNotice(period: starPeriod, metric: starMetric)
      : sort.notice;
  String? _expandedSidebarGroup = 'applications';
  late bool _sidebarExpanded;
  int _mobileTab = 0;
  final _visitedMobileTabs = <int>{0};
  String _historyPath = '/people';
  bool _libraryVisited = false;
  LibrarySection _librarySection = LibrarySection.all;
  int _librarySelectionRevision = 0;
  static const _mobilePaths = ['/', '/vps', '/jichang', '/feed', '/people'];
  static const _historySections = {
    '/people': '人物',
    '/history/protocols': '协议',
    '/history/cores': '内核',
    '/history/apps': '应用',
    '/articles': '文章',
  };
  bool get _isMobileContent =>
      section == 0 ||
      section == 5 &&
          (_mobilePaths.contains(sitePath) ||
              _historySections.containsKey(sitePath));
  bool get _usesMobileTabs {
    final width = MediaQuery.sizeOf(context).width;
    return width < 900 &&
        (defaultTargetPlatform != TargetPlatform.iOS ||
            width < compactLayoutBreakpoint);
  }

  int _filterRun = 0;
  late int _sourceRevision;
  bool _sourceNeedsMetadata = false;
  final search = TextEditingController();
  @override
  void initState() {
    super.initState();
    _sourceRevision = widget.controller.sources.revision;
    widget.controller.addListener(_contentChanged);
    _sidebarExpanded =
        widget.controller.preferences.getBool('sidebarExpanded') ?? true;
    widget.libraryRequests?.addListener(_showDownloads);
    if (device != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_loadMetadata());
      });
    }
  }

  void _contentChanged() {
    if (!mounted) return;
    final controller = widget.controller;
    if (_sourceRevision != controller.sources.revision) {
      _sourceRevision = controller.sources.revision;
      _filterRun++;
      _sourceNeedsMetadata = true;
    }
    if (_sourceNeedsMetadata &&
        !controller.loading &&
        controller.snapshot != null) {
      _sourceNeedsMetadata = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_loadMetadata(refreshScopes: true));
      });
    }
  }

  @override
  void didUpdateWidget(covariant HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.libraryRequests != widget.libraryRequests) {
      oldWidget.libraryRequests?.removeListener(_showDownloads);
      widget.libraryRequests?.addListener(_showDownloads);
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_contentChanged);
      widget.controller.addListener(_contentChanged);
      _contentChanged();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_contentChanged);
    widget.libraryRequests?.removeListener(_showDownloads);
    widget.controller.stopDateLoading();
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.controller, widget.downloads]),
    builder: (context, _) {
      final desktop = MediaQuery.sizeOf(context).width >= 900;
      final mobileTabs = _usesMobileTabs;
      final floatingDock =
          mobileTabs &&
          usesMobileDesign(context) &&
          MediaQuery.viewInsetsOf(context).bottom == 0;
      return Scaffold(
        extendBody: floatingDock,
        body: PageBottomInset(
          inset: floatingDock ? CompactNavigation.insetOf(context) : 0,
          child: MediaQuery.removePadding(
            context: context,
            removeTop: hasMacWindowControls && desktop,
            removeBottom: floatingDock,
            child: PageSafeArea(
              bottom: !floatingDock,
              child: Row(
                children: [
                  if (desktop) _sidebar(context),
                  Expanded(
                    child: Builder(
                      builder: (context) => _contentPages(
                        context,
                        desktop,
                        mobileTabs: mobileTabs,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        bottomNavigationBar:
            desktop || MediaQuery.viewInsetsOf(context).bottom > 0
            ? null
            : mobileTabs
            ? CompactNavigation(
                selectedIndex: switch (section) {
                  2 => 1,
                  3 => 4,
                  _ => switch (_mobileTab) {
                    1 => 2,
                    2 => 3,
                    _ => 0,
                  },
                },
                onSelected: _selectMobileTab,
                destinations: [
                  const NavigationDestination(
                    icon: Icon(Icons.grid_view_rounded),
                    label: '发现',
                  ),
                  _libraryDestination(),
                  const NavigationDestination(
                    icon: Icon(Icons.cloud_rounded),
                    label: 'VPS',
                  ),
                  const NavigationDestination(
                    icon: Icon(Icons.flight_rounded),
                    label: '机场',
                  ),
                  const NavigationDestination(
                    icon: Icon(Icons.tune_rounded),
                    label: '设置',
                  ),
                ],
              )
            : CompactNavigation(
                selectedIndex: switch (section) {
                  2 => 1,
                  3 => 2,
                  _ => 0,
                },
                onSelected: (index) {
                  if (index == 1) {
                    _selectLibrary();
                  } else {
                    _changeFilters(() => section = index == 0 ? 0 : 3);
                  }
                },
                destinations: [
                  const NavigationDestination(
                    icon: Icon(Icons.grid_view_rounded),
                    label: '发现',
                  ),
                  _libraryDestination(),
                  const NavigationDestination(
                    icon: Icon(Icons.tune_rounded),
                    label: '设置',
                  ),
                ],
              ),
      );
    },
  );

  // Keep the same page tree across navigation layouts so resizing does not
  // discard a directory's search, filters, loaded pages or scroll position.
  Widget _contentPages(
    BuildContext context,
    bool desktop, {
    required bool mobileTabs,
  }) {
    final libraryIndex = _mobilePaths.length;
    final secondaryIndex = libraryIndex + 1;
    final activeIndex = section == 2
        ? libraryIndex
        : _isMobileContent
        ? _mobileTab
        : secondaryIndex;
    return IndexedStack(
      index: activeIndex,
      sizing: StackFit.expand,
      children: [
        for (var index = 0; index <= secondaryIndex; index++)
          TickerMode(
            enabled: index == activeIndex,
            child: ExcludeFocus(
              excluding: index != activeIndex,
              child: PrimaryScrollController.none(
                child: index == libraryIndex
                    ? _libraryVisited
                          ? AppLibraryPage(
                              controller: widget.controller,
                              manager: widget.downloads,
                              active: index == activeIndex,
                              initialSection: _librarySection,
                              selectionRevision: _librarySelectionRevision,
                            )
                          : const SizedBox.shrink()
                    : index == secondaryIndex
                    ? _secondaryPage()
                    : !_visitedMobileTabs.contains(index)
                    ? const SizedBox.shrink()
                    : index == 0
                    ? _catalog(context, desktop)
                    : SitePage(
                        key: ValueKey(
                          index == 4 ? _historyPath : _mobilePaths[index],
                        ),
                        url:
                            '${SiteRoutes.origin}${index == 4 ? _historyPath : _mobilePaths[index]}',
                        embedded: true,
                        active: index == activeIndex,
                        controller: widget.controller,
                        downloads: widget.downloads,
                        sectionNavigation: mobileTabs && index == 4
                            ? _historyNavigation()
                            : null,
                      ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _secondaryPage() => switch (section) {
    3 => SettingsPage(
      controller: widget.controller,
      downloads: widget.downloads,
    ),
    5 when !_isMobileContent => SitePage(
      key: ValueKey(sitePath),
      url: '${SiteRoutes.origin}$sitePath',
      embedded: true,
      active: true,
      controller: widget.controller,
      downloads: widget.downloads,
    ),
    _ => const SizedBox.shrink(),
  };

  void _selectMobileTab(int index) {
    if (index == 1) {
      _selectLibrary();
      return;
    }
    final contentIndex = index > 1 ? index - 1 : 0;
    if (index == 4
        ? section == 3
        : contentIndex == _mobileTab && _isMobileContent) {
      return;
    }
    FocusScope.of(context).unfocus();
    _changeFilters(() {
      if (index == 4) {
        section = 3;
        return;
      }
      _mobileTab = contentIndex;
      _visitedMobileTabs.add(contentIndex);
      section = contentIndex == 0 ? 0 : 5;
      if (contentIndex != 0) {
        sitePath = _mobilePaths[contentIndex];
      }
    });
  }

  Widget _historyNavigation() => Semantics(
    container: true,
    label: '纪事分区',
    child: SingleChildScrollView(
      key: const PageStorageKey('android-history-section-scroll'),
      scrollDirection: Axis.horizontal,
      child: Row(
        spacing: 8,
        children: [
          for (final entry in _historySections.entries)
            Semantics(
              selected: entry.key == _historyPath,
              child: TextButton(
                key: ValueKey('history-section-${entry.key}'),
                style: TextButton.styleFrom(
                  backgroundColor: entry.key == _historyPath
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.surfaceContainer,
                  foregroundColor: entry.key == _historyPath
                      ? Theme.of(context).colorScheme.onPrimary
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                  shape: surfaceShape(1000),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  minimumSize: const Size(0, 40),
                ),
                onPressed: () {
                  if (entry.key == _historyPath) return;
                  _changeFilters(() {
                    _historyPath = sitePath = entry.key;
                  });
                },
                child: Text(entry.value),
              ),
            ),
        ],
      ),
    ),
  );

  int get _activeDownloads =>
      widget.downloads.tasks.where((task) => task.busy).length;

  NavigationDestination _libraryDestination() => NavigationDestination(
    icon: Badge.count(
      count: _activeDownloads,
      isLabelVisible: _activeDownloads > 0,
      child: const Icon(Icons.inventory_2_outlined),
    ),
    label: '应用库',
  );

  void _selectLibrary({LibrarySection? filter}) {
    FocusScope.of(context).unfocus();
    _changeFilters(() {
      section = 2;
      _libraryVisited = true;
      if (filter != null) {
        _librarySection = filter;
        _librarySelectionRevision++;
      }
    });
  }

  void _showDownloads() => _selectLibrary(filter: LibrarySection.downloads);

  void _toggleSidebar() {
    setState(() => _sidebarExpanded = !_sidebarExpanded);
    unawaited(
      widget.controller.preferences.setBool(
        'sidebarExpanded',
        _sidebarExpanded,
      ),
    );
  }

  Widget _sidebar(BuildContext context) => AppSidebar(
    key: const ValueKey('desktop-sidebar'),
    expanded: _sidebarExpanded,
    onToggle: _toggleSidebar,
    entries: [
      _navGroup(
        id: 'applications',
        title: '发现',
        icon: Icons.grid_view_rounded,
        active: section == 0,
        onSelectFirst: () => _selectApplicationType(null),
        children: [
          _nav(
            '全部',
            Icons.apps_rounded,
            section == 0 && applicationType == null,
            () => _selectApplicationType(null),
            key: const ValueKey('nav-applications'),
            nested: true,
          ),
          for (final type in ApplicationType.values)
            _nav(
              type.label,
              switch (type) {
                ApplicationType.client => Icons.devices_rounded,
                ApplicationType.server => Icons.dns_outlined,
                ApplicationType.subscriptionTool =>
                  Icons.subscriptions_outlined,
                ApplicationType.ruleConfig => Icons.rule_rounded,
              },
              section == 0 && applicationType == type,
              () => _selectApplicationType(type),
              key: ValueKey('nav-type-${type.value}'),
              nested: true,
            ),
        ],
      ),
      const SizedBox(height: 12),
      _nav(
        '应用库',
        Icons.inventory_2_outlined,
        section == 2,
        _selectLibrary,
        key: const ValueKey('nav-library'),
        count: _activeDownloads,
      ),
      _siteNav('/vps'),
      _siteNav('/jichang'),
    ],
    footer: [
      _nav(
        '偏好设置',
        Icons.tune_rounded,
        section == 3,
        () => _changeFilters(() => section = 3),
      ),
      _nav(
        '访问 huarun.win',
        Icons.north_east_rounded,
        false,
        () => openLink(context, 'https://huarun.win/'),
      ),
    ],
  );

  Widget _siteNav(String path, {bool nested = false}) => _nav(
    SiteRoutes.sections[path]!,
    siteIcon(path),
    section == 5 && sitePath == path,
    () => _selectSitePath(path),
    key: ValueKey('nav-site-$path'),
    nested: nested,
  );

  Widget _navGroup({
    required String id,
    required String title,
    required IconData icon,
    required bool active,
    required VoidCallback onSelectFirst,
    required List<Widget> children,
  }) {
    final expanded = _sidebarExpanded && _expandedSidebarGroup == id;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _nav(
          title,
          icon,
          active && !expanded,
          () {
            setState(() {
              _sidebarExpanded = true;
              _expandedSidebarGroup = expanded ? null : id;
            });
            if (!expanded && !active) onSelectFirst();
            unawaited(
              widget.controller.preferences.setBool('sidebarExpanded', true),
            );
          },
          key: ValueKey('nav-group-$id'),
          expanded: expanded,
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: expanded
              ? Column(mainAxisSize: MainAxisSize.min, children: children)
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _nav(
    String title,
    IconData icon,
    bool selected,
    VoidCallback tap, {
    Key? key,
    bool nested = false,
    bool? expanded,
    int count = 0,
  }) => Semantics(
    key: key,
    container: true,
    selected: selected,
    expanded: expanded,
    button: true,
    child: SidebarItem(
      title: title,
      icon: icon,
      selected: selected,
      onTap: tap,
      nested: nested,
      count: count,
    ),
  );

  Widget _catalog(BuildContext context, bool desktop) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    final currentPlatform = runningDownloadPlatform;
    final platformOptions = List.of(catalogPlatforms);
    if (currentPlatform != null && platformOptions.remove(currentPlatform)) {
      platformOptions.insert(1, currentPlatform);
    }
    final inlineFilters = useInlineCatalogFilters(context, wide: desktop);
    final clientFilters = _usesClientFilters;
    final selectedCore = clientFilters ? core : '全部';
    final hasFilters =
        (!desktop && applicationType != null) ||
        (clientFilters &&
            (device != null ||
                platform != '全部' ||
                core != '全部' ||
                source != '全部' ||
                price != '全部')) ||
        query.isNotEmpty;
    final controller = widget.controller;
    final all = controller.snapshot?.apps ?? [];
    final filtered = _matchingApps();
    final useGrid = !compact && (controller.catalogGrid ?? desktop);
    final corePending =
        selectedCore != '全部' &&
        !controller.coreCatalogs.containsKey(selectedCore);
    final devicePending =
        device != null && !controller.deviceCatalogs.containsKey(device);
    final scopeLoading =
        controller.loadingCores.contains(selectedCore) ||
        controller.loadingDevices.contains(device);
    final scopeWarning =
        controller.deviceCatalogs[device]?.warning ??
        controller.coreCatalogs[selectedCore]?.warning;
    final scopeError =
        controller.deviceErrors[device] ?? controller.coreErrors[selectedCore];
    final title = compact ? '发现' : applicationType?.label ?? '发现';
    final padding = compact ? 16.0 : 32.0;
    final filters = CatalogFilterControls(
      inline: inlineFilters,
      compact: compact,
      showType: !desktop,
      showClientFilters: clientFilters,
      onReset: !compact && !desktop && hasFilters ? _resetFilters : null,
      type: applicationType,
      platform: device?.label ?? platform,
      platforms: platformOptions,
      core: selectedCore,
      source: clientFilters ? source : '全部',
      price: clientFilters ? price : '全部',
      onPlatformChanged: (value) =>
          _changeFilters(() => controller.selectCatalogPlatform(value)),
      onChanged: (nextType, nextCore, nextSource, nextPrice) =>
          _changeFilters(() {
            if (applicationType != nextType) {
              if (nextType == null) {
                controller.restoreCatalogPlatform();
              } else {
                controller.clearCatalogPlatform();
              }
            }
            applicationType = nextType;
            core = nextCore;
            source = nextSource;
            price = nextPrice;
          }),
    );
    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            padding,
            (compact ? 16 : 34) + PageSafeArea.topInsetOf(context),
            padding,
            16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PageHeader(
                title: title,
                titleStyle: Theme.of(context).textTheme.headlineMedium,
                actions: [
                  RefreshIconButton(
                    tooltip: '刷新目录',
                    loading: controller.loading || scopeLoading,
                    onPressed: _refresh,
                  ),
                ],
              ),
              CatalogSearchPanel(
                grouped: !compact,
                builder: (context) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    CatalogSearchField(
                      controller: search,
                      compact: compact,
                      hintText: applicationType != null
                          ? '搜索${applicationType!.label}'
                          : compact
                          ? '搜索应用、工具或规则'
                          : '搜索客户端、服务端、订阅工具、规则与配置',
                      onChanged: (value) => _changeFilters(() => query = value),
                    ),
                    const SizedBox(height: 12),
                    if (compact)
                      CompactCatalogFilters(
                        type: applicationType,
                        showClientFilters: clientFilters,
                        platform: device?.label ?? platform,
                        platforms: platformOptions,
                        core: selectedCore,
                        source: clientFilters ? source : '全部',
                        price: clientFilters ? price : '全部',
                        onPlatformChanged: (value) => _changeFilters(
                          () => controller.selectCatalogPlatform(value),
                        ),
                        onChanged: filters.onChanged,
                      ),
                    if (!compact && (!desktop || clientFilters)) ...[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: filters),
                          if (desktop && hasFilters)
                            TextButton(
                              onPressed: () => _resetFilters(clearType: false),
                              child: const Text('重置筛选'),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                    ],
                  ],
                ),
              ),
              if (usesMobileDesign(context)) const SizedBox(height: 12),
              _resultToolbar(filtered.length, useGrid),
              if (scopeWarning != null)
                Text(
                  scopeWarning,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (scopeError != null)
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        scopeError,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    TextButton(
                      onPressed: () => _loadMetadata(refreshScopes: true),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              if (sort == CatalogSort.updated) _dateLoading(),
            ],
          ),
        ),
        if (controller.snapshot?.warning != null ||
            (controller.error != null && all.isNotEmpty))
          Padding(
            padding: EdgeInsets.fromLTRB(padding, 0, padding, 8),
            child: Text(
              controller.snapshot?.warning ?? controller.error!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ),
      ],
    );
    return RefreshIndicator(
      edgeOffset: PageSafeArea.topInsetOf(context),
      onRefresh: _refresh,
      child: CustomScrollView(
        key: PageStorageKey(
          'catalog-$applicationType-${controller.catalogPlatform}',
        ),
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: header),
          if (filtered.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child:
                  (controller.loading && all.isEmpty) ||
                      ((corePending || devicePending) && scopeLoading)
                  ? const Center(child: CircularProgressIndicator())
                  : controller.error != null && all.isEmpty
                  ? EmptyState(
                      icon: Icons.cloud_off_rounded,
                      title: '暂时无法连接',
                      message: controller.error!,
                      action: FilledButton(
                        onPressed: () => controller.load(refresh: true),
                        child: const Text('重新加载'),
                      ),
                    )
                  : sort == CatalogSort.stars &&
                        _matchingApps(unsorted: true).isNotEmpty
                  ? EmptyState(
                      icon: Icons.bar_chart_rounded,
                      title: '暂无所选周期的开源统计',
                      message:
                          '当前筛选范围没有可用的${starPeriod.label}新增 Star${starMetric == CatalogStarMetric.share ? '比例' : '数'}，可选择其他周期或切换排序。',
                      action: TextButton(
                        onPressed: () => _changeFilters(
                          () => sort = CatalogSort.comprehensive,
                        ),
                        child: const Text('切回综合'),
                      ),
                    )
                  : EmptyState(
                      icon: Icons.search_off_rounded,
                      title: '没有找到匹配的应用',
                      message: '试试其他关键词，或调整筛选条件。',
                      action: TextButton(
                        onPressed: () => _resetFilters(clearType: !desktop),
                        child: const Text('清除筛选'),
                      ),
                    ),
            )
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                padding,
                0,
                padding,
                28 + PageBottomInset.of(context),
              ),
              sliver: SliverLayoutBuilder(
                builder: (context, constraints) {
                  if (!desktop) {
                    return SliverList.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) => usesMobileDesign(context)
                          ? _mobileAppItem(filtered[index], expanded: useGrid)
                          : useGrid
                          ? _appCard(filtered[index], bounded: false)
                          : _compactAppItem(filtered[index]),
                    );
                  }
                  return SliverGrid(
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: useGrid
                          ? (constraints.crossAxisExtent / 290).floor().clamp(
                              2,
                              5,
                            )
                          : 1,
                      mainAxisExtent: useGrid ? 266 : 150,
                      mainAxisSpacing: 14,
                      crossAxisSpacing: 14,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) => useGrid
                          ? _appCard(filtered[index])
                          : _appListItem(filtered[index]),
                      childCount: filtered.length,
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  List<CatalogApp> _matchingApps({bool unsorted = false}) {
    final controller = widget.controller;
    return filterCatalog(
      controller.snapshot?.apps ?? [],
      type: applicationType,
      platform: platform,
      source: _usesClientFilters ? source : '全部',
      price: _usesClientFilters ? price : '全部',
      query: query,
      coreIds: !_usesClientFilters || core == '全部'
          ? null
          : controller.coreCatalogs[core]?.apps.map((app) => app.key).toSet() ??
                <String>{},
      deviceIds: device == null
          ? null
          : controller.deviceCatalogs[device]?.apps
                    .map((app) => app.key)
                    .toSet() ??
                <String>{},
      sort: unsorted ? CatalogSort.comprehensive : sort,
      starPeriod: starPeriod,
      starMetric: starMetric,
      updateDates: controller.updateDates,
    );
  }

  void _changeFilters(VoidCallback change) {
    _filterRun++;
    widget.controller.stopDateLoading();
    setState(() {
      change();
      if (section == 0) _mobileTab = 0;
    });
    if (section == 0) unawaited(_loadMetadata());
  }

  void _selectApplicationType(ApplicationType? type) {
    _changeFilters(() {
      section = 0;
      _mobileTab = 0;
      if (applicationType != type) {
        applicationType = type;
        core = source = price = '全部';
        if (type == null) {
          widget.controller.restoreCatalogPlatform();
        } else {
          widget.controller.clearCatalogPlatform();
        }
      }
    });
  }

  void _selectSitePath(String path) {
    _changeFilters(() {
      sitePath = path;
      section = 5;
      final index = _mobilePaths.indexOf(path);
      if (index > 0 || _historySections.containsKey(path)) {
        _mobileTab = index > 0 ? index : 4;
        _visitedMobileTabs.add(_mobileTab);
        if (_mobileTab == 4) _historyPath = path;
      }
    });
  }

  Future<void> _loadMetadata({
    bool refreshScopes = false,
    bool retryDates = false,
  }) async {
    if (section != 0) return;
    final run = _filterRun;
    await Future.wait([
      if (_usesClientFilters && core != '全部')
        widget.controller.loadCore(core, refresh: refreshScopes),
      if (device != null)
        widget.controller.loadDevice(device!, refresh: refreshScopes),
    ]);
    if (!mounted || run != _filterRun || section != 0) {
      return;
    }
    if (sort == CatalogSort.updated) {
      await widget.controller.loadUpdateDates(
        _matchingApps(unsorted: true),
        retry: retryDates,
      );
    }
  }

  Future<void> _refresh() async {
    if (widget.controller.loading) return;
    if (runningDownloadPlatform == 'Android') {
      widget.downloads.installedApps.invalidate();
    }
    _filterRun++;
    widget.controller.stopDateLoading();
    await widget.controller.load(refresh: true);
    if (mounted) await _loadMetadata(refreshScopes: true);
  }

  void _resetFilters({bool clearType = true}) {
    search.clear();
    _changeFilters(() {
      query = '';
      if (clearType) applicationType = null;
      core = source = price = '全部';
      widget.controller.selectCatalogPlatform('全部');
    });
  }

  Widget _resultToolbar(int count, bool useGrid) {
    final controller = widget.controller;
    final showCacheStatus =
        !usesMobileDesign(context) && controller.snapshot?.cached == true;
    final countLabel = '$count 款应用${showCacheStatus ? ' · 已缓存' : ''}';
    CatalogSortControls sorting({Widget? trailing}) => CatalogSortControls(
      sort: sort,
      starPeriod: starPeriod,
      starMetric: starMetric,
      onSortChanged: (value) => _changeFilters(() => sort = value),
      onPeriodChanged: (value) => _changeFilters(() => starPeriod = value),
      onMetricChanged: (value) => _changeFilters(() => starMetric = value),
      trailing: trailing,
    );
    if (MediaQuery.sizeOf(context).width < 600) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final count = CatalogResultCount(countLabel);
          final inlineCount =
              sorting().compactWidthOf(context) + count.widthOf(context) + 8 <=
              constraints.maxWidth;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              sorting(trailing: inlineCount ? count : null),
              if (!inlineCount) ...[
                const SizedBox(height: 8),
                Align(alignment: Alignment.centerRight, child: count),
              ],
            ],
          );
        },
      );
    }
    return CatalogToolbar(
      count: countLabel,
      grid: useGrid,
      onGridChanged: controller.setCatalogGrid,
      sort: sorting(),
    );
  }

  Widget _dateLoading() {
    final controller = widget.controller;
    if (controller.loadingDates) {
      return const Padding(
        padding: EdgeInsets.only(top: 12),
        child: Center(
          child: SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              semanticsLabel: '加载中',
            ),
          ),
        ),
      );
    }
    final hasPendingDates = _matchingApps(unsorted: true)
        .any((app) => !controller.updateDates.containsKey(app.key));
    if (!hasPendingDates) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        onPressed: () => _loadMetadata(retryDates: true),
        child: const Text('重试加载'),
      ),
    );
  }

  String _sortValue(CatalogApp app) => switch (sort) {
    CatalogSort.comprehensive => '',
    CatalogSort.updated =>
      widget.controller.updateDates[app.key]?.toIso8601String().substring(
            0,
            10,
          ) ??
          (widget.controller.updateDates.containsKey(app.key)
              ? '日期未记录'
              : '日期未读取'),
    CatalogSort.stars => _starValue(app),
    CatalogSort.ratings => '评分数：${app.ratingCount ?? '—'}',
  };

  String _starValue(CatalogApp app) {
    final count = starPeriod.count(app);
    if (starMetric == CatalogStarMetric.count) {
      return '${starPeriod.label}新增 Star：${count ?? '—'}';
    }
    final total = app.starCount;
    final share = count != null && total != null && total > 0
        ? '${(count / total * 100).toStringAsFixed(1)}%'
        : '—';
    return '${starPeriod.label}新增比例：$share';
  }

  Widget _sortMetadata(CatalogApp app) => Tooltip(
    message: sort == CatalogSort.stars
        ? '$_sortNotice${app.starNote == null ? '' : '\n${app.starNote}'}'
        : sort == CatalogSort.ratings
        ? app.ratingNote ?? _sortNotice
        : _sortNotice,
    child: Text(
      _sortValue(app),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 11,
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );

  String _appSubtitle(CatalogApp app) => [
    app.type.label,
    if (app.isClient) ...[app.core, app.source] else ...app.badges,
  ].where((value) => value.isNotEmpty).join(' · ');

  String _appEnvironment(CatalogApp app) => app.isClient
      ? app.platforms.map((p) => p == 'macOS' ? 'Mac' : p).join(' · ')
      : app.environments.isEmpty
      ? ''
      : '${app.type.environmentLabel}：${app.environments.join(' · ')}';

  bool _hasDownloadAction(CatalogApp app) =>
      !app.withdrawn && app.isClient && app.platforms.isNotEmpty;

  Widget _appListItem(CatalogApp app) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _showDetails(app),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              AppIcon(app, size: 58),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      app.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      app.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      [
                        _appSubtitle(app),
                        _appEnvironment(app),
                      ].where((s) => s.isNotEmpty).join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (sort != CatalogSort.comprehensive) _sortMetadata(app),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              if (_hasDownloadAction(app))
                AppDownloadButton(
                  app: app,
                  selectedPlatform: platform,
                  compact: true,
                  loadDetails: () async =>
                      (await widget.controller.repository.detail(app)).details,
                  manager: widget.downloads,
                  onStarted: _showDownloads,
                )
              else
                Pill(
                  app.withdrawn
                      ? '已下架'
                      : app.price.isEmpty
                      ? '查看详情'
                      : app.price,
                  accent: !app.withdrawn && app.priceCategory == '免费',
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showDetails(CatalogApp app) async {
    _filterRun++;
    widget.controller.stopDateLoading();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DetailPage(
          app: app,
          selectedPlatform: platform,
          controller: widget.controller,
          downloads: widget.downloads,
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  Widget _mobileAppItem(CatalogApp app, {required bool expanded}) {
    final compact = MediaQuery.sizeOf(context).width < compactLayoutBreakpoint;
    final environment = _appEnvironment(app);
    final hasDownload = _hasDownloadAction(app);
    final priceLabel = app.withdrawn
        ? '已下架'
        : hasDownload
        ? ''
        : app.price;
    final subtitle = compact && app.withdrawn
        ? '已下架 · ${_appSubtitle(app)}'
        : _appSubtitle(app);
    return SurfacePanel(
      key: ValueKey('android-app-${app.key}'),
      child: InkWell(
        onTap: () => _showDetails(app),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Builder(
            builder: (context) {
              final theme = Theme.of(context);
              final secondary = theme.textTheme.bodySmall!.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              );
              Widget fact(String label, String value) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: secondary.copyWith(fontSize: 12)),
                  const SizedBox(height: 4),
                  Text(
                    value,
                    style: theme.textTheme.bodySmall!.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              );
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      AppIcon(app, size: 48),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              app.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium,
                            ),
                            if (subtitle.isNotEmpty) ...[
                              const SizedBox(height: 3),
                              Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: secondary.copyWith(fontSize: 12),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (hasDownload)
                        AppDownloadButton(
                          app: app,
                          selectedPlatform: platform,
                          compact: true,
                          loadDetails: () async =>
                              (await widget.controller.repository.detail(app))
                                  .details,
                          manager: widget.downloads,
                          onStarted: _showDownloads,
                        )
                      else
                        Icon(
                          Icons.chevron_right_rounded,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                    ],
                  ),
                  if (app.description.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(
                      app.description,
                      maxLines: expanded ? 3 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: secondary,
                    ),
                  ],
                  if (!compact &&
                      (environment.isNotEmpty || priceLabel.isNotEmpty)) ...[
                    const SizedBox(height: 16),
                    SurfacePanel(
                      radius: 22,
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (environment.isNotEmpty)
                            Expanded(
                              flex: 3,
                              child: fact(
                                app.isClient ? '支持平台' : '运行环境',
                                environment,
                              ),
                            ),
                          if (environment.isNotEmpty && priceLabel.isNotEmpty)
                            const SizedBox(width: 16),
                          if (priceLabel.isNotEmpty)
                            Flexible(flex: 2, child: fact('费用', priceLabel)),
                        ],
                      ),
                    ),
                  ],
                  if (sort != CatalogSort.comprehensive) ...[
                    const SizedBox(height: 12),
                    _sortMetadata(app),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _compactAppItem(CatalogApp app) {
    final colors = Theme.of(context).colorScheme;
    final hasDownload = _hasDownloadAction(app);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _showDetails(app),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  AppIcon(app, size: 44),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          app.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        if (_appSubtitle(app).isNotEmpty)
                          Text(
                            _appSubtitle(app),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (hasDownload)
                    AppDownloadButton(
                      app: app,
                      selectedPlatform: platform,
                      compact: true,
                      loadDetails: () async =>
                          (await widget.controller.repository.detail(app))
                              .details,
                      manager: widget.downloads,
                      onStarted: _showDownloads,
                    )
                  else
                    Icon(
                      Icons.chevron_right_rounded,
                      color: colors.onSurfaceVariant,
                      size: 20,
                    ),
                ],
              ),
              if (app.description.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  app.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.45,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _appEnvironment(app),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (app.withdrawn ||
                      !hasDownload && app.price.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        app.withdrawn ? '已下架' : app.price,
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              if (sort != CatalogSort.comprehensive) _sortMetadata(app),
            ],
          ),
        ),
      ),
    );
  }

  Widget _appCard(CatalogApp app, {bool bounded = true}) {
    final colors = Theme.of(context).colorScheme;
    final priceTag = Pill(
      app.withdrawn
          ? '已下架'
          : app.price.isEmpty
          ? '查看详情'
          : app.price,
      accent: !app.withdrawn && app.price == '免费',
    );
    final download = _hasDownloadAction(app)
        ? AppDownloadButton(
            app: app,
            selectedPlatform: platform,
            compact: true,
            loadDetails: () async =>
                (await widget.controller.repository.detail(app)).details,
            manager: widget.downloads,
            onStarted: _showDownloads,
          )
        : null;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _showDetails(app),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  AppIcon(app, size: 52),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          app.name,
                          maxLines: bounded ? 1 : 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _appSubtitle(app),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.onSurfaceVariant,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 17),
              Text(
                app.description,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontSize: 12,
                  height: 1.65,
                ),
              ),
              if (bounded) const Spacer() else const SizedBox(height: 20),
              if (sort != CatalogSort.comprehensive) ...[
                _sortMetadata(app),
                const SizedBox(height: 8),
              ],
              if (!bounded) ...[
                Text(
                  _appEnvironment(app),
                  style: TextStyle(
                    fontSize: 11,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: download == null
                      ? Alignment.centerLeft
                      : Alignment.centerRight,
                  child: download ?? priceTag,
                ),
              ] else
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _appEnvironment(app),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    download ?? priceTag,
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
