import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'mac_window.dart';
import 'page_bar.dart';
import 'theme.dart';

class PageSafeArea extends StatelessWidget {
  const PageSafeArea({super.key, this.bottom = true, required this.child});

  final bool bottom;
  final Widget child;

  // Mobile top insets scroll with the content. Mac window controls retain their
  // fixed safe area, including when the window is narrow.
  static double topInsetOf(BuildContext context) =>
      usesMobileDesign(context) && !hasMacWindowControls
      ? MediaQuery.paddingOf(context).top
      : 0;

  @override
  Widget build(BuildContext context) => SafeArea(
    top: hasMacWindowControls || !usesMobileDesign(context),
    bottom: bottom,
    child: child,
  );
}

class PageRefreshIndicator extends StatelessWidget {
  const PageRefreshIndicator({
    super.key,
    required this.onRefresh,
    required this.child,
  });

  final AsyncCallback onRefresh;
  final Widget child;

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    edgeOffset: PageSafeArea.topInsetOf(context),
    notificationPredicate: (notification) =>
        usesMobileDesign(context) &&
        defaultScrollNotificationPredicate(notification),
    onRefresh: onRefresh,
    child: child,
  );
}

class PageBottomInset extends InheritedWidget {
  const PageBottomInset({super.key, required this.inset, required super.child});

  final double inset;

  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PageBottomInset>()?.inset ?? 0;

  @override
  bool updateShouldNotify(PageBottomInset oldWidget) =>
      inset != oldWidget.inset;
}

class SurfacePanel extends StatelessWidget {
  const SurfacePanel({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.radius,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double? radius;

  static Color raisedColor(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return switch (_SurfaceDepth.of(context)) {
      0 => colors.surfaceContainerLow,
      1 => colors.surfaceContainer,
      _ => colors.surfaceContainerHigh,
    };
  }

  @override
  Widget build(BuildContext context) => Material(
    color: raisedColor(context),
    shape: surfaceShape(radius ?? (usesMobileDesign(context) ? 34 : 20)),
    clipBehavior: Clip.antiAlias,
    child: _SurfaceDepth(
      depth: _SurfaceDepth.of(context) + 1,
      child: Padding(padding: padding, child: child),
    ),
  );
}

class _SurfaceDepth extends InheritedWidget {
  const _SurfaceDepth({required this.depth, required super.child});
  final int depth;

  static int of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SurfaceDepth>()?.depth ?? 0;

  @override
  bool updateShouldNotify(_SurfaceDepth oldWidget) => depth != oldWidget.depth;
}

class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    this.actions = const [],
    this.showBackButton = false,
    this.titleStyle,
  });

  final String title;
  final List<Widget> actions;
  final bool showBackButton;
  final TextStyle? titleStyle;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 600;
      final theme = Theme.of(context);
      final visibleActions = PageBarActions.visibleActions(context, actions);
      return Padding(
        padding: EdgeInsets.only(bottom: compact ? 16 : 20),
        // Match the action touch target even when this page has no buttons.
        // A minimum still lets wrapped titles and larger text grow naturally.
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: kMinInteractiveDimension,
          ),
          child: Row(
            children: [
              if (showBackButton && Navigator.canPop(context)) ...[
                PageBarButton(
                  child: IconButton(
                    tooltip: MaterialLocalizations.of(context)
                        .backButtonTooltip,
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: Icon(
                      Directionality.of(context) == TextDirection.rtl
                          ? Icons.chevron_right_rounded
                          : Icons.chevron_left_rounded,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  title,
                  style: (titleStyle ?? theme.textTheme.headlineSmall)
                      ?.copyWith(
                        fontSize: compact ? 24 : null,
                        height: usesMobileDesign(context) ? 30 / 24 : null,
                        letterSpacing: usesMobileDesign(context) ? 0 : null,
                        fontWeight: FontWeight.w700,
                      ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (visibleActions.isNotEmpty) ...[
                const SizedBox(width: 8),
                PageBarActions(actions: visibleActions),
              ],
            ],
          ),
        ),
      );
    },
  );
}

