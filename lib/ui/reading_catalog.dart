import 'package:flutter/material.dart';

import '../data/site_models.dart';
import '../data/site_parser.dart';
import 'adaptive_dialog.dart';
import 'catalog_controls.dart';
import 'content_image.dart';
import 'components.dart';
import 'page_components.dart';
import 'theme.dart';

IconData readingIcon(SiteReadingKind kind) => switch (kind) {
  SiteReadingKind.feed => Icons.rss_feed_rounded,
  SiteReadingKind.person => Icons.person_outline_rounded,
  SiteReadingKind.article => Icons.menu_book_outlined,
  SiteReadingKind.history => Icons.history_edu_rounded,
  SiteReadingKind.core => Icons.memory_rounded,
  SiteReadingKind.protocol => Icons.hub_outlined,
};

class ReadingCatalog extends StatefulWidget {
  const ReadingCatalog({
    super.key,
    required this.kind,
    required this.document,
    required this.items,
    required this.embedded,
    required this.loading,
    required this.collecting,
    required this.allLoaded,
    required this.actions,
    required this.onRefresh,
    required this.onOpen,
    required this.onCollect,
    required this.onStop,
    this.message = '',
    this.initialError,
    this.reference,
    this.footer,
    this.referenceExpanded = false,
    this.onReferenceExpansion,
    this.sectionNavigation,
  });
  final SiteReadingKind kind;
  final SiteDocument document;
  final List<SiteItem> items;
  final bool embedded, loading, collecting, allLoaded;
  final List<Widget> actions;
  final Future<void> Function() onRefresh;
  final ValueChanged<String> onOpen;
  final VoidCallback onCollect, onStop;
  final String message;
  final String? initialError;
  final Widget? reference, footer;
  final Widget? sectionNavigation;
  final bool referenceExpanded;
  final ValueChanged<bool>? onReferenceExpansion;

  @override
  State<ReadingCatalog> createState() => _ReadingCatalogState();
}

class _ReadingCatalogState extends State<ReadingCatalog> {
  final _search = TextEditingController();
  String _query = '', _sort = 'original';
  Map<String, String> _selected = {};
  bool? _grid;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Map<String, Set<String>> get _facets {
    final result = <String, Set<String>>{};
    for (final item in widget.items) {
      for (final entry in item.facets.entries) {
        // Published people group links already provide this navigation.
        if (entry.key == '群体' && widget.document.groups.isNotEmpty) continue;
        result.putIfAbsent(entry.key, () => {}).addAll(entry.value);
      }
    }
    result.removeWhere(
      (key, values) => values.length < 2 && !_selected.containsKey(key),
    );
    return result;
  }

  void _reset() => setState(() {
    _query = '';
    _search.clear();
    _selected.clear();
  });

