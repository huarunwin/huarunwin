import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../data/models.dart';
import 'components.dart';
import 'page_bar.dart';
import 'theme.dart';

class AppDetailHero extends StatelessWidget {
  const AppDetailHero({
    super.key,
    required this.app,
    required this.action,
    this.compact = false,
  });

  final CatalogApp app;
  final Widget action;
  final bool compact;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final colors = Theme.of(context).colorScheme;
      final heading = Text(
        app.name,
        maxLines: compact ? 3 : null,
        overflow: compact ? TextOverflow.ellipsis : null,
        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
          fontSize: compact ? 22 : 30,
          height: compact ? 27 / 22 : null,
          fontWeight: compact ? FontWeight.w600 : null,
        ),
      );
      final description = Text(
        app.description,
        maxLines: compact ? 3 : 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: colors.onSurfaceVariant, height: 1.4),
      );
      if (compact) {
        final iconSize = (constraints.maxWidth * .3).clamp(88.0, 140.0);
        final category = [
          app.type.label,
          if (app.isClient && app.core.isNotEmpty) app.core,
        ].join(' · ');
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppIcon(app, size: iconSize),
            const SizedBox(width: 16),
            Expanded(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: iconSize),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Tooltip(message: app.name, child: heading),
                        const SizedBox(height: 4),
                        Text(
                          category,
                          style: TextStyle(
                            fontSize: 14,
                            height: 20 / 14,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: action,
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppIcon(app, size: 112),
          const SizedBox(width: 26),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                heading,
                if (app.description.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  description,
                ],
                const SizedBox(height: 16),
                action,
              ],
            ),
          ),
        ],
      );
    },
  );
}

class AppDetailMetadata extends StatelessWidget {
  const AppDetailMetadata({
    super.key,
    required this.detail,
    this.compact = false,
  });
  final AppDetails detail;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final app = detail.app;
    final values = <String, String?>{
      if (compact && app.starCount != null)
        'GitHub Star': app.starCount.toString(),
      if (compact && app.ratingCount != null) '评分数': app.ratingCount.toString(),
      if (!compact) ...{
        '应用类型': app.type.label,
        detail.versionLabel: detail.version,
        '最近更新': detail.updatedAt,
      },
      if (!app.isClient)
        app.type.environmentLabel: app.environments.isEmpty
            ? null
            : app.environments.join(' · '),
      if (app.isClient) ...{
        '支持平台': app.platforms.isEmpty ? null : app.platforms.join(' · '),
        '主导开发': detail.facts['主导开发'],
        '内核': app.core.isNotEmpty ? app.core : detail.facts['代理内核'],
        '代码状态': app.source.isNotEmpty ? app.source : detail.facts['代码状态'],
      },
      if (compact) '应用类型': app.type.label,
    }..removeWhere((_, value) => value == null || value.trim().isEmpty);
    return DetailMetadata(
      values: values,
      compact: compact,
      tooltips: {
        if (app.starNote != null) 'GitHub Star': app.starNote!,
        if (app.ratingNote != null) '评分数': app.ratingNote!,
      },
    );
  }
}

class DetailMetadata extends StatelessWidget {
  const DetailMetadata({
    super.key,
    required this.values,
    this.compact = false,
    this.tooltips = const {},
  });
  final Map<String, String?> values;
  final bool compact;
  final Map<String, String> tooltips;

  @override
  Widget build(BuildContext context) {
    if (values.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final line = BorderSide(color: colors.outlineVariant.withValues(alpha: .5));
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: line, bottom: line),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = compact
              ? (constraints.maxWidth / values.length.clamp(1, 3.4)).clamp(
                  104.0,
                  160.0,
                )
              : (constraints.maxWidth / values.length).clamp(
                  140.0,
                  double.infinity,
                );
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final entry in values.entries) ...[
                    if (compact && entry.key != values.keys.first)
                      VerticalDivider(
                        width: 1,
                        thickness: 1,
                        indent: 26,
                        endIndent: 18,
                        color: line.color,
                      ),
                    SizedBox(
                      width: width,
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: compact ? 16 : 18,
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              entry.key,
                              style: TextStyle(
                                fontSize: 11,
                                color: colors.onSurfaceVariant,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            SizedBox(height: compact ? 10 : 7),
                            Tooltip(
                              message: tooltips[entry.key] ?? entry.value!,
                              child: Text(
                                entry.value!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: compact
                                    ? TextStyle(
                                        fontSize:
                                            int.tryParse(entry.value!) != null
                                            ? 18
                                            : 14,
                                        height: 1.3,
                                        fontWeight: FontWeight.w400,
                                        color: colors.onSurfaceVariant,
                                      )
                                    : Theme.of(context).textTheme.titleSmall,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class AppDetailReleaseInfo extends StatelessWidget {
  const AppDetailReleaseInfo({super.key, required this.detail});

  final AppDetails detail;

  @override
  Widget build(BuildContext context) => DefaultTextStyle.merge(
    style: TextStyle(
      fontSize: 14,
      height: 1.4,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
    child: SizedBox(
      width: double.infinity,
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        spacing: 16,
        runSpacing: 6,
        children: [
          if (detail.version?.trim().isNotEmpty == true)
            Text('${detail.versionLabel} ${detail.version}'),
          if (detail.updatedAt?.trim().isNotEmpty == true)
            Tooltip(
              message: '最近更新：${detail.updatedAt}',
              child: Text(detail.updatedAt!),
            ),
        ],
      ),
    ),
  );
}

class DetailSection extends StatelessWidget {
  const DetailSection({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
  });
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          Expanded(
            child: Text(title, style: Theme.of(context).textTheme.titleLarge),
          ),
          ?trailing,
        ],
      ),
      const SizedBox(height: 14),
      child,
    ],
  );
}

class DetailSectionDivider extends StatelessWidget {
  const DetailSectionDivider({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24),
    child: Divider(
      height: 1,
      color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: .5),
    ),
  );
}

class DetailText extends StatefulWidget {
  const DetailText(this.text, {super.key, this.maxLines = 5});
  final String text;
  final int maxLines;

