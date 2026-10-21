import 'package:flutter/material.dart';

import '../data/catalog_filters.dart';
import '../data/models.dart';
import 'adaptive_dialog.dart';
import 'catalog_selection_sheet.dart';
import 'page_components.dart';
import 'theme.dart';

bool useInlineCatalogFilters(BuildContext context, {required bool wide}) =>
    wide ||
    MediaQuery.sizeOf(context).width >= 600 &&
        switch (Theme.of(context).platform) {
          TargetPlatform.macOS ||
          TargetPlatform.windows ||
          TargetPlatform.linux => true,
          _ => false,
        };

class CatalogSearchPanel extends StatelessWidget {
  const CatalogSearchPanel({
    super.key,
    required this.builder,
    this.grouped = true,
  });

  final WidgetBuilder builder;
  final bool grouped;

  @override
  Widget build(BuildContext context) {
    if (!grouped || !usesMobileDesign(context)) {
      return Builder(builder: builder);
    }
    return SurfacePanel(
      padding: const EdgeInsets.all(16),
      child: Builder(
        builder: (context) => Theme(
          data: Theme.of(context).copyWith(
            inputDecorationTheme: Theme.of(context).inputDecorationTheme
                .copyWith(fillColor: SurfacePanel.raisedColor(context)),
          ),
          child: Builder(builder: builder),
        ),
      ),
    );
  }
}

class CatalogSearchField extends StatelessWidget {
  const CatalogSearchField({
    super.key,
    required this.controller,
    required this.hintText,
    required this.compact,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String hintText;
  final bool compact;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => Material(
    color: SurfacePanel.raisedColor(context),
    shape: surfaceShape(1000),
    clipBehavior: Clip.antiAlias,
    child: TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: const TextStyle(fontSize: 14),
        prefixIcon: const Icon(Icons.search_rounded),
        suffixIcon: controller.text.isEmpty
            ? null
            : IconButton(
                tooltip: '清空搜索',
                onPressed: () {
                  controller.clear();
                  onChanged('');
                },
                icon: const Icon(Icons.close_rounded, size: 18),
              ),
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: EdgeInsets.symmetric(vertical: compact ? 12 : 16),
      ),
    ),
  );
}

class CatalogMenu<T> extends StatelessWidget {
  const CatalogMenu({
    super.key,
    required this.label,
    required this.tooltip,
    required this.selected,
    required this.values,
    required this.labelFor,
    required this.onSelected,
    this.active = false,
    this.filled = true,
    this.icon,
    this.iconOnly = false,
    this.compact = false,
    this.optionKey,
    this.optionTooltip,
  });

