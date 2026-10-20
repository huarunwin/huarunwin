import 'dart:convert';

import 'models.dart';

enum AppUpdateChannel { release, debug }

class AppRelease {
  const AppRelease({
    required this.version,
    required this.changes,
    this.downloadUrl,
    this.packages = const [],
  });

  final String version;
  final List<String> changes;
  final Uri? downloadUrl;
  final List<DownloadLink> packages;
}

class AppChangelog {
  const AppChangelog({required this.publishedVersion, required this.releases});

  final String publishedVersion;
  final List<AppRelease> releases;

  // Release identities omit build metadata; CI build numbers do not select updates.
  static final _version = RegExp(
    r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
    r'(?:-(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)'
    r'(?:\.(?:0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*)?$',
  );

  static bool isVersion(String value) => _version.stringMatch(value) == value;

  factory AppChangelog.decode(String source) {
    final data = jsonDecode(source);
    if (data is! Map<String, dynamic> ||
        data['publishedVersion'] is! String ||
        !isVersion(data['publishedVersion'] as String) ||
        data['releases'] is! List) {
      throw const FormatException('Invalid changelog metadata');
    }
    final releases = _readReleases(data['releases']);
    final publishedVersion = data['publishedVersion'] as String;
    if (!releases.any((entry) => entry.version == publishedVersion)) {
      throw const FormatException('publishedVersion has no changelog');
    }
    return AppChangelog(
      publishedVersion: publishedVersion,
      releases: List.unmodifiable(releases),
    );
  }

  AppRelease get published =>
      releases.singleWhere((entry) => entry.version == publishedVersion);
}

class AppUpdateFeed {
  const AppUpdateFeed({required this.publishedVersion, required this.releases});

  final String? publishedVersion;
  final List<AppRelease> releases;

  factory AppUpdateFeed.decode(
    String source, {
    required AppUpdateChannel channel,
  }) {
    final data = jsonDecode(source);
    final entry = data is Map<String, dynamic> ? data[channel.name] : null;
    if (entry is! Map<String, dynamic> ||
        !entry.containsKey('publishedVersion')) {
      throw const FormatException('Missing update channel or publishedVersion');
    }
    final publishedVersion = entry['publishedVersion'];
    if (publishedVersion != null &&
        (publishedVersion is! String ||
            !AppChangelog.isVersion(publishedVersion))) {
      throw const FormatException('Invalid publishedVersion');
    }
    final releases = _readReleases(entry['releases'], requireDownloadUrl: true);
    if (publishedVersion != null &&
        !releases.any((release) => release.version == publishedVersion)) {
      throw const FormatException('publishedVersion has no changelog');
    }
    return AppUpdateFeed(
      publishedVersion: publishedVersion as String?,
      releases: releases,
    );
  }

  AppRelease? get published => publishedVersion == null
      ? null
      : releases.singleWhere((entry) => entry.version == publishedVersion);
}

List<AppRelease> _readReleases(
  dynamic entries, {
  bool requireDownloadUrl = false,
}) {
  if (entries is! List) {
    throw const FormatException('Missing releases array');
  }
  final versions = <String>{};
  final releases = <AppRelease>[];
  for (final entry in entries) {
    if (entry is! Map<String, dynamic> ||
        entry['version'] is! String ||
        !AppChangelog.isVersion(entry['version'] as String) ||
        !versions.add(entry['version'] as String) ||
        entry['changes'] is! List) {
      throw const FormatException('Invalid or duplicate changelog version');
    }
    final changes = entry['changes'] as List;
    if (changes.isEmpty ||
        changes.any((item) => item is! String || item.trim().isEmpty)) {
      throw const FormatException('Release changes must not be empty');
    }
    Uri? downloadUrl;
    if (requireDownloadUrl) {
      final value = entry['downloadUrl'];
      downloadUrl = value is String ? Uri.tryParse(value) : null;
      if (downloadUrl == null ||
          downloadUrl.scheme != 'https' ||
          !downloadUrl.hasAuthority ||
          downloadUrl.host.isEmpty ||
          downloadUrl.userInfo.isNotEmpty) {
        throw const FormatException(
          'downloadUrl must be an absolute HTTPS URL',
        );
      }
    }
    releases.add(
      AppRelease(
        version: entry['version'] as String,
        changes: List.unmodifiable(changes.cast<String>()),
        downloadUrl: downloadUrl,
        packages: requireDownloadUrl ? _readPackages(entry) : const [],
      ),
    );
  }
  return List.unmodifiable(releases);
}

List<DownloadLink> _readPackages(Map<String, dynamic> release) {
  final entries = release['packages'];
  if (entries == null) return const [];
  if (entries is! List || entries.isEmpty) {
    throw const FormatException('packages must be a nonempty array');
  }
  final packages = <DownloadLink>[];
  for (final entry in entries) {
    if (entry is! Map<String, dynamic>) {
      throw const FormatException('Invalid update package');
    }
    final platform = entry['platform'];
    final kind = entry['kind'];
    final architecture = entry['architecture'];
    final url = entry['downloadUrl'] is String
        ? Uri.tryParse(entry['downloadUrl'] as String)
        : null;
    final supported = switch (platform) {
      'Android' => ['apk'],
      'macOS' => ['dmg', 'zip'],
      'Windows' => ['exe', 'msi', 'msix', 'zip'],
      'Linux' => ['deb', 'rpm', 'pkg.tar.zst', 'appimage'],
      'iOS' => ['store'],
      _ => <String>[],
    };
    final digest = entry['sha256'] is String
        ? normalizeSha256(entry['sha256'] as String)
        : null;
    if (!supported.contains(kind) ||
        url == null ||
        url.scheme != 'https' ||
        !url.hasAuthority ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty ||
        (platform != 'iOS' &&
            ![
              'arm64',
              'armv7',
              'x64',
              'x86',
              'universal',
            ].contains(architecture)) ||
        (architecture != null && architecture is! String) ||
        (entry['sha256'] != null && digest == null)) {
      throw const FormatException('Invalid update package identity or URL');
    }
    packages.add(
      DownloadLink(
        url: url.toString(),
        label: url.pathSegments.isEmpty
            ? platform as String
            : url.pathSegments.last,
        platform: platform as String,
        architecture: architecture as String?,
        kind: kind as String,
        sha256: digest,
        checksumSource: digest == null
            ? null
            : 'huarunwin-hub/api/updates.json',
        version: release['version'] as String,
        releaseUrl: release['downloadUrl'] as String,
      ),
    );
  }
  if (packages.where((item) => item.platform == 'iOS').length > 1) {
    throw const FormatException(
      'Each channel version must have one iOS update destination',
    );
  }
  return List.unmodifiable(packages);
}
