import 'dart:io';

import 'package:flutter/material.dart';

import '../data/site_models.dart';
import 'adaptive_dialog.dart';
import 'catalog_controls.dart';
import 'content_image.dart';
import 'components.dart';
import 'page_components.dart';
import 'theme.dart';

enum ServiceCatalogKind { airport, vps }

class ServiceCatalog extends StatefulWidget {
  const ServiceCatalog({
    super.key,
    required this.kind,
    required this.document,
    required this.items,
    required this.embedded,
    required this.loading,
    required this.collecting,
    required this.allLoaded,
    required this.onRefresh,
    required this.onCollect,
    required this.onStop,
    required this.onOpen,
    required this.actions,
    required this.footer,
    this.hasSnapshot = true,
    this.message,
    this.reference,
    this.initialError,
  });

  final ServiceCatalogKind kind;
  final SiteDocument document;
  final List<SiteItem> items;
  final bool embedded, loading, collecting, allLoaded, hasSnapshot;
  final Future<void> Function() onRefresh;
  final VoidCallback onCollect, onStop;
  final ValueChanged<String> onOpen;
  final List<Widget> actions;
  final Widget footer;
  final Widget? reference;
  final String? message;
  final String? initialError;

  @override
  State<ServiceCatalog> createState() => _ServiceCatalogState();
}

class _ServiceCatalogState extends State<ServiceCatalog> {
  final _search = TextEditingController();
  Map<String, String> _selected = {};
  String _query = '', _sort = 'original';
  double? _memory, _traffic, _minPrice, _maxPrice;
  bool? _grid;

  bool get _isVps => widget.kind == ServiceCatalogKind.vps;
  String get _subject => _isVps ? 'VPS' : '机场';
  String get _prefix => _isVps ? 'vps' : 'airport';
  String get _moneyName => _isVps ? '人民币参考价格' : '人民币付款金额';
  String get _pricePrefix => _isVps ? '参考价' : '金额';
  static const _memoryValues = [0.0, 1.0, 2.0, 4.0, 8.0, 16.0];
  static const _trafficValues = [0.0, 100.0, 200.0, 500.0, 1000.0];
  static const _priceRanges = <String, (double?, double?)>{
    '不限': (null, null),
    '≤ ¥10': (null, 10),
    '¥10–30': (10, 30),
    '¥30–100': (30, 100),
    '> ¥100': (100, null),
  };

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Map<String, Set<String>> get _facets {
    final values = <String, Set<String>>{};
    for (final item in widget.items) {
      for (final entry in item.facets.entries) {
        values.putIfAbsent(entry.key, () => {}).addAll(entry.value);
      }
    }
    if (_providerLinks.isNotEmpty) values.remove('厂商');
    return values;
  }

  Map<String, String> get _providerLinks => {
    if (_isVps)
      for (final link in widget.document.providers) link.url: link.label,
  };

  SiteLink? get _currentProvider =>
      widget.document.providers.where((link) => link.selected).firstOrNull ??
      widget.document.providers
          .where((link) => link.url == widget.document.url)
          .firstOrNull;

  void _changeProvider(String url) {
    if (url != _currentProvider?.url) widget.onOpen(url);
  }

  Map<String, String> get _directoryLinks => {
    for (final group in widget.document.groups)
      for (final link in group.links)
        if (!_providerLinks.containsKey(link.url)) link.url: link.label,
  };

  bool get _hasMemory =>
      _isVps && widget.items.any((item) => item.memory != null);
  bool get _hasTraffic => widget.items.any((item) => item.traffic != null);
  bool get _hasPrice => widget.items.any((item) => item.price != null);
  bool get _hasFilterMenus =>
      _facets.isNotEmpty ||
      _hasMemory ||
      _hasTraffic ||
      _hasPrice ||
      _providerLinks.isNotEmpty ||
      _directoryLinks.isNotEmpty;

  List<SiteItem> get _results => SiteQuery(
    text: _query,
    facets: _selected,
    sort: _sort,
    minimumMemory: _memory,
    minimumTraffic: _traffic,
    minimumPrice: _minPrice,
    maximumPrice: _maxPrice,
  ).apply(widget.items);

  int get _filterCount =>
      _selected.length +
      (_memory == null ? 0 : 1) +
      (_traffic == null ? 0 : 1) +
      (_minPrice == null && _maxPrice == null ? 0 : 1);

  String _number(double value) =>
      value == value.roundToDouble() ? value.toInt().toString() : '$value';

  String get _priceLabel {
    if (_minPrice == null && _maxPrice == null) {
      return _isVps ? '参考价格不限' : '付款金额不限';
    }
    return '$_pricePrefix $_priceValue';
  }

  String get _priceValue {
    if (_minPrice == null && _maxPrice == null) return '不限';
    if (_minPrice == null) return '≤ ¥${_number(_maxPrice!)}';
    if (_maxPrice == null) return '> ¥${_number(_minPrice!)}';
    return '¥${_number(_minPrice!)}–${_number(_maxPrice!)}';
  }

