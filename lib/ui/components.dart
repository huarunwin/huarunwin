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

/// One labelled statistic in the compact card footer style: a small caption
/// above a single exact value. Store and GitHub statistics share this shape.
/// Equal flex keeps column edges aligned across cards even when values differ
/// in length (an em dash versus a six-digit count, for example). Adjacent
/// columns are grouped by whitespace alone, without divider lines.
Widget _metricColumn(
  BuildContext context, {
  required String label,
  required String value,
  Color? valueColor,
  double fontSize = 14,
}) {
  final colors = Theme.of(context).colorScheme;
  return Expanded(
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
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: fontSize,
            height: 1.25,
            fontWeight: FontWeight.w600,
            color: valueColor ?? colors.onSurface,
          ),
        ),
      ],
    ),
  );
}

/// Public store statistics in the same two-column shape as the website card.
///
/// The 7-day value is a signed net change (`+N`, `0` or `-N`); a missing
/// baseline stays unknown instead of becoming a zero. Both columns use exact
/// published counts. Rating sorting can keep the change column visible with an
/// em dash when the website has no 7-day baseline for this snapshot, so the
/// field is not silently dropped. All published figures stay neutral: the card
/// footer carries no colour coding or hover explanation, and the current sort
/// is already visible in the sort controls.
class StoreRatingMetrics extends StatelessWidget {
  const StoreRatingMetrics({
    super.key,
    required this.app,
    this.ratingSort = false,
  });

  final CatalogApp app;
  final bool ratingSort;

  @override
  Widget build(BuildContext context) {
    final change = app.ratingChangeLabel;
    final count = app.ratingCountLabel;
    if (change == null && count == null) return const SizedBox.shrink();
    final showChange = change != null || (ratingSort && count != null);
    final colors = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (showChange)
          _metricColumn(
            context,
            label: '7日评分变化',
            value: change ?? '—',
            valueColor: change == null ? colors.onSurfaceVariant : null,
          ),
        if (showChange && count != null) const SizedBox(width: 14),
        if (count != null) _metricColumn(context, label: '评分数', value: count),
      ],
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
        final fontSize = tight ? 13.0 : 14.0;
        final gap = tight ? 8.0 : 14.0;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _metricColumn(
              context,
              label: tight
                  ? period.label.replaceAll(' ', '')
                  : '${period.label}新增',
              value: gain,
              fontSize: fontSize,
              valueColor: count == null ? colors.onSurfaceVariant : null,
            ),
            SizedBox(width: gap),
            _metricColumn(
              context,
              label: tight ? '占比' : '${period.label}新增占比',
              value: shareLabel,
              fontSize: fontSize,
              valueColor: share == null ? colors.onSurfaceVariant : null,
            ),
            SizedBox(width: gap),
            _metricColumn(
              context,
              label: tight ? 'Star' : '总 Star',
              value: totalLabel,
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
