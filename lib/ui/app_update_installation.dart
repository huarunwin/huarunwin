import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/app_changelog.dart';
import '../data/models.dart';
import '../services/download_platform.dart';
import '../services/downloads.dart';
import '../services/self_update.dart';
import 'components.dart';
import 'page_components.dart';

Future<void> installClientUpdate(
  BuildContext context,
  DownloadManager manager,
  DownloadTask task,
) async {
  if (manager.tasks.any(
    (t) => t != task && t.state == DownloadState.installing,
  )) {
    throw const FormatException('请先完成其他安装任务，再更新华润赢。');
  }
  final exitRequired = SelfUpdateInstaller.needsExit(task);
  if (exitRequired) {
    final downloading = manager.tasks.any((t) => t != task && t.busy);
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('安装华润赢更新'),
        content: Text(
          '更新准备完成后将退出当前客户端，由独立更新进程继续安装。'
          '${task.kind == 'zip' || task.kind == 'dmg' || task.kind == 'appimage' ? '替换完成后重新打开华润赢。' : '请在系统安装界面完成确认，安装后重新打开华润赢。'}'
          '${downloading ? '\n其他下载任务会中断，重新打开后可重试。' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('退出并安装'),
          ),
        ],
      ),
    );
    if (approved != true || !context.mounted) return;
  }
  await manager.installSelfUpdate(
    task,
    (digest) => SelfUpdateInstaller.install(manager, task, digest),
  );
  if (exitRequired) exit(0);
}

class AppUpdateDownloadPage extends StatefulWidget {
  const AppUpdateDownloadPage({
    super.key,
    required this.release,
    required this.channel,
    required this.manager,
  });
  final AppRelease release;
  final AppUpdateChannel channel;
  final DownloadManager manager;
  @override
  State<AppUpdateDownloadPage> createState() => _AppUpdateDownloadPageState();
}

class _AppUpdateDownloadPageState extends State<AppUpdateDownloadPage> {
  bool _loading = true, _installing = false, _automaticInstall = false;
  String? _error, _architecture;
  List<DownloadLink> _packages = const [];
  DownloadLink? _selected;
  DownloadTask? _task;

  @override
  void initState() {
    super.initState();
    widget.manager.addListener(_changed);
    _resolve();
  }

