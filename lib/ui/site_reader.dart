import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/site_models.dart';
import '../data/site_parser.dart';
import 'reading_catalog.dart';
import 'content_image.dart';
import 'components.dart';
import 'detail_components.dart';
import 'page_bar.dart';
import 'theme.dart';
import 'page_components.dart';

class SiteRichText extends StatefulWidget {
  const SiteRichText(this.runs, {super.key, required this.onLink, this.style});
  final List<SiteText> runs;
  final ValueChanged<String> onLink;
  final TextStyle? style;
  @override
  State<SiteRichText> createState() => _SiteRichTextState();
}

class _SiteRichTextState extends State<SiteRichText> {
  final recognizers = <TapGestureRecognizer>[];
  void clear() {
    for (final r in recognizers) {
      r.dispose();
    }
    recognizers.clear();
  }

  @override
  void dispose() {
    clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    clear();
    final colors = Theme.of(context).colorScheme;
    return Text.rich(
      TextSpan(
        children: [
          for (final run in widget.runs)
            TextSpan(
              text: run.text,
              style: TextStyle(
                fontWeight: run.bold ? FontWeight.w600 : null,
                fontStyle: run.italic ? FontStyle.italic : null,
                fontFamily: run.code ? 'monospace' : null,
                backgroundColor: run.code
                    ? colors.surfaceContainerHighest
                    : null,
                color: run.url == null ? null : colors.primary,
                decoration: TextDecoration.combine([
                  if (run.url != null) TextDecoration.underline,
                  if (run.struck) TextDecoration.lineThrough,
                ]),
                decorationColor: colors.primary.withValues(alpha: .35),
              ),
              recognizer: run.url == null ? null : _recognizer(run.url!),
              mouseCursor: run.url == null ? null : SystemMouseCursors.click,
            ),
        ],
      ),
      style:
          widget.style ??
          Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.75),
    );
  }

  TapGestureRecognizer _recognizer(String url) {
    final r = TapGestureRecognizer()..onTap = () => widget.onLink(url);
    recognizers.add(r);
    return r;
  }
}