  final String label, tooltip;
  final T selected;
  final List<T> values;
  final String Function(T) labelFor;
  final ValueChanged<T> onSelected;
  final bool active, filled, iconOnly, compact;
  final IconData? icon;
  final Key Function(T)? optionKey;
  final String? Function(T)? optionTooltip;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = active ? colors.onSurface : colors.onSurfaceVariant;
    return Material(
      color: filled ? SurfacePanel.raisedColor(context) : Colors.transparent,
      shape: surfaceShape(1000),
      clipBehavior: Clip.antiAlias,
      child: Semantics(
        button: true,
        label: iconOnly ? tooltip : null,
        child: PopupMenuButton<T>(
          tooltip: tooltip,
          position: PopupMenuPosition.under,
          offset: const Offset(0, 6),
          shape: surfaceShape(24),
          elevation: 8,
          shadowColor: Colors.black.withValues(
            alpha: usesMobileDesign(context) ? .16 : .45,
          ),
          color: colors.brightness == Brightness.dark
              ? colors.surfaceContainerHighest
              : colors.surfaceContainerLow,
          surfaceTintColor: Colors.transparent,
          onSelected: onSelected,
          itemBuilder: (_) => [
            for (final value in values)
              PopupMenuItem<T>(
                key: optionKey?.call(value),
                value: value,
                child: Tooltip(
                  message: optionTooltip?.call(value) ?? '',
                  child: Semantics(
                    selected: value == selected,
                    child: Row(
                      children: [
                        Expanded(child: Text(labelFor(value))),
                        const SizedBox(width: 20),
                        if (value == selected)
                          Icon(
                            Icons.check_rounded,
                            size: 18,
                            color: colors.primary,
                          )
                        else
                          const SizedBox(width: 18),
                      ],
                    ),
                  ),
                ),
              ),
          ],
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: MediaQuery.sizeOf(context).width < 600 ? 48 : 40,
              minWidth: MediaQuery.sizeOf(context).width < 600 ? 48 : 40,
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: iconOnly ? 10 : (compact ? 8 : 14),
                vertical: 10,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(
                      icon,
                      size: usesMobileDesign(context) && iconOnly ? 22 : 16,
                      color: foreground,
                    ),
                    if (!iconOnly) const SizedBox(width: 6),
                  ],
                  if (!iconOnly) ...[
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: active
                              ? FontWeight.w600
                              : FontWeight.w500,
                          color: foreground,
                        ),
                      ),
                    ),
                    SizedBox(width: compact ? 4 : 6),
                    Icon(
                      Icons.expand_more_rounded,
                      size: 16,
                      color: foreground,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class CatalogViewSwitch extends StatelessWidget {
  const CatalogViewSwitch({
    super.key,
    required this.grid,
    required this.onChanged,
  });

  final bool grid;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Material(
      color: colors.surfaceContainer,
      shape: surfaceShape(1000),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final isGrid in [true, false])
              IconButton(
                tooltip: isGrid ? '网格视图' : '列表视图',
                isSelected: grid == isGrid,
                style: IconButton.styleFrom(
                  minimumSize: compact
                      ? const Size(44, 40)
                      : const Size(36, 32),
                  padding: const EdgeInsets.all(7),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: surfaceShape(1000),
                  backgroundColor: grid == isGrid
                      ? colors.primary
                      : Colors.transparent,
                  foregroundColor: grid == isGrid
                      ? colors.onPrimary
                      : colors.onSurfaceVariant,
                ),
                onPressed: () => onChanged(isGrid),
                icon: Icon(
                  isGrid ? Icons.grid_view_rounded : Icons.view_list_rounded,
                  size: 18,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class CompactCatalogFilters extends StatelessWidget {
  const CompactCatalogFilters({
    super.key,
    required this.type,
    required this.platform,
    required this.platforms,
    required this.core,
    required this.source,
    required this.price,
    required this.onPlatformChanged,
    required this.onChanged,
    this.showClientFilters = true,
  });

  final ApplicationType? type;
  final bool showClientFilters;
  final String platform, core, source, price;
  final List<String> platforms;
  final ValueChanged<String> onPlatformChanged;
  final void Function(ApplicationType?, String, String, String) onChanged;

  @override
  Widget build(BuildContext context) {
    final clientFilters =
        showClientFilters && (type == null || type == ApplicationType.client);
    final platformLabel = platform == '全部'
        ? '平台'
        : platform == 'macOS'
        ? 'Mac'
        : platform;
    final coreLabel = usesMobileDesign(context) && core != '全部' ? core : '内核';
    final sourceLabel = usesMobileDesign(context) && source != '全部'
        ? source
        : '代码';
    final priceLabel = usesMobileDesign(context) && price != '全部'
        ? price
        : '价格';
    final menus = <CompactCatalogMenu<Object?>>[
      CompactCatalogMenu<ApplicationType?>(
        key: const ValueKey('catalog-type-menu'),
        label: type?.label ?? '应用',
        title: '应用类型',
        selected: type,
        values: [null, ...ApplicationType.values],
        active: type != null,
        labelFor: (value) => value?.label ?? '全部',
        optionKey: (value) => ValueKey('type-${value?.value ?? 'all'}'),
        onChanged: (value) => onChanged(value, '全部', '全部', '全部'),
      ),
      if (clientFilters) ...[
        CompactCatalogMenu<String>(
          key: const ValueKey('catalog-platform-menu'),
          label: platformLabel,
          title: '平台与设备',
          selected: platform,
          values: platforms,
          active: platform != '全部',
          labelFor: (value) => value == 'macOS' ? 'Mac' : value,
          optionKey: (value) => ValueKey('platform-option-$value'),
          onChanged: onPlatformChanged,
        ),
        CompactCatalogMenu<String>(
          key: const ValueKey('catalog-filter-内核'),
          label: coreLabel,
          title: '内核',
          selected: core,
          values: ['全部', ...catalogCorePaths.keys],
          active: core != '全部',
          labelFor: (value) => value,
          optionKey: (value) => ValueKey('filter-内核-$value'),
          optionTooltip: (value) =>
              value == '自研' ? '沿用网站“自研”分类，其中包含内核尚待核实的条目。' : null,
          onChanged: (value) => onChanged(type, value, source, price),
        ),
        CompactCatalogMenu<String>(
          key: const ValueKey('catalog-filter-代码状态'),
          label: sourceLabel,
          title: '代码状态',
          selected: source,
          values: catalogSources,
          active: source != '全部',
          labelFor: (value) => value,
          optionKey: (value) => ValueKey('filter-代码状态-$value'),
          onChanged: (value) => onChanged(type, core, value, price),
        ),
        CompactCatalogMenu<String>(
          key: const ValueKey('catalog-filter-价格'),
          label: priceLabel,
          title: '价格',
          selected: price,
          values: catalogPrices,
          active: price != '全部',
          labelFor: (value) => value,
          optionKey: (value) => ValueKey('filter-价格-$value'),
          onChanged: (value) => onChanged(type, core, source, value),
        ),
      ],
    ];
    if (!clientFilters) {
      return Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(width: 120, child: menus.single),
      );
    }
    return CompactCatalogFilterRow(menus: menus);
  }
}

class CompactCatalogFilterRow extends StatelessWidget {
  const CompactCatalogFilterRow({super.key, required this.menus});

  final List<CompactCatalogMenu<Object?>> menus;

  @override
  Widget build(BuildContext context) {
    if (menus.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final minimumWidth = menus
            .map((menu) => CompactCatalogMenu.widthOf(context, menu.label))
            .reduce((a, b) => a > b ? a : b);
        final availableWidth =
            (constraints.maxWidth - 6 * (menus.length - 1)) / menus.length;
        final menuWidth = availableWidth > minimumWidth
            ? availableWidth
            : minimumWidth;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            spacing: 6,
            children: [
              for (final menu in menus) SizedBox(width: menuWidth, child: menu),
            ],
          ),
        );
      },
    );
  }
}

class CompactCatalogMenu<T> extends StatelessWidget {
  const CompactCatalogMenu({
    super.key,
    required this.label,
    required this.title,
    required this.selected,
    required this.values,
    required this.labelFor,
    required this.optionKey,
    required this.onChanged,
    this.optionTooltip,
    this.tooltip,
    this.active = false,
    this.dense = false,
  });

