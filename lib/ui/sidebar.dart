import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'mac_window.dart';
import 'page_components.dart';
import 'theme.dart';

class AppSidebar extends StatefulWidget {
  const AppSidebar({
    super.key,
    required this.expanded,
    required this.onToggle,
    required this.entries,
    required this.footer,
  });

  final bool expanded;
  final VoidCallback onToggle;
  final List<Widget> entries, footer;

  @override
  State<AppSidebar> createState() => _AppSidebarState();
}

class _AppSidebarState extends State<AppSidebar> {
  final _scroll = ScrollController();
  bool _fadeTop = false, _fadeBottom = false;

  void _updateEdges() {
    if (!mounted || !_scroll.hasClients) return;
    final position = _scroll.position;
    final top = position.extentBefore > 1;
    final bottom = position.extentAfter > 1;
    if (_fadeTop == top && _fadeBottom == bottom) return;
    setState(() {
      _fadeTop = top;
      _fadeBottom = bottom;
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final chrome = Color.alphaBlend(
      colors.onSurface.withValues(alpha: 0.04),
      colors.surface,
    );
    return TweenAnimationBuilder<double>(
      tween: Tween(end: widget.expanded ? 1 : 0),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOutCubic,
      builder: (context, progress, _) => _SidebarPresentation(
        progress: progress,
        child: SizedBox(
          width: 80 + 140 * progress,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: chrome,
              border: BorderDirectional(
                end: BorderSide(
                  color: colors.onSurface.withValues(alpha: 0.14),
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  height:
                      (hasMacWindowControls ? 32 : 16) +
                      PageSafeArea.topInsetOf(context),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: SizedBox(
                    height:
                        48.0 +
                        math.max(
                          0.0,
                          MediaQuery.textScalerOf(context).scale(16) - 16,
                        ),
                    child: ClipRect(
                      child: OverflowBox(
                        alignment: AlignmentDirectional.centerStart,
                        minWidth: 196,
                        maxWidth: 196,
                        child: Row(
                          children: [
                            SizedBox(
                              width: 56,
                              child: IconButton(
                                tooltip: widget.expanded ? '收起侧边栏' : '展开侧边栏',
                                onPressed: widget.onToggle,
                                style: IconButton.styleFrom(
                                  shape: surfaceShape(10),
                                  foregroundColor: colors.onSurfaceVariant,
                                ),
                                icon: const Icon(
                                  Icons.view_sidebar_outlined,
                                  size: 22,
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Opacity(
                                opacity: progress,
                                child: ExcludeSemantics(
                                  excluding: progress < 0.5,
                                  child: Row(
                                    children: [
                                      Image.asset(
                                        'assets/brand/huarun-icon.png',
                                        width: 28,
                                        height: 28,
                                        excludeFromSemantics: true,
                                      ),
                                      const SizedBox(width: 8),
                                      const Expanded(
                                        child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              '华润赢',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 16,
                                                height: 1.1,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                            Text(
                                              'HUARUN WIN',
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 7,
                                                height: 1.1,
                                                letterSpacing: 1.2,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: Stack(
                    children: [
                      NotificationListener<ScrollMetricsNotification>(
                        onNotification: (_) {
                          WidgetsBinding.instance.addPostFrameCallback(
                            (_) => _updateEdges(),
                          );
                          return false;
                        },
                        child: NotificationListener<ScrollNotification>(
                          onNotification: (_) {
                            _updateEdges();
                            return false;
                          },
                          child: ListView(
                            key: const PageStorageKey('sidebar-navigation'),
                            controller: _scroll,
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            children: widget.entries,
                          ),
                        ),
                      ),
                      for (final top in [true, false])
                        PositionedDirectional(
                          start: 0,
                          end: 0,
                          top: top ? 0 : null,
                          bottom: top ? null : 0,
                          height: 12,
                          child: IgnorePointer(
                            child: AnimatedOpacity(
                              duration: const Duration(milliseconds: 120),
                              opacity: (top ? _fadeTop : _fadeBottom) ? 1 : 0,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: top
                                        ? Alignment.topCenter
                                        : Alignment.bottomCenter,
                                    end: top
                                        ? Alignment.bottomCenter
                                        : Alignment.topCenter,
                                    colors: [
                                      chrome,
                                      chrome.withValues(alpha: 0),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  child: Divider(
                    height: 1,
                    color: colors.onSurface.withValues(alpha: 0.12),
                  ),
                ),
                ...widget.footer,
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarPresentation extends InheritedWidget {
  const _SidebarPresentation({required this.progress, required super.child});

  final double progress;

  @override
  bool updateShouldNotify(_SidebarPresentation oldWidget) =>
      progress != oldWidget.progress;
}

class SidebarItem extends StatefulWidget {
  const SidebarItem({
    super.key,
    required this.title,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.nested = false,
    this.count = 0,
  });

  final String title;
  final IconData icon;
  final bool selected, nested;
  final int count;
  final VoidCallback onTap;

  @override
  State<SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<SidebarItem> {
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final progress = context
        .dependOnInheritedWidgetOfExactType<_SidebarPresentation>()!
        .progress;
    final inset = widget.nested ? 12 * progress : 0.0;
    final height =
        40.0 + math.max(0.0, MediaQuery.textScalerOf(context).scale(14) - 14);
    final shape = surfaceShape(10);
    final labelStyle = DefaultTextStyle.of(context).style.copyWith(
      fontSize: 14,
      height: 1.2,
      color: colors.onSurface,
      fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w400,
    );
    final label = TextPainter(
      text: TextSpan(text: widget.title, style: labelStyle),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final countWidth = widget.count > 0 ? 28.0 : 0.0;
    final labelWidth = 196 - inset - 56 - 12 - countWidth;
    final showTooltip = progress < 1 || label.width > labelWidth;
    label.dispose();
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(12 + inset, 2, 12, 2),
      child: FocusableActionDetector(
        onShowFocusHighlight: (value) => setState(() => _focus = value),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          foregroundDecoration: ShapeDecoration(
            shape: shape.copyWith(
              side: _focus
                  ? BorderSide(color: colors.primary, width: 2)
                  : BorderSide.none,
            ),
          ),
          child: Material(
            color: widget.selected
                ? colors.onSurface.withValues(alpha: 0.08)
                : Colors.transparent,
            shape: shape,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: widget.onTap,
              canRequestFocus: false,
              customBorder: shape,
              splashFactory: NoSplash.splashFactory,
              overlayColor: WidgetStateProperty.resolveWith(
                (states) => colors.onSurface.withValues(
                  alpha: states.contains(WidgetState.pressed) ? 0.06 : 0.04,
                ),
              ),
              child: Tooltip(
                message: showTooltip ? widget.title : '',
                excludeFromSemantics: true,
                child: SizedBox(
                  height: height,
                  child: Stack(
                    children: [
                      ClipRect(
                        child: OverflowBox(
                          alignment: AlignmentDirectional.centerStart,
                          minWidth: 196 - inset,
                          maxWidth: 196 - inset,
                          child: Row(
                            children: [
                              SizedBox(
                                width: 56,
                                child: Icon(
                                  widget.icon,
                                  size: 22,
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                              Expanded(
                                child: Opacity(
                                  opacity: ((progress - 0.35) / 0.65).clamp(
                                    0.0,
                                    1.0,
                                  ),
                                  alwaysIncludeSemantics: true,
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          widget.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: labelStyle,
                                        ),
                                      ),
                                      if (widget.count > 0)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            left: 4,
                                          ),
                                          child: Text(
                                            '${widget.count}',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: colors.primary,
                                            ),
                                          ),
                                        ),
                                      const SizedBox(width: 12),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      PositionedDirectional(
                        start: 0,
                        top: (height - 16) / 2,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          width: 3,
                          height: widget.selected ? 16 : 0,
                          decoration: ShapeDecoration(
                            color: colors.primary,
                            shape: surfaceShape(1000),
                          ),
                        ),
                      ),
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