  String get _selectedPriceRange =>
      _priceRanges.entries
          .where((e) => e.value == (_minPrice, _maxPrice))
          .firstOrNull
          ?.key ??
      '自定义…';

  void _reset() => setState(() {
    _search.clear();
    _query = '';
    _selected.clear();
    _memory = _traffic = _minPrice = _maxPrice = null;
  });

  @override
  Widget build(BuildContext context) {
    final desktop = MediaQuery.sizeOf(context).width >= 900;
    final compact = MediaQuery.sizeOf(context).width < 600;
    final grid = !compact && (_grid ?? desktop);
    final padding = compact ? 16.0 : 32.0;
    final results = _results;
    return Scaffold(
      resizeToAvoidBottomInset: !widget.embedded,
      body: PageSafeArea(
        child: RefreshIndicator(
          edgeOffset: PageSafeArea.topInsetOf(context),
          onRefresh: widget.onRefresh,
          child: CustomScrollView(
            key: ValueKey('$_prefix-catalog-scroll'),
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  padding,
                  (compact ? 16 : 24) + PageSafeArea.topInsetOf(context),
                  padding,
                  16,
                ),
                sliver: SliverToBoxAdapter(
                  child: _header(desktop, grid, results.length),
                ),
              ),
              if (widget.collecting)
                const SliverToBoxAdapter(
                  child: LinearProgressIndicator(minHeight: 2),
                ),
              if (widget.initialError != null)
                SliverToBoxAdapter(
                  child: EmptyState(
                    icon: Icons.cloud_off_rounded,
                    title: '暂时无法加载$_subject',
                    message: widget.initialError!,
                    action: Wrap(
                      spacing: 12,
                      children: [
                        FilledButton(
                          onPressed: widget.onRefresh,
                          child: const Text('重试'),
                        ),
                        TextButton(
                          onPressed: () => openLink(
                            context,
                            widget.document.url,
                            inApp: Platform.isAndroid,
                          ),
                          child: const Text('查看网页'),
                        ),
                      ],
                    ),
                  ),
                )
              else if (results.isEmpty && !widget.loading)
                SliverToBoxAdapter(
                  child: EmptyState(
                    icon: Icons.search_off_rounded,
                    title: '没有找到匹配的$_subject',
                    message: '试试其他关键词或筛选条件，也可以载入其他分页。',
                    action: TextButton(
                      onPressed: _reset,
                      child: const Text('清除筛选'),
                    ),
                  ),
                ),
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: padding),
                sliver: SliverLayoutBuilder(
                  builder: (context, constraints) {
                    final columns = grid && desktop
                        ? (constraints.crossAxisExtent / 290).floor().clamp(
                            2,
                            5,
                          )
                        : 1;
                    final cardWidth =
                        (constraints.crossAxisExtent - 14 * (columns - 1)) /
                            columns -
                        (grid || usesMobileDesign(context) ? 40 : 32);
                    final metricWidth = grid && !usesMobileDesign(context)
                        ? 90.0
                        : 130.0;
                    final metricsColumns =
                        (cardWidth /
                                MediaQuery.textScalerOf(context)
                                    .scale(metricWidth))
                            .floor()
                            .clamp(1, 3);
                    return SliverList.builder(
                      itemCount: (results.length / columns).ceil(),
                      itemBuilder: (context, row) => Padding(
                        padding: EdgeInsets.only(bottom: compact ? 8 : 14),
                        child: IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (var col = 0; col < columns; col++) ...[
                                if (col > 0) const SizedBox(width: 14),
                                Expanded(
                                  child: row * columns + col < results.length
                                      ? _ServiceCard(
                                          kind: widget.kind,
                                          item: results[row * columns + col],
                                          list: !grid,
                                          wide:
                                              constraints.crossAxisExtent >=
                                              760,
                                          metricsColumns: metricsColumns,
                                          onOpen: widget.onOpen,
                                        )
                                      : const SizedBox.shrink(),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              if (!widget.allLoaded)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(padding),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        TextButton.icon(
                          onPressed: widget.loading
                              ? null
                              : widget.collecting
                              ? widget.onStop
                              : widget.onCollect,
                          icon: Icon(
                            widget.collecting
                                ? Icons.stop_circle_outlined
                                : Icons.download_rounded,
                            size: 17,
                          ),
                          label: Text(widget.collecting ? '停止加载' : '载入全部页'),
                        ),
                        for (final link in widget.document.pagination)
                          TextButton(
                            onPressed: () => widget.onOpen(link.url),
                            child: Text(link.label),
                          ),
                      ],
                    ),
                  ),
                ),
              if (widget.reference != null)
                SliverPadding(
                  padding: EdgeInsets.all(padding),
                  sliver: SliverToBoxAdapter(child: widget.reference),
                ),
              SliverToBoxAdapter(child: widget.footer),
              SliverToBoxAdapter(
                child: SizedBox(height: PageBottomInset.of(context)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(bool desktop, bool grid, int count) => LayoutBuilder(
    builder: (context, constraints) =>
        _headerContent(desktop, grid, count, constraints.maxWidth),
  );

  Widget _headerContent(bool desktop, bool grid, int count, double width) {
    final theme = Theme.of(context);
    final header = PageHeader(
      title: _isVps ? 'VPS' : '机场',
      titleStyle: theme.textTheme.headlineMedium,
      showBackButton: !widget.embedded,
      actions: widget.actions,
    );
    if (!widget.hasSnapshot) return header;
    final compact = MediaQuery.sizeOf(context).width < 600;
    final colors = theme.colorScheme;
    final inlineFilters = useInlineCatalogFilters(context, wide: desktop);
    final combineControls =
        !compact &&
        inlineFilters &&
        width >= MediaQuery.textScalerOf(context).scale(800);
    final hasFilters = _filterCount > 0 || _query.isNotEmpty;
    final countLabel = widget.initialError != null
        ? '尚未载入$_subject'
        : widget.loading && widget.items.isEmpty
        ? '正在载入$_subject…'
        : _filterCount > 0 || _query.trim().isNotEmpty
        ? '匹配 $count / 已载入 ${widget.items.length}'
        : '已载入 ${widget.items.length} 条';
    final sorts = {
      'original': '综合排序',
      'name': '按名称',
      if (widget.items.any((item) => item.price != null)) ...{
        'price': _isVps ? '参考价从低到高' : '金额从低到高',
        'priceDesc': _isVps ? '参考价从高到低' : '金额从高到低',
      },
      if (_isVps && widget.items.any((item) => item.memory != null))
        'memory': '内存从高到低',
    };
    final sortMenu = CatalogMenu<String>(
      key: ValueKey('$_prefix-sort'),
      label: sorts[_sort] ?? '综合排序',
      tooltip: '排序方式：${sorts[_sort]}',
      selected: _sort,
      active: _sort != 'original',
      values: sorts.keys.toList(),
      labelFor: (value) => sorts[value]!,
      onSelected: (value) => setState(() => _sort = value),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        CatalogSearchPanel(
          grouped: !compact,
          builder: (context) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Material(
                      color: SurfacePanel.raisedColor(context),
                      shape: surfaceShape(1000),
                      clipBehavior: Clip.antiAlias,
                      child: TextField(
                        controller: _search,
                        onChanged: (value) => setState(() => _query = value),
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          hintText: compact
                              ? (_isVps ? '搜索已载入的 VPS' : '搜索已载入的机场')
                              : (_isVps
                                    ? '搜索已载入的厂商、地区、套餐或规格'
                                    : '搜索已载入的机场、套餐或规格'),
                          hintStyle: const TextStyle(fontSize: 14),
                          prefixIcon: const Icon(Icons.search_rounded),
                          suffixIcon: _query.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: '清空搜索',
                                  onPressed: () => setState(() {
                                    _search.clear();
                                    _query = '';
                                  }),
                                  icon: const Icon(
                                    Icons.close_rounded,
                                    size: 18,
                                  ),
                                ),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 12,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              if (compact && _hasFilterMenus) ...[
                const SizedBox(height: 12),
                _compactFilters(),
              ],
              if (!compact && _hasFilterMenus && !combineControls) ...[
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 40),
                        child: inlineFilters
                            ? _inlineFilters(showReset: !desktop && hasFilters)
                            : Align(
                                alignment: Alignment.centerLeft,
                                child: FilledButton.icon(
                                  key: ValueKey('$_prefix-filters'),
                                  onPressed: _showFilters,
                                  style: FilledButton.styleFrom(
                                    backgroundColor: colors.surfaceContainerLow,
                                    foregroundColor: colors.onSurface,
                                    shape: surfaceShape(1000),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                    ),
                                  ),
                                  icon: const Icon(
                                    Icons.tune_rounded,
                                    size: 18,
                                  ),
                                  label: Text(
                                    _filterCount == 0
                                        ? '筛选'
                                        : '筛选 · $_filterCount',
                                  ),
                                ),
                              ),
                      ),
                    ),
                    if (hasFilters && (desktop || !inlineFilters))
                      TextButton(onPressed: _reset, child: const Text('重置筛选')),
                  ],
                ),
              ],
              if (!compact &&
                  widget.document.groups.isNotEmpty &&
                  (!_isVps || !inlineFilters)) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (_isVps) ...[
                      if (_providerLinks.isNotEmpty)
                        _vpsProviderMenu(compact: !desktop),
                      if (_directoryLinks.isNotEmpty)
                        _vpsDirectoryMenu(compact: !desktop),
                    ] else
                      for (final group in widget.document.groups)
                        CatalogMenu<String>(
                          label: group.label.isEmpty ? '分类导航' : group.label,
                          tooltip: '分类导航',
                          selected:
                              group.links
                                  .where((l) => l.selected)
                                  .firstOrNull
                                  ?.url ??
                              '',
                          values: group.links.map((l) => l.url).toList(),
                          labelFor: (value) => group.links
                              .firstWhere((l) => l.url == value)
                              .label,
                          onSelected: widget.onOpen,
                        ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (compact)
          _compactToolbar(sorts, countLabel)
        else if (combineControls)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _inlineFilters(showReset: hasFilters, sort: sortMenu),
              ),
              const SizedBox(width: 16),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: width / 3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(child: CatalogResultCount(countLabel)),
                    const SizedBox(width: 8),
                    CatalogViewSwitch(
                      grid: grid,
                      onChanged: (value) => setState(() => _grid = value),
                    ),
                  ],
                ),
              ),
            ],
          )
        else
          CatalogToolbar(
            count: countLabel,
            grid: grid,
            onGridChanged: (value) => setState(() => _grid = value),
            sort: sortMenu,
          ),
        if (widget.message?.isNotEmpty ?? false)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(widget.message!, style: theme.textTheme.bodySmall),
          ),
      ],
    );
  }

  Widget _vpsProviderMenu({required bool compact}) {
    final links = _providerLinks;
    return CatalogMenu<String>(
      key: const ValueKey('vps-filter-厂商'),
      label: _currentProvider?.label ?? '厂商',
      tooltip: '切换厂商目录；筛选仅针对该目录已载入套餐',
      selected: _currentProvider?.url ?? '',
      values: links.keys.toList(),
      labelFor: (value) => links[value]!,
      optionKey: (value) => ValueKey('vps-provider-$value'),
      onSelected: _changeProvider,
      compact: compact,
    );
  }

  Widget _vpsDirectoryMenu({required bool compact}) {
    final links = _directoryLinks;
    return CatalogMenu<String>(
      key: const ValueKey('vps-directory-menu'),
      label: '分类目录',
      tooltip: '打开公开分类目录；当前筛选仅针对已载入套餐',
      selected: widget.document.url,
      values: links.keys.toList(),
      labelFor: (value) => links[value]!,
      optionKey: (value) => ValueKey('vps-directory-$value'),
      onSelected: widget.onOpen,
      compact: compact,
      icon: Icons.explore_outlined,
    );
  }

  Widget _compactFilters() => CompactCatalogFilterRow(
    key: ValueKey('$_prefix-compact-filters'),
    menus: [
      if (_providerLinks.isNotEmpty)
        CompactCatalogMenu<String>(
          key: const ValueKey('vps-filter-厂商'),
          label: _currentProvider?.label ?? '厂商',
          title: '厂商',
          tooltip: '切换厂商目录；筛选仅针对该目录已载入套餐',
          selected: _currentProvider?.url ?? '',
          values: _providerLinks.keys.toList(),
          labelFor: (value) => _providerLinks[value]!,
          optionKey: (value) => ValueKey('vps-provider-$value'),
          onChanged: _changeProvider,
        ),
      for (final entry in _facets.entries)
        CompactCatalogMenu<String>(
          key: ValueKey('$_prefix-filter-${entry.key}'),
          label: _selected[entry.key] ?? entry.key,
          title: entry.key,
          selected: _selected[entry.key] ?? '',
          values: ['', ...entry.value],
          labelFor: (value) => value.isEmpty ? '全部' : value,
          optionKey: (value) => ValueKey('$_prefix-${entry.key}-$value'),
          active: _selected.containsKey(entry.key),
          onChanged: (value) => setState(() {
            if (value.isEmpty) {
              _selected.remove(entry.key);
            } else {
              _selected[entry.key] = value;
            }
          }),
        ),
      if (_hasMemory)
        CompactCatalogMenu<double>(
          key: const ValueKey('vps-filter-memory'),
          label: _memory == null ? '内存' : '≥ ${_number(_memory!)} GB',
          title: '最低内存',
          selected: _memory ?? 0,
          values: _memoryValues,
          labelFor: (value) => value == 0 ? '不限' : '至少 ${_number(value)} GB',
          optionKey: (value) => ValueKey('vps-memory-${_number(value)}'),
          active: _memory != null,
          onChanged: (value) =>
              setState(() => _memory = value == 0 ? null : value),
        ),
      if (_hasTraffic)
        CompactCatalogMenu<double>(
          key: ValueKey('$_prefix-filter-traffic'),
          label: _traffic == null ? '月流量' : '≥ ${_number(_traffic!)} GB/月',
          title: '明确月流量下限',
          selected: _traffic ?? 0,
          values: _trafficValues,
          labelFor: (value) =>
              value == 0 ? '不限' : '至少 ${_number(value)} GB / 月',
          optionKey: (value) => ValueKey('$_prefix-traffic-${_number(value)}'),
          active: _traffic != null,
          onChanged: (value) =>
              setState(() => _traffic = value == 0 ? null : value),
        ),
      if (_hasPrice)
        CompactCatalogMenu<String>(
          key: ValueKey('$_prefix-filter-price'),
          label: _priceValue == '不限' ? _pricePrefix : _priceValue,
          title: _moneyName,
          tooltip: '$_moneyName：$_priceValue；下限不含、上限包含，保留原付款周期',
          selected: _selectedPriceRange,
          values: [..._priceRanges.keys, '自定义…'],
          labelFor: (value) => value,
          optionKey: (value) => ValueKey('$_prefix-price-$value'),
          active: _minPrice != null || _maxPrice != null,
          onChanged: (value) {
            final range = _priceRanges[value];
            if (range == null) {
              _showFilters(priceOnly: true);
            } else {
              setState(() {
                _minPrice = range.$1;
                _maxPrice = range.$2;
              });
            }
          },
        ),
      if (_isVps && _directoryLinks.isNotEmpty)
        CompactCatalogMenu<String>(
          key: const ValueKey('vps-directory-menu'),
          label: '分类目录',
          title: '分类目录',
          tooltip: '打开公开分类目录；当前筛选仅针对已载入套餐',
          selected: widget.document.url,
          values: _directoryLinks.keys.toList(),
          labelFor: (value) => _directoryLinks[value]!,
          optionKey: (value) => ValueKey('vps-directory-$value'),
          onChanged: widget.onOpen,
        )
      else if (!_isVps)
        for (final group in widget.document.groups)
          if (group.links.isNotEmpty)
            CompactCatalogMenu<String>(
              key: ValueKey('airport-directory-${group.label}'),
              label: group.label.isEmpty ? '分类导航' : group.label,
              title: '分类导航',
              selected:
                  group.links.where((link) => link.selected).firstOrNull?.url ??
                  '',
              values: group.links.map((link) => link.url).toList(),
              labelFor: (value) =>
                  group.links
                      .where((link) => link.url == value)
                      .firstOrNull
                      ?.label ??
                  '全部',
              optionKey: (value) => ValueKey('airport-directory-$value'),
              onChanged: widget.onOpen,
            ),
    ],
  );

  Widget _compactToolbar(Map<String, String> sorts, String countLabel) =>
      LayoutBuilder(
        builder: (context, constraints) {
          final label = sorts[_sort] ?? '综合排序';
          final width = CompactCatalogMenu.widthOf(context, label);
          final count = CatalogResultCount(countLabel);
          final inlineCount =
              width + count.widthOf(context) + 8 <= constraints.maxWidth;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: width,
                        child: CompactCatalogMenu<String>(
                          key: ValueKey('$_prefix-sort'),
                          label: label,
                          title: '排序方式',
                          selected: _sort,
                          values: sorts.keys.toList(),
                          labelFor: (value) => sorts[value] ?? '综合排序',
                          optionKey: (value) =>
                              ValueKey('$_prefix-sort-$value'),
                          active: _sort != 'original',
                          onChanged: (value) => setState(() => _sort = value),
                        ),
                      ),
                    ),
                  ),
                  if (inlineCount) ...[const SizedBox(width: 8), count],
                ],
              ),
              if (!inlineCount) ...[
                const SizedBox(height: 8),
                Align(alignment: Alignment.centerRight, child: count),
              ],
            ],
          );
        },
      );

  Widget _inlineFilters({required bool showReset, Widget? sort}) {
    final facets = _facets;
    final hasMemory = _hasMemory;
    final hasTraffic = _hasTraffic;
    final hasPrice = _hasPrice;
    final hasProvider = _providerLinks.isNotEmpty;
    final hasDirectory = _isVps && _directoryLinks.isNotEmpty;
    final menuCount =
        facets.length +
        (hasMemory ? 1 : 0) +
        (hasTraffic ? 1 : 0) +
        (hasPrice ? 1 : 0) +
        (hasProvider ? 1 : 0) +
        (hasDirectory ? 1 : 0) +
        (sort == null ? 0 : 1);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 600;
        final spacing = compact ? 6.0 : 8.0;
        final textScale = MediaQuery.textScalerOf(context).scale(13) / 13;
        final columns =
            (constraints.maxWidth / ((_isVps ? 120 : 90) * textScale + spacing))
                .floor()
                .clamp(1, menuCount == 0 ? 1 : menuCount);
        Widget fit(Widget menu) {
          if (!compact) return menu;
          final width =
              (constraints.maxWidth - spacing * (columns - 1)) / columns;
          return ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: columns < menuCount ? width : 0,
              maxWidth: width,
            ),
            child: menu,
          );
        }

        return Wrap(
          spacing: spacing,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (hasProvider) fit(_vpsProviderMenu(compact: compact)),
            for (final entry in facets.entries)
              fit(
                CatalogMenu<String>(
                  key: ValueKey('$_prefix-filter-${entry.key}'),
                  label: _selected[entry.key] ?? entry.key,
                  tooltip: '${entry.key}筛选：${_selected[entry.key] ?? '全部'}',
                  compact: compact,
                  selected: _selected[entry.key] ?? '',
                  values: ['', ...entry.value],
                  labelFor: (value) => value.isEmpty ? '全部' : value,
                  optionKey: (value) =>
                      ValueKey('$_prefix-${entry.key}-$value'),
                  active: _selected.containsKey(entry.key),
                  onSelected: (value) => setState(() {
                    if (value.isEmpty) {
                      _selected.remove(entry.key);
                    } else {
                      _selected[entry.key] = value;
                    }
                  }),
                ),
              ),
            if (hasMemory)
              fit(
                CatalogMenu<double>(
                  key: const ValueKey('vps-filter-memory'),
                  label: _memory == null
                      ? '内存不限'
                      : '内存 ≥ ${_number(_memory!)} GB',
                  tooltip: _memory == null
                      ? '最低内存：不限'
                      : '最低内存：${_number(_memory!)} GB',
                  compact: compact,
                  selected: _memory ?? 0,
                  values: _memoryValues,
                  labelFor: (value) =>
                      value == 0 ? '内存不限' : '至少 ${_number(value)} GB',
                  optionKey: (value) =>
                      ValueKey('vps-memory-${_number(value)}'),
                  active: _memory != null,
                  onSelected: (value) =>
                      setState(() => _memory = value == 0 ? null : value),
                ),
              ),
            if (hasTraffic)
              fit(
                CatalogMenu<double>(
                  key: ValueKey('$_prefix-filter-traffic'),
                  label: _traffic == null
                      ? '月流量不限'
                      : '月流量 ≥ ${_number(_traffic!)} GB',
                  tooltip: _traffic == null
                      ? '明确月流量下限：不限'
                      : '明确月流量下限：至少 ${_number(_traffic!)} GB / 月',
                  compact: compact,
                  selected: _traffic ?? 0,
                  values: _trafficValues,
                  labelFor: (value) =>
                      value == 0 ? '月流量不限' : '至少 ${_number(value)} GB / 月',
                  optionKey: (value) =>
                      ValueKey('$_prefix-traffic-${_number(value)}'),
                  active: _traffic != null,
                  onSelected: (value) =>
                      setState(() => _traffic = value == 0 ? null : value),
                ),
              ),
            if (hasPrice)
              fit(
                CatalogMenu<String>(
                  key: ValueKey('$_prefix-filter-price'),
                  label: _priceLabel,
                  tooltip: '$_moneyName：$_priceLabel；下限不含、上限包含',
                  compact: compact,
                  selected: _selectedPriceRange,
                  values: [..._priceRanges.keys, '自定义…'],
                  labelFor: (value) =>
                      value == '不限' ? (_isVps ? '参考价格不限' : '付款金额不限') : value,
                  optionKey: (value) => ValueKey('$_prefix-price-$value'),
                  active: _minPrice != null || _maxPrice != null,
                  onSelected: (value) {
                    final range = _priceRanges[value];
                    if (range == null) {
                      _showFilters();
                    } else {
                      setState(() {
                        _minPrice = range.$1;
                        _maxPrice = range.$2;
                      });
                    }
                  },
                ),
              ),
            if (hasDirectory) fit(_vpsDirectoryMenu(compact: compact)),
            if (sort != null) fit(sort),
            if (showReset)
              TextButton(onPressed: _reset, child: const Text('重置筛选')),
          ],
        );
      },
    );
  }

  Future<void> _showFilters({bool priceOnly = false}) async {
    var selected = Map<String, String>.from(_selected);
    var memory = _memory,
        traffic = _traffic,
        minPrice = _minPrice,
        maxPrice = _maxPrice;
    var reset = 0;
    String? rangeError;
    final form = GlobalKey<FormState>();
    final confirmed = await showAdaptiveForm<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) {
          final colors = Theme.of(context).colorScheme;
          Widget choice(String label, bool chosen, VoidCallback onTap) =>
              ChoiceChip(
                label: Text(label),
                selected: chosen,
                onSelected: (_) => update(onTap),
                selectedColor: colors.primary,
                backgroundColor: colors.surfaceContainer,
                labelStyle: TextStyle(
                  color: chosen ? colors.onPrimary : colors.onSurfaceVariant,
                ),
                shape: surfaceShape(1000),
              );
          Widget group(String label, List<Widget> children) => Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 6, children: children),
              ],
            ),
          );
          return AdaptiveDialog(
            title: priceOnly ? _moneyName : '筛选$_subject',
            onReset: () => update(() {
              reset++;
              if (!priceOnly) {
                selected = {};
                memory = traffic = null;
              }
              minPrice = maxPrice = null;
              rangeError = null;
            }),
            content: SizedBox(
              width: 440,
              child: Form(
                key: form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!priceOnly)
                      for (final entry in _facets.entries)
                        group(entry.key, [
                          choice(
                            '全部',
                            !selected.containsKey(entry.key),
                            () => selected.remove(entry.key),
                          ),
                          for (final value in entry.value)
                            choice(
                              value,
                              selected[entry.key] == value,
                              () => selected[entry.key] = value,
                            ),
                        ]),
                    if (!priceOnly && _hasMemory)
                      group('最低内存', [
                        for (final value in _memoryValues)
                          choice(
                            value == 0 ? '不限' : '${_number(value)} GB',
                            (memory ?? 0) == value,
                            () => memory = value == 0 ? null : value,
                          ),
                      ]),
                    if (!priceOnly && _hasTraffic)
                      group('明确月流量下限', [
                        for (final value in _trafficValues)
                          choice(
                            value == 0 ? '不限' : '${_number(value)} GB / 月',
                            (traffic ?? 0) == value,
                            () => traffic = value == 0 ? null : value,
                          ),
                      ]),
                    if (_hasPrice) ...[
                      if (!priceOnly) ...[
                        Text(
                          _moneyName,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                      ],
                      Row(
                        children: [
                          for (final lower in [true, false]) ...[
                            if (!lower) const SizedBox(width: 12),
                            Expanded(
                              child: TextFormField(
                                key: ValueKey((lower, reset)),
                                initialValue:
                                    (lower ? minPrice : maxPrice)?.toString() ??
                                    '',
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                decoration: InputDecoration(
                                  labelText: lower ? '下限（不含）' : '上限（含）',
                                ),
                                validator: (text) {
                                  if (text == null || text.trim().isEmpty) {
                                    return null;
                                  }
                                  final value = double.tryParse(text);
                                  return value == null ||
                                          !value.isFinite ||
                                          value < 0
                                      ? '请输入非负金额'
                                      : null;
                                },
                                onChanged: (text) => update(() {
                                  if (lower) {
                                    minPrice = double.tryParse(text);
                                  } else {
                                    maxPrice = double.tryParse(text);
                                  }
                                  rangeError = null;
                                }),
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (rangeError != null)
                        Text(
                          rangeError!,
                          style: TextStyle(color: colors.error),
                        ),
                    ],
                  ],
                ),
              ),
            ),
            actions: DialogActionsRow(
              confirmLabel: '确认',
              onCancel: () => Navigator.pop(context, false),
              onConfirm: () {
                if (!form.currentState!.validate()) return;
                if (minPrice != null &&
                    maxPrice != null &&
                    minPrice! >= maxPrice!) {
                  update(() => rangeError = '上限须大于下限');
                  return;
                }
                Navigator.pop(context, true);
              },
            ),
          );
        },
      ),
    );
    if (confirmed == true && mounted) {
      setState(() {
        if (!priceOnly) {
          _selected = selected;
          _memory = memory;
          _traffic = traffic;
        }
        _minPrice = minPrice;
        _maxPrice = maxPrice;
      });
    }
  }
}