  final String label, title;
  final String? tooltip;
  final T selected;
  final List<T> values;
  final String Function(T) labelFor;
  final Key Function(T) optionKey;
  final String? Function(T)? optionTooltip;
  final ValueChanged<T> onChanged;
  final bool active, dense;

  static double widthOf(BuildContext context, String label) {
    final text = TextPainter(
      text: TextSpan(
        text: label,
        style: DefaultTextStyle.of(context).style.merge(_labelStyle),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final width = text.width + 30;
    text.dispose();
    return width < 44 ? 44 : width;
  }

  static const _labelStyle = TextStyle(
    fontSize: 13,
    height: 18 / 13,
    fontWeight: FontWeight.w500,
  );

  Future<void> _show(BuildContext context) async {
    final result = usesMobileDesign(context)
        ? await _showPopup(context)
        : await showCatalogSelectionSheet<T>(
            context: context,
            title: title,
            selected: selected,
            values: values,
            labelFor: labelFor,
            optionKey: optionKey,
            optionTooltip: optionTooltip,
          );
    if (result != null && context.mounted) onChanged(result.value);
  }

  Future<({T value})?> _showPopup(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
    final anchor = context.findRenderObject() as RenderBox;
    RelativeRect positionOf() {
      final origin = anchor.localToGlobal(Offset.zero, ancestor: overlay);
      return RelativeRect.fromRect(
        Rect.fromLTWH(
          origin.dx,
          origin.dy + anchor.size.height + 6,
          anchor.size.width,
          0,
        ),
        Offset.zero & overlay.size,
      );
    }

    var position = positionOf();
    final selectedKey = GlobalKey();
    final result = showMenu<({T value})>(
      context: context,
      semanticLabel: title,
      positionBuilder: (_, _) {
        if (anchor.attached) position = positionOf();
        return position;
      },
      constraints: BoxConstraints(
        minWidth: 160,
        maxWidth: 280,
        maxHeight: MediaQuery.textScalerOf(context).scale(44) * 7.5 + 12,
      ),
      shape: surfaceShape(28),
      clipBehavior: Clip.antiAlias,
      elevation: 8,
      shadowColor: colors.scrim.withValues(alpha: .16),
      surfaceTintColor: Colors.transparent,
      color: theme.brightness == Brightness.dark
          ? colors.surfaceContainerHigh
          : colors.surfaceContainerLow,
      menuPadding: const EdgeInsets.all(6),
      items: [
        for (final value in values)
          PopupMenuItem<({T value})>(
            key: optionKey(value),
            value: (value: value),
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            textStyle: theme.textTheme.bodyMedium!.copyWith(
              fontSize: 15,
              height: 20 / 15,
              color: colors.onSurface,
            ),
            child: Tooltip(
              message: optionTooltip?.call(value) ?? labelFor(value),
              child: Semantics(
                key: value == selected ? selectedKey : null,
                selected: value == selected,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        labelFor(value),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 16),
                    if (value == selected)
                      Icon(Icons.check_rounded, size: 18, color: colors.primary)
                    else
                      const SizedBox(width: 18),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final selectedContext = selectedKey.currentContext;
      if (selectedContext != null) {
        Scrollable.ensureVisible(selectedContext, alignment: .5);
      }
    });
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final description = tooltip ?? '$title：${labelFor(selected)}';
    return Tooltip(
      message: description,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        label: description,
        excludeSemantics: true,
        onTap: () => _show(context),
        child: Material(
          color: SurfacePanel.raisedColor(context),
          shape: surfaceShape(1000),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => _show(context),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: dense ? 6 : 7,
                  vertical: 8,
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) => Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: _labelStyle.copyWith(color: colors.onSurface),
                        ),
                      ),
                      if (dense ||
                          constraints.maxWidth >=
                              MediaQuery.textScalerOf(context).scale(26) +
                                  16) ...[
                        const SizedBox(width: 2),
                        Icon(
                          Icons.expand_more_rounded,
                          size: 14,
                          color: active
                              ? colors.primary
                              : colors.onSurfaceVariant,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class CatalogSortTabs extends StatelessWidget {
  const CatalogSortTabs({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  final CatalogSort selected;
  final ValueChanged<CatalogSort> onChanged;

  static TextStyle _styleOf(BuildContext context) => Theme.of(context)
      .textTheme
      .labelLarge!
      .copyWith(
        fontSize: 13,
        height: 18 / 13,
        letterSpacing: 0,
        fontWeight: FontWeight.w600,
      );

  static double compactWidthOf(BuildContext context) {
    var width = 8.0;
    for (final value in CatalogSort.values) {
      final text = TextPainter(
        text: TextSpan(text: value.label, style: _styleOf(context)),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      width += text.width + 10;
      text.dispose();
    }
    return width;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: SurfacePanel.raisedColor(context),
      shape: surfaceShape(1000),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final value in CatalogSort.values)
              Semantics(
                selected: selected == value,
                child: TextButton(
                  key: ValueKey('sort-${value.name}'),
                  style: TextButton.styleFrom(
                    backgroundColor: selected == value
                        ? colors.primary
                        : Colors.transparent,
                    foregroundColor: selected == value
                        ? colors.onPrimary
                        : colors.onSurfaceVariant,
                    minimumSize: const Size(0, 36),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 6,
                    ),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    shape: surfaceShape(1000),
                    animationDuration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 200),
                    textStyle: _styleOf(context),
                  ),
                  onPressed: () => onChanged(value),
                  child: Text(value.label),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class CatalogSortControls extends StatelessWidget {
  const CatalogSortControls({
    super.key,
    required this.sort,
    required this.starPeriod,
    required this.starMetric,
    required this.onSortChanged,
    required this.onPeriodChanged,
    required this.onMetricChanged,
    this.trailing,
  });

  final CatalogSort sort;
  final CatalogStarPeriod starPeriod;
  final CatalogStarMetric starMetric;
  final ValueChanged<CatalogSort> onSortChanged;
  final ValueChanged<CatalogStarPeriod> onPeriodChanged;
  final ValueChanged<CatalogStarMetric> onMetricChanged;
  final Widget? trailing;

  double compactWidthOf(BuildContext context) =>
      (usesMobileDesign(context)
          ? CompactCatalogMenu.widthOf(context, sort.label)
          : CatalogSortTabs.compactWidthOf(context)) +
      (sort == CatalogSort.stars
          ? CompactCatalogMenu.widthOf(context, starPeriod.label) +
                CompactCatalogMenu.widthOf(context, starMetric.label) +
                12
          : 0);

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    final period = compact
        ? CompactCatalogMenu<CatalogStarPeriod>(
            key: const ValueKey('catalog-star-period-menu'),
            label: starPeriod.label,
            title: '新增 Star 周期',
            selected: starPeriod,
            values: CatalogStarPeriod.values,
            labelFor: (value) => value.label,
            optionKey: (value) => ValueKey('star-period-${value.name}'),
            optionTooltip: (value) => value == CatalogStarPeriod.today
                ? '最近一次采集对应的 GitHub 日期，并非本地当天的实时统计。'
                : null,
            onChanged: onPeriodChanged,
            dense: true,
          )
        : CatalogMenu<CatalogStarPeriod>(
            key: const ValueKey('catalog-star-period-menu'),
            label: starPeriod.label,
            tooltip: '新增 Star 周期：${starPeriod.label}',
            selected: starPeriod,
            values: CatalogStarPeriod.values,
            labelFor: (value) => value.label,
            optionKey: (value) => ValueKey('star-period-${value.name}'),
            optionTooltip: (value) => value == CatalogStarPeriod.today
                ? '最近一次采集对应的 GitHub 日期，并非本地当天的实时统计。'
                : null,
            onSelected: onPeriodChanged,
          );
    final metric = compact
        ? CompactCatalogMenu<CatalogStarMetric>(
            key: const ValueKey('catalog-star-metric-menu'),
            label: starMetric.label,
            title: '新增 Star 排序依据',
            selected: starMetric,
            values: CatalogStarMetric.values,
            labelFor: (value) => value.label,
            optionKey: (value) => ValueKey('star-metric-${value.name}'),
            onChanged: onMetricChanged,
            dense: true,
          )
        : CatalogMenu<CatalogStarMetric>(
            key: const ValueKey('catalog-star-metric-menu'),
            label: starMetric.label,
            tooltip: '新增 Star 排序依据：${starMetric.label}',
            selected: starMetric,
            values: CatalogStarMetric.values,
            labelFor: (value) => value.label,
            optionKey: (value) => ValueKey('star-metric-${value.name}'),
            onSelected: onMetricChanged,
          );
    if (compact) {
      return Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                spacing: 6,
                children: [
                  if (usesMobileDesign(context))
                    SizedBox(
                      width: CompactCatalogMenu.widthOf(context, sort.label),
                      child: CompactCatalogMenu<CatalogSort>(
                        key: const ValueKey('catalog-sort-menu'),
                        label: sort.label,
                        title: '排序方式',
                        selected: sort,
                        values: CatalogSort.values,
                        labelFor: (value) => value.label,
                        optionKey: (value) => ValueKey('sort-${value.name}'),
                        active: sort != CatalogSort.comprehensive,
                        onChanged: onSortChanged,
                      ),
                    )
                  else
                    CatalogSortTabs(selected: sort, onChanged: onSortChanged),
                  if (sort == CatalogSort.stars) ...[
                    SizedBox(
                      width: CompactCatalogMenu.widthOf(
                        context,
                        starPeriod.label,
                      ),
                      child: period,
                    ),
                    SizedBox(
                      width: CompactCatalogMenu.widthOf(
                        context,
                        starMetric.label,
                      ),
                      child: metric,
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        CatalogMenu<CatalogSort>(
          key: const ValueKey('catalog-sort-menu'),
          label: sort == CatalogSort.comprehensive ? '综合排序' : sort.label,
          tooltip: '排序方式：${sort.label}',
          selected: sort,
          active: sort != CatalogSort.comprehensive,
          values: CatalogSort.values,
          labelFor: (value) =>
              value == CatalogSort.comprehensive ? '综合排序' : value.label,
          optionKey: (value) => ValueKey('sort-${value.name}'),
          onSelected: onSortChanged,
        ),
        if (sort == CatalogSort.stars) ...[period, metric],
      ],
    );
  }
}

class CatalogToolbar extends StatelessWidget {
  const CatalogToolbar({
    super.key,
    required this.count,
    required this.sort,
    required this.grid,
    required this.onGridChanged,
    this.showViewSwitch = true,
  });

  final String? count;
  final Widget sort;
  final bool grid;
  final bool showViewSwitch;
  final ValueChanged<bool> onGridChanged;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final controls = Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (count != null) Flexible(child: CatalogResultCount(count!)),
          if (showViewSwitch) ...[
            if (count != null) const SizedBox(width: 8),
            CatalogViewSwitch(grid: grid, onChanged: onGridChanged),
          ],
        ],
      );
      if (constraints.maxWidth < MediaQuery.textScalerOf(context).scale(240)) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            sort,
            const SizedBox(height: 8),
            Align(alignment: Alignment.centerRight, child: controls),
          ],
        );
      }
      return Row(
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth / 2),
            child: sort,
          ),
          const SizedBox(width: 8),
          Expanded(child: controls),
        ],
      );
    },
  );
}

class CatalogResultCount extends StatelessWidget {
  const CatalogResultCount(this.label, {super.key});
  final String label;

  static TextStyle? _styleOf(BuildContext context) =>
      Theme.of(context).textTheme.bodySmall
          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);

  double widthOf(BuildContext context) {
    final text = TextPainter(
      text: TextSpan(text: label, style: _styleOf(context)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final width = text.width;
    text.dispose();
    return width;
  }

  @override
  Widget build(BuildContext context) => Tooltip(
    message: label,
    child: Text(
      label,
      textAlign: TextAlign.end,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: _styleOf(context),
    ),
  );
}

class CatalogFilterButton extends StatelessWidget {
  const CatalogFilterButton({
    super.key,
    required this.onPressed,
    this.count = 0,
    this.compact = false,
    this.tooltip = '筛选',
  });

  final VoidCallback onPressed;
  final int count;
  final bool compact;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (compact) {
      return Badge.count(
        count: count,
        isLabelVisible: count > 0,
        backgroundColor: colors.primary,
        child: IconButton.filledTonal(
          tooltip: '$tooltip${count == 0 ? '' : ' · $count 项'}',
          style: IconButton.styleFrom(
            minimumSize: const Size(48, 48),
            backgroundColor: SurfacePanel.raisedColor(context),
            foregroundColor: colors.onSurface,
            shape: surfaceShape(1000),
          ),
          onPressed: onPressed,
          icon: const Icon(Icons.tune_rounded, size: 20),
        ),
      );
    }
    return FilledButton.icon(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: colors.surfaceContainerLow,
        foregroundColor: colors.onSurface,
        shape: surfaceShape(1000),
        minimumSize: const Size(0, 40),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      ),
      icon: const Icon(Icons.tune_rounded, size: 18),
      label: Text(count == 0 ? '筛选' : '筛选 · $count'),
    );
  }
}

class CatalogFilterControls extends StatelessWidget {
  const CatalogFilterControls({
    super.key,
    required this.inline,
    required this.type,
    required this.platform,
    required this.platforms,
    required this.core,
    required this.source,
    required this.price,
    required this.onChanged,
    required this.onPlatformChanged,
    this.showType = true,
    this.showClientFilters = true,
    this.onReset,
    this.compact = false,
  });

