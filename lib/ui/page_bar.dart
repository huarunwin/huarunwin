import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'theme.dart';

Color _buttonFill(BuildContext context, Color? backgroundColor) {
  final theme = Theme.of(context);
  final colors = theme.colorScheme;
  final background =
      backgroundColor ??
      Scaffold.maybeOf(context)?.widget.backgroundColor ??
      theme.scaffoldBackgroundColor;
  if (theme.brightness == Brightness.dark) {
    return Color.alphaBlend(
      colors.onSurface.withValues(alpha: .08),
      background,
    );
  }
  return background == colors.surfaceContainerLow
      ? colors.surfaceContainer
      : colors.surfaceContainerLow;
}

bool _enabled(Widget action) => switch (action) {
  IconButton(:final onPressed) => onPressed != null,
  RefreshIconButton(:final loading) => !loading,
  PopupMenuButton<dynamic>(:final enabled) => enabled,
  _ => true,
};

class PageBarButton extends StatelessWidget {
  const PageBarButton({super.key, this.backgroundColor, required this.child});

  final Color? backgroundColor;
  final Widget child;

  @override
  Widget build(BuildContext context) => _BarPressFeedback(
    enabled: _enabled(child),
    child: _BarButtonTheme(backgroundColor: backgroundColor, child: child),
  );
}

class PageBarActions extends StatelessWidget {
  const PageBarActions({
    super.key,
    this.backgroundColor,
    required this.actions,
  });

  final Color? backgroundColor;
  final List<Widget> actions;

  static List<Widget> visibleActions(
    BuildContext context,
    List<Widget> actions,
  ) => [
    for (final action in actions)
      if (action is! RefreshIconButton || !usesMobileDesign(context)) action,
  ];

  @override
  Widget build(BuildContext context) {
    final visible = visibleActions(context, actions);
    if (visible.isEmpty) return const SizedBox.shrink();
    final group = visible.length > 1 ? visible.take(2).toList() : <Widget>[];
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [
        if (group.isNotEmpty)
          _BarPressFeedback(
            enabled: group.any(_enabled),
            child: _BarButtonTheme(
              grouped: true,
              child: Stack(
                children: [
                  Positioned.fill(
                    left: 2,
                    top: 2,
                    right: 2,
                    bottom: 2,
                    child: DecoratedBox(
                      decoration: ShapeDecoration(
                        color: _buttonFill(context, backgroundColor),
                        shape: surfaceShape(1000),
                      ),
                    ),
                  ),
                  Row(mainAxisSize: MainAxisSize.min, children: group),
                ],
              ),
            ),
          ),
        for (final action in visible.skip(group.length))
          PageBarButton(backgroundColor: backgroundColor, child: action),
      ],
    );
  }
}

class _BarButtonTheme extends StatelessWidget {
  const _BarButtonTheme({
    this.backgroundColor,
    this.grouped = false,
    required this.child,
  });

  final Color? backgroundColor;
  final bool grouped;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final fill = grouped
        ? Colors.transparent
        : _buttonFill(context, backgroundColor);
    final style =
        IconButton.styleFrom(
          fixedSize: const Size.square(44),
          minimumSize: const Size.square(44),
          padding: EdgeInsets.zero,
          iconSize: 24,
          backgroundColor: fill,
          disabledBackgroundColor: fill,
          foregroundColor: colors.onSurface,
          disabledForegroundColor: colors.onSurface.withValues(alpha: .38),
          shape: surfaceShape(1000),
          visualDensity: VisualDensity.standard,
          tapTargetSize: MaterialTapTargetSize.padded,
          splashFactory: NoSplash.splashFactory,
        ).copyWith(
          overlayColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return Colors.transparent;
            }
            if (states.contains(WidgetState.pressed)) {
              return colors.onSurface.withValues(alpha: .06);
            }
            if (states.contains(WidgetState.focused)) {
              return colors.primary.withValues(alpha: .10);
            }
            if (states.contains(WidgetState.hovered)) {
              return colors.onSurface.withValues(alpha: .06);
            }
            return Colors.transparent;
          }),
          side: WidgetStateProperty.resolveWith(
            (states) =>
                states.contains(WidgetState.focused) &&
                    !states.contains(WidgetState.disabled)
                ? BorderSide(color: colors.primary, width: 1.5)
                : BorderSide.none,
          ),
        );
    return IconButtonTheme(
      data: IconButtonThemeData(style: style),
      child: IconTheme.merge(
        data: IconThemeData(size: 24, color: colors.onSurface),
        child: child,
      ),
    );
  }
}

class _BarPressFeedback extends StatefulWidget {
  const _BarPressFeedback({required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  @override
  State<_BarPressFeedback> createState() => _BarPressFeedbackState();
}

class _BarPressFeedbackState extends State<_BarPressFeedback> {
  int? _pointer;

  @override
  void didUpdateWidget(covariant _BarPressFeedback oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _pointer = null;
  }

  void _release(PointerEvent event) {
    if (_pointer == event.pointer) setState(() => _pointer = null);
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Listener(
      onPointerDown: widget.enabled
          ? (event) {
              if (_pointer == null && event.buttons & kPrimaryButton != 0) {
                setState(() => _pointer = event.pointer);
              }
            }
          : null,
      onPointerUp: _release,
      onPointerCancel: _release,
      child: AnimatedScale(
        scale: !reduceMotion && _pointer != null ? .94 : 1,
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}

class RefreshIconButton extends StatelessWidget {
  const RefreshIconButton({
    super.key,
    required this.loading,
    required this.onPressed,
    this.tooltip = '刷新内容',
  });

  final bool loading;
  final VoidCallback onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) => usesMobileDesign(context)
      ? const SizedBox.shrink()
      : IconButton(
          tooltip: tooltip,
          onPressed: loading ? null : onPressed,
          icon: loading
              ? SizedBox.square(
                  dimension: 24,
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      semanticsLabel: '正在刷新',
                    ),
                  ),
                )
              : const Icon(Icons.refresh_rounded),
        );
}
