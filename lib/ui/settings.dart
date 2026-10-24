import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/site_parser.dart';
import '../services/app_controller.dart';
import '../services/content_sources.dart';
import '../services/download_locations.dart';
import '../services/download_copies.dart';
import '../services/downloads.dart';
import '../services/github_acceleration.dart';
import 'about_page.dart';
import 'adaptive_dialog.dart';
import 'app_updates.dart';
import 'components.dart';
import 'page_components.dart';
import 'theme.dart';

String _contentSourceStatus(AppController controller) {
  if (controller.sources.mode != ContentSourceMode.automatic) {
    return controller.sources.mode.label;
  }
  final source = controller.sources.active;
  final github = controller.repository.github;
  if (source != ContentOrigin.github || github == null) return source.label;
  final route = switch (github.mode) {
    GitHubAccessMode.automatic => github.lastSuccessful(GitHubTraffic.raw),
    GitHubAccessMode.direct => GitHubRoute.direct,
    GitHubAccessMode.proxy => GitHubRoute.proxy,
  };
  return route == GitHubRoute.proxy
      ? ContentSourceMode.ghproxy.label
      : source.label;
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.controller,
    required this.downloads,
    this.showBackButton = false,
  });
  final AppController controller;
  final DownloadManager downloads;
  final bool showBackButton;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      controller,
      controller.repository.github,
      downloads,
      downloads.github,
    ]),
    builder: (context, _) => ContentPage(
      title: '设置',
      showBackButton: showBackButton,
      onRefresh: () async {
        try {
          await controller.refreshPreferences();
          await downloads.locations?.refreshPreferences();
          await downloads.copies?.refresh(validate: false);
          await downloads.github?.reload();
        } catch (_) {
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('暂时无法读取本机偏好，请稍后重试。')));
          }
        }
      },
      children: [
        PageSection(
          title: '外观',
          bottomSpacing: 16,
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (index, mode) in ThemeMode.values.indexed) ...[
                    if (index > 0) const SizedBox(width: 10),
                    Expanded(
                      child: _AppearanceChoice(
                        mode: mode,
                        selected: controller.themeMode == mode,
                        onTap: () => controller.setTheme(mode),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        if (downloads.locations case final locations?)
          PageSection(
            title: '应用目录',
            bottomSpacing: 16,
            children: [
              PageRow(
                title: '下载目录',
                subtitle:
                    downloads.copies?.directoryDescription ??
                    locations.directory.path,
                icon: Icons.folder_outlined,
                trailing: const Icon(Icons.chevron_right_rounded, size: 18),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => _DownloadDirectoryPage(
                      locations: locations,
                      copies: downloads.copies,
                    ),
                  ),
                ),
              ),
            ],
          ),
        PageSection(
          title: '帮助与反馈',
          bottomSpacing: 16,
          children: [
            PageRow(
              title: SiteRoutes.onlineLinks['/corrections']!,
              icon: Icons.feedback_outlined,
              trailing: const Icon(Icons.chevron_right_rounded, size: 18),
              onTap: () =>
                  openLink(context, '${SiteRoutes.origin}/corrections'),
            ),
          ],
        ),
        PageSection(
          title: '版本信息',
          bottomSpacing: 16,
          children: [AppVersionRows(manager: downloads)],
        ),
        PageSection(
          bottomSpacing: 16,
          children: [
            PageRow(
              title: '关于华润赢',
              icon: Icons.info_outline_rounded,
              trailing: const Icon(Icons.chevron_right_rounded, size: 18),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) =>
                      AboutPage(controller: controller, downloads: downloads),
                ),
              ),
            ),
            PageRow(
              title: '高级设置',
              icon: Icons.tune_rounded,
              trailing: const Icon(Icons.chevron_right_rounded, size: 18),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => _AdvancedSettingsPage(controller: controller),
                ),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            '偏好保存在这台设备。目录内容可以离线浏览，下载和刷新需要网络。',
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    ),
  );
}

