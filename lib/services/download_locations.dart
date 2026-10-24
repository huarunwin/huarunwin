import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

class DownloadDirectoryOption {
  const DownloadDirectoryOption(this.label, this.directory);

  final String label;
  final Directory directory;
}

/// Package locations. History stays in the original application directory.
class DownloadLocations extends ChangeNotifier {
  DownloadLocations._(
    this._preferences,
    this.defaultDirectory,
    this._directory,
    this._roots,
    this.directoryOptions,
  );

  static const _preferenceKey = 'downloadDirectories';
  static const _legacyPreferenceKey = 'desktopDownloadDirectories';
  final SharedPreferences _preferences;
  final Directory defaultDirectory;
  Directory _directory;
  Set<String> _roots;

  /// Android only offers app-owned locations that support ordinary file I/O.
  final List<DownloadDirectoryOption>? directoryOptions;
  Future<void> _pending = Future.value();

  Directory get directory => _directory;

  static Future<DownloadLocations> load({
    required SharedPreferences preferences,
    required Directory legacyDirectory,
    required Directory defaultDirectory,
    List<DownloadDirectoryOption>? directoryOptions,
  }) async {
    final legacy = p.normalize(legacyDirectory.absolute.path);
    final fallback = p.normalize(defaultDirectory.absolute.path);
    final saved =
        preferences.getStringList(_preferenceKey) ??
        preferences.getStringList(_legacyPreferenceKey);
    final roots = <String>{
      legacy,
      if (await legacyDirectory.exists())
        p.normalize(await legacyDirectory.resolveSymbolicLinks()),
      for (final path in saved ?? const <String>[])
        if (p.isAbsolute(path)) p.normalize(path),
    };
    // Earlier versions created this directory even without any downloads.
    // Keep their files in place; fresh installations use the system Downloads.
    final selected =
        saved != null && saved.isNotEmpty && p.isAbsolute(saved.first)
        ? p.normalize(saved.first)
        : await legacyDirectory.exists()
        ? legacy
        : fallback;
    roots.add(selected);
    final locations = DownloadLocations._(
      preferences,
      Directory(fallback),
      Directory(selected),
      roots,
      directoryOptions == null ? null : List.unmodifiable(directoryOptions),
    );
    await locations._save(selected, roots);
    return locations;
  }

  /// Each task owns one immediate child folder. Selecting a nested folder later
  /// must not change which root an existing task belongs to.
  Directory? managedRoot(String filePath) {
    final rootPath = p.dirname(p.dirname(p.normalize(p.absolute(filePath))));
    for (final root in _roots) {
      if (p.equals(root, rootPath)) return Directory(root);
    }
    return null;
  }

  Future<void> refreshPreferences() => _serial(() async {
    await _preferences.reload();
    final saved = _preferences.getStringList(_preferenceKey);
    if (saved == null || saved.isEmpty || !p.isAbsolute(saved.first)) return;
    _roots = {
      ..._roots,
      for (final path in saved)
        if (p.isAbsolute(path)) p.normalize(path),
    };
    _directory = Directory(p.normalize(saved.first));
    notifyListeners();
  });

  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = _pending.then((_) => operation());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _save(String selected, Set<String> roots) async {
    if (!await _preferences.setStringList(_preferenceKey, [
      selected,
      ...roots,
    ])) {
      throw const FileSystemException('下载目录设置未能保存，请重试。');
    }
  }

  /// Persist the root before any task can create files there.
  Future<Directory> prepareDirectory() => _serial(() async {
    final selected = _directory;
    await selected.create(recursive: true);
    final canonical = p.normalize(await selected.resolveSymbolicLinks());
    if (!_roots.contains(canonical)) {
      final roots = {..._roots, canonical};
      await _save(selected.path, roots);
      _roots = roots;
    }
    return Directory(canonical);
  });

  Future<void> selectDirectory(String path) => _serial(() async {
    if (!p.isAbsolute(path)) {
      throw const FileSystemException('请选择完整的文件夹路径。');
    }
    final selected = Directory(p.normalize(path));
    if (directoryOptions case final options?) {
      if (!options.any(
        (option) => p.equals(
          p.normalize(option.directory.absolute.path),
          selected.absolute.path,
        ),
      )) {
        throw const FileSystemException('请选择应用可用的存储位置。');
      }
    }
    await selected.create(recursive: true);
    final canonical = p.normalize(await selected.resolveSymbolicLinks());
    final directory = Directory(canonical);
    // Creating a folder alone does not establish that package files can be
    // written. Use a unique, temporary probe and remove only what we created.
    final probe = await directory.createTemp('.huarun-write-');
    final file = File(p.join(probe.path, 'probe'));
    try {
      await file.writeAsBytes([0], flush: true);
    } finally {
      if (await file.exists()) await file.delete();
      await probe.delete();
    }
    final roots = {..._roots, canonical};
    // Retain the requested alias too, particularly for the default folder.
    roots.add(selected.path);
    await _save(selected.path, roots);
    _roots = roots;
    _directory = selected;
    notifyListeners();
  });

  Future<void> resetDirectory() => selectDirectory(defaultDirectory.path);
}
