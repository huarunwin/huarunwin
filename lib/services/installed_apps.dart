import 'package:flutter/foundation.dart';

import '../data/models.dart';

class InstalledApplication {
  const InstalledApplication({
    this.path = '',
    this.bundleIdentifier = '',
    this.packageName,
    this.uninstallId,
    required this.version,
    required this.names,
  });

  final String path, bundleIdentifier, version;
  final String? packageName, uninstallId;
  final List<String> names;

  factory InstalledApplication.fromMap(Map<Object?, Object?> map) =>
      InstalledApplication(
        path: map['path'] as String? ?? '',
        bundleIdentifier: map['bundleIdentifier'] as String? ?? '',
        packageName: map['packageName'] as String?,
        uninstallId: map['uninstallId'] as String?,
        version: map['version'] as String? ?? '',
        names: List<String>.from(map['names'] as List),
      );
}

class InstalledApplications extends ChangeNotifier {
  InstalledApplications(this.load);

  final Future<List<InstalledApplication>> Function() load;
  List<InstalledApplication>? _snapshot;
  Future<List<InstalledApplication>>? _pending;
  int _generation = 0;

  void invalidate() {
    _generation++;
    _snapshot = null;
    _pending = null;
    notifyListeners();
  }

  Future<List<InstalledApplication>> read({bool refresh = false}) {
    if (_pending case final pending?) return pending;
    if (!refresh && _snapshot != null) return Future.value(_snapshot!);
    final generation = _generation;
    final request = load()
        .then((apps) {
          if (generation == _generation) _snapshot = apps;
          return apps;
        })
        .whenComplete(() {
          if (generation == _generation) _pending = null;
        });
    _pending = request;
    return request;
  }

  Future<InstalledApplication?> find(
    CatalogApp app, {
    String platform = 'macOS',
    bool refresh = false,
  }) async {
    final matches = await findAll(app, platform: platform, refresh: refresh);
    return matches.length == 1 ? matches.single : null;
  }

  Future<List<InstalledApplication>> findAll(
    CatalogApp app, {
    String platform = 'macOS',
    bool refresh = false,
  }) async {
    if (!app.isClient ||
        app.withdrawn ||
        !['macOS', 'Android', 'Windows', 'Linux'].contains(platform) ||
        !app.platforms.contains(platform)) {
      return const [];
    }
    final names = {
      if (app.name.trim().isNotEmpty) app.name.trim().toLowerCase(),
      if (app.alias.trim().isNotEmpty) app.alias.trim().toLowerCase(),
    };
    return (await read(refresh: refresh))
        .where(
          (candidate) =>
              (platform == 'Android'
                  ? candidate.packageName?.isNotEmpty == true
                  : platform == 'macOS'
                  ? candidate.bundleIdentifier.isNotEmpty
                  : candidate.uninstallId?.isNotEmpty == true) &&
              candidate.names.any(
                (name) => names.contains(name.trim().toLowerCase()),
              ),
        )
        .toList();
  }
}

bool hasNewerVersion(String installed, String available) {
  final current = _Version.parse(installed);
  final published = _Version.parse(available);
  return current != null &&
      published != null &&
      published.compareTo(current) > 0;
}

class _Version implements Comparable<_Version> {
  const _Version(this.numbers, this.prerelease);

  final List<int> numbers;
  final List<String> prerelease;

  static _Version? parse(String value) {
    final match = RegExp(
      r'^[vV]?(\d+(?:\.\d+)*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
    ).firstMatch(value.trim());
    if (match == null) return null;
    final parts = match.group(1)!.split('.').map(int.tryParse).toList();
    if (parts.any((part) => part == null)) return null;
    return _Version(parts.cast<int>(), match.group(2)?.split('.') ?? const []);
  }

  @override
  int compareTo(_Version other) {
    final length = numbers.length > other.numbers.length
        ? numbers.length
        : other.numbers.length;
    for (var index = 0; index < length; index++) {
      final comparison = (index < numbers.length ? numbers[index] : 0)
          .compareTo(index < other.numbers.length ? other.numbers[index] : 0);
      if (comparison != 0) return comparison;
    }
    if (prerelease.isEmpty || other.prerelease.isEmpty) {
      return prerelease.isEmpty == other.prerelease.isEmpty
          ? 0
          : prerelease.isEmpty
          ? 1
          : -1;
    }
    for (var index = 0; index < prerelease.length; index++) {
      if (index >= other.prerelease.length) return 1;
      final left = prerelease[index], right = other.prerelease[index];
      if (left == right) continue;
      final leftNumber = int.tryParse(left), rightNumber = int.tryParse(right);
      if (leftNumber != null && rightNumber != null) {
        return leftNumber.compareTo(rightNumber);
      }
      if (leftNumber != null || rightNumber != null) {
        return leftNumber != null ? -1 : 1;
      }
      return left.compareTo(right);
    }
    return prerelease.length.compareTo(other.prerelease.length);
  }
}