class _ServiceCard extends StatelessWidget {
  const _ServiceCard({
    required this.kind,
    required this.item,
    required this.list,
    required this.wide,
    required this.metricsColumns,
    required this.onOpen,
  });

  final ServiceCatalogKind kind;
  final SiteItem item;
  final bool list, wide;
  final int metricsColumns;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 600;
    final isVps = kind == ServiceCatalogKind.vps;
    final icon = isVps ? Icons.cloud_outlined : Icons.flight_rounded;
    final period = item.facets['付款周期']?.join(' · ') ?? '';
    final facts = item.facts.entries
        .where((e) => !{'付款金额', '官方报价', '人民币参考价'}.contains(e.key))
        .toList();
    final payment = item.facts[isVps ? '官方报价' : '付款金额'];
    final referencePrice = isVps ? item.facts['人民币参考价'] : null;
    final emphasizeAirportPrice = !isVps && !usesMobileDesign(context);
    final paymentPrefix = const [
      '参考付款金额：',
      '参考付款金额:',
      '付款金额：',
      '付款金额:',
    ].where((prefix) => payment?.startsWith(prefix) ?? false).firstOrNull;
    final paymentValue = payment?.substring(paymentPrefix?.length ?? 0).trim();
    final identity = Row(
      children: [
        ClipPath.shape(
          shape: surfaceShape(14),
          child: SizedBox.square(
            dimension: usesMobileDesign(context)
                ? 48
                : list
                ? 44
                : 48,
            child: item.image == null
                ? usesMobileDesign(context)
                      ? ColoredBox(
                          color: colors.surfaceContainer,
                          child: Icon(icon, color: colors.onSurfaceVariant),
                        )
                      : Icon(icon, color: colors.primary)
                : ColoredBox(
                    // Some published logos are black with a transparent background.
                    color: const Color(0xfff5f5f5),
                    child: Padding(
                      padding: EdgeInsets.all(
                        usesMobileDesign(context) ? 0 : 4,
                      ),
                      child: ClipPath.shape(
                        shape: surfaceShape(10),
                        child: ContentImage(
                          imageUrl: item.image!,
                          fit: BoxFit.contain,
                          errorWidget: (_, _, _) =>
                              Icon(icon, color: Colors.black54),
                        ),
                      ),
                    ),
                  ),
          ),
        ),
        SizedBox(width: compact ? 12 : 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.title,
                style: Theme.of(context).textTheme.titleMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (period.isNotEmpty || item.subtitle.isNotEmpty) ...[
                SizedBox(height: compact ? 3 : 4),
                Text(
                  [
                    period,
                    item.subtitle,
                  ].where((s) => s.isNotEmpty).join(' · '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: compact
                        ? 12
                        : (usesMobileDesign(context) ? 13 : 12),
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
    final metrics = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var start = 0; start < facts.length; start += metricsColumns) ...[
          if (start > 0) const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final fact in facts.skip(start).take(metricsColumns)) ...[
                if (fact != facts[start]) const SizedBox(width: 12),
                Expanded(
                  child: Tooltip(
                    message: '${fact.key}：${fact.value}',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          fact.key,
                          style: TextStyle(
                            fontSize: compact
                                ? 12
                                : (usesMobileDesign(context) ? 13 : 11),
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          fact.value,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: compact
                                ? 13
                                : (usesMobileDesign(context) ? 15 : 13),
                            fontWeight: compact
                                ? FontWeight.w500
                                : FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              // Keep incomplete rows aligned with the full column layout.
              for (
                var column = facts.length - start;
                column < metricsColumns;
                column++
              ) ...[const SizedBox(width: 12), const Spacer()],
            ],
          ),
        ],
      ],
    );
    Widget action(SiteLink link) => FilledButton(
      style: downloadButtonStyle(context),
      onPressed: () => onOpen(link.url),
      child: Text(link.label),
    );

    final commerce = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (emphasizeAirportPrice && paymentValue != null)
                    _AirportPrice(value: paymentValue, compact: list)
                  else
                    Text(
                      payment ?? (isVps ? '官方报价未记录' : '付款金额未记录'),
                      style: TextStyle(
                        fontSize: payment == null ? 12 : 16,
                        fontWeight: payment == null ? null : FontWeight.w600,
                        color: payment != null
                            ? colors.onSurface
                            : colors.onSurfaceVariant,
                      ),
                    ),
                  if (referencePrice != null) ...[
                    const SizedBox(height: 5),
                    Text(
                      '人民币参考价：$referencePrice',
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (!compact && item.actions.length == 1) ...[
              const SizedBox(width: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 128),
                child: action(item.actions.single),
              ),
            ],
          ],
        ),
        if (item.actions.length > 1) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: item.actions.map(action).toList(),
          ),
        ],
      ],
    );
    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (item.summary.isNotEmpty) ...[
          Text(
            item.summary,
            maxLines: compact ? 2 : 3,
            overflow: TextOverflow.ellipsis,
            style: compact
                ? Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colors.onSurfaceVariant)
                : null,
          ),
          if (!compact || facts.isNotEmpty) const SizedBox(height: 16),
        ],
        if (!compact && usesMobileDesign(context) && facts.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: ShapeDecoration(
              color: colors.surfaceContainer,
              shape: surfaceShape(22),
            ),
            child: metrics,
          )
        else
          metrics,
        if (item.badges.isNotEmpty) ...[
          if (!compact || item.summary.isNotEmpty || facts.isNotEmpty)
            const SizedBox(height: 12),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final badge in item.badges) Pill(badge)],
          ),
        ],
      ],
    );
    if (compact) {
      return SurfacePanel(
        child: InkWell(
          onTap: () => onOpen(item.url),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: identity),
                    const SizedBox(width: 8),
                    if (item.actions.length == 1)
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 128),
                        child: action(item.actions.single),
                      )
                    else
                      Icon(
                        Icons.chevron_right_rounded,
                        color: colors.onSurfaceVariant,
                      ),
                  ],
                ),
                if (item.summary.isNotEmpty ||
                    facts.isNotEmpty ||
                    item.badges.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  details,
                ],
                const SizedBox(height: 16),
                commerce,
              ],
            ),
          ),
        ),
      );
    }
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => onOpen(item.url),
        child: Padding(
          padding: EdgeInsets.all(list && !usesMobileDesign(context) ? 16 : 20),
          child: list && wide && !usesMobileDesign(context)
              ? Row(
                  children: [
                    Expanded(flex: 3, child: identity),
                    const SizedBox(width: 24),
                    Expanded(flex: 3, child: details),
                    const SizedBox(width: 24),
                    Expanded(flex: 3, child: commerce),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    identity,
                    const SizedBox(height: 16),
                    details,
                    const Spacer(),
                    const SizedBox(height: 16),
                    commerce,
                  ],
                ),
        ),
      ),
    );
  }
}

class _AirportPrice extends StatelessWidget {
  const _AirportPrice({required this.value, required this.compact});

  final String value;
  final bool compact;

  // Split only for typography; keep the published amount and suffix as text.
  static final _parts = RegExp(r'^([≈约]?\s*[¥￥\$€£]\s*)(\d+(?:[.,]\d+)*)(.*)$');

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final parts = _parts.firstMatch(value);
    if (parts == null) {
      return Text(
        value,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: colors.onSurface,
        ),
      );
    }
    final suffix = parts[3]!.trimLeft();
    return Semantics(
      label: value,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            parts[1]!,
            style: TextStyle(
              fontSize: 14,
              height: 1.15,
              fontWeight: FontWeight.w600,
              color: colors.onSurfaceVariant,
            ),
          ),
          Flexible(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: parts[2]),
                  if (suffix.isNotEmpty)
                    TextSpan(
                      text: ' $suffix',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
              style: TextStyle(
                fontSize: compact ? 22 : 26,
                height: 1.15,
                fontWeight: FontWeight.w700,
                color: colors.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