class ContentPage extends StatefulWidget {
  const ContentPage({
    super.key,
    required this.title,
    required this.children,
    this.showBackButton = false,
    this.onRefresh,
  });

  final String title;
  final List<Widget> children;
  final bool showBackButton;
  final AsyncCallback? onRefresh;

  @override
  State<ContentPage> createState() => _ContentPageState();
}

class _ContentPageState extends State<ContentPage> {
  Future<void> _refresh() async {
    await widget.onRefresh?.call();
    // Static overview and bundled text pages only need to render local content.
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1040),
      child: LayoutBuilder(
        builder: (context, size) => PageRefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.fromLTRB(
              size.maxWidth < 600 ? 16 : 32,
              (size.maxWidth < 600 ? 16 : 28) +
                  PageSafeArea.topInsetOf(context),
              size.maxWidth < 600 ? 16 : 32,
              32 + PageBottomInset.of(context),
            ),
            children: [
              PageHeader(
                title: widget.title,
                showBackButton: widget.showBackButton,
              ),
              ...widget.children,
            ],
          ),
        ),
      ),
    ),
  );
}

class PageSection extends StatelessWidget {
  const PageSection({
    super.key,
    this.title,
    required this.children,
    this.footer,
    this.dividerIndent = 60,
    this.bottomSpacing = 22,
  });

  final String? title;
  final List<Widget> children;
  final String? footer;
  final double dividerIndent;
  final double bottomSpacing;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomSpacing),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
              child: Text(
                title!,
                style: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          SurfacePanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var index = 0; index < children.length; index++) ...[
                  if (index > 0)
                    Divider(
                      height: 1,
                      thickness: 1 / MediaQuery.devicePixelRatioOf(context),
                      indent: dividerIndent,
                      endIndent: 16,
                    ),
                  children[index],
                ],
              ],
            ),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                footer!,
                style: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class IconWell extends StatelessWidget {
  const IconWell(this.icon, {super.key, this.size = 32});
  final IconData icon;
  final double size;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: ShapeDecoration(
      shape: surfaceShape(10),
      color: SurfacePanel.raisedColor(context),
    ),
    child: SizedBox.square(
      dimension: size,
      child: Icon(
        icon,
        size: size * .56,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

class PageRow extends StatelessWidget {
  const PageRow({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.leading,
    this.trailing,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget? leading, trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    minTileHeight: 56,
    horizontalTitleGap: 12,
    leading: leading ?? (icon == null ? null : IconWell(icon!)),
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle!),
    trailing: trailing,
    onTap: onTap,
  );
}

class DialogActionsRow extends StatelessWidget {
  const DialogActionsRow({
    super.key,
    this.cancelLabel = '取消',
    required this.confirmLabel,
    required this.onCancel,
    required this.onConfirm,
    this.destructive = false,
    this.busy = false,
  });

  final String cancelLabel, confirmLabel;
  final VoidCallback? onCancel;
  final VoidCallback? onConfirm;
  final bool destructive, busy;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        Expanded(
          child: FilledButton(
            onPressed: busy ? null : onCancel,
            style: FilledButton.styleFrom(
              backgroundColor:
                  usesMobileDesign(context) ||
                      Theme.of(context).brightness == Brightness.dark
                  ? colors.surfaceContainerHighest
                  : colors.surfaceContainer,
              foregroundColor: colors.onSurface,
              minimumSize: const Size(0, 46),
            ),
            child: Text(cancelLabel, textAlign: TextAlign.center),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: FilledButton(
            onPressed: busy ? null : onConfirm,
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 46),
              backgroundColor: destructive ? colors.error : null,
              foregroundColor: destructive ? colors.onError : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (busy && (ModalRoute.isCurrentOf(context) ?? true)) ...[
                  const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Text(confirmLabel, textAlign: TextAlign.center),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