  final bool inline, showType, showClientFilters, compact;
  final VoidCallback? onReset;
  final ApplicationType? type;
  final String platform, core, source, price;
  final List<String> platforms;
  final ValueChanged<String> onPlatformChanged;
  final void Function(
    ApplicationType? type,
    String core,
    String source,
    String price,
  )
  onChanged;
  bool get clientFilters =>
      showClientFilters && (type == null || type == ApplicationType.client);

  Widget _platformMenu({bool compact = false}) => CatalogMenu<String>(
    key: const ValueKey('catalog-platform-menu'),
    label: platform == '全部'
        ? '平台'
        : platform == 'macOS'
        ? 'Mac'
        : platform,
    tooltip: '平台与设备：${platform == 'macOS' ? 'Mac' : platform}',
    compact: compact,
    selected: platform,
    values: platforms,
    active: platform != '全部',
    labelFor: (value) => value == 'macOS' ? 'Mac' : value,
    optionKey: (value) => ValueKey('platform-option-$value'),
    onSelected: onPlatformChanged,
  );

  Widget _typeMenu(
    ApplicationType? selected,
    ValueChanged<ApplicationType?> select, {
    bool compact = false,
  }) => CatalogMenu<String>(
    key: const ValueKey('catalog-type-menu'),
    label: selected?.label ?? '应用',
    tooltip: '应用类型：${selected?.label ?? '全部'}',
    compact: compact,
    selected: selected?.value ?? 'all',
    values: ['all', ...ApplicationType.values.map((type) => type.value)],
    active: selected != null,
    labelFor: (value) => ApplicationType.fromValue(value)?.label ?? '全部',
    optionKey: (value) => ValueKey('type-$value'),
    onSelected: (value) => select(ApplicationType.fromValue(value)),
  );