  @override
  State<DetailText> createState() => _DetailTextState();
}

class _DetailTextState extends State<DetailText> {
  bool expanded = false;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final style = Theme.of(context).textTheme.bodyMedium!;
      final measurement = TextPainter(
        text: TextSpan(text: widget.text, style: style),
        maxLines: widget.maxLines,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: constraints.maxWidth);
      final overflows = measurement.didExceedMaxLines;
      measurement.dispose();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (expanded || !overflows)
            SelectableText(widget.text, style: style)
          else
            Text(
              widget.text,
              style: style,
              maxLines: widget.maxLines,
              overflow: TextOverflow.ellipsis,
            ),
          if (overflows)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => setState(() => expanded = !expanded),
                child: Text(expanded ? '收起' : '更多'),
              ),
            ),
        ],
      );
    },
  );
}

class AppScreenshotGallery extends StatefulWidget {
  const AppScreenshotGallery({super.key, required this.urls});
  final List<String> urls;

  @override
  State<AppScreenshotGallery> createState() => _AppScreenshotGalleryState();
}

class _AppScreenshotGalleryState extends State<AppScreenshotGallery> {
  final scroll = ScrollController();
  bool canBack = false, canForward = false;

  @override
  void initState() {
    super.initState();
    scroll.addListener(_update);
  }

  void _update() {
    if (!mounted || !scroll.hasClients) return;
    final back = scroll.offset > 1;
    final forward = scroll.offset < scroll.position.maxScrollExtent - 1;
    if (back != canBack || forward != canForward) {
      setState(() {
        canBack = back;
        canForward = forward;
      });
    }
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  void _move(int direction) {
    if (!scroll.hasClients) return;
    scroll.animateTo(
      (scroll.offset + direction * scroll.position.viewportDimension * .85)
          .clamp(0.0, scroll.position.maxScrollExtent),
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) => DetailSection(
    title: '预览',
    trailing: widget.urls.length < 2
        ? null
        : Row(
            children: [
              IconButton(
                tooltip: '上一组截图',
                onPressed: canBack ? () => _move(-1) : null,
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              IconButton(
                tooltip: '下一组截图',
                onPressed: canForward ? () => _move(1) : null,
                icon: const Icon(Icons.chevron_right_rounded),
              ),
            ],
          ),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxWidth < 600
            ? (MediaQuery.sizeOf(context).height * .42).clamp(180.0, 320.0)
            : 320.0;
        final colors = Theme.of(context).colorScheme;
        return NotificationListener<ScrollMetricsNotification>(
          onNotification: (_) {
            WidgetsBinding.instance.addPostFrameCallback((_) => _update());
            return false;
          },
          child: SizedBox(
            height: height,
            child: ListView.separated(
              controller: scroll,
              scrollDirection: Axis.horizontal,
              itemCount: widget.urls.length,
              separatorBuilder: (_, _) => const SizedBox(width: 16),
              itemBuilder: (context, index) => ClipPath.shape(
                shape: surfaceShape(12),
                child: Material(
                  color: colors.surfaceContainer,
                  child: InkWell(
                    onTap: () => _preview(index),
                    child: CachedNetworkImage(
                      imageUrl: widget.urls[index],
                      height: height,
                      fit: BoxFit.contain,
                      imageBuilder: (context, provider) => Image(
                        image: provider,
                        height: height,
                        fit: BoxFit.contain,
                        semanticLabel: '应用截图 ${index + 1}',
                      ),
                      placeholder: (_, _) => SizedBox(
                        width: height * .6,
                        child: const Center(child: CircularProgressIndicator()),
                      ),
                      errorWidget: (_, _, _) => SizedBox(
                        width: height * .6,
                        child: const Center(
                          child: Icon(Icons.broken_image_outlined),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );

  void _preview(int index) => showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: MediaQuery.sizeOf(context).width * .86,
        height: MediaQuery.sizeOf(context).height * .82,
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: .8,
                maxScale: 5,
                child: Center(
                  child: CachedNetworkImage(
                    imageUrl: widget.urls[index],
                    fit: BoxFit.contain,
                    placeholder: (_, _) =>
                        const Center(child: CircularProgressIndicator()),
                    errorWidget: (_, _, _) =>
                        const Center(child: Text('图片暂时无法加载')),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 8,
              top: 8,
              child: PageBarButton(
                backgroundColor: Theme.of(context).dialogTheme.backgroundColor,
                child: IconButton(
                  tooltip: '关闭预览',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
