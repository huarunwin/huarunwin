import 'package:flutter/material.dart';

import 'page_bar.dart';
import 'theme.dart';

Future<T?> showAdaptiveForm<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool enableDrag = true,
}) {
  if (MediaQuery.sizeOf(context).width < 600) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: false,
      enableDrag: enableDrag,
      builder: builder,
    );
  }
  return showDialog<T>(context: context, builder: builder);
}

class AdaptiveDialog extends StatelessWidget {
  const AdaptiveDialog({
    super.key,
    required this.title,
    required this.content,
    required this.actions,
    this.onReset,
    this.scrollable = true,
    this.showDragHandle = true,
  });

  final String title;
  final Widget content, actions;
  final VoidCallback? onReset;
  final bool scrollable;
  final bool showDragHandle;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 600;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final background = compact
        ? theme.bottomSheetTheme.backgroundColor ?? colors.surface
        : theme.dialogTheme.backgroundColor ?? colors.surface;
    Widget body = content;
    if (theme.brightness == Brightness.dark) {
      Color raised(Color base) =>
          Color.alphaBlend(colors.onSurface.withValues(alpha: .06), base);
      final panel = raised(background);
      final block = raised(panel);
      final inset = raised(block);
      body = Theme(
        data: theme.copyWith(
          colorScheme: colors.copyWith(
            surfaceContainerLow: panel,
            surfaceContainer: block,
            surfaceContainerHigh: inset,
            surfaceContainerHighest: inset,
          ),
        ),
        child: content,
      );
    }
    final heading = Row(
      children: [
        Expanded(
          child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
        if (onReset != null)
          PageBarButton(
            backgroundColor: background,
            child: IconButton(
              tooltip: '重置筛选',
              onPressed: onReset,
              icon: const Icon(Icons.restart_alt_rounded),
            ),
          ),
      ],
    );
    if (!compact) {
      return AlertDialog(
        title: heading,
        scrollable: scrollable,
        content: body,
        actions: [actions],
      );
    }
    final media = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight:
              media.size.height - media.padding.top - media.viewInsets.bottom,
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (showDragHandle)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 10, bottom: 6),
                    child: DecoratedBox(
                      decoration: ShapeDecoration(
                        color: colors.onSurface.withValues(alpha: .2),
                        shape: surfaceShape(1000),
                      ),
                      child: const SizedBox(width: 32, height: 4),
                    ),
                  ),
                ),
              Padding(
                padding: EdgeInsets.fromLTRB(
                  20,
                  showDragHandle ? 4 : 20,
                  12,
                  12,
                ),
                child: DefaultTextStyle(
                  style: Theme.of(context).textTheme.titleLarge!,
                  child: heading,
                ),
              ),
              Flexible(
                child: scrollable
                    ? SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                        child: body,
                      )
                    : Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: body,
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: actions,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
