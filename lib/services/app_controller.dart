import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/models.dart';
import '../data/catalog_filters.dart';
import '../data/repository.dart';
import 'content_sources.dart';
import 'download_platform.dart';

class AppController extends ChangeNotifier {
  AppController(this.repository, this.preferences) {
    sources.restore(preferences);
    _sourceRevision = sources.revision;
    sources.addListener(_sourceChanged);
    _readAppearancePreferences();
    catalogPlatform = _preferredCatalogPlatform;
  }

  void _readAppearancePreferences() {
    themeMode = switch (preferences.getString('theme')) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    catalogGrid = preferences.getBool('catalogGrid');
  }

  Future<void> refreshPreferences() async {
    await preferences.reload();
    if (_disposed) return;
    _readAppearancePreferences();
    sources.restore(preferences, notify: true);
    notifyListeners();
  }

  final CatalogRepository repository;
  final SharedPreferences preferences;
  ContentSources get sources => repository.sources;
  late int _sourceRevision;
  int _catalogRun = 0;

  void _sourceChanged() {
    if (_disposed) return;
    if (_sourceRevision == sources.revision) {
      notifyListeners();
      return;
    }
    _sourceRevision = sources.revision;
    _catalogRun++;
    stopDateLoading();
    snapshot = null;
    loading = false;
    error = null;
    updateDates.clear();
    updateDateFailures.clear();
    coreCatalogs.clear();
    deviceCatalogs.clear();
    _coreRequests.clear();
    _deviceRequests.clear();
    loadingCores.clear();
    loadingDevices.clear();
    coreErrors.clear();
    deviceErrors.clear();
    unawaited(load(refresh: true));
  }