  @override
  Widget build(BuildContext context) {
    if (inline) {
      return LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 600;
          final spacing = compact ? 6.0 : 8.0;
          final menuCount = (showType ? 1 : 0) + (clientFilters ? 4 : 0);
          final twoColumns =
              constraints.maxWidth <
              MediaQuery.textScalerOf(context).scale(90) * menuCount +
                  spacing * (menuCount - 1);
          Widget fit(Widget menu, {int weight = 4}) {
            if (!compact) return menu;
            final width = !clientFilters
                ? constraints.maxWidth
                : twoColumns
                ? (constraints.maxWidth - spacing) / 2
                // Give the longer code-status label more room in a single row.
                : (constraints.maxWidth - spacing * (menuCount - 1)) *
                      weight /
                      (showType ? 21 : 17);
            return ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: clientFilters && twoColumns ? width : 0,
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
              if (showType)
                fit(
                  _typeMenu(
                    type,
                    (value) => onChanged(value, '全部', '全部', '全部'),
                    compact: compact,
                  ),
                ),
              if (clientFilters) ...[
                fit(_platformMenu(compact: compact)),
                fit(
                  _menu(
                    context,
                    '内核',
                    ['全部', ...catalogCorePaths.keys],
                    core,
                    (value) => onChanged(type, value, source, price),
                    compact: compact,
                  ),
                ),
                fit(
                  _menu(
                    context,
                    '代码状态',
                    catalogSources,
                    source,
                    (value) => onChanged(type, core, value, price),
                    compact: compact,
                  ),
                  weight: 5,
                ),
                fit(
                  _menu(
                    context,
                    '价格',
                    catalogPrices,
                    price,
                    (value) => onChanged(type, core, source, value),
                    compact: compact,
                  ),
                ),
              ],
              if (onReset != null)
                TextButton(onPressed: onReset, child: const Text('重置筛选')),
            ],
          );
        },
      );
    }
    final active = [
      if (type != null) type!.label,
      core,
      source,
      price,
    ].where((value) => value != '全部').toList();
    final button = CatalogFilterButton(
      key: const ValueKey('catalog-filter-button'),
      onPressed: () => _showFilters(context),
      count: active.length,
      compact: compact,
      tooltip: active.isEmpty ? '筛选应用' : '筛选应用：${active.join(' · ')}',
    );
    if (compact) return button;
    return Row(
      children: [
        if (clientFilters) ...[_platformMenu(), const SizedBox(width: 8)],
        button,
        if (active.isNotEmpty) ...[
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              active.join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ],
    );
  }

