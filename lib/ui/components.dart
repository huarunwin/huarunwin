import 'dart:io';

import 'package:flutter/material.dart';

import 'package:url_launcher/url_launcher.dart';

import '../data/catalog_filters.dart';
import '../data/models.dart';
import '../data/site_parser.dart';
import '../services/mac_downloads.dart';
import 'corrections_page.dart';
import 'page_components.dart';
import 'content_image.dart';
import 'theme.dart';
import 'web_page.dart';

export 'page_bar.dart' show RefreshIconButton;

Future<void> openLink(
  BuildContext context,
  String url, {
  String? downloadPlatform,
  bool inApp = false,
}) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !['https', 'http'].contains(uri.scheme)) return;
  try {
    if (SiteRoutes.isCorrection(uri)) {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => const CorrectionsPage()),
      );
      return;
    }
    if (inApp) {
      await Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => WebPage(uri: uri, title: '访问网站'),
        ),
      );
      return;
    }
    if (Platform.isMacOS &&
        (downloadPlatform == null || downloadPlatform == 'macOS') &&
        isAppStoreUrl(url)) {
      if (await launchUrl(
        macAppStoreUri(url),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    }
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw StateError('open');
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('暂时无法打开链接，请稍后重试。')));
    }
  }
}

/// A fixed column width keeps the footer a compact, left aligned group: the
/// figures no longer spread out when a card gets wider. The preferred width
/// follows the system text size, and is capped by the space actually available
/// so narrow cards and large text fall back to equal columns instead of
/// overflowing.
double _metricColumnWidth(
  BuildContext context, {
  required double availableWidth,
  required int columns,
  required double gap,
  required double preferred,
}) {
  final scaled = preferred * MediaQuery.textScalerOf(context).scale(1);
  if (!availableWidth.isFinite) return scaled;
  final max = (availableWidth - gap * (columns - 1)) / columns;
  final cap = max > 0 ? max : 0.0;
  return scaled < cap ? scaled : cap;
}

/// One labelled statistic in the compact card footer style: a small caption
/// above a single exact value. Store and GitHub statistics share this shape,
/// and adjacent columns are grouped by whitespace alone, without dividers.
Widget _metricColumn(
  BuildContext context, {
  required String label,
  required String value,
  required double width,
  Color? valueColor,
  double fontSize = 13,
}) {
  final colors = Theme.of(context).colorScheme;
  return SizedBox(
    width: width,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11,
            height: 1.2,
            color: colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 3),
        // A narrow column scales its value down instead of showing an
        // ellipsis: the published figure stays exact and complete even when
        // the card shares this footer with the download action.
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            maxLines: 1,
            style: TextStyle(
              fontSize: fontSize,
              height: 1.25,
              fontWeight: FontWeight.w600,
              color: valueColor ?? colors.onSurface,
            ),
          ),
        ),
      ],
    ),
  );
}

/// The published update date uses the same labelled column as the store and
/// GitHub statistics: a small caption above one exact, neutral value. Dates
/// the website did not publish keep their status text but stay muted, so a
/// pending load is still distinguishable from an unrecorded date.
class UpdateDateMetric extends StatelessWidget {
  const UpdateDateMetric({super.key, required this.value, this.hasDate = true});

  final String value;
  final bool hasDate;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final tight = constraints.hasBoundedWidth && constraints.maxWidth < 230;
        final width = _metricColumnWidth(
          context,
          availableWidth: constraints.maxWidth,
          columns: 1,
          gap: 0,
          preferred: tight ? 68.0 : 84.0,
        );
        return _metricColumn(
          context,
          label: '更新日期',
          value: value,
          width: width,
          fontSize: tight ? 11.0 : 13.0,
          valueColor: hasDate
              ? null
              : Theme.of(context).colorScheme.onSurfaceVariant,
        );
      },
    );
  }
}

/// Public store statistics in the same column style as the website card.
///
/// The 7-day value is a signed net change (`+N`, `0` or `-N`); a missing
/// baseline stays unknown instead of becoming a zero. Both columns use exact
/// published counts. When the website published no 7-day change, the whole
/// column is omitted at every width, leaving only the count at the left edge:
/// an em dash would reserve space for a figure that never existed. All
/// published figures stay neutral: the card footer carries no colour coding
/// or hover explanation, and the current sort is visible in the sort controls.
class StoreRatingMetrics extends StatelessWidget {
  const StoreRatingMetrics({super.key, required this.app});

  final CatalogApp app;