  CatalogSnapshot? snapshot;
  bool loading = false;
  String? error;
  ThemeMode themeMode = ThemeMode.system;
  bool? catalogGrid;
  late String catalogPlatform;
  final Map<String, CatalogSnapshot> coreCatalogs = {};
  final Map<String, Future<void>> _coreRequests = {};
  final Set<String> loadingCores = {};
  final Map<String, String> coreErrors = {};
  final Map<CatalogDevice, CatalogSnapshot> deviceCatalogs = {};
  final Map<CatalogDevice, Future<void>> _deviceRequests = {};
  final Set<CatalogDevice> loadingDevices = {};
  final Map<CatalogDevice, String> deviceErrors = {};
  final Map<String, DateTime?> updateDates = {};
  final Set<String> updateDateFailures = {};
  bool loadingDates = false;
  int datesDone = 0, datesTotal = 0;
  int _dateRun = 0;
  int _activeDateRequests = 0;
  Completer<void>? _dateSlot;
  bool _disposed = false;
  Future<void> load({bool refresh = false}) async {
    if (_disposed || loading) return;
    final run = ++_catalogRun;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final result = await repository.catalog(refresh: refresh);
      if (_disposed || run != _catalogRun) return;
      snapshot = result;
      if (refresh) {
        stopDateLoading();
        updateDates.clear();
        updateDateFailures.clear();
        coreCatalogs.clear();
        deviceCatalogs.clear();
      }
    } catch (_) {
      if (!_disposed && run == _catalogRun) {
        error = '暂时无法获取应用目录，请重试或在设置中切换内容来源。';
      }
    } finally {
      if (!_disposed && run == _catalogRun) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadCore(String core, {bool refresh = false}) async {
    if (!catalogCorePaths.containsKey(core)) return;
    final pending = _coreRequests[core];
    if (pending != null) return pending;
    if (!refresh && coreCatalogs.containsKey(core)) return;
    final request = _fetchCore(core, refresh: refresh);
    _coreRequests[core] = request;
    try {
      await request;
    } finally {
      if (identical(_coreRequests[core], request)) _coreRequests.remove(core);
    }
  }

  Future<void> _fetchCore(String core, {required bool refresh}) async {
    final revision = sources.revision;
    bool isCurrent() => !_disposed && revision == sources.revision;
    loadingCores.add(core);
    coreErrors.remove(core);
    notifyListeners();
    try {
      final result = await repository.catalog(core: core, refresh: refresh);
      if (isCurrent()) coreCatalogs[core] = result;
    } catch (_) {
      if (isCurrent()) coreErrors[core] = '暂时无法加载内核分类，请重试。';
    } finally {
      if (isCurrent()) {
        loadingCores.remove(core);
        notifyListeners();
      }
    }
  }

  Future<void> loadDevice(CatalogDevice device, {bool refresh = false}) async {
    final pending = _deviceRequests[device];
    if (pending != null) return pending;
    if (!refresh && deviceCatalogs.containsKey(device)) return;
    final request = _fetchDevice(device, refresh: refresh);
    _deviceRequests[device] = request;
    try {
      await request;
    } finally {
      if (identical(_deviceRequests[device], request)) {
        _deviceRequests.remove(device);
      }
    }
  }

  Future<void> _fetchDevice(
    CatalogDevice device, {
    required bool refresh,
  }) async {
    final revision = sources.revision;
    bool isCurrent() => !_disposed && revision == sources.revision;
    loadingDevices.add(device);
    deviceErrors.remove(device);
    notifyListeners();
    try {
      final result = await repository.deviceCatalog(device, refresh: refresh);
      if (isCurrent()) deviceCatalogs[device] = result;
    } catch (_) {
      if (isCurrent()) deviceErrors[device] = '暂时无法加载设备分类，请重试。';
    } finally {
      if (isCurrent()) {
        loadingDevices.remove(device);
        notifyListeners();
      }
    }
  }

  /// Dates are absent from the catalog HTML. Fetch detail HTML only after the
  /// user selects date sorting, with at most four requests at a time.
  Future<void> loadUpdateDates(
    List<CatalogApp> apps, {
    bool retry = false,
  }) async {
    final run = ++_dateRun;
    if (retry) updateDateFailures.removeAll(apps.map((app) => app.key));
    final pending = apps
        .where(
          (app) =>
              !updateDates.containsKey(app.key) &&
              !updateDateFailures.contains(app.key),
        )
        .toList();
    datesTotal = apps.length;
    datesDone = apps.length - pending.length;
    loadingDates = pending.isNotEmpty;
    notifyListeners();
    var next = 0;
    Future<void> worker() async {
      while (!_disposed && run == _dateRun && next < pending.length) {
        while (_activeDateRequests >= 4 && !_disposed && run == _dateRun) {
          _dateSlot ??= Completer<void>();
          await _dateSlot!.future;
        }
        if (_disposed || run != _dateRun || next >= pending.length) return;
        final app = pending[next++];
        _activeDateRequests++;
        try {
          final detail = await repository.detail(app);
          if (_disposed || run != _dateRun) return;
          updateDates[app.key] = catalogDate(detail.details.updatedAt);
        } catch (_) {
          if (_disposed || run != _dateRun) return;
          updateDateFailures.add(app.key);
        } finally {
          _activeDateRequests--;
          _releaseDateSlot();
        }
        datesDone++;
        notifyListeners();
      }
    }

    await Future.wait([for (var i = 0; i < 4; i++) worker()]);
    if (!_disposed && run == _dateRun) {
      loadingDates = false;
      notifyListeners();
    }
  }

  void stopDateLoading() {
    _dateRun++;
    loadingDates = false;
    _releaseDateSlot();
  }

  void _releaseDateSlot() {
    final slot = _dateSlot;
    _dateSlot = null;
    slot?.complete();
  }

  void setCatalogGrid(bool grid) {
    catalogGrid = grid;
    preferences.setBool('catalogGrid', grid);
    notifyListeners();
  }

  String get _preferredCatalogPlatform {
    final saved = preferences.get('catalogPlatform');
    return saved is String && catalogPlatforms.contains(saved)
        ? saved
        : runningDownloadPlatform ?? '全部';
  }

  void selectCatalogPlatform(String value) {
    catalogPlatform = value;
    unawaited(preferences.setString('catalogPlatform', value));
    notifyListeners();
  }

  void restoreCatalogPlatform() {
    catalogPlatform = _preferredCatalogPlatform;
    notifyListeners();
  }

  void clearCatalogPlatform() {
    catalogPlatform = '全部';
    notifyListeners();
  }

  Future<void> resetCatalogPlatform() async {
    await preferences.remove('catalogPlatform');
    if (_disposed) return;
    restoreCatalogPlatform();
  }

  @override
  void dispose() {
    _disposed = true;
    sources.removeListener(_sourceChanged);
    stopDateLoading();
    super.dispose();
  }

  void setTheme(ThemeMode value) {
    themeMode = value;
    preferences.setString('theme', value.name);
    notifyListeners();
  }
}