  Widget _menu(
    BuildContext context,
    String label,
    List<String> values,
    String selected,
    ValueChanged<String> onSelected, {
    bool compact = false,
  }) => CatalogMenu<String>(
    key: ValueKey('catalog-filter-$label'),
    label: selected == '全部'
        ? label
        : usesMobileDesign(context)
        ? selected
        : '$label · $selected',
    tooltip: '$label筛选：$selected',
    compact: compact,
    selected: selected,
    values: values,
    active: selected != '全部',
    labelFor: (value) => value,
    optionKey: (value) => ValueKey('filter-$label-$value'),
    optionTooltip: (value) =>
        value == '自研' ? '沿用网站“自研”分类，其中包含内核尚待核实的条目。' : null,
    onSelected: onSelected,
  );

  Widget _chip(
    BuildContext context,
    String label,
    String value,
    String selected,
    ValueChanged<String> onSelected,
  ) {
    final chip = ChoiceChip(
      key: ValueKey('filter-$label-$value'),
      label: Text(value, style: const TextStyle(fontSize: 13)),
      shape: surfaceShape(1000),
      selectedColor: Theme.of(context).colorScheme.primary,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
      labelStyle: TextStyle(
        color: value == selected
            ? Theme.of(context).colorScheme.onPrimary
            : Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      selected: value == selected,
      visualDensity: usesMobileDesign(context)
          ? VisualDensity.standard
          : VisualDensity.compact,
      padding: EdgeInsets.symmetric(
        horizontal: usesMobileDesign(context) ? 10 : 6,
        vertical: usesMobileDesign(context) ? 8 : 5,
      ),
      onSelected: (_) => onSelected(value),
    );
    return value == '自研'
        ? Tooltip(message: '沿用网站“自研”分类，其中包含内核尚待核实的条目。', child: chip)
        : chip;
  }

  Future<void> _showFilters(BuildContext context) async {
    var nextType = type;
    var nextCore = core, nextSource = source, nextPrice = price;
    final confirmed = await showAdaptiveForm<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          Widget group(
            String label,
            List<String> values,
            String selected,
            ValueChanged<String> select,
          ) {
            final options = Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final value in values)
                  _chip(context, label, value, selected, select),
              ],
            );
            return Padding(
              padding: const EdgeInsets.only(bottom: 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  if (usesMobileDesign(context))
                    SurfacePanel(
                      radius: 24,
                      padding: const EdgeInsets.all(12),
                      child: SizedBox(width: double.infinity, child: options),
                    )
                  else
                    options,
                ],
              ),
            );
          }

          return AdaptiveDialog(
            title: '筛选应用',
            onReset: () => setState(() {
              nextType = null;
              nextCore = nextSource = nextPrice = '全部';
            }),
            content: SizedBox(
              width: 440,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('应用类型', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  _typeMenu(
                    nextType,
                    (value) => setState(() {
                      nextType = value;
                      nextCore = nextSource = nextPrice = '全部';
                    }),
                  ),
                  const SizedBox(height: 18),
                  if (nextType == null && showClientFilters ||
                      nextType == ApplicationType.client) ...[
                    group(
                      '内核',
                      ['全部', ...catalogCorePaths.keys],
                      nextCore,
                      (value) => setState(() => nextCore = value),
                    ),
                    group(
                      '代码状态',
                      catalogSources,
                      nextSource,
                      (value) => setState(() => nextSource = value),
                    ),
                    group(
                      '价格',
                      catalogPrices,
                      nextPrice,
                      (value) => setState(() => nextPrice = value),
                    ),
                  ],
                ],
              ),
            ),
            actions: DialogActionsRow(
              confirmLabel: '确认',
              onCancel: () => Navigator.pop(context, false),
              onConfirm: () => Navigator.pop(context, true),
            ),
          );
        },
      ),
    );
    if (confirmed == true) onChanged(nextType, nextCore, nextSource, nextPrice);
  }
}