/// Renders semantic content with native text, tables, disclosures and images.
/// The widget never embeds a browser or executes HTML/JavaScript.
class SiteBlockView extends StatelessWidget {
  const SiteBlockView({
    super.key,
    required this.block,
    required this.onLink,
    required this.anchors,
    required this.expanded,
    required this.onExpansion,
    this.depth = 0,
    this.flat = false,
    this.appDetailStyle = false,
    this.sectionDivider = true,
    this.timelineDescending = false,
    this.imageGallery = const [],
  });
  final SiteBlock block;
  final ValueChanged<String> onLink;
  final Map<SiteBlock, GlobalKey> anchors;
  final Set<SiteBlock> expanded;
  final void Function(SiteBlock, bool) onExpansion;
  final int depth;
  final bool flat;
  final bool appDetailStyle;
  final bool sectionDivider;
  final bool timelineDescending;
  final List<SiteBlock> imageGallery;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final content = switch (block.kind) {
      BlockKind.heading => Padding(
        padding: appDetailStyle
            ? EdgeInsets.only(top: block.level <= 2 ? 0 : 8, bottom: 2)
            : EdgeInsets.only(top: block.level <= 2 ? 16 : 10, bottom: 5),
        child: SiteRichText(
          block.runs,
          onLink: onLink,
          style: switch (block.level) {
            1 => Theme.of(context).textTheme.headlineMedium,
            2 => Theme.of(context).textTheme.titleLarge,
            _ => Theme.of(context).textTheme.titleMedium,
          },
        ),
      ),
      BlockKind.text => SiteRichText(
        block.runs,
        onLink: onLink,
        style: appDetailStyle
            ? Theme.of(context).textTheme.bodyMedium
            : flat
            ? Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.85)
            : null,
      ),
      BlockKind.caption => SiteRichText(
        block.runs,
        onLink: onLink,
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(height: 1.6, color: colors.onSurfaceVariant),
      ),
      BlockKind.code => SurfacePanel(
        radius: 14,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Align(
              alignment: Alignment.topRight,
              child: TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: block.text));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('已复制代码')));
                  }
                },
                icon: const Icon(Icons.copy_rounded, size: 15),
                label: const Text('复制'),
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text(
                block.text,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.6,
                ),
              ),
            ),
          ],
        ),
      ),
      BlockKind.table => _table(context),
      BlockKind.facts => _facts(context),
      BlockKind.offer => _offer(context),
      BlockKind.image => _image(context),
      BlockKind.related => _related(context),
      BlockKind.reference => _reference(context),
      BlockKind.event => _event(context),
      BlockKind.timeline => _children(),
      BlockKind.gallery => LayoutBuilder(
        builder: (context, size) {
          final columns = (size.maxWidth / 220).floor().clamp(1, 3);
          return Wrap(
            spacing: 16,
            runSpacing: 12,
            children: [
              for (final child in block.children)
                SizedBox(
                  width: (size.maxWidth - (columns - 1) * 16) / columns,
                  child: _child(child),
                ),
            ],
          );
        },
      ),
      BlockKind.disclosure => SurfacePanel(
        radius: 16,
        child: ExpansionTile(
          key: ValueKey((block, expanded.contains(block))),
          shape: const Border(),
          collapsedShape: const Border(),
          initiallyExpanded: expanded.contains(block),
          onExpansionChanged: (value) => onExpansion(block, value),
          title: SiteRichText(
            block.runs,
            onLink: onLink,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [_children()],
        ),
      ),
      BlockKind.quote => SurfacePanel(
        padding: const EdgeInsets.all(18),
        radius: 16,
        child: SizedBox(
          width: double.infinity,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.format_quote_rounded,
                size: 24,
                color: colors.onSurfaceVariant,
              ),
              const SizedBox(height: 6),
              if (block.runs.isNotEmpty)
                SiteRichText(block.runs, onLink: onLink),
              if (block.children.isNotEmpty) _children(),
            ],
          ),
        ),
      ),
      BlockKind.panel =>
        flat
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (depth == 0 && sectionDivider) ...[
                    if (appDetailStyle)
                      const DetailSectionDivider()
                    else ...[
                      const SizedBox(height: 12),
                      Divider(
                        color: colors.outlineVariant.withValues(alpha: .5),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ],
                  _children(),
                ],
              )
            : depth <= 1
            ? SurfacePanel(
                padding: const EdgeInsets.all(18),
                child: SizedBox(width: double.infinity, child: _children()),
              )
            : _children(),
    };
    return Padding(
      key: anchors.putIfAbsent(block, GlobalKey.new),
      padding: EdgeInsets.only(
        bottom: appDetailStyle && block.kind == BlockKind.panel ? 0 : 12,
      ),
      child: content,
    );
  }

  Widget _child(SiteBlock child) => SiteBlockView(
    block: child,
    onLink: onLink,
    anchors: anchors,
    expanded: expanded,
    onExpansion: onExpansion,
    depth: depth + 1,
    flat: flat,
    appDetailStyle: appDetailStyle,
    timelineDescending: timelineDescending,
    imageGallery: imageGallery,
  );

  Widget _children() {
    var ordered = block.children;
    int compare(SiteBlock a, SiteBlock b) {
      double? date(SiteBlock value) {
        if (value.item?.publishedAt case final date?) {
          return date.millisecondsSinceEpoch.toDouble();
        }
        if (value.id?.startsWith('history-year-') == true) {
          return double.tryParse(value.id!.replaceFirst('history-year-', ''));
        }
        return null;
      }

      final x = date(a), y = date(b);
      if (x == null) return y == null ? 0 : 1;
      if (y == null) return -1;
      return timelineDescending ? y.compareTo(x) : x.compareTo(y);
    }

    if (block.kind == BlockKind.timeline) {
      ordered = [...ordered]..sort(compare);
    } else if (ordered.any((child) => child.kind == BlockKind.event)) {
      final events =
          ordered.where((child) => child.kind == BlockKind.event).toList()
            ..sort(compare);
      var eventIndex = 0;
      ordered = [
        for (final child in ordered)
          child.kind == BlockKind.event ? events[eventIndex++] : child,
      ];
    }
    final children = <Widget>[];
    for (var index = 0; index < ordered.length;) {
      final child = ordered[index];
      if (flat &&
          (child.kind == BlockKind.offer || child.kind == BlockKind.related)) {
        final offers = <SiteBlock>[];
        while (index < ordered.length && ordered[index].kind == child.kind) {
          offers.add(ordered[index++]);
        }
        children.add(
          LayoutBuilder(
            builder: (context, size) {
              final columns =
                  size.maxWidth >= (child.kind == BlockKind.related ? 580 : 760)
                  ? 2
                  : 1;
              final width = (size.maxWidth - (columns - 1) * 16) / columns;
              return Wrap(
                spacing: 16,
                children: [
                  for (final offer in offers)
                    SizedBox(width: width, child: _child(offer)),
                ],
              );
            },
          ),
        );
      } else {
        children.add(_child(child));
        index++;
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _related(BuildContext context) {
    final item = block.item!;
    final kind =
        SiteRoutes.readingKind(Uri.parse(item.url)) ??
        (item.date.isNotEmpty ? SiteReadingKind.core : SiteReadingKind.article);
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainer,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: item.url.isEmpty ? null : () => onLink(item.url),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ReadingAvatar(url: item.image, kind: kind, size: 38),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (item.date.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          item.date,
                          style: Theme.of(context).textTheme.labelMedium
                              ?.copyWith(
                                color: Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                              ),
                        ),
                      ),
                    Text(
                      item.title,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    if (item.summary.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Text(
                          item.summary,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(height: 1.6),
                        ),
                      ),
                    if (item.subtitle.isNotEmpty)
                      Text(
                        item.subtitle,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    if (item.actions.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            for (final action in item.actions)
                              TextButton(
                                onPressed: () => onLink(action.url),
                                child: Text(action.label),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              if (item.url.isNotEmpty) ...[
                const SizedBox(width: 8),
                const Icon(Icons.chevron_right_rounded, size: 17),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _reference(BuildContext context) {
    final item = block.item!;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 44,
            child: Text(
              item.badges.firstOrNull ?? '',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SiteRichText(
                  [SiteText(item.title, url: item.url)],
                  onLink: onLink,
                  style: theme.textTheme.titleSmall?.copyWith(height: 1.6),
                ),
                if (item.summary.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Text(
                      item.summary,
                      style: theme.textTheme.bodyMedium?.copyWith(height: 1.65),
                    ),
                  ),
                if (item.subtitle.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Text(
                      item.subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        height: 1.5,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _event(BuildContext context) {
    final item = block.item!;
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: colors.outlineVariant)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 0, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (item.date.isNotEmpty)
                    Text(
                      item.date,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: colors.primary,
                      ),
                    ),
                  for (final badge in item.badges) Pill(badge),
                  if (block.id != null)
                    IconButton(
                      tooltip: '复制节点链接',
                      visualDensity: VisualDensity.compact,
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: item.url));
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已复制节点链接')),
                          );
                        }
                      },
                      icon: const Icon(Icons.link_rounded, size: 17),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                item.title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 12),
              if (item.summary.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    item.summary,
                    style: theme.textTheme.bodyLarge?.copyWith(height: 1.85),
                  ),
                ),
              _children(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _facts(BuildContext context) => LayoutBuilder(
    builder: (context, size) => Column(
      children: [
        for (final row in block.rows.where((row) => row.length >= 2))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: appDetailStyle || size.maxWidth < 600 ? 100 : 150,
                  child: SiteRichText(
                    row.first,
                    onLink: onLink,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      height: 1.6,
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: SiteRichText(
                    row[1],
                    onLink: onLink,
                    style: appDetailStyle
                        ? Theme.of(context).textTheme.bodyMedium
                        : null,
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );

  Widget _offer(BuildContext context) {
    final item = block.item!;
    final colors = Theme.of(context).colorScheme;
    final price = item.facts['付款金额'] ?? item.facts['官方报价'];
    final facts = item.facts.entries
        .where((entry) => !{'付款金额', '官方报价'}.contains(entry.key))
        .toList();
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(item.title, style: Theme.of(context).textTheme.titleMedium),
        if (item.subtitle.isNotEmpty) ...[
          const SizedBox(height: 5),
          Text(item.subtitle, style: TextStyle(color: colors.onSurfaceVariant)),
        ],
        if (price != null) ...[
          const SizedBox(height: 12),
          Text(
            price,
            style: appDetailStyle
                ? Theme.of(context).textTheme.bodyLarge?.copyWith(
                    fontSize: 16,
                    height: 1.4,
                    fontWeight: FontWeight.w600,
                  )
                : Theme.of(context).textTheme.titleLarge,
          ),
        ],
        if (facts.isNotEmpty) ...[
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, size) {
              final columns = appDetailStyle
                  ? (size.maxWidth /
                            MediaQuery.textScalerOf(context).scale(130))
                        .floor()
                        .clamp(1, 3)
                  : size.maxWidth >= 340
                  ? 3
                  : 2;
              return Wrap(
                spacing: 12,
                runSpacing: 14,
                children: [
                  for (final fact in facts)
                    SizedBox(
                      width: (size.maxWidth - 12 * (columns - 1)) / columns,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            fact.key,
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            fact.value,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        ],
        if (block.children.isNotEmpty) ...[
          const SizedBox(height: 12),
          _children(),
        ],
        if (item.url != '' &&
            (item.actions.isNotEmpty || item.subtitle.isNotEmpty)) ...[
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              TextButton.icon(
                onPressed: () => onLink(item.url),
                icon: const Icon(Icons.arrow_forward_rounded, size: 17),
                label: const Text('查看套餐'),
              ),
              for (final action in item.actions)
                FilledButton.tonal(
                  onPressed: () => onLink(action.url),
                  style: appDetailStyle ? downloadButtonStyle(context) : null,
                  child: Text(action.label),
                ),
            ],
          ),
        ],
      ],
    );
    if (appDetailStyle) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: content,
      );
    }
    return Card(
      color: colors.surfaceContainer,
      shape: surfaceShape(18),
      child: Padding(padding: const EdgeInsets.all(20), child: content),
    );
  }

  Widget _table(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      final rows = block.rows.where((r) => r.isNotEmpty).toList();
      if (rows.isEmpty) return const SizedBox.shrink();
      final columns = rows.map((r) => r.length).reduce(math.max);
      final width = math.max(
        size.maxWidth,
        columns == 2 ? 440.0 : columns * 170.0,
      );
      return ClipPath.shape(
        shape: surfaceShape(12),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: width,
            child: Table(
              defaultVerticalAlignment: TableCellVerticalAlignment.top,
              columnWidths: columns == 2
                  ? const {0: FlexColumnWidth(1), 1: FlexColumnWidth(2.6)}
                  : null,
              children: [
                for (var i = 0; i < rows.length; i++)
                  TableRow(
                    decoration: BoxDecoration(
                      color: i.isEven
                          ? Theme.of(context).colorScheme.surfaceContainer
                          : Theme.of(context).colorScheme.surface,
                    ),
                    children: [
                      for (var j = 0; j < columns; j++)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: SiteRichText(
                            j < rows[i].length ? rows[i][j] : const [],
                            onLink: onLink,
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _image(BuildContext context) {
    final small = block.level > 0 && block.level <= 160;
    final url = block.url!;
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        onTap: () => showDialog<void>(
          context: context,
          builder: (_) => _ReadingImagePreview(
            images: imageGallery.contains(block) ? imageGallery : [block],
            initial: block,
          ),
        ),
        child: ClipPath.shape(
          shape: surfaceShape(14),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: small ? 72 : 420),
            child: ContentImage(
              imageUrl: url,
              width: small ? 72 : null,
              height: small ? 72 : null,
              fit: BoxFit.contain,
              placeholder: (_, _) => const SizedBox(
                height: 72,
                child: Center(child: Icon(Icons.image_outlined)),
              ),
              errorWidget: (_, _, _) => Padding(
                padding: const EdgeInsets.all(14),
                child: Text(block.text.isEmpty ? '图片暂时无法加载' : block.text),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReadingImagePreview extends StatefulWidget {
  const _ReadingImagePreview({required this.images, required this.initial});
  final List<SiteBlock> images;
  final SiteBlock initial;
  @override
  State<_ReadingImagePreview> createState() => _ReadingImagePreviewState();
}

class _ReadingImagePreviewState extends State<_ReadingImagePreview> {
  late final controller = PageController(
    initialPage: widget.images.indexOf(widget.initial),
  );
  late int index = widget.images.indexOf(widget.initial);
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(20),
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              const SizedBox(width: 12),
              Text('${index + 1} / ${widget.images.length}'),
              const Spacer(),
              PageBarActions(
                backgroundColor: Theme.of(context).dialogTheme.backgroundColor,
                actions: [
                  IconButton(
                    tooltip: '上一张',
                    onPressed: index > 0
                        ? () => controller.previousPage(
                            duration: const Duration(milliseconds: 180),
                            curve: Curves.easeOut,
                          )
                        : null,
                    icon: const Icon(Icons.chevron_left_rounded),
                  ),
                  IconButton(
                    tooltip: '下一张',
                    onPressed: index < widget.images.length - 1
                        ? () => controller.nextPage(
                            duration: const Duration(milliseconds: 180),
                            curve: Curves.easeOut,
                          )
                        : null,
                    icon: const Icon(Icons.chevron_right_rounded),
                  ),
                  IconButton(
                    tooltip: '关闭预览',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: PageView.builder(
            controller: controller,
            itemCount: widget.images.length,
            onPageChanged: (value) => setState(() => index = value),
            itemBuilder: (context, page) => InteractiveViewer(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: ContentImage(
                  imageUrl: widget.images[page].url!,
                  fit: BoxFit.contain,
                  errorWidget: (_, _, _) => Center(
                    child: Text(
                      widget.images[page].text.isEmpty
                          ? '图片暂时无法加载'
                          : widget.images[page].text,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (widget.images[index].text.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Text(
              widget.images[index].text,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    ),
  );
}