  @override
  Widget build(BuildContext context) {
    final change = app.ratingChangeLabel;
    final count = app.ratingCountLabel;
    if (change == null && count == null) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final tight = constraints.hasBoundedWidth && constraints.maxWidth < 230;
        // The figure is one step smaller than body text: readable without
        // outweighing the caption above it or the action on the card.
        final fontSize = tight ? 11.0 : 13.0;
        final gap = tight ? 6.0 : 14.0;
        final columns = (change != null ? 1 : 0) + (count != null ? 1 : 0);
        final width = _metricColumnWidth(
          context,
          availableWidth: constraints.maxWidth,
          columns: columns,
          gap: gap,
          preferred: tight ? 68.0 : 84.0,
        );
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (change != null)
              _metricColumn(
                context,
                label: tight ? '7日变化' : '7日评分变化',
                value: change,
                width: width,
                fontSize: fontSize,
              ),
            if (change != null && count != null) SizedBox(width: gap),
            if (count != null)
              _metricColumn(
                context,
                label: '评分数',
                value: count,
                width: width,
                fontSize: fontSize,
              ),
          ],
        );
      },
    );
  }
}

/// GitHub Star growth for the selected period, in the same column style as
/// store statistics: period gain, its share of the total, and total Star.
///
/// All published figures stay neutral; the current sort is visible in the sort
/// controls and the footer carries no hover explanation. The share is a
/// snapshot composition, not a growth rate: it carries no plus sign, names the
/// period in its label, and is always computed from the exact count divided by
/// a positive published total (never a rounded value). Missing values stay
/// visible as an em dash.
class OpenSourceGrowthMetrics extends StatelessWidget {
  const OpenSourceGrowthMetrics({
    super.key,
    required this.app,
    required this.period,
  });

  final CatalogApp app;
  final CatalogStarPeriod period;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final count = period.count(app);
    final total = app.starCount;
    final share = count != null && total != null && total > 0
        ? count / total * 100
        : null;
    final gain = count == null
        ? '—'
        : '${count > 0
              ? '+'
              : count < 0
              ? '-'
              : ''}${CatalogApp.groupDigits(count)}';
    final shareLabel = share == null ? '—' : '${share.toStringAsFixed(1)}%';
    final totalLabel = app.starCountLabel ?? '—';
    return LayoutBuilder(
      builder: (context, constraints) {
        // Very narrow cards keep all three figures but use short captions and
        // tighter gaps instead of ellipsizing values.
        final tight = constraints.hasBoundedWidth && constraints.maxWidth < 230;
        // The figure is one step smaller than body text: readable without
        // outweighing the caption above it or the action on the card.
        final fontSize = tight ? 11.0 : 13.0;
        final gap = tight ? 6.0 : 14.0;
        final width = _metricColumnWidth(
          context,
          availableWidth: constraints.maxWidth,
          columns: 3,
          gap: gap,
          preferred: tight ? 68.0 : 84.0,
        );
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _metricColumn(
              context,
              label: tight
                  ? period.label.replaceAll(' ', '')
                  : '${period.label}新增',
              value: gain,
              width: width,
              fontSize: fontSize,
              valueColor: count == null ? colors.onSurfaceVariant : null,
            ),
            SizedBox(width: gap),
            _metricColumn(
              context,
              label: tight ? '占比' : '${period.label}新增占比',
              value: shareLabel,
              width: width,
              fontSize: fontSize,
              valueColor: share == null ? colors.onSurfaceVariant : null,
            ),
            SizedBox(width: gap),
            _metricColumn(
              context,
              label: tight ? 'Star' : '总 Star',
              value: totalLabel,
              width: width,
              fontSize: fontSize,
              valueColor: total == null ? colors.onSurfaceVariant : null,
            ),
          ],
        );
      },
    );
  }
}

class AppIcon extends StatelessWidget {
  const AppIcon(this.app, {super.key, this.size = 56});
  final CatalogApp app;
  final double size;
  @override
  Widget build(BuildContext context) => ClipPath.shape(
    shape: surfaceShape(size * .25),
    child: SizedBox.square(
      dimension: size,
      child: app.icon == null
          ? _fallback(context)
          : ContentImage(
              imageUrl: app.icon!,
              fit: BoxFit.cover,
              placeholder: (_, _) => _fallback(context),
              errorWidget: (_, _, _) => _fallback(context),
            ),
    ),
  );
  Widget _fallback(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainer,
    child: Center(
      child: Text(
        app.name.characters.first,
        style: TextStyle(
          fontSize: size * .4,
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ),
  );
}

class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.accent = false});
  final String text;
  final bool accent;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: surfaceShape(9),
        color: colors.onSurface.withValues(alpha: .06),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: accent ? colors.primary : colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });
  final IconData icon;
  final String title, message;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconWell(icon, size: 64),
            const SizedBox(height: 16),
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: TextStyle(
                fontSize: 13,
                height: 1.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    ),
  );
}

IconData platformIcon(String platform) => switch (platform) {
  'macOS' || 'iOS' => Icons.apple_rounded,
  'Windows' => Icons.window_rounded,
  'Android' => Icons.android_rounded,
  'Linux' => Icons.terminal_rounded,
  _ => Icons.devices_rounded,
};

String bytesLabel(int value) {
  if (value >= 1024 * 1024 * 1024) {
    return '${(value / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
  }
  if (value >= 1024 * 1024) {
    return '${(value / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(value / 1024).toStringAsFixed(0)} KB';
}
