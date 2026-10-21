import 'dart:io';

import 'package:flutter/material.dart';

import 'package:url_launcher/url_launcher.dart';

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