  @override
  void dispose() {
    widget.manager.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    final task = _task;
    if (_automaticInstall &&
        !_installing &&
        task?.state == DownloadState.downloaded &&
        task?.error == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _automaticInstall &&
            ModalRoute.of(context)?.isCurrent == true) {
          _automaticInstall = false;
          _install();
        }
      });
    }
  }

  Future<void> _resolve() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final platform = runningDownloadPlatform;
      if (platform == null) throw const FormatException('无法确认当前运行平台。');
      final packages = await SelfUpdatePackages.resolve(
        widget.release,
        platform,
        widget.manager,
      );
      if (!mounted) return;
      if (platform == 'iOS') {
        final uri = SelfUpdatePackages.iosStore(packages.single);
        if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          throw const FormatException('系统未能打开此应用的更新渠道，请重试。');
        }
        if (mounted) {
          setState(() {
            _loading = false;
            _error = '已打开系统更新渠道，请在 App Store 或 TestFlight 完成更新。';
          });
        }
        return;
      }
      try {
        _architecture = await widget.manager.installer.architecture();
      } catch (_) {
        /* User chooses when architecture is unavailable. */
      }
      if (!mounted) return;
      final matching = packages
          .where(
            (item) =>
                _architecture == null ||
                item.architecture == null ||
                item.architecture == 'universal' ||
                item.architecture == _architecture,
          )
          .toList();
      if (matching.isEmpty) throw const FormatException('此版本尚未提供适合当前设备架构的安装包。');
      String? linuxKind;
      if (platform == 'Linux') {
        linuxKind =
            (await widget.manager.installer.linuxSystemInfo()).packageKind;
      }
      if (!mounted) return;
      final recommended = ReleaseDownloadPreferences(
        platform: platform,
        running: platform,
        architecture: _architecture,
        linuxPackageKind: linuxKind,
      ).recommended(matching);
      setState(() {
        _packages = matching;
        _selected = recommended;
        _loading = false;
      });
      if (recommended != null) await _download();
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = _message(error);
        });
      }
    }
  }

  Future<void> _download() async {
    if (_selected == null || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final task = await widget.manager.downloadSelfUpdate(
        _selected!,
        widget.channel.name,
      );
      if (!mounted) return;
      _task = task;
      _automaticInstall = true;
      if ([
        DownloadState.failed,
        DownloadState.cancelled,
      ].contains(task.state)) {
        await widget.manager.retry(task);
      }
      setState(() => _loading = false);
      _changed();
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = _message(error);
        });
      }
    }
  }

  Future<void> _install() async {
    if (_installing || _task == null) return;
    setState(() {
      _automaticInstall = false;
      _installing = true;
      _error = null;
    });
    try {
      await installClientUpdate(context, widget.manager, _task!);
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  String _message(Object error) => error is FormatException
      ? error.message
      : error is PlatformException
      ? error.message ?? '更新安装未完成。'
      : '暂时无法完成更新，请稍后重试。';

  @override
  Widget build(BuildContext context) {
    final task = _task;
    final busy = _loading || _installing || task?.busy == true;
    return Scaffold(
      body: PageSafeArea(
        child: ContentPage(
          title: '更新华润赢',
          showBackButton: true,
          children: [
            PageSection(
              title: '版本 ${widget.release.version}',
              children: [
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_loading && task == null)
                        const LinearProgressIndicator(),
                      if (task != null) ...[
                        Text(switch (task.state) {
                          DownloadState.queued => '等待下载',
                          DownloadState.downloading => '正在下载安装包…',
                          DownloadState.verifying => '正在校验安装包…',
                          DownloadState.installing => '正在准备更新安装…',
                          DownloadState.downloaded => '安装包已就绪',
                          DownloadState.cancelled => '下载已取消',
                          DownloadState.failed => '下载失败',
                          DownloadState.installed => '更新安装已完成',
                          DownloadState.handedOff => '已交给系统安装，请完成系统确认后重新打开客户端。',
                          _ => '正在处理更新…',
                        }),
                        const SizedBox(height: 12),
                        if (task.busy)
                          LinearProgressIndicator(
                            value: task.state == DownloadState.downloading
                                ? task.progress
                                : null,
                          ),
                        Text(
                          '${bytesLabel(task.received)}${task.total > 0 ? ' / ${bytesLabel(task.total)}' : ''}',
                        ),
                        if (task.error != null)
                          Text(
                            task.error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                      ] else if (!_loading && _packages.isNotEmpty) ...[
                        const Text('选择用于当前设备的安装包'),
                        for (final item in _packages)
                          ListTile(
                            selected: _selected == item,
                            onTap: busy
                                ? null
                                : () => setState(() => _selected = item),
                            trailing: Icon(
                              _selected == item
                                  ? Icons.check_circle_rounded
                                  : Icons.radio_button_unchecked_rounded,
                            ),
                            title: Text(item.label),
                            subtitle: Text(
                              item.architecture ?? '架构未知，请确认安装包适用于当前设备',
                            ),
                          ),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(_error!),
                      ],
                      const SizedBox(height: 16),
                      if (task == null && !_loading)
                        FilledButton(
                          onPressed: _packages.isNotEmpty
                              ? (_selected == null ? null : _download)
                              : _resolve,
                          child: Text(_packages.isNotEmpty ? '确认下载' : '重试'),
                        ),
                      if (task != null &&
                          [
                            DownloadState.downloading,
                            DownloadState.queued,
                            DownloadState.verifying,
                          ].contains(task.state))
                        TextButton(
                          onPressed: () {
                            _automaticInstall = false;
                            widget.manager.cancel(task);
                          },
                          child: const Text('取消下载'),
                        ),
                      if (task != null &&
                          !busy &&
                          [
                            DownloadState.failed,
                            DownloadState.cancelled,
                          ].contains(task.state))
                        FilledButton(
                          onPressed: () async {
                            _automaticInstall = true;
                            await widget.manager.retry(task);
                          },
                          child: const Text('重新下载'),
                        ),
                      if (task != null &&
                          !busy &&
                          task.canInstallOn(runningDownloadPlatform))
                        FilledButton(
                          onPressed: _install,
                          child: const Text('安装更新'),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
