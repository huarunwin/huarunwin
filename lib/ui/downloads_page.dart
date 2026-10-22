import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../services/downloads.dart';
import '../services/download_platform.dart';
import '../services/github_releases.dart';
import '../services/mac_downloads.dart';
import 'components.dart';
import 'adaptive_dialog.dart';
import 'android_install_dialog.dart';
import 'app_update_installation.dart';
import 'apk_file_details.dart';
import '../services/android_package.dart';
import 'page_components.dart';
import 'release_download_dialog.dart';
import 'theme.dart';

typedef DownloadsOverviewBuilder = Widget Function(
  BuildContext context,
  List<DownloadEntry> entries,
  ValueChanged<DownloadEntry> onInstall,
);

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({
    super.key,
    required this.manager,
    this.showBackButton = false,
    this.initialTask,
    this.initialPackage,
    this.taskIds,
    this.appKey,
    this.title = '安装包与资源',
    this.importOnEntry = false,
    this.overviewBuilder,
    this.onRefresh,
  });
  final DownloadManager manager;
  final bool showBackButton;
  final DownloadTask? initialTask;
  final DownloadPackage? initialPackage;
  final Set<String>? taskIds;
  final String? appKey;
  final String title;
  final bool importOnEntry;
  final DownloadsOverviewBuilder? overviewBuilder;
  final Future<void> Function(bool online)? onRefresh;
  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  bool importing = false;
  Future<void>? _refreshRequest;
  bool get _refreshing => _refreshRequest != null || widget.manager.refreshing;
  String? get _platform => runningDownloadPlatform;
  List<String> get _importKinds => switch (_platform) {
    'macOS' => ['dmg', 'zip', 'pkg'],
    'Android' => ['apk'],
    'Windows' => ['exe', 'msi', 'msix', 'zip'],
    'Linux' => ['deb', 'rpm', 'zst', 'appimage', 'zip'],
    _ => [],
  };

  @override
  void initState() {
    super.initState();
    _refreshOnEntry();
    if (widget.initialTask case final task?) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _install(task, package: widget.initialPackage);
      });
    } else if (widget.importOnEntry) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _import();
      });
    }
  }

  @override
  void didUpdateWidget(covariant DownloadsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.manager != oldWidget.manager) _refreshOnEntry();
  }

  void _refreshOnEntry() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refresh(online: false);
    });
  }

  Future<void> _refresh({bool online = true}) {
    if (_refreshRequest case final pending?) return pending;
    final request = _refreshState(online: online);
    setState(() {
      _refreshRequest = request;
    });
    return request.whenComplete(() {
      if (mounted) setState(() => _refreshRequest = null);
    });
  }

  Future<void> _refreshState({required bool online}) async {
    try {
      if (widget.onRefresh case final refresh?) {
        await refresh(online);
      } else {
        await widget.manager.refresh();
      }
    } catch (_) {
      if (mounted) _message('部分文件状态未能刷新，已保留原有记录，请稍后重试。');
    }
  }

  bool _includes(DownloadTask task) {
    final selected = widget.taskIds;
    if (selected == null) return true;
    if (widget.appKey != null &&
        task.appKey == widget.appKey &&
        task.kind != 'resource' &&
        !task.isSelfUpdate) {
      return true;
    }
    final visited = <String>{};
    DownloadTask? current = task;
    while (current != null && visited.add(current.id)) {
      if (selected.contains(current.id) ||
          selected.contains(current.sourceTaskId)) {
        return true;
      }
      final source = current.sourceTaskId;
      current = widget.manager.tasks
          .where((item) => item.id == source)
          .firstOrNull;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.manager,
    builder: (context, _) => Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1040),
        child: LayoutBuilder(
          builder: (context, size) {
            final inset = size.maxWidth < 600 ? 16.0 : 32.0;
            final entries = widget.manager.entries
                .where((entry) => _includes(entry.task))
                .toList();
            final entryIndexes = {
              for (var index = 0; index < entries.length; index++)
                ValueKey(
                  '${entries[index].task.id}:${entries[index].package?.name}',
                ): index,
            };
            final actions = [
              RefreshIconButton(
                tooltip: '刷新下载状态',
                loading: _refreshing,
                onPressed: _refresh,
              ),
              if (_importKinds.isNotEmpty && widget.taskIds == null)
                IconButton(
                  tooltip:
                      '安装本地 ${_importKinds.map((v) => v.toUpperCase()).join(' / ')}',
                  onPressed: importing ? null : _import,
                  icon: importing
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.add_rounded),
                ),
            ];
            return PageRefreshIndicator(
              onRefresh: _refresh,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      inset,
                      (size.maxWidth < 600 ? 16 : 28) +
                          PageSafeArea.topInsetOf(context),
                      inset,
                      0,
                    ),
                    sliver: SliverToBoxAdapter(
                      child: PageHeader(
                        title: widget.title,
                        actions: actions,
                        showBackButton: widget.showBackButton,
                      ),
                    ),
                  ),
                  if (widget.overviewBuilder case final builder?)
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(inset, 0, inset, 16),
                      sliver: SliverToBoxAdapter(
                        child: builder(
                          context,
                          entries,
                          (entry) =>
                              _install(entry.task, package: entry.package),
                        ),
                      ),
                    ),
                  for (final warning in [
                    widget.manager.historyWarning,
                    widget.manager.downloadWarning,
                  ].nonNulls)
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(inset, 0, inset, 16),
                      sliver: SliverToBoxAdapter(
                        child: Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(warning),
                            TextButton(
                              onPressed: _refreshing ? null : _refresh,
                              child: const Text('重试'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (entries.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: EmptyState(
                        icon: Icons.download_for_offline_outlined,
                        title: widget.taskIds != null ? '暂无本地安装包' : '下载准备就绪',
                        message: widget.taskIds != null
                            ? '此应用没有保存在应用库中的安装包。'
                            : _platform == 'macOS'
                            ? '在应用详情页下载，或选择本地 DMG / ZIP / PKG 安装包。'
                            : _platform == 'Android'
                            ? '在应用详情页下载，或选择本地 APK 安装包。'
                            : _platform == 'Windows'
                            ? '下载或导入 EXE / MSI / MSIX 安装包，通过系统安装器完成安装；ZIP 需手动解压。'
                            : _platform == 'Linux'
                            ? '下载或导入 AppImage、DEB、RPM、Arch 包或 ZIP。AppImage 安装到用户目录，软件包交由系统工具处理。'
                            : Platform.isIOS
                            ? '在应用详情页选择安装包后，由系统浏览器完成下载。'
                            : '在应用详情页选择安装包，即可开始下载。',
                        action:
                            _importKinds.isNotEmpty && widget.taskIds == null
                            ? FilledButton.icon(
                                onPressed: importing ? null : _import,
                                icon: const Icon(
                                  Icons.folder_open_rounded,
                                  size: 18,
                                ),
                                label: const Text('选择本地安装包'),
                              )
                            : null,
                      ),
                    )
                  else
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(inset, 0, inset, 32),
                      sliver: SliverList.separated(
                        itemCount: entries.length,
                        findItemIndexCallback: (key) => entryIndexes[key],
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final entry = entries[index];
                          return KeyedSubtree(
                            key: ValueKey(
                              '${entry.task.id}:${entry.package?.name}',
                            ),
                            child: _task(entry.task, package: entry.package),
                          );
                        },
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    ),
  );

  Widget _task(DownloadTask task, {DownloadPackage? package}) {
    final colors = Theme.of(context).colorScheme;
    final isApk = package != null;
    final selected = package ?? task.defaultPackage;
    final isOperation = !isApk || selected == task.operationPackage;
    final available = isApk ? task.hasPackage(selected) : task.packageAvailable;
    final installed =
        task.state == DownloadState.installed &&
        (!isApk ||
            selected == (task.installedApkPackage ?? task.defaultPackage));
    final canInstall = task.isSelfUpdate
        ? task.canInstallOn(_platform)
        : isApk
        ? task.canInstallPackageOn(_platform, selected) && !installed
        : task.canInstallOn(_platform);
    final status = isApk
        ? _apkStatus(task, selected)
        : switch (task.state) {
            DownloadState.queued => '等待下载',
            DownloadState.downloading => '下载中',
            DownloadState.verifying => '正在校验',
            DownloadState.resigning => '正在重签',
            DownloadState.downloaded =>
              task.wantsResign
                  ? task.resignReady
                        ? '重签完成'
                        : '重签未完成'
                  : '下载完成',
            DownloadState.cancelled => '已取消',
            DownloadState.failed => '下载失败',
            DownloadState.installing => '正在安装',
            DownloadState.installed => '已安装',
            DownloadState.handedOff => '已交给系统',
          };
    return SurfacePanel(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconWell(
                installed
                    ? Icons.check_circle_outline_rounded
                    : Icons.inventory_2_outlined,
                size: 40,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  task.appName,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              const SizedBox(width: 8),
              Pill(status, accent: installed),
            ],
          ),
          const SizedBox(height: 12),
          if (!isApk && task.version != null) ...[
            Text('版本：${task.version}'),
            const SizedBox(height: 6),
          ],
          if (isApk) ...[
            Text(
              task.packageLabel(selected),
              style: Theme.of(context).textTheme.labelLarge,
            ),
            Text(
              selected == DownloadPackage.original
                  ? '原包名 · 原签名'
                  : task.isRenamedPackage(selected)
                  ? '修改包名 · 个人签名'
                  : '包名不变 · 个人签名',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 6),
          ],
          Text(
            p.basename(task.packagePath(selected)),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
          if (isApk && available)
            ApkFileDetails(
              key: ValueKey('${task.id}:${selected.name}:details'),
              task: task,
              package: selected,
              manager: widget.manager,
              revision: widget.manager.apkMetadataRevision,
              readable: !task.busy && !task.deleting,
              fingerprint:
                  '${task.packagePath(selected)}:${task.verifiedSha256}:${task.resignedSha256}:${task.packageSortTime(selected).microsecondsSinceEpoch}',
            ),
          if (!isApk || selected == DownloadPackage.original && !available)
            Text(
              '${task.kind == 'resource' ? '资源 · 仅下载' : task.kind.toUpperCase()}${task.platform == null ? '' : ' · ${task.platform}'} · ${bytesLabel(task.received)}${task.total > 0 ? ' / ${bytesLabel(task.total)} · ${(task.progress! * 100).toStringAsFixed(0)}%' : ''}',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          if (isOperation &&
              (task.state == DownloadState.downloading ||
                  task.state == DownloadState.resigning ||
                  task.state == DownloadState.verifying ||
                  task.state == DownloadState.installing)) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(
              value:
                  task.state == DownloadState.installing ||
                      task.state == DownloadState.resigning ||
                      task.state == DownloadState.verifying
                  ? null
                  : task.progress,
              minHeight: 4,
            ),
          ],
          if (isOperation && task.installPhase != null) ...[
            const SizedBox(height: 8),
            Text(
              _phaseLabel(task.installPhase!),
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
          ],
          if (task.checking &&
              (!isApk || task.androidCheckingPackage == selected)) ...[
            const SizedBox(height: 8),
            const Text('正在检查安装包…'),
          ],
          if (task.state == DownloadState.handedOff && isOperation) ...[
            const SizedBox(height: 8),
            Text(
              ['Windows', 'Linux'].contains(task.platform) && task.kind == 'zip'
                  ? '已打开压缩包，请选择位置并手动解压；应用安装结果尚未确认。'
                  : '请在系统窗口中完成安装，安装结果尚未确认。',
            ),
          ],
          if (available &&
              !task.busy &&
              selected == DownloadPackage.original) ...[
            const SizedBox(height: 8),
            Text(
              task.checksumVerified
                  ? task.wantsResign
                        ? '原始 APK 的公开 SHA-256 已验证'
                        : 'SHA-256 已验证'
                  : task.sha256 != null
                  ? 'SHA-256 尚未验证'
                  : '未取得公开 SHA-256 校验值',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ],
          if (task.wantsResign && selected == DownloadPackage.resigned) ...[
            const SizedBox(height: 8),
            Text(
              '重签密钥：${task.resignKey!.label}',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
            if (task.isRenamedPackage(selected))
              Text(
                '修改后包名：${task.resignedPackageName}',
                style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
              ),
            if (task.resignedSha256 != null && task.packageAvailable) ...[
              Text(
                task.isDerivedApk
                    ? '独立生成的副本 · 源包保持不变'
                    : task.originalAvailable
                    ? '本机重签副本 · 原始 APK 单独保留'
                    : '本机重签副本 · 原始 APK 不在本地',
              ),
            ],
          ],
          if (task.signingInfo.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              _signingLabel(task.signingInfo),
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ],
          if (task.error != null && isOperation) ...[
            const SizedBox(height: 12),
            Text(
              task.error!,
              style: TextStyle(fontSize: 12, color: colors.error),
            ),
            if (task.platform == 'Android' &&
                task.androidInstallErrorDetails.isNotEmpty)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('失败详情'),
                children: [
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: SelectableText(
                      [
                        for (final (key, label) in const [
                          ('code', '错误类型'),
                          ('versionCode', '安装包版本码'),
                          ('installedVersionCode', '本机版本码'),
                          ('status', '系统状态'),
                          ('legacyStatus', '安装错误码'),
                          ('systemError', '系统错误'),
                          ('systemMessage', '系统说明'),
                        ])
                          if (task.androidInstallErrorDetails[key]
                              case final value?)
                            '$label：$value',
                      ].join('\n'),
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
          ],
          if (installed && !available) ...[
            const SizedBox(height: 12),
            Text(
              '安装包已被移动或删除，已安装的应用仍可打开。',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              if (isOperation &&
                  [
                    DownloadState.queued,
                    DownloadState.downloading,
                    DownloadState.verifying,
                    DownloadState.resigning,
                  ].contains(task.state))
                OutlinedButton(
                  onPressed: () => widget.manager.cancel(task),
                  child: Text(
                    task.state == DownloadState.resigning ? '取消重签' : '取消下载',
                  ),
                ),
              if (task.wantsResign &&
                  (selected == DownloadPackage.resigned ||
                      task.removedPackages.contains(
                        DownloadPackage.resigned,
                      )) &&
                  !task.busy &&
                  task.originalAvailable &&
                  task.verifiedSha256 != null &&
                  (!task.resignReady || !task.packageAvailable))
                FilledButton(
                  onPressed: task.deleting
                      ? null
                      : () => widget.manager.retry(task),
                  child: const Text('重试重签'),
                ),
              if ((!isApk ||
                      selected == DownloadPackage.original ||
                      task.removedPackages.contains(
                        DownloadPackage.original,
                      )) &&
                  [
                    DownloadState.failed,
                    DownloadState.cancelled,
                  ].contains(task.state) &&
                  task.url.startsWith('https://') &&
                  !(task.wantsResign &&
                      task.originalAvailable &&
                      task.verifiedSha256 != null))
                FilledButton(
                  onPressed: task.deleting
                      ? null
                      : () => widget.manager.retry(task),
                  style: downloadButtonStyle(context),
                  child: const Text('重新下载'),
                ),
              if (canInstall)
                FilledButton.icon(
                  onPressed: task.deleting
                      ? null
                      : () => _install(task, package: package),
                  icon: Icon(
                    task.platform == 'Android'
                        ? Icons.install_mobile_rounded
                        : Icons.install_desktop_rounded,
                    size: 18,
                  ),
                  label: Text(task.isSelfUpdate ? '安装更新' : '安装应用'),
                ),
              if (!task.isSelfUpdate &&
                  isApk &&
                  _platform == 'Android' &&
                  task.canInstallPackageOn('Android', selected))
                OutlinedButton.icon(
                  onPressed: () => _repack(task, selected),
                  icon: const Icon(Icons.edit_note_rounded, size: 18),
                  label: const Text('修改包名／重新签名'),
                ),
              if (!task.isSelfUpdate &&
                  _platform == 'macOS' &&
                  task.platform == 'macOS' &&
                  task.canHandOff &&
                  task.kind == 'pkg')
                FilledButton(
                  onPressed: task.deleting ? null : () => _openPackage(task),
                  child: const Text('使用系统安装器'),
                ),
              if (!task.isSelfUpdate &&
                  _platform == 'macOS' &&
                  task.platform == 'macOS' &&
                  task.canHandOff &&
                  task.kind != 'pkg')
                OutlinedButton(
                  onPressed: task.deleting ? null : () => _openPackage(task),
                  child: const Text('手动安装'),
                ),
              if (!task.isSelfUpdate &&
                  _platform == 'Windows' &&
                  task.platform == 'Windows' &&
                  task.canHandOff)
                FilledButton.icon(
                  onPressed: task.deleting ? null : () => _openPackage(task),
                  icon: const Icon(Icons.install_desktop_rounded, size: 18),
                  label: Text(task.kind == 'zip' ? '打开压缩包' : '使用系统安装器'),
                ),
              if (!task.isSelfUpdate &&
                  _platform == 'Linux' &&
                  task.platform == 'Linux' &&
                  task.canHandOff)
                FilledButton.icon(
                  onPressed: task.deleting ? null : () => _openPackage(task),
                  icon: const Icon(Icons.install_desktop_rounded, size: 18),
                  label: Text(task.kind == 'zip' ? '打开压缩包' : '使用系统工具安装'),
                ),
              if (installed &&
                  (task.installedPath != null || task.installedPackage != null))
                FilledButton(
                  onPressed: () => _openInstalled(task),
                  child: const Text('打开应用'),
                ),
              if (available &&
                  !task.busy &&
                  (isApk ||
                      [
                        DownloadState.downloaded,
                        DownloadState.installed,
                        DownloadState.handedOff,
                      ].contains(task.state)))
                OutlinedButton.icon(
                  onPressed: task.deleting
                      ? null
                      : () => _reveal(task, package: package),
                  icon: Icon(
                    _platform == 'Android'
                        ? Icons.share_outlined
                        : Icons.folder_open_rounded,
                    size: 17,
                  ),
                  label: Text(_platform == 'Android' ? '分享安装包' : '查看文件'),
                ),
              if (task.url.startsWith('https://'))
                OutlinedButton.icon(
                  onPressed: () async {
                    try {
                      await Clipboard.setData(ClipboardData(text: task.url));
                      if (mounted) _message('已复制原始链接');
                    } catch (_) {
                      if (mounted) _message('复制失败，请重试。');
                    }
                  },
                  icon: const Icon(Icons.copy_rounded, size: 17),
                  label: const Text('复制原始链接'),
                ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: colors.error),
                onPressed:
                    task.state == DownloadState.installing ||
                        task.checking ||
                        isApk && task.busy && !isOperation ||
                        task.deleting
                    ? null
                    : () => _remove(task, package: package),
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                label: Text(
                  task.deleting
                      ? '正在删除…'
                      : task.busy && isOperation
                      ? '取消并删除'
                      : '删除',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _apkStatus(DownloadTask task, DownloadPackage package) {
    if (task.checking && task.androidCheckingPackage == package) return '正在检查';
    if (task.state == DownloadState.installed &&
        package == (task.installedApkPackage ?? task.defaultPackage)) {
      return '已安装';
    }
    final available = task.hasPackage(package);
    final selected = package == task.operationPackage;
    if (selected && task.state == DownloadState.installing) return '正在安装';
    if (selected && task.state == DownloadState.handedOff) return '已交给系统';
    if (package == DownloadPackage.resigned) {
      if (task.state == DownloadState.resigning) return '正在重签';
      if (available) return '重签完成';
      return switch (task.state) {
        DownloadState.queued ||
        DownloadState.downloading ||
        DownloadState.verifying => '等待重签',
        DownloadState.cancelled => '重签已取消',
        _ => task.resignReady ? '文件不可用' : '重签未完成',
      };
    }
    if (available) return '下载完成';
    return switch (task.state) {
      DownloadState.queued => '等待下载',
      DownloadState.downloading => '下载中',
      DownloadState.verifying => '正在校验',
      DownloadState.cancelled => '已取消',
      DownloadState.failed => '下载失败',
      _ => '文件不可用',
    };
  }

  Future<void> _import() async {
    if (importing) return;
    setState(() => importing = true);
    var selecting = true;
    try {
      final selected = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: _importKinds,
      );
      if (selected == null) return;
      selecting = false;
      final path = selected.path;
      if (path == null || path.isEmpty) {
        throw const FormatException('未能取得安装包路径，请重新选择本地文件。');
      }
      await widget.manager.importFile(File(path), platform: _platform);
    } catch (error, stack) {
      debugPrint(
        'Local package ${selecting ? 'selection' : 'import'} failed: $error\n$stack',
      );
      final message = selecting
          ? switch (error) {
              PlatformException(:final code)
                  when code.startsWith('ENTITLEMENT_') =>
                '文件选择器缺少读取权限配置，请更新客户端后重试。',
              _ => '无法打开文件选择窗口，请重试。',
            }
          : switch (error) {
              FormatException(:final message) => message,
              FileSystemException() => '无法读取或复制所选安装包，请检查文件访问权限和可用磁盘空间。',
              _ => '导入安装包失败，请重试。',
            };
      if (mounted) _message(message);
    } finally {
      if (mounted) setState(() => importing = false);
    }
  }

  Future<void> _remove(DownloadTask task, {DownloadPackage? package}) async {
    final label = task.packageLabel(package ?? task.defaultPackage);
    final approved = await showAdaptiveForm<bool>(
      context: context,
      builder: (context) => AdaptiveDialog(
        title: package == null ? '删除 ${task.appName} 的下载？' : '删除$label？',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (package != null) ...[
              Text(p.basename(task.packagePath(package))),
              const SizedBox(height: 12),
            ],
            Text(
              package == null
                  ? '删除下载记录和安装包；进行中的下载会取消。已安装的应用会保留。'
                  : '仅删除此$label及其临时文件，其他包会保留。全部包删除后清理下载记录，已安装的应用不受影响。',
            ),
            if (package != null && task.busy) ...[
              const SizedBox(height: 8),
              const Text('进行中的下载或重签会取消。'),
            ],
          ],
        ),
        actions: DialogActionsRow(
          confirmLabel: '删除',
          destructive: true,
          onCancel: () => Navigator.pop(context, false),
          onConfirm: () => Navigator.pop(context, true),
        ),
      ),
    );
    if (approved != true) return;
    try {
      await widget.manager.remove(
        task,
        packages: package == null ? null : {package},
      );
    } catch (error, stack) {
      debugPrint('Local package removal failed: $error\n$stack');
      if (mounted) _message('未能删除下载，请稍后重试；安装中的任务需要等待完成。');
    }
  }

  Future<void> _showAndroidDowngrade(DownloadTask task, String message) async {
    final source = [
      ?task.releaseUrl,
      task.url,
    ].map(MacDownloadResolver.releasePage).whereType<Uri>().firstOrNull;
    final chooseVersion = await showAdaptiveForm<bool>(
      context: context,
      enableDrag: false,
      builder: (context) => AdaptiveDialog(
        title: '无法覆盖安装旧版本',
        showDragHandle: false,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message),
            const SizedBox(height: 12),
            const Text('如果确实需要旧版，请先自行备份配置，再卸载现有应用。卸载会清除应用数据，重签也不能直接覆盖降级。'),
          ],
        ),
        actions: DialogActionsRow(
          confirmLabel: source == null ? '选择其他安装包' : '选择其他版本',
          onCancel: () => Navigator.pop(context, false),
          onConfirm: () => Navigator.pop(context, true),
        ),
      ),
    );
    if (chooseVersion != true || !mounted) return;
    if (source == null) {
      await _import();
      return;
    }
    try {
      final architecture = await widget.manager.installer.architecture();
      if (!mounted) return;
      final selection = await showAdaptiveForm<ReleaseDownloadSelection>(
        context: context,
        builder: (_) => ReleaseDownloadDialog(
          appName: task.appName,
          source: source,
          resolver: GitHubReleaseResolver(widget.manager.macResolver),
          installer: widget.manager.installer,
          preferences: ReleaseDownloadPreferences(
            platform: 'Android',
            running: 'Android',
            architecture: architecture,
          ),
          deviceDescription: architecture,
          suggestedPackageName: task.isRenamedPackage(DownloadPackage.resigned)
              ? task.resignedPackageName
              : null,
          suggestedSigningKey: task.resignKey,
        ),
      );
      if (selection == null || !mounted) return;
      if (selection.websiteFallback) {
        await openLink(
          context,
          GitHubReleaseResolver.indexFor(source).toString(),
        );
        return;
      }
      final resource = selection.resource!;
      if (resource.platform != 'Android' || resource.kind != 'apk') {
        await openLink(
          context,
          resource.url,
          downloadPlatform: resource.platform,
        );
        return;
      }
      await widget.manager.downloadVersion(
        task,
        resource,
        resignKey: selection.resignKey,
        resignPackageName: selection.resignPackageName,
      );
    } on PlatformException catch (error) {
      if (mounted) _message(error.message ?? '暂时无法选择其他版本，请稍后重试。');
    } catch (_) {
      if (mounted) _message('暂时无法选择其他版本，请稍后重试。');
    }
  }

  Future<void> _repack(DownloadTask task, DownloadPackage package) async {
    try {
      final info = await widget.manager.inspectApk(task, package: package);
      if (!mounted) return;
      final selection = await showAdaptiveForm<AndroidInstallSelection>(
        context: context,
        enableDrag: false,
        builder: (_) => AndroidInstallDialog(
          task: task,
          package: package,
          info: info,
          installer: widget.manager.installer,
          repackOnly: true,
        ),
      );
      if (!mounted || selection?.resignKey == null) return;
      await widget.manager.resignForInstallation(
        task,
        selection!.resignKey!,
        package: package,
        packageName: selection.resignPackageName,
      );
      if (mounted) _message('副本已生成，源包已保留。');
    } on PlatformException catch (error) {
      if (mounted) _message(error.message ?? '生成副本失败，所选包已保留。');
    } on FormatException catch (error) {
      if (mounted) _message(error.message);
    } catch (_) {
      if (mounted) _message('生成副本失败，所选包已保留，请重试。');
    }
  }

  Future<void> _install(DownloadTask task, {DownloadPackage? package}) async {
    if (task.isSelfUpdate) {
      try {
        await installClientUpdate(context, widget.manager, task);
      } catch (error) {
        if (mounted) {
          _message(
            error is FormatException
                ? error.message
                : error is PlatformException
                ? error.message ?? '更新安装未完成。'
                : '更新安装未完成。',
          );
        }
      }
      return;
    }
    if (task.platform == 'Linux') {
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('安装 ${task.appName}'),
          content: const Text(
            'AppImage 将复制到 ~/Applications/HuarunWin 下的独立目录，并授予当前用户执行权限。原安装包与其他已安装应用会保留。安装后点击“打开应用”启动。',
          ),
          actions: [
            DialogActionsRow(
              confirmLabel: '开始安装',
              onCancel: () => Navigator.pop(context, false),
              onConfirm: () => Navigator.pop(context, true),
            ),
          ],
        ),
      );
      if (approved != true || !mounted) return;
      try {
        await widget.manager.install(task);
      } on PlatformException catch (error) {
        if (mounted) _message(error.message ?? 'AppImage 安装未完成。');
      } catch (_) {
        if (mounted) _message('AppImage 安装未完成，请检查文件权限和可用空间。');
      }
      return;
    }
    if (task.platform == 'Android') {
      var installTask = task;
      var selected = package ?? task.defaultPackage;
      try {
        final info = await widget.manager.inspectApk(task, package: selected);
        if (!mounted) return;
        if (info.isDowngrade) {
          await _showAndroidDowngrade(task, info.downgradeMessage);
          return;
        }
        final selection = await showAdaptiveForm<AndroidInstallSelection>(
          context: context,
          enableDrag: false,
          builder: (_) => AndroidInstallDialog(
            task: task,
            package: selected,
            info: info,
            installer: widget.manager.installer,
          ),
        );
        if (selection == null || !mounted) return;
        if (!task.canInstallPackageOn('Android', selected)) return;
        if (selection.resignKey case final key?) {
          installTask = await widget.manager.resignForInstallation(
            task,
            key,
            package: selected,
            packageName: selection.resignPackageName,
          );
          if (!mounted) return;
          selected = DownloadPackage.resigned;
          final resignedInfo = await widget.manager.inspectApk(
            installTask,
            package: selected,
          );
          if (!mounted) return;
          if (resignedInfo.isDowngrade) {
            await _showAndroidDowngrade(
              installTask,
              resignedInfo.downgradeMessage,
            );
            return;
          }
        }
        if (!mounted) return;
        if (selection.method == AndroidInstallMethod.other) {
          await widget.manager.handOff(installTask, package: selected);
          if (mounted &&
              installTask.androidInstallErrorDetails['code'] ==
                  'version_downgrade') {
            await _showAndroidDowngrade(
              installTask,
              installTask.error ?? '无法覆盖安装旧版本。',
            );
          }
        } else {
          await widget.manager.install(
            installTask,
            androidMethod: selection.method,
            package: selected,
          );
        }
      } on PlatformException catch (error) {
        if (!mounted) return;
        if (error.code == 'version_downgrade') {
          await _showAndroidDowngrade(
            installTask,
            error.message ?? '无法覆盖安装旧版本。',
          );
        } else {
          _message(error.message ?? '无法检查或安装 APK，请重试。');
        }
      } catch (_) {
        if (mounted) _message('无法检查或安装 APK，请重试。');
      }
      return;
    }
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('安装 ${task.appName}'),
        content: const SizedBox(
          width: 420,
          child: Text('应用将安装到“应用程序”文件夹，已安装的同一应用会被替换。若应用正在运行，会询问是否退出并继续安装。'),
        ),
        actions: [
          DialogActionsRow(
            confirmLabel: '开始安装',
            onCancel: () => Navigator.pop(context, false),
            onConfirm: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    final manager = widget.manager;
    var authorize = false;
    Map<String, String>? quitApplication;
    Map<String, String>? signerApproval;
    while (mounted &&
        widget.manager == manager &&
        manager.tasks.contains(task)) {
      try {
        await manager.install(
          task,
          authorize: authorize,
          quitApplication: quitApplication,
          signerApproval: signerApproval,
        );
        return;
      } on PlatformException catch (error) {
        if (!mounted || widget.manager != manager) return;
        if (error.code == 'running') {
          final details = error.details;
          if (details is! Map ||
              details['path'] is! String ||
              details['bundleIdentifier'] is! String) {
            return;
          }
          final path = details['path'] as String;
          final name = p.basenameWithoutExtension(path);
          final quit = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('是否退出当前应用，继续安装？'),
              content: SizedBox(
                width: 420,
                child: Text('$name 正在运行。请先保存未完成的工作，退出后会自动继续安装。'),
              ),
              actions: [
                DialogActionsRow(
                  confirmLabel: '退出并继续安装',
                  onCancel: () => Navigator.pop(context, false),
                  onConfirm: () => Navigator.pop(context, true),
                ),
              ],
            ),
          );
          if (quit != true) return;
          quitApplication = {
            'path': path,
            'bundleIdentifier': details['bundleIdentifier'] as String,
          };
        } else if (error.code == 'signer_changed') {
          final details = error.details;
          if (details is! Map ||
              ![
                'path',
                'bundleIdentifier',
                'oldIdentity',
                'newIdentity',
              ].every((key) => details[key] is String)) {
            return;
          }
          final approved = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('应用的开发者签名已变化'),
              content: Text(
                '现有应用：${details['oldIdentity']}\n新版本：${details['newIdentity']}\n\n请确认下载来源后继续替换。',
              ),
              actions: [
                DialogActionsRow(
                  confirmLabel: '确认并继续',
                  onCancel: () => Navigator.pop(context, false),
                  onConfirm: () => Navigator.pop(context, true),
                ),
              ],
            ),
          );
          if (approved != true) return;
          signerApproval = {
            for (final key in [
              'path',
              'bundleIdentifier',
              'oldIdentity',
              'newIdentity',
            ])
              key: details[key] as String,
          };
        } else if (error.code == 'permission_required' && !authorize) {
          final approved = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('需要管理员授权'),
              content: const Text(
                '当前用户无法写入“应用程序”文件夹。继续后由 macOS 申请管理员权限，授权一次后，后续安装、卸载和客户端更新会持续复用，重启后仍有效。华润赢不会读取或保存密码。',
              ),
              actions: [
                DialogActionsRow(
                  cancelLabel: '暂不安装',
                  confirmLabel: '继续授权',
                  onCancel: () => Navigator.pop(context, false),
                  onConfirm: () => Navigator.pop(context, true),
                ),
              ],
            ),
          );
          if (approved != true) return;
          authorize = true;
        } else {
          return; // The task exposes its native error inline.
        }
      } catch (_) {
        return; // The task exposes its error inline.
      }
    }
  }

  Future<void> _openInstalled(DownloadTask task) async {
    try {
      if (task.installedPackage case final packageName?) {
        await widget.manager.installer.openAndroidApp(packageName);
      } else if (task.platform == 'Linux') {
        await widget.manager.installer.openAppImage(task.installedPath!);
      } else {
        await widget.manager.installer.openApp(task.installedPath!);
      }
    } catch (error) {
      if (mounted) {
        _message(
          task.platform == 'Android'
              ? '应用未能启动，请确认应用仍已安装且支持直接打开。'
              : task.platform == 'Linux'
              ? error is PlatformException
                    ? error.message ?? 'AppImage 未能启动，请检查系统兼容性。'
                    : 'AppImage 未能启动，请检查执行权限、系统兼容性和 FUSE 支持。'
              : '应用未能启动，请在“应用程序”中查看。',
        );
      }
    }
  }

  Future<void> _openPackage(DownloadTask task) async {
    await widget.manager.handOff(task);
  }

  String _phaseLabel(String phase) => switch (phase) {
    'mounting' => '正在挂载安装包…',
    'extracting' => '正在解压安装包…',
    'validating' => '正在验证应用与架构…',
    'signature' => '正在检查签名与系统评估…',
    'copying' => '正在复制应用…',
    'quarantine' => '正在处理本次应用的隔离属性…',
    'replacing' => '正在完成安装替换…',
    'authorizing' => '等待系统授权并完成安装…',
    'privileged' => '正在通过管理员助手完成安装…',
    'quitting' => '正在等待目标应用退出…',
    'opening_system' => '正在打开系统安装窗口…',
    'installing' => 'Android 正在安装应用…',
    'waiting_confirmation' => '请在系统窗口确认安装…',
    _ => '正在准备安装…',
  };

  String _signingLabel(Map<String, String> info) {
    final status = switch (info['signature']) {
      'valid' => '签名校验通过',
      'adhoc' => '本地签名',
      'unsigned' => '未签名',
      'invalid' => '签名校验未通过',
      _ => '签名状态未知',
    };
    final assessment = switch (info['assessment']) {
      'accepted' => '系统评估通过',
      'rejected' => '系统评估未通过',
      _ => '系统评估未确认',
    };
    return [
      '安装包：$status',
      if ((info['teamIdentifier'] ?? '').isNotEmpty)
        '开发者 ${info['teamIdentifier']}',
      info['notarization'] == 'notarized' ? '已公证' : '公证未确认',
      assessment,
    ].join(' · ');
  }

  Future<void> _reveal(DownloadTask task, {DownloadPackage? package}) async {
    final path = task.packagePath(package ?? task.defaultPackage);
    try {
      if (_platform == 'Linux') {
        await widget.manager.installer.revealLinux(path);
      } else if (_platform == 'Android' && package != null) {
        await widget.manager.shareApk(task, package);
      } else if (['macOS', 'Android', 'Windows'].contains(_platform)) {
        await widget.manager.installer.reveal(path);
      } else if (!await launchUrl(Uri.directory(File(path).parent.path))) {
        throw StateError('open');
      }
    } catch (error) {
      if (mounted) {
        _message(
          error is PlatformException
              ? error.message ?? '无法分享安装包。'
              : _platform == 'Android'
              ? '无法分享安装包，请确认文件仍在本地。'
              : '无法打开文件位置。',
        );
      }
    }
  }

  void _message(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}