  Future<void> _filters() async {
    final draft = Map<String, String>.of(_selected);
    final confirmed = await showAdaptiveForm<bool>(
      context: context,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, update) => AdaptiveDialog(
          title: '筛选已载入的内容',
          onReset: () => update(draft.clear),
          content: SizedBox(
            width: 440,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final entry in _facets.entries) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 20, bottom: 10),
                    child: Text(entry.key),
                  ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final value in ['', ...entry.value])
                        ChoiceChip(
                          label: Text(value.isEmpty ? '全部' : value),
                          selected: (draft[entry.key] ?? '') == value,
                          onSelected: (_) => update(() {
                            value.isEmpty
                                ? draft.remove(entry.key)
                                : draft[entry.key] = value;
                          }),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          actions: DialogActionsRow(
            confirmLabel: '确认',
            onCancel: () => Navigator.pop(sheet, false),
            onConfirm: () => Navigator.pop(sheet, true),
          ),
        ),
      ),
    );
    if (confirmed == true && mounted) setState(() => _selected = draft);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final kind = widget.kind;
    final results = SiteQuery(
      text: _query,
      facets: _selected,
      sort: _sort,
    ).apply(widget.items);
    final title =
        SiteRoutes.sections[Uri.parse(widget.document.url).path] ??
        widget.document.title;
    return Scaffold(
      resizeToAvoidBottomInset: !widget.embedded,
      body: PageSafeArea(
        child: LayoutBuilder(
          builder: (context, size) {
            final inset = size.maxWidth < 600 ? 16.0 : 32.0;
            final compact = size.maxWidth < 600;
            final grid =
                !compact &&
                (_grid ??
                    (size.maxWidth >= 700 &&
                        ![
                          SiteReadingKind.feed,
                          SiteReadingKind.article,
                        ].contains(kind)));
            final inline = useInlineCatalogFilters(
              context,
              wide: size.maxWidth >= 700,
            );
            return RefreshIndicator(
              edgeOffset: PageSafeArea.topInsetOf(context),
              onRefresh: widget.onRefresh,
              child: CustomScrollView(
                key: const ValueKey('reading-catalog-scroll'),
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      inset,
                      (compact ? 16 : 28) + PageSafeArea.topInsetOf(context),
                      inset,
                      14,
                    ),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          PageHeader(
                            title: title,
                            showBackButton: !widget.embedded,
                            actions: widget.actions,
                          ),
                          if (widget.sectionNavigation != null) ...[
                            widget.sectionNavigation!,
                            const SizedBox(height: 16),
                          ],
                          CatalogSearchPanel(
                            builder: (context) => Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        key: const ValueKey(
                                          'reading-catalog-search',
                                        ),
                                        controller: _search,
                                        onChanged: (value) =>
                                            setState(() => _query = value),
                                        decoration: InputDecoration(
                                          hintText: widget.allLoaded
                                              ? '搜索名称、介绍或关键词'
                                              : '搜索已载入的内容',
                                          prefixIcon: const Icon(
                                            Icons.search_rounded,
                                          ),
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
                                                  ),
                                                ),
                                        ),
                                      ),
                                    ),
                                    if (compact && _facets.isNotEmpty) ...[
                                      const SizedBox(width: 8),
                                      CatalogFilterButton(
                                        compact: true,
                                        count: _selected.length,
                                        tooltip: '筛选已载入的内容',
                                        onPressed: _filters,
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 16),
                                if (widget.document.groups.isNotEmpty ||
                                    _facets.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        for (final group
                                            in widget.document.groups)
                                          CatalogMenu<String>(
                                            label:
                                                group.links
                                                    .where(
                                                      (link) => link.selected,
                                                    )
                                                    .firstOrNull
                                                    ?.label ??
                                                '分类目录',
                                            tooltip: group.label.isEmpty
                                                ? '分类目录'
                                                : group.label,
                                            selected:
                                                group.links
                                                    .where(
                                                      (link) => link.selected,
                                                    )
                                                    .firstOrNull
                                                    ?.url ??
                                                '',
                                            values: group.links
                                                .map((link) => link.url)
                                                .toList(),
                                            labelFor: (value) => group.links
                                                .firstWhere(
                                                  (link) => link.url == value,
                                                )
                                                .label,
                                            onSelected: (value) {
                                              if (!group.links.any(
                                                (link) =>
                                                    link.url == value &&
                                                    link.selected,
                                              )) {
                                                widget.onOpen(value);
                                              }
                                            },
                                          ),
                                        if (inline)
                                          for (final entry in _facets.entries)
                                            CatalogMenu<String>(
                                              key: ValueKey(
                                                'reading-filter-${entry.key}',
                                              ),
                                              label:
                                                  _selected.containsKey(
                                                    entry.key,
                                                  )
                                                  ? '${entry.key} · ${_selected[entry.key]}'
                                                  : entry.key,
                                              tooltip: '${entry.key}筛选',
                                              selected:
                                                  _selected[entry.key] ?? '',
                                              values: ['', ...entry.value],
                                              labelFor: (value) =>
                                                  value.isEmpty ? '全部' : value,
                                              active: _selected.containsKey(
                                                entry.key,
                                              ),
                                              onSelected: (value) =>
                                                  setState(() {
                                                    value.isEmpty
                                                        ? _selected.remove(
                                                            entry.key,
                                                          )
                                                        : _selected[entry.key] =
                                                              value;
                                                  }),
                                            )
                                        else if (!compact && _facets.isNotEmpty)
                                          TextButton.icon(
                                            onPressed: _filters,
                                            icon: const Icon(
                                              Icons.filter_list_rounded,
                                            ),
                                            label: Text(
                                              _selected.isEmpty
                                                  ? '筛选'
                                                  : '筛选 ${_selected.length}',
                                            ),
                                          ),
                                        if (_selected.isNotEmpty ||
                                            _query.isNotEmpty)
                                          TextButton(
                                            onPressed: _reset,
                                            child: const Text('重置筛选'),
                                          ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (usesMobileDesign(context))
                            const SizedBox(height: 12),
                          if (widget.message.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Text(
                                widget.message,
                                style: TextStyle(color: colors.error),
                              ),
                            ),
                          if (!(widget.loading && widget.items.isEmpty) &&
                              widget.initialError == null)
                            CatalogToolbar(
                              count: _query.isNotEmpty || _selected.isNotEmpty
                                  ? '匹配 ${results.length} / 已载入 ${widget.items.length}'
                                  : '已载入 ${widget.items.length} 条',
                              grid: grid,
                              showViewSwitch: !compact,
                              onGridChanged: (value) =>
                                  setState(() => _grid = value),
                              sort: CatalogMenu<String>(
                                label: _sortLabel(_sort),
                                tooltip: '排序：${_sortLabel(_sort)}',
                                selected: _sort,
                                values: [
                                  'original',
                                  if (widget.items.any(
                                    (item) => item.publishedAt != null,
                                  )) ...[
                                    'newest',
                                    'oldest',
                                  ],
                                  'name',
                                ],
                                labelFor: _sortLabel,
                                onSelected: (value) =>
                                    setState(() => _sort = value),
                                icon: Icons.sort_rounded,
                                filled: false,
                                compact: true,
                                iconOnly: compact,
                              ),
                            ),
                        ],
                      ),
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
                        title: '暂时无法加载',
                        message: '请检查网络后重试。',
                        action: FilledButton(
                          onPressed: widget.onRefresh,
                          child: const Text('重试'),
                        ),
                      ),
                    )
                  else if (widget.loading && widget.items.isEmpty)
                    SliverPadding(
                      padding: EdgeInsets.symmetric(horizontal: inset),
                      sliver: SliverToBoxAdapter(
                        child: Column(
                          children: [
                            for (var i = 0; i < 3; i++)
                              Padding(
                                padding: EdgeInsets.only(
                                  bottom: usesMobileDesign(context) ? 8 : 12,
                                ),
                                child: SurfacePanel(
                                  child: SizedBox(
                                    height: 140,
                                    child: Center(
                                      child: i == 0
                                          ? const CircularProgressIndicator(
                                              strokeWidth: 2,
                                            )
                                          : null,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    )
                  else if (results.isEmpty)
                    SliverToBoxAdapter(
                      child: EmptyState(
                        icon: Icons.search_off_rounded,
                        title: '没有找到匹配的内容',
                        message: widget.allLoaded
                            ? '试试其他关键词或筛选条件。'
                            : '试试其他关键词，或载入更多分页。',
                        action: TextButton(
                          onPressed: _reset,
                          child: const Text('清除筛选'),
                        ),
                      ),
                    ),
                  SliverPadding(
                    padding: EdgeInsets.symmetric(horizontal: inset),
                    sliver: SliverLayoutBuilder(
                      builder: (context, constraints) {
                        final columns = grid
                            ? (constraints.crossAxisExtent / 310).floor().clamp(
                                1,
                                3,
                              )
                            : 1;
                        return SliverList.builder(
                          itemCount: (results.length / columns).ceil(),
                          itemBuilder: (context, row) => Padding(
                            padding: EdgeInsets.only(
                              bottom: usesMobileDesign(context) ? 8 : 12,
                            ),
                            child: IntrinsicHeight(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  for (var col = 0; col < columns; col++) ...[
                                    if (col > 0) const SizedBox(width: 14),
                                    Expanded(
                                      child:
                                          row * columns + col < results.length
                                          ? ReadingCatalogCard(
                                              item:
                                                  results[row * columns + col],
                                              kind: kind,
                                              compact: !grid,
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
                  if (!widget.allLoaded &&
                      widget.initialError == null &&
                      !(widget.loading && widget.items.isEmpty))
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.all(inset),
                        child: Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 10,
                          runSpacing: 8,
                          children: [
                            FilledButton.tonalIcon(
                              onPressed: widget.collecting
                                  ? widget.onStop
                                  : widget.onCollect,
                              icon: Icon(
                                widget.collecting
                                    ? Icons.stop_rounded
                                    : Icons.unfold_more_rounded,
                              ),
                              label: Text(widget.collecting ? '停止加载' : '载入全部页'),
                            ),
                            for (final link in widget.document.pagination.where(
                              (link) =>
                                  link.label.contains('上一页') ||
                                  link.label.contains('下一页'),
                            ))
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
                      padding: EdgeInsets.fromLTRB(inset, 16, inset, 0),
                      sliver: SliverToBoxAdapter(
                        child: SurfacePanel(
                          child: ExpansionTile(
                            key: ValueKey(widget.referenceExpanded),
                            initiallyExpanded: widget.referenceExpanded,
                            onExpansionChanged: widget.onReferenceExpansion,
                            shape: const Border(),
                            collapsedShape: const Border(),
                            title: Text(
                              kind == SiteReadingKind.protocol
                                  ? '评分依据与选型说明'
                                  : '栏目说明与参考',
                            ),
                            subtitle: kind == SiteReadingKind.protocol
                                ? const Text('编辑判断、使用边界与公开来源')
                                : null,
                            childrenPadding: const EdgeInsets.all(20),
                            children: [widget.reference!],
                          ),
                        ),
                      ),
                    ),
                  if (widget.footer != null)
                    SliverToBoxAdapter(child: widget.footer!),
                  SliverToBoxAdapter(
                    child: SizedBox(height: 24 + PageBottomInset.of(context)),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  String _sortLabel(String value) => switch (value) {
    'newest' => '最新优先',
    'oldest' => '最早优先',
    'name' => '按名称',
    _ => '网站顺序',
  };
}

class ReadingCatalogCard extends StatelessWidget {
  const ReadingCatalogCard({
    super.key,
    required this.item,
    required this.kind,
    required this.compact,
    required this.onOpen,
  });
  final SiteItem item;
  final SiteReadingKind kind;
  final bool compact;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final feed = kind == SiteReadingKind.feed;
    final person = kind == SiteReadingKind.person;
    final badgeLimit = compact || person ? 3 : 5;
    final tags = item.badges
        .where((badge) => !feed || item.facets['动态分类']?.contains(badge) == true)
        .toList();
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => onOpen(item.url),
        child: Padding(
          padding: EdgeInsets.all(
            usesMobileDesign(context) || compact ? 20 : 22,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ReadingAvatar(
                    url: item.image,
                    kind: kind,
                    size: person ? 52 : 42,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (feed) ...[
                          Text(
                            item.byline.isEmpty ? '生态动态' : item.byline,
                            style: theme.textTheme.labelLarge,
                          ),
                          if (item.date.isNotEmpty)
                            Tooltip(
                              message: item.date,
                              child: Text(
                                item.date,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                        ] else ...[
                          Text(
                            item.title,
                            maxLines: compact ? 2 : 3,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (item.subtitle.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                item.subtitle,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
                  if (!feed) ...[
                    const SizedBox(width: 8),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: colors.onSurfaceVariant,
                    ),
                  ],
                ],
              ),
              if (feed)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(
                    item.title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      height: 1.5,
                    ),
                  ),
                ),
              if (item.summary.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    item.summary,
                    maxLines: compact && person ? 2 : 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      height: 1.65,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              if (item.facts.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final fact in item.facts.entries)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            '${fact.key} · ${fact.value}',
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              height: 1.6,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              if (tags.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final badge in tags.take(badgeLimit)) Pill(badge),
                      if (tags.length > badgeLimit)
                        Tooltip(
                          message: tags.skip(badgeLimit).join('、'),
                          child: Pill('+${tags.length - badgeLimit}'),
                        ),
                    ],
                  ),
                ),
              if (item.actions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final action in item.actions.take(3))
                        TextButton(
                          onPressed: () => onOpen(action.url),
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
  }
}

class ReadingAvatar extends StatelessWidget {
  const ReadingAvatar({
    super.key,
    this.url,
    required this.kind,
    this.size = 64,
  });
  final String? url;
  final SiteReadingKind kind;
  final double size;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final fallback = Icon(
      readingIcon(kind),
      size: size * .45,
      color: colors.onSurfaceVariant,
    );
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: ShapeDecoration(
        color: colors.surfaceContainer,
        shape: surfaceShape(
          kind == SiteReadingKind.person || kind == SiteReadingKind.feed
              ? 1000
              : 14,
        ),
      ),
      child: url == null
          ? fallback
          : ContentImage(
              imageUrl: url!,
              width: size,
              height: size,
              fit: BoxFit.cover,
              placeholder: (_, _) => fallback,
              errorWidget: (_, _, _) => fallback,
            ),
    );
  }
}