class _AdvancedSettingsPage extends StatelessWidget {
  const _AdvancedSettingsPage({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: PageSafeArea(
      child: ListenableBuilder(
        listenable: Listenable.merge([
          controller.sources,
          controller.repository.github,
        ]),
        builder: (context, _) => ContentPage(
          title: '高级设置',
          showBackButton: true,
          onRefresh: () async {
            try {
              await controller.sources.reload();
              await controller.repository.github?.reload();
            } catch (_) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('暂时无法读取本机偏好，请稍后重试。')),
                );
              }
            }
          },
          children: [
            PageSection(
              title: '网络',
              children: [
                PageRow(
                  title: '内容来源',
                  subtitle:
                      controller.sources.mode == ContentSourceMode.automatic
                      ? '自动 · ${_contentSourceStatus(controller)}'
                      : _contentSourceStatus(controller),
                  icon: Icons.public_rounded,
                  trailing: const Icon(Icons.chevron_right_rounded, size: 18),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          _ContentSourcePage(controller: controller),
                    ),
                  ),
                ),
              ],
            ),
            PageSection(
              title: '重置',
              children: [
                PageRow(
                  title: '恢复默认平台筛选',
                  subtitle: '清除记住的平台与设备选择，恢复当前设备平台。',
                  icon: Icons.restart_alt_rounded,
                  onTap: () async {
                    await controller.resetCatalogPlatform();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已恢复默认平台筛选')),
                      );
                    }
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _ContentSourcePage extends StatefulWidget {
  const _ContentSourcePage({required this.controller});
  final AppController controller;

  @override
  State<_ContentSourcePage> createState() => _ContentSourcePageState();
}

class _ContentSourcePageState extends State<_ContentSourcePage> {
  bool _saving = false;

  Future<void> _select(ContentSourceMode mode) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.controller.sources.select(mode);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('未能保存内容来源，请重试。')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _refresh() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.controller.sources.reload();
      await widget.controller.repository.github?.reload();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('暂时无法读取内容来源，请重试。')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: PageSafeArea(
      child: ListenableBuilder(
        listenable: Listenable.merge([
          widget.controller.sources,
          widget.controller.repository.github,
        ]),
        builder: (context, _) {
          final sources = widget.controller.sources;
          return ContentPage(
            title: '内容来源',
            showBackButton: true,
            onRefresh: _refresh,
            children: [
              PageSection(
                title: '选择来源',
                footer: '切换后重新加载目录、详情和图片。镜像内容可能晚于网站；更多历史版本仍需直连 GitHub。',
                children: [
                  for (final mode in ContentSourceMode.values)
                    PageRow(
                      title: mode.label,
                      subtitle: switch (mode) {
                        ContentSourceMode.automatic => '优先访问网站，失败后依次尝试 GitHub 镜像、GH-Proxy 和 jsDelivr；回退成功保持 2 小时。',
                        ContentSourceMode.website => '始终从华润赢网站读取内容。',
                        ContentSourceMode.github =>
                          '直连 GitHub 获取镜像内容、图片和应用内文件。',
                        ContentSourceMode.ghproxy =>
                          '通过 gh-proxy.com 获取镜像内容、图片和应用内 GitHub 文件。',
                        ContentSourceMode.jsdelivr =>
                          '通过 jsDelivr 读取同一份 GitHub 镜像。',
                      },
                      trailing: sources.mode == mode
                          ? Icon(
                              Icons.check_rounded,
                              color: Theme.of(context).colorScheme.primary,
                            )
                          : null,
                      onTap: _saving ? null : () => _select(mode),
                    ),
                ],
              ),
              PageSection(
                title: '连接状态',
                children: [
                  PageRow(
                    title:
                        sources.mode != ContentSourceMode.automatic ||
                            sources.hasSuccessfulSource
                        ? '当前来源'
                        : '优先尝试来源',
                    subtitle: _contentSourceStatus(widget.controller),
                    icon: Icons.cloud_done_outlined,
                  ),
                ],
              ),
            ],
          );
        },
      ),
    ),
  );
}

class _DownloadDirectoryPage extends StatefulWidget {
  const _DownloadDirectoryPage({required this.locations, this.copies});

  final DownloadLocations locations;
  final AndroidDownloadCopies? copies;

  @override
  State<_DownloadDirectoryPage> createState() => _DownloadDirectoryPageState();
}

class _DownloadDirectoryPageState extends State<_DownloadDirectoryPage> {
  bool _working = false;

  @override
  void initState() {
    super.initState();
    widget.copies?.refresh();
  }

  void _message(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _refresh() async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await widget.locations.refreshPreferences();
      await widget.copies?.refresh();
    } catch (_) {
      _message('暂时无法读取下载目录设置，请稍后重试。');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _change({bool reset = false}) async {
    if (_working) return;
    setState(() => _working = true);
    var selecting = !reset;
    try {
      if (reset) {
        final confirmed = await showAdaptiveForm<bool>(
          context: context,
          builder: (context) => AdaptiveDialog(
            title: '恢复默认下载目录？',
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(widget.locations.defaultDirectory.path),
                const SizedBox(height: 12),
                Text(
                  widget.copies == null
                      ? '新任务将保存到此目录，已有任务及文件保留原位置。'
                      : '新下载将使用应用默认位置，不再保存到自选文件夹；已有任务及文件保留原位置。',
                ),
              ],
            ),
            actions: DialogActionsRow(
              confirmLabel: '恢复默认',
              onCancel: () => Navigator.pop(context, false),
              onConfirm: () => Navigator.pop(context, true),
            ),
          ),
        );
        if (confirmed != true || !mounted) return;
        await widget.locations.resetDirectory();
        await widget.copies?.resetDirectory();
      } else if (widget.copies case final copies?) {
        selecting = false;
        if (!await copies.chooseDirectory()) return;
      } else {
        final current = widget.locations.directory;
        final initial = await current.exists() ? current.path : null;
        if (!mounted) return;
        final selected = await FilePicker.getDirectoryPath(
          dialogTitle: '选择下载目录',
          initialDirectory: initial,
        );
        if (selected == null || !mounted) return;
        selecting = false;
        await widget.locations.selectDirectory(selected);
      }
      _message(
        widget.copies == null
            ? '下载目录已更新，仅对新任务生效。'
            : reset
            ? '已恢复默认目录，已有文件保留原位置。'
            : '下载目录已更新，之后完成的原始 APK 将自动保存副本。',
      );
    } catch (_) {
      _message(selecting ? '无法打开目录选择窗口，请重试。' : '无法使用此目录，请检查文件夹权限、磁盘连接和可用空间。');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _open() async {
    if (_working) return;
    setState(() => _working = true);
    try {
      if (widget.copies case final copies?) {
        final directory = copies.hasCustomDirectory
            ? widget.locations.directory
            : await widget.locations.prepareDirectory();
        await copies.openDirectory(managedPath: directory.path);
        return;
      }
      final directory = await widget.locations.prepareDirectory();
      if (!await launchUrl(
        directory.uri,
        mode: LaunchMode.externalApplication,
      )) {
        throw StateError('open_directory');
      }
    } on MissingPluginException {
      _message('当前安装包尚未包含打开目录功能，请安装最新版本后重试。');
    } on PlatformException catch (error) {
      _message(error.message ?? '无法打开当前下载目录，请检查文件夹是否可访问。');
    } catch (_) {
      _message('无法打开下载目录，请检查文件夹是否可访问。');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: PageSafeArea(
      child: ListenableBuilder(
        listenable: Listenable.merge([widget.locations, widget.copies]),
        builder: (context, _) => ContentPage(
          title: '下载目录',
          showBackButton: true,
          onRefresh: _refresh,
          children: [
            PageSection(
              title: '当前下载目录',
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(
                    widget.copies?.directoryDescription ??
                        widget.locations.directory.path,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                if (widget.copies?.warning case final warning?)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Text(
                      warning,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
            PageSection(
              title: '目录操作',
              footer: widget.copies == null
                  ? '更改目录仅对新下载和新导入生效，已有任务及文件保留原位置。'
                  : '选择其他文件夹后，原始 APK 下载完成会自动保存副本；安装所需文件仍由应用管理。',
              children: [
                PageRow(
                  title: '修改目录',
                  icon: Icons.folder_outlined,
                  trailing: _working
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.chevron_right_rounded, size: 18),
                  onTap: _working ? null : _change,
                ),
                PageRow(
                  title: '打开目录',
                  icon: Icons.folder_open_outlined,
                  trailing: const Icon(Icons.chevron_right_rounded, size: 18),
                  onTap: _working ? null : _open,
                ),
                PageRow(
                  title: '恢复默认',
                  icon: Icons.restart_alt_rounded,
                  onTap: _working ? null : () => _change(reset: true),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

class _AppearanceChoice extends StatelessWidget {
  const _AppearanceChoice({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final ThemeMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final label = switch (mode) {
      ThemeMode.system => '跟随系统',
      ThemeMode.light => '浅色',
      ThemeMode.dark => '深色',
    };
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: SurfacePanel.raisedColor(context),
        shape: surfaceShape(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              children: [
                ExcludeSemantics(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 88),
                    child: ClipPath.shape(
                      shape: surfaceShape(8),
                      child: AspectRatio(
                        aspectRatio: 1.65,
                        child: mode == ThemeMode.system
                            ? const Row(
                                children: [
                                  Expanded(child: _MiniWindow(dark: false)),
                                  Expanded(child: _MiniWindow(dark: true)),
                                ],
                              )
                            : _MiniWindow(dark: mode == ThemeMode.dark),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 13, height: 1.4),
                      ),
                    ),
                    if (selected) ...[
                      const SizedBox(width: 2),
                      Icon(
                        Icons.check_circle_rounded,
                        color: colors.primary,
                        size: 18,
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniWindow extends StatelessWidget {
  const _MiniWindow({required this.dark});
  final bool dark;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: dark ? const Color(0xFF141414) : const Color(0xFFF4F4F4),
    child: Row(
      children: [
        Expanded(
          flex: 2,
          child: ColoredBox(
            color: dark ? const Color(0xFF242424) : const Color(0xFFDDDDDD),
            child: const SizedBox.expand(),
          ),
        ),
        Expanded(
          flex: 7,
          child: Padding(
            padding: const EdgeInsets.all(7),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  height: 5,
                  decoration: ShapeDecoration(
                    shape: surfaceShape(3),
                    color: dark
                        ? const Color(0xFF777777)
                        : const Color(0xFFAAAAAA),
                  ),
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      shape: surfaceShape(5),
                      color: dark
                          ? const Color(0xFF333333)
                          : const Color(0xFFFFFFFF),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
