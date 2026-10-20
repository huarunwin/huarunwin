import 'package:flutter/foundation.dart';

import '../data/models.dart';

String? get runningDownloadPlatform => switch (defaultTargetPlatform) {
  TargetPlatform.macOS => 'macOS',
  TargetPlatform.windows => 'Windows',
  TargetPlatform.linux => 'Linux',
  TargetPlatform.android => 'Android',
  TargetPlatform.iOS => 'iOS',
  _ => null,
};

String? directDownloadPlatform({
  required String selected,
  required String? running,
  required Iterable<String> supported,
}) {
  if (running == null || !supported.contains(running)) return null;
  return selected == '全部' || selected == running ? running : null;
}

String downloadPlatformLabel(String platform) =>
    platform == 'macOS' ? 'Mac' : platform;

class ReleaseDownloadPreferences {
  const ReleaseDownloadPreferences({
    required this.platform,
    required this.running,
    this.architecture,
    this.linuxPackageKind,
  });

  final String platform;
  final String? running, architecture, linuxPackageKind;

  List<String> get _kinds => switch (platform) {
    'macOS' => ['dmg', 'zip', 'pkg'],
    'Windows' => ['exe', 'msi', 'msix', 'zip'],
    'Android' => ['apk'],
    'Linux' => [?linuxPackageKind, 'appimage', 'zip'],
    _ => [],
  };

  List<DownloadLink> packages(List<DownloadLink> resources) =>
      resources.where((r) => r.platform == platform && r.isPackage).toList();

  bool _suitable(DownloadLink resource) =>
      running != platform ||
      _kinds.contains(resource.kind) &&
          (architecture == null ||
              [architecture, 'universal'].contains(resource.architecture));

  bool hasSuitableResource(List<DownloadLink> resources) =>
      packages(resources).any(_suitable);

  DownloadLink? recommended(List<DownloadLink> resources) {
    if (running != platform || architecture == null) return null;
    final candidates = packages(resources);
    for (final arch in [architecture, 'universal']) {
      for (final kind in _kinds) {
        final matches = candidates
            .where((r) => r.architecture == arch && r.kind == kind)
            .toList();
        if (matches.length == 1) return matches.single;
        // Distinct variants at the same priority need an explicit choice.
        if (matches.length > 1) return null;
      }
    }
    return null;
  }

  DownloadLink? initialResource(List<DownloadLink> resources) {
    final best = recommended(resources);
    if (best != null) return best;
    final candidates = packages(resources).where(_suitable);
    return candidates.firstOrNull;
  }
}

/// A recommendation must identify one real asset for the device architecture.
DownloadLink? recommendedAndroidPackage(
  List<DownloadLink> packages,
  String? architecture,
) {
  if (architecture == null) return null;
  for (final arch in [architecture, 'universal']) {
    final candidates = packages
        .where((p) => p.kind == 'apk' && p.architecture == arch)
        .toList();
    if (candidates.length == 1) return candidates.single;
    if (candidates.length > 1) return null;
  }
  return null;
}

DownloadLink? recommendedWindowsPackage(
  List<DownloadLink> packages,
  String? architecture,
) {
  if (architecture == null) return null;
  for (final arch in [architecture, 'universal']) {
    final matches = packages.where((p) => p.architecture == arch).toList();
    if (matches.length == 1) return matches.single;
    if (matches.length > 1) return null;
  }
  return null;
}
