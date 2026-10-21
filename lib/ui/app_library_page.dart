import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../data/models.dart';
import '../services/app_controller.dart';
import '../services/app_download_status.dart';
import '../services/app_library.dart';
import '../services/download_platform.dart';
import '../services/downloads.dart';
import 'app_download_button.dart';
import 'app_library_navigation.dart';
import 'app_library_overview.dart';
import 'catalog_controls.dart';
import 'components.dart';
import 'detail.dart';
import 'downloads_page.dart';
import 'page_components.dart';
import 'theme.dart';

enum _LibrarySort { updates, recent, name }

class AppLibraryPage extends StatefulWidget {
  const AppLibraryPage({
    super.key,
    required this.controller,
    required this.manager,
    this.showBackButton = false,
    this.initialSection = LibrarySection.all,
    this.selectionRevision = 0,
    this.active = true,
  });

  final AppController controller;
  final DownloadManager manager;
  final bool showBackButton;
  final LibrarySection initialSection;
  final int selectionRevision;
  final bool active;

  @override
  State<AppLibraryPage> createState() => _AppLibraryPageState();
}

class _AppLibraryPageState extends State<AppLibraryPage>
    with WidgetsBindingObserver {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final _detailChanges = ValueNotifier(0);
  final _managedPackageNames = <String>{};
  late LibrarySection _section = widget.initialSection;
  _LibrarySort _sort = _LibrarySort.updates;
  Map<String, LibraryAppStatus> _statuses = {};
  Map<String, AppDownloadStatus?> _androidPackages = {};
  CatalogSnapshot? _catalog;
  late int _sourceRevision = widget.controller.sources.revision;
  int? _taskSignature;
  int _generation = 0;
  bool _checking = true,
      _refreshing = false,
      _checkAgain = false,
      _online = false,
      _statusCheckFailed = false,
      _hasSnapshot = false;
  Future<void>? _checks, _refreshRequest;
  String? _refreshError, _statusError;

  String? get _platform => runningDownloadPlatform;
  List<CatalogApp> get _apps => widget.controller.snapshot?.apps ?? const [];
  int get _signature => Object.hashAll([
    widget.manager.apkMetadataRevision,
    for (final task in widget.manager.tasks)
      Object.hash(
        task.id,
        task.state,
        task.checking,
        task.deleting,
        task.packageAvailable,
        task.originalAvailable,
        task.installedPath,
        task.installedPackage,
        task.resignedSha256,
        task.removedPackages.length,
      ),
  ]);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.manager.addListener(_changed);
    widget.controller.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.active) unawaited(_refresh(online: false));
    });
  }

  @override
  void didUpdateWidget(covariant AppLibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialSection != widget.initialSection ||
        oldWidget.selectionRevision != widget.selectionRevision) {
      _section = widget.initialSection;
      if (_section == LibrarySection.downloads) _resetDownloadSearch();
    }
    final dependenciesChanged =
        oldWidget.manager != widget.manager ||
        oldWidget.controller != widget.controller;
    if (dependenciesChanged) {
      oldWidget.manager.removeListener(_changed);
      oldWidget.controller.removeListener(_changed);
      widget.manager.addListener(_changed);
      widget.controller.addListener(_changed);
      _statuses = {};
      _sourceRevision = widget.controller.sources.revision;
      _androidPackages = {};
      _hasSnapshot = false;
      _generation++;
    }
    if (oldWidget.active && !widget.active) _generation++;
    if (widget.active && (!oldWidget.active || dependenciesChanged)) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await _refreshRequest;
        if (mounted && widget.active) unawaited(_refresh(online: false));
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (widget.active && state == AppLifecycleState.resumed) {
      unawaited(_refresh(online: false));
    }
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    widget.manager.removeListener(_changed);
    widget.controller.removeListener(_changed);
    _search.dispose();
    _scroll.dispose();
    _detailChanges.dispose();
    super.dispose();
  }

  void _changed() {
    final signature = _signature;
    final sourceChanged = _sourceRevision != widget.controller.sources.revision;
    if (!sourceChanged &&
        signature == _taskSignature &&
        _catalog == widget.controller.snapshot) {
      return;
    }
    if (sourceChanged) {
      _sourceRevision = widget.controller.sources.revision;
      // Keep local installation facts, but never reuse another source's
      // release details as the result of the new source's update check.
      _statuses = {
        for (final entry in _statuses.entries)
          entry.key: LibraryAppStatus(entry.value.local),
      };
      _statusError = null;
    }
    _taskSignature = signature;
    _catalog = widget.controller.snapshot;
    _generation++;
    _checkAgain = true;
    _detailChanges.value++;
    if (!_refreshing && !widget.manager.refreshing) unawaited(_check());
  }

  Future<void> _refresh({bool online = true}) {
    if (!widget.active) return Future.value();
    if (_refreshRequest case final pending?) return pending;
    final request = _refreshLibrary(online: online);
    _refreshRequest = request;
    return request.whenComplete(() => _refreshRequest = null);
  }

  Future<void> _refreshLibrary({required bool online}) async {
    setState(() {
      _refreshing = true;
      _refreshError = null;
    });
    _detailChanges.value++;
    _generation++;
    if (_platform == 'macOS') widget.manager.installedApps.invalidate();
    try {
      await widget.manager.refresh();
    } catch (_) {
      if (mounted) _refreshError = '部分文件状态未能刷新，已保留记录。';
    }
    if (!mounted) return;
    if (!widget.active) {
      setState(() => _refreshing = false);
      return;
    }
    if (online || widget.controller.snapshot == null) {
      await widget.controller.load(refresh: online);
    }
    if (!mounted) return;
    setState(() => _refreshing = false);
    _online = _online || online;
    await _check();
  }

  Future<void> _check() {
    _checkAgain = true;
    if (!widget.active) return Future.value();
    if (_checks case final pending?) return pending;
    final request = _readStatuses();
    _checks = request;
    return request.whenComplete(() {
      _checks = null;
      if (mounted && widget.active && _checkAgain && !_refreshing) {
        unawaited(_check());
      }
    });
  }

  Future<void> _readStatuses() async {
    setState(() => _checking = true);
    _detailChanges.value++;
    try {
      do {
        _checkAgain = false;
        final generation = _generation;
        final online = _online;
        _online = false;
        bool isCurrent() =>
            mounted &&
            widget.active &&
            !_refreshing &&
            generation == _generation;
        try {
          final result = await readLibraryStatus(
            apps: _apps,
            repository: widget.controller.repository,
            manager: widget.manager,
            platform: _platform,
            isCurrent: isCurrent,
            refresh: online,
            knownAndroidPackages: _managedPackageNames,
          );
          if (!isCurrent()) continue;
          setState(() {
            _statuses = {
              for (final entry in result.apps.entries)
                entry.key:
                    entry.value.updateCheckFailed && entry.value.details == null
                    ? LibraryAppStatus(
                        entry.value.local,
                        details: _statuses[entry.key]?.details,
                        updateCheckFailed: true,
                      )
                    : entry.value,
            };
            _androidPackages = result.androidPackages;
            _statusCheckFailed = false;
            _hasSnapshot = true;
            _statusError = result.updateCheckFailed
                ? '部分应用未能获取最新版本，已保留上次结果，请重试。'
                : null;
          });
        } catch (_) {
          if (isCurrent()) {
            setState(() {
              _hasSnapshot = true;
              _statusCheckFailed = true;
              _statusError = '应用状态未能检查，已保留上次结果，请重试。';
            });
          }
        }
      } while (mounted && widget.active && !_refreshing && _checkAgain);
    } finally {
      if (mounted) {
        setState(() => _checking = false);
        _detailChanges.value++;
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.manager,
    builder: (context, _) {
      final items = libraryItems(
        apps: _apps,
        manager: widget.manager,
        statuses: _statuses,
        androidPackages: _androidPackages,
        platform: _platform,
      );
      final query = _search.text.trim().toLowerCase();
      final visible = items
          .where(
            (item) =>
                item.matches(_section) &&
                (query.isEmpty ||
                    [
                      item.name,
                      item.app?.alias ?? '',
                      for (final file in item.files)
                        p.basename(
                          file.task.packagePath(
                            file.package ?? file.task.defaultPackage,
                          ),
                        ),
                    ].any((text) => text.toLowerCase().contains(query))),
          )
          .toList();
      final positions = {for (var i = 0; i < items.length; i++) items[i].id: i};
      int priority(LibraryItem item) => item.activeTasks.isNotEmpty
          ? 0
          : item.updateVersion != null
          ? 1
          : item.hasPendingPackage
          ? 2
          : item.isInstalled
          ? 3
          : 4;
      visible.sort((a, b) {
        if (_sort == _LibrarySort.updates) {
          final order = priority(a).compareTo(priority(b));
          if (order != 0) return order;
        }
        final order = _sort == _LibrarySort.name
            ? a.name.toLowerCase().compareTo(b.name.toLowerCase())
            : b.modifiedAt.compareTo(a.modifiedAt);
        return order != 0
            ? order
            : positions[a.id]!.compareTo(positions[b.id]!);
      });
      final notices = [
        widget.manager.historyWarning,
        widget.manager.downloadWarning,
        _refreshError ?? _statusError ?? widget.controller.error,
      ].nonNulls;
      return Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040),
          child: LayoutBuilder(
            builder: (context, size) {
              final compact = size.maxWidth < 600;
              final inset = compact ? 16.0 : 32.0;
              return PageRefreshIndicator(
                onRefresh: _refresh,
                child: CustomScrollView(
                  controller: _scroll,
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        inset,
                        (compact ? 16 : 34) + PageSafeArea.topInsetOf(context),
                        inset,
                        0,
                      ),
                      sliver: SliverToBoxAdapter(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            PageHeader(
                              title: '应用库',
                              titleStyle: Theme.of(context)
                                  .textTheme
                                  .headlineMedium,
                              showBackButton: widget.showBackButton,
                              actions: [
                                RefreshIconButton(
                                  tooltip: '刷新应用库',
                                  loading: _refreshing || _checking,
                                  onPressed: _refresh,
                                ),
                                if ([
                                  'macOS',
                                  'Android',
                                  'Windows',
                                  'Linux',
                                ].contains(_platform))
                                  IconButton(
                                    tooltip: '导入安装包',
                                    icon: const Icon(Icons.add_rounded),
                                    onPressed: () => _openFiles(import: true),
                                  ),
                              ],
                            ),
                            CatalogSearchPanel(
                              grouped: !compact,
                              builder: (context) => Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  CatalogSearchField(
                                    controller: _search,
                                    hintText: '搜索应用与安装包',
                                    compact: compact,
                                    onChanged: (_) => setState(() {}),
                                  ),
                                  const SizedBox(height: 12),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: _sectionMenu(
                                      items,
                                      compact: compact,
                                    ),
                                  ),
                                  if (!compact) const SizedBox(height: 16),
                                ],
                              ),
                            ),
                            if (usesMobileDesign(context))
                              const SizedBox(height: 12),
                            _resultToolbar(visible.length, compact: compact),
                            for (final error in notices)
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Wrap(
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    Text(error),
                                    TextButton(
                                      onPressed: _refreshing || _checking
                                          ? null
                                          : _refresh,
                                      child: const Text('重试'),
                                    ),
                                  ],
                                ),
                              ),
                            const SizedBox(height: 16),
                          ],
                        ),
                      ),
                    ),
                    if (visible.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: (_checking || _refreshing) && query.isEmpty
                            ? const Center(
                                child: CircularProgressIndicator(
                                  semanticsLabel: '正在检查应用库',
                                ),
                              )
                            : EmptyState(
                                icon: Icons.apps_rounded,
                                title: query.isNotEmpty
                                    ? '没有匹配的应用'
                                    : switch (_section) {
                                        LibrarySection.updates =>
                                          _statusError == null
                                              ? '暂无可更新的应用'
                                              : '更新检查未完成',
                                        LibrarySection.installed =>
                                          '暂无已确认安装的应用',
                                        LibrarySection.pending => '暂无待安装的应用',
                                        LibrarySection.downloads => '暂无下载任务',
                                        LibrarySection.all => '应用库为空',
                                      },
                                message: query.isNotEmpty
                                    ? '试试其他名称或文件名。'
                                    : '下载、导入或安装的应用会显示在这里。',
                              ),
                      )
                    else
                      SliverPadding(
                        padding: EdgeInsets.fromLTRB(
                          inset,
                          0,
                          inset,
                          32 + PageBottomInset.of(context),
                        ),
                        sliver: SliverList.separated(
                          itemCount: visible.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (context, index) =>
                              _item(visible[index]),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      );
    },
  );

  Widget _sectionMenu(List<LibraryItem> items, {required bool compact}) {
    final label = _section == LibrarySection.all ? '状态' : _section.label;
    final tooltip = '应用状态：${_section.label}';
    String optionLabel(LibrarySection section) => _hasSnapshot
        ? '${section.label} ${items.where((item) => item.matches(section)).length}'
        : section.label;
    void select(LibrarySection value) => setState(() => _section = value);

    if (compact) {
      final width = CompactCatalogMenu.widthOf(context, label);
      return SizedBox(
        width: width < 120 ? 120 : width,
        child: CompactCatalogMenu<LibrarySection>(
          key: const ValueKey('library-status-menu'),
          label: label,
          title: '应用状态',
          tooltip: tooltip,
          selected: _section,
          values: LibrarySection.values,
          labelFor: optionLabel,
          optionKey: (value) => ValueKey('library-status-${value.name}'),
          active: _section != LibrarySection.all,
          onChanged: select,
        ),
      );
    }
    return CatalogMenu<LibrarySection>(
      key: const ValueKey('library-status-menu'),
      label: label,
      tooltip: tooltip,
      selected: _section,
      values: LibrarySection.values,
      labelFor: optionLabel,
      optionKey: (value) => ValueKey('library-status-${value.name}'),
      active: _section != LibrarySection.all,
      onSelected: select,
    );
  }

  Widget _resultToolbar(int count, {required bool compact}) {
    final label = _sortLabel(_sort);
    void select(_LibrarySort value) => setState(() => _sort = value);

    return CatalogToolbar(
      count: _hasSnapshot ? '$count 款应用' : null,
      grid: false,
      showViewSwitch: false,
      onGridChanged: (_) {},
      sort: compact
          ? SizedBox(
              width: CompactCatalogMenu.widthOf(context, label),
              child: CompactCatalogMenu<_LibrarySort>(
                key: const ValueKey('library-sort-menu'),
                label: label,
                title: '排序方式',
                selected: _sort,
                values: _LibrarySort.values,
                labelFor: _sortLabel,
                optionKey: (value) => ValueKey('library-sort-${value.name}'),
                active: _sort != _LibrarySort.updates,
                onChanged: select,
              ),
            )
          : CatalogMenu<_LibrarySort>(
              key: const ValueKey('library-sort-menu'),
              label: label,
              tooltip: '排序方式：$label',
              selected: _sort,
              values: _LibrarySort.values,
              labelFor: _sortLabel,
              optionKey: (value) => ValueKey('library-sort-${value.name}'),
              active: _sort != _LibrarySort.updates,
              onSelected: select,
            ),
    );
  }

  String _sortLabel(_LibrarySort value) => switch (value) {
    _LibrarySort.updates => '更新优先',
    _LibrarySort.recent => '最近修改',
    _LibrarySort.name => '名称',
  };

  String _summary(LibraryItem item) {
    final active = item.activeTasks;
    if (active.length > 1) return '${active.length} 个任务进行中';
    if (active.isNotEmpty) {
      final task = active.single;
      return task.checking
          ? '正在检查'
          : switch (task.state) {
              DownloadState.queued => '等待下载',
              DownloadState.downloading =>
                '下载中 · ${bytesLabel(task.received)}${task.total > 0 ? ' / ${bytesLabel(task.total)}' : ''}',
              DownloadState.verifying => '正在校验',
              DownloadState.resigning => '正在重签',
              DownloadState.installing => task.installPhase ?? '正在安装',
              _ => '正在处理',
            };
    }
    if (_section == LibrarySection.downloads &&
        item.tasks.any(
          (task) =>
              task.state == DownloadState.failed ||
              task.state == DownloadState.cancelled,
        )) {
      return '有未完成的任务';
    }
    final pending = item.pendingPackages;
    if (pending.isNotEmpty) {
      if (pending.any((file) => file.task.state == DownloadState.handedOff)) {
        return '已交给系统 · 安装结果待确认';
      }
      final file = pending.singleOrNull;
      final version = file?.task.packageVersion(
        file.package ?? file.task.defaultPackage,
      );
      return '待安装${version == null ? '' : ' · $version'}';
    }
    if (item.updateVersion case final version?) {
      return '${item.status!.local.version} → $version';
    }
    final installed = item.installations;
    if (installed.length > 1) return '${installed.length} 个已安装应用';
    if (installed.isNotEmpty) {
      return '已安装${installed.single.version == null ? '' : ' · ${installed.single.version}'}';
    }
    if (item.tasks.any((task) => task.state == DownloadState.handedOff)) {
      return '已交给系统 · 安装结果待确认';
    }
    if (item.tasks.any((task) => task.state == DownloadState.failed)) {
      return '任务失败';
    }
    if (item.tasks.any((task) => task.state == DownloadState.cancelled)) {
      return '已取消';
    }
    return '已下载';
  }

  Widget _item(LibraryItem item) {
    final active = item.activeTasks;
    final label = _summary(item);
    final metadata = [
      label,
      if (item.files.isNotEmpty) '${item.files.length} 个文件',
      if (item.files.isNotEmpty && !item.isInstalled)
        ...item.tasks
            .map((task) => task.platform)
            .nonNulls
            .toSet()
            .map(downloadPlatformLabel),
    ].join(' · ');
    final action = _action(item);
    return SurfacePanel(
      key: ValueKey(item.id),
      child: InkWell(
        onTap: () => _openItem(item),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: LayoutBuilder(
            builder: (context, size) {
              final compact =
                  size.maxWidth < 360 ||
                  MediaQuery.textScalerOf(context).scale(14) > 20;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      if (item.app case final app?)
                        AppIcon(app, size: 44)
                      else
                        const IconWell(Icons.inventory_2_outlined, size: 44),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              metadata,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                            ),
                          ],
                        ),
                      ),
                      if (!compact && action != null) ...[
                        const SizedBox(width: 12),
                        action,
                      ],
                      const SizedBox(width: 4),
                      const Icon(Icons.chevron_right_rounded, size: 18),
                    ],
                  ),
                  if (active.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    LinearProgressIndicator(
                      value:
                          active.length == 1 &&
                              active.single.state == DownloadState.downloading
                          ? active.single.progress
                          : null,
                      semanticsLabel: label,
                    ),
                  ],
                  if (compact && action != null) ...[
                    const SizedBox(height: 8),
                    Align(alignment: Alignment.centerRight, child: action),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget? _action(
    LibraryItem item, {
    BuildContext? pageContext,
    ValueChanged<DownloadEntry>? onInstall,
  }) {
    final managing = pageContext != null;
    final active = item.activeTasks;
    if (active.isNotEmpty) {
      if (active.length != 1 ||
          active.single.checking ||
          active.single.state == DownloadState.installing) {
        return null;
      }
      return TextButton(
        onPressed: () => widget.manager.cancel(active.single),
        child: const Text('取消'),
      );
    }
    if ((_section == LibrarySection.downloads || managing) &&
        item.tasks.length == 1 &&
        [
          DownloadState.failed,
          DownloadState.cancelled,
        ].contains(item.tasks.single.state)) {
      final task = item.tasks.single;
      if (task.url.isNotEmpty || task.wantsResign) {
        return TextButton(
          onPressed: () async {
            try {
              await widget.manager.retry(task);
            } catch (_) {
              if (!mounted) return;
              final currentContext = pageContext ?? context;
              if (currentContext.mounted) {
                ScaffoldMessenger.of(currentContext).showSnackBar(
                  const SnackBar(content: Text('未能重试，请查看安装包的失败详情。')),
                );
              }
            }
          },
          child: const Text('重试'),
        );
      }
    }
    final pending = item.pendingPackages;
    if (pending.isNotEmpty) {
      final file = pending.singleOrNull;
      final installable =
          file != null &&
          item.installations.length <= 1 &&
          !file.task.deleting &&
          (file.package == null
              ? file.task.canInstallOn(_platform)
              : file.task.canInstallPackageOn(_platform, file.package!));
      // Multiple files/identities keep their individual controls below.
      if (managing && !installable) return null;
      return FilledButton(
        style: downloadButtonStyle(context),
        onPressed: managing && installable
            ? () => onInstall!(file)
            : () => _openFiles(item: item, install: installable ? file : null),
        child: Text(installable ? '安装' : '查看'),
      );
    }
    if (item.app != null &&
        item.status?.details != null &&
        item.installations.length == 1) {
      return AppDownloadButton(
        app: item.app!,
        manager: widget.manager,
        selectedPlatform: _platform ?? '全部',
        compact: true,
        // Reuse the library's bounded detail check. Failed or missing version
        // checks retain the separate open action below.
        details: item.status!.details,
        loadDetails: () async =>
            (await widget.controller.repository.detail(item.app!)).details,
        onStarted: () => _showDownloads(pageContext),
      );
    }
    if (item.installations.length == 1) {
      return FilledButton(
        style: downloadButtonStyle(context),
        onPressed: () => _openInstallation(
          item.installations.single,
          pageContext ?? context,
        ),
        child: const Text('打开'),
      );
    }
    if (item.installations.length > 1 && !managing) {
      return FilledButton(
        style: downloadButtonStyle(context),
        onPressed: () => _openFiles(item: item),
        child: const Text('查看'),
      );
    }
    if (managing &&
        item.files.isEmpty &&
        item.installations.isEmpty &&
        item.app != null) {
      final app = item.app!;
      return AppDownloadButton(
        app: app,
        manager: widget.manager,
        selectedPlatform: _platform ?? '全部',
        compact: true,
        loadDetails: () async =>
            (await widget.controller.repository.detail(app)).details,
        onStarted: () => _showDownloads(pageContext),
      );
    }
    return null;
  }

  Future<void> _openInstallation(
    AppDownloadStatus installed,
    BuildContext pageContext,
  ) async {
    try {
      if (installed.installedPackage case final package?) {
        await widget.manager.installer.openAndroidApp(package);
      } else if (installed.installedPath case final path?) {
        if (_platform == 'Linux') {
          await widget.manager.installer.openAppImage(path);
        } else {
          await widget.manager.installer.openApp(path);
        }
      }
    } catch (_) {
      if (mounted && pageContext.mounted) {
        ScaffoldMessenger.of(pageContext)
            .showSnackBar(const SnackBar(content: Text('应用未能打开，请刷新后重试。')));
        unawaited(_refresh(online: false));
      }
    }
  }

  void _showDownloads(BuildContext? pageContext) {
    if (!mounted || pageContext != null && !pageContext.mounted) return;
    if (pageContext != null &&
        AppLibraryNavigation.showDownloads(pageContext)) {
      return;
    }
    if (pageContext != null) Navigator.of(pageContext).pop();
    setState(() {
      _section = LibrarySection.downloads;
      _resetDownloadSearch();
    });
  }

  void _resetDownloadSearch() {
    _search.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  Future<void> _openItem(LibraryItem item) => _openFiles(item: item);

  Future<void> _showAppDetails(BuildContext pageContext, CatalogApp app) async {
    await Navigator.push<void>(
      pageContext,
      MaterialPageRoute(
        builder: (_) => DetailPage(
          app: app,
          controller: widget.controller,
          downloads: widget.manager,
          selectedPlatform: _platform ?? '全部',
        ),
      ),
    );
    if (mounted) unawaited(_refresh(online: false));
  }

  Future<void> _openFiles({
    LibraryItem? item,
    DownloadEntry? install,
    bool import = false,
  }) async {
    final knownPackages = <String>{
      if (item != null) ...[
        for (final installed in item.installations) ?installed.installedPackage,
        for (final task in item.tasks)
          for (final package in task.androidPackages)
            ?task.packageName(package),
      ],
    };
    _managedPackageNames.addAll(knownPackages);
    try {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => Scaffold(
            body: PageSafeArea(
              child: ListenableBuilder(
                listenable: _detailChanges,
                builder: (pageContext, _) => DownloadsPage(
                  manager: widget.manager,
                  showBackButton: true,
                  title: item == null ? '安装包与资源' : '应用管理',
                  taskIds: item?.taskIds,
                  appKey: item?.app?.key,
                  initialTask: install?.task,
                  initialPackage: install?.package,
                  importOnEntry: import,
                  onRefresh: item == null
                      ? null
                      : (online) => _refresh(online: online),
                  overviewBuilder: item == null
                      ? null
                      : (context, entries, onInstall) {
                          // Keep identities observed while this page is open,
                          // including newly generated copies, for a fresh
                          // native check after their download records are gone.
                          for (final entry in entries) {
                            if (entry.task.platform == 'Android') {
                              final name = entry.task.packageName(
                                entry.package ?? entry.task.defaultPackage,
                              );
                              if (name != null) knownPackages.add(name);
                            }
                          }
                          _managedPackageNames.addAll(knownPackages);
                          final app =
                              _apps
                                  .where((app) => app.key == item.app?.key)
                                  .firstOrNull ??
                              item.app;
                          final current = LibraryItem(
                            id: item.id,
                            name: app?.name ?? item.name,
                            app: app,
                            platform: _platform,
                            status: _statuses[app?.key],
                            androidPackages: _androidPackages,
                            additionalInstallations: [
                              for (final package in knownPackages)
                                ?_androidPackages[package],
                            ],
                          )..files.addAll(entries);
                          return AppLibraryOverview(
                            item: current,
                            action: _action(
                              current,
                              pageContext: context,
                              onInstall: onInstall,
                            ),
                            checking: _refreshing || _checking,
                            warning:
                                _refreshError ??
                                (_statusCheckFailed ? _statusError : null),
                            onOpenInstallation: (installed) =>
                                _openInstallation(installed, context),
                            onCheckUpdates: app == null
                                ? null
                                : () => _refresh(),
                            onViewDetails: app == null
                                ? null
                                : () => _showAppDetails(context, app),
                          );
                        },
                ),
              ),
            ),
          ),
        ),
      );
    } finally {
      _managedPackageNames.removeAll(knownPackages);
      if (mounted) unawaited(_refresh(online: false));
    }
  }
}
