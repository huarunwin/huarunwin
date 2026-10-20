import 'package:flutter/material.dart';

import 'page_components.dart';
import 'page_bar.dart';
import 'theme.dart';

Future<({T value})?> showCatalogSelectionSheet<T>({
  required BuildContext context,
  required String title,
  required T selected,
  required List<T> values,
  required String Function(T) labelFor,
  required Key Function(T) optionKey,
  String? Function(T)? optionTooltip,
}) => showModalBottomSheet<({T value})>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: false,
  barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: .32),
  builder: (_) => _CatalogSelectionSheet<T>(
    title: title,
    selected: selected,
    values: values,
    labelFor: labelFor,
    optionKey: optionKey,
    optionTooltip: optionTooltip,
  ),
);

class _CatalogSelectionSheet<T> extends StatefulWidget {
  const _CatalogSelectionSheet({
    required this.title,
    required this.selected,
    required this.values,
    required this.labelFor,
    required this.optionKey,
    this.optionTooltip,
  });

  final String title;
  final T selected;
  final List<T> values;
  final String Function(T) labelFor;
  final Key Function(T) optionKey;
  final String? Function(T)? optionTooltip;

  @override
  State<_CatalogSelectionSheet<T>> createState() =>
      _CatalogSelectionSheetState<T>();
}

class _CatalogSelectionSheetState<T> extends State<_CatalogSelectionSheet<T>> {
  final _search = TextEditingController();
  final _selectedKey = GlobalKey();
  late T _draft = widget.selected;
  var _revealRequested = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _revealSelected() {
    if (_revealRequested) return;
    _revealRequested = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _selectedKey.currentContext;
      if (mounted && target != null) {
        Scrollable.ensureVisible(
          target,
          alignment: .5,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final background = theme.bottomSheetTheme.backgroundColor ?? colors.surface;
    final panel = theme.brightness == Brightness.dark
        ? Color.alphaBlend(colors.onSurface.withValues(alpha: .06), background)
        : colors.surfaceContainerLow;
    final query = _search.text.trim().toLowerCase();
    final values = widget.values
        .where((value) => widget.labelFor(value).toLowerCase().contains(query))
        .toList();
    final searchable = widget.values.length >= 10;
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final bodyStyle = theme.textTheme.bodyLarge!.copyWith(
      fontSize: 17,
      height: 22 / 17,
      letterSpacing: 0,
      color: colors.onSurface,
    );
    _revealSelected();

    Widget content(
      ScrollController? controller, {
      required bool fillsHeight,
    }) => SafeArea(
      top: false,
      child: Column(
        mainAxisSize: fillsHeight ? MainAxisSize.max : MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: colors.onSurfaceVariant,
                shape: surfaceShape(1000),
              ),
              child: const SizedBox(width: 28, height: 4),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Row(
                children: [
                  const SizedBox(width: 48),
                  Expanded(
                    child: Text(
                      widget.title,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: bodyStyle.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  PageBarButton(
                    backgroundColor: background,
                    child: IconButton(
                      tooltip: '关闭筛选',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Flexible(
            fit: fillsHeight ? FlexFit.tight : FlexFit.loose,
            child: SingleChildScrollView(
              controller: controller,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
              child: values.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 28),
                      child: Text(
                        '没有匹配的选项',
                        style: bodyStyle.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    )
                  : Material(
                      color: panel,
                      shape: surfaceShape(24),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final (index, value) in values.indexed) ...[
                            if (index > 0)
                              Divider(
                                height: 0,
                                thickness:
                                    1 / MediaQuery.devicePixelRatioOf(context),
                                indent: 16,
                                endIndent: 14,
                                color: colors.onSurface.withValues(alpha: .14),
                              ),
                            KeyedSubtree(
                              key: value == widget.selected
                                  ? _selectedKey
                                  : null,
                              child: Tooltip(
                                message:
                                    widget.optionTooltip?.call(value) ??
                                    widget.labelFor(value),
                                child: Semantics(
                                  selected: _draft == value,
                                  child: ListTile(
                                    key: widget.optionKey(value),
                                    minTileHeight: 56,
                                    minVerticalPadding: 10,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                    ),
                                    titleTextStyle: bodyStyle,
                                    title: Text(
                                      widget.labelFor(value),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    trailing: _draft == value
                                        ? Icon(
                                            Icons.check_rounded,
                                            size: 24,
                                            color: colors.primary,
                                          )
                                        : null,
                                    onTap: () => setState(() => _draft = value),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (searchable) ...[
                  Material(
                    color: panel,
                    elevation: 3,
                    shadowColor: colors.scrim.withValues(alpha: .12),
                    shape: surfaceShape(1000),
                    clipBehavior: Clip.antiAlias,
                    child: TextField(
                      key: const ValueKey('catalog-selection-search'),
                      controller: _search,
                      onChanged: (_) => setState(() {}),
                      style: bodyStyle,
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: '搜索${widget.title}',
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        prefixIcon: const Icon(Icons.search_rounded, size: 22),
                        suffixIcon: query.isEmpty
                            ? null
                            : IconButton(
                                tooltip: '清除搜索',
                                onPressed: () => setState(_search.clear),
                                icon: const Icon(Icons.close_rounded, size: 20),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                DialogActionsRow(
                  confirmLabel: '确认',
                  onCancel: () => Navigator.pop(context),
                  onConfirm: () => Navigator.pop(context, (value: _draft)),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    return Padding(
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: widget.values.length > 6
          ? DraggableScrollableSheet(
              expand: false,
              initialChildSize: keyboardInset > 0 ? .9 : 9 / 16,
              minChildSize: keyboardInset > 0 ? .9 : 9 / 16,
              maxChildSize: .9,
              snap: true,
              builder: (context, controller) =>
                  content(controller, fillsHeight: true),
            )
          : content(null, fillsHeight: false),
    );
  }
}
