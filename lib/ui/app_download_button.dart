import 'package:flutter/material.dart';

import '../data/models.dart';
import '../services/android_package.dart';
import '../services/app_download_status.dart';
import '../services/download_platform.dart';
import '../services/downloads.dart';
import '../services/github_releases.dart';
import '../services/installed_apps.dart';
import '../services/linux_installer.dart';
import '../services/mac_downloads.dart';
import 'adaptive_dialog.dart';
import 'components.dart';
import 'page_components.dart';
import 'release_download_dialog.dart';
import 'theme.dart';

class _DownloadChoice<T> {
  const _DownloadChoice({
    required this.value,
    required this.icon,
    required this.title,
    this.subtitle,
  });

  final T value;
  final IconData icon;
  final String title;
  final String? subtitle;
}

class AppDownloadButton extends StatefulWidget {
  const AppDownloadButton({
    super.key,
    required this.app,
    required this.loadDetails,
    required this.manager,
    required this.onStarted,
    this.compact = false,
    this.primary = false,
    this.selectedPlatform = '全部',
    this.details,
    this.style,
  });
  final CatalogApp app;
  final Future<AppDetails> Function() loadDetails;
  final DownloadManager manager;
  final VoidCallback onStarted;
  final bool compact;
  final bool primary;
  final String selectedPlatform;
  final AppDetails? details;
  final ButtonStyle? style;

  @override
  State<AppDownloadButton> createState() => _AppDownloadButtonState();
}

class _AppDownloadButtonState extends State<AppDownloadButton>
    with WidgetsBindingObserver {
  bool loading = false;
  bool _waitingForChoice = false;
  bool updateAvailable = false;
  String? updateDescription;
  AppDownloadStatus? localDownload;
  bool _hasCheckedStatus = false;
  int _statusRequest = 0;
  int? _lastTaskSignature;

  String? get _localPlatform => directDownloadPlatform(
    selected: widget.selectedPlatform,
    running: runningDownloadPlatform,
    supported: widget.app.platforms,
  );

  int get _taskSignature => Object.hashAll([
    for (final task in appDownloadTasks(
      widget.manager,
      widget.app,
      _localPlatform ?? '',
    ))
      Object.hash(
        task.id,
        task.state,
        task.deleting,
        task.checking,
        task.packageAvailable,
        task.originalAvailable,
        task.installedPath,
        task.installedPackage,
        task.resignedSha256,
        task.version,
      ),
  ]);

  void _downloadsChanged() {
    if (_lastTaskSignature != _taskSignature) _checkInstalled();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.manager.addListener(_downloadsChanged);
    widget.manager.installedApps.addListener(_checkInstalled);
    _checkInstalled(refresh: widget.primary);
  }

  @override
  void didUpdateWidget(covariant AppDownloadButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldPlatform = directDownloadPlatform(
      selected: oldWidget.selectedPlatform,
      running: runningDownloadPlatform,
      supported: oldWidget.app.platforms,
    );
    if (oldWidget.manager != widget.manager ||
        oldWidget.app.key != widget.app.key ||
        oldPlatform != _localPlatform) {
      _hasCheckedStatus = false;
      localDownload = null;
      updateAvailable = false;
      updateDescription = null;
    }
    if (oldWidget.manager != widget.manager) {
      oldWidget.manager.removeListener(_downloadsChanged);
      oldWidget.manager.installedApps.removeListener(_checkInstalled);
      widget.manager.addListener(_downloadsChanged);
      widget.manager.installedApps.addListener(_checkInstalled);
    }
    if (oldWidget.manager != widget.manager ||
        oldWidget.app != widget.app ||
        oldWidget.selectedPlatform != widget.selectedPlatform ||
        oldWidget.details != widget.details) {
      _checkInstalled(refresh: widget.primary);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkInstalled(refresh: true);
  }

  @override
  void dispose() {
    _statusRequest++;
    widget.manager.removeListener(_downloadsChanged);
    widget.manager.installedApps.removeListener(_checkInstalled);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _checkInstalled({bool refresh = false}) async {
    final request = ++_statusRequest;
    _lastTaskSignature = _taskSignature;
    var available = false;
    String? description;
    AppDownloadStatus? local;
    try {
      final platform = _localPlatform;
      if (platform == null) return;
      local = await readAppDownloadStatus(
        widget.manager,
        widget.app,
        platform,
        refresh: refresh,
      );
      if (!mounted || request != _statusRequest || local == null) return;
      if (local.version == null) return;
      final detail = widget.details ?? await widget.loadDetails();
      if (!mounted || request != _statusRequest) return;
      final version = detail.versionForPlatform(platform);
      if (detail.app.key != widget.app.key ||
          detail.app.withdrawn ||
          version == null ||
          !hasNewerVersion(local.version!, version)) {
        return;
      }
      available = true;
      description =
          '${local.canOpenApplication ? '本机' : '已下载'} ${local.version}，可更新至 $version';
    } catch (_) {
      // Unavailable local metadata must not prevent the normal download flow.
    } finally {
      if (mounted && request == _statusRequest) {
        setState(() {
          // Publish the local status and version comparison together. Refresh
          // keeps the previous result until both checks have finished.
          _hasCheckedStatus = true;
          localDownload = local;
          updateAvailable = available;
          updateDescription = description;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final checkingStatus = !_hasCheckedStatus;
    final busy = loading || checkingStatus;
    final label = localDownload == null
        ? appDownloadLabel(widget.app)
        : updateAvailable
        ? '更新'
        : '打开';
    final child = checkingStatus || loading && !_waitingForChoice
        ? SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              semanticsLabel: checkingStatus ? '正在检查应用状态' : null,
              color:
                  widget.style?.foregroundColor?.resolve({
                    WidgetState.disabled,
                  }) ??
                  Theme.of(context).colorScheme.primary,
            ),
          )
        : Text(label, maxLines: 1, overflow: TextOverflow.ellipsis);
    final button = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 200),
      child: FilledButton(
        onPressed: busy
            ? null
            : localDownload != null && !updateAvailable
            ? _open
            : _download,
        style: widget.style ?? downloadButtonStyle(context),
        child: child,
      ),
    );
    final description = checkingStatus
        ? '正在检查应用状态'
        : updateDescription ??
              (localDownload != null && !localDownload!.canOpenApplication
                  ? '打开应用库，继续安装或查看安装包'
                  : label);
    return Tooltip(message: description, child: button);
  }

  Future<T?> _showChoice<T>(Future<T?> Function() open) async {
    setState(() => _waitingForChoice = true);
    try {
      return await open();
    } finally {
      if (mounted) setState(() => _waitingForChoice = false);
    }
  }

  Future<void> _open() async {
    setState(() => loading = true);
    try {
      final platform = _localPlatform;
      final local = platform == null
          ? null
          : await readAppDownloadStatus(
              widget.manager,
              widget.app,
              platform,
              refresh: true,
            );
      if (!mounted) return;
      if (local == null) {
        await _checkInstalled(refresh: true);
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('应用或安装包已被移除，请重新下载。')));
        }
      } else if (local.installedPackage case final packageName?) {
        await widget.manager.installer.openAndroidApp(packageName);
      } else if (local.installedPath case final path?) {
        if (platform == 'Linux') {
          await widget.manager.installer.openAppImage(path);
        } else {
          await widget.manager.installer.openApp(path);
        }
      } else {
        widget.onStarted();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('应用未能打开，请在应用库中检查应用或安装包。')));
        _checkInstalled(refresh: true);
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  String _label(DownloadLink package, String? current) {
    if (package.platform != 'macOS') {
      return [
        package.kind!.toUpperCase(),
        if (package.architecture != null) package.architecture!,
        if (current != null &&
            (package.architecture == current ||
                package.architecture == 'universal'))
          '适合当前设备',
      ].join(' · ');
    }
    final arch = switch (package.architecture) {
      'arm64' => 'Apple Silicon',
      'x64' => 'Intel',
      'universal' => '通用版本',
      _ => '安装时检查架构',
    };
    final recommended =
        package.architecture == current || package.architecture == 'universal';
    return '${package.kind!.toUpperCase()} · $arch${recommended ? ' · 适合当前 Mac' : ''}';
  }

  Future<T?> _chooseDownload<T>({
    required String title,
    required List<_DownloadChoice<T>> choices,
    T? initialValue,
    String? description,
  }) {
    var selected = initialValue ?? choices.first.value;
    return _showChoice(
      () => showAdaptiveForm<T>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, updateSelection) {
            final theme = Theme.of(context);
            final colors = theme.colorScheme;
            return AdaptiveDialog(
              title: title,
              content: SizedBox(
                width: 440,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (description != null) ...[
                      Text(description),
                      const SizedBox(height: 16),
                    ],
                    Material(
                      color: theme.brightness == Brightness.dark
                          ? colors.surfaceContainerHighest
                          : colors.surfaceContainer,
                      shape: surfaceShape(20),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final choice in choices)
                            ListTile(
                              leading: Icon(choice.icon),
                              title: Text(choice.title),
                              titleTextStyle: theme.textTheme.bodyLarge,
                              subtitle: choice.subtitle == null
                                  ? null
                                  : Text(
                                      choice.subtitle!,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                              textColor: colors.onSurface,
                              iconColor: colors.onSurfaceVariant,
                              selectedColor: colors.onSurface,
                              subtitleTextStyle: theme.textTheme.bodyMedium
                                  ?.copyWith(color: colors.onSurfaceVariant),
                              selected: choice.value == selected,
                              trailing: SizedBox.square(
                                dimension: 24,
                                child: choice.value == selected
                                    ? Icon(
                                        Icons.check_rounded,
                                        color: colors.primary,
                                      )
                                    : null,
                              ),
                              onTap: () => updateSelection(
                                () => selected = choice.value,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              actions: DialogActionsRow(
                confirmLabel: '确认',
                onCancel: () => Navigator.pop(context),
                onConfirm: () => Navigator.pop(context, selected),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<String?> _choosePlatform(AppDetails detail) => _chooseDownload<String>(
    title: '选择下载平台',
    description: detail.app.name,
    initialValue: detail.app.platforms.contains(widget.selectedPlatform)
        ? widget.selectedPlatform
        : detail.app.platforms.contains(runningDownloadPlatform)
        ? runningDownloadPlatform
        : null,
    choices: [
      for (final platform in detail.app.platforms.toSet())
        _DownloadChoice(
          value: platform,
          icon: platformIcon(platform),
          title: downloadPlatformLabel(platform),
          subtitle: platform == runningDownloadPlatform
              ? '当前设备'
              : platform == widget.selectedPlatform
              ? '当前浏览的平台'
              : null,
        ),
    ],
  );

  Future<MacDownloadOptions> _options(AppDetails detail, String target) async {
    if (target == 'macOS') return widget.manager.macResolver.resolve(detail);
    final stores = target == 'iOS'
        ? {
            for (final link in detail.downloads)
              if (link.platform == 'iOS' && isAppStoreUrl(link.url)) link.url,
            for (final url in [detail.releaseUrl, detail.officialUrl])
              if (url != null && isAppStoreUrl(url)) url,
          }.toList()
        : <String>[];
    return MacDownloadOptions(
      stores: stores,
      packages: stores.isNotEmpty
          ? const []
          : await widget.manager.macResolver.resolvePackages(detail, target),
    );
  }

  Future<void> _download() async {
    setState(() => loading = true);
    AppDetails? detail;
    try {
      detail = await widget.loadDetails();
      if (detail.app.withdrawn) throw const FormatException('这个应用已下架。');
      if (!mounted) return;
      if (detail.app.platforms.isEmpty) {
        throw const FormatException('暂未确认支持的平台，请使用官方渠道。');
      }
      final running = runningDownloadPlatform;
      final target =
          directDownloadPlatform(
            selected: widget.selectedPlatform,
            running: running,
            supported: detail.app.platforms,
          ) ??
          await _choosePlatform(detail);
      if (!mounted || target == null) return;
      String? architecture;
      LinuxSystemInfo? linux;
      if (target == 'Linux' && running == target) {
        try {
          linux = await widget.manager.installer.linuxSystemInfo();
          architecture = linux.architecture;
        } catch (_) {
          /* Keep manual package selection available. */
        }
      }
      if (target == running &&
          ['macOS', 'Android', 'Windows'].contains(target)) {
        try {
          architecture = await widget.manager.installer.architecture();
        } catch (_) {
          /* Allow manual package selection. */
        }
      }
      if (!mounted) return;
      final source = GitHubReleaseResolver.sourceFor(detail, target);
      if (source != null) {
        final stores = target == 'macOS'
            ? detail.downloads
                  .where((d) => d.platform == target && isAppStoreUrl(d.url))
                  .map((d) => d.url)
                  .toSet()
            : <String>{};
        if (stores.isNotEmpty) {
          final channel = await _chooseDownload<String>(
            title: '选择下载来源',
            choices: [
              for (final store in stores)
                _DownloadChoice(
                  value: store,
                  icon: Icons.apple_rounded,
                  title: 'App Store',
                  subtitle: '在商店中下载',
                ),
              _DownloadChoice(
                value: source.toString(),
                icon: Icons.download_rounded,
                title: 'GitHub',
                subtitle: '选择版本与资源',
              ),
            ],
          );
          if (!mounted || channel == null) return;
          if (isAppStoreUrl(channel)) {
            await openLink(context, channel, downloadPlatform: target);
            return;
          }
        }
        final downloadApp = detail.app;
        final signingPreference = widget.manager.resigningPreferenceFor(
          appKey: downloadApp.key,
          appName: downloadApp.name,
        );
        final selection = await _showChoice(
          () => showAdaptiveForm<ReleaseDownloadSelection>(
            context: context,
            builder: (context) => ReleaseDownloadDialog(
              appName: downloadApp.name,
              source: source,
              resolver: GitHubReleaseResolver(widget.manager.macResolver),
              installer: widget.manager.installer,
              suggestedPackageName: signingPreference?.resignedPackageName,
              suggestedSigningKey: signingPreference?.resignKey,
              preferences: ReleaseDownloadPreferences(
                platform: target,
                running: running,
                architecture: architecture,
                linuxPackageKind: linux?.packageKind,
              ),
              deviceDescription: [
                ?linux?.distribution,
                ?architecture,
              ].join(' · '),
            ),
          ),
        );
        if (!mounted || selection == null) return;
        if (!selection.websiteFallback) {
          await _startDownload(
            detail,
            selection.resource!,
            target,
            running,
            resignKey: selection.resignKey,
            resignPackageName: selection.resignPackageName,
          );
          return;
        }
      }
      final options = await _options(detail, target);
      if (!mounted) return;
      if (options.stores.length == 1 && options.packages.isEmpty) {
        await openLink(
          context,
          options.stores.single,
          downloadPlatform: target,
        );
        return;
      }
      final recommendation = switch (target) {
        'Android' when running == target => recommendedAndroidPackage(
          options.packages,
          architecture,
        ),
        'Windows' when running == target => recommendedWindowsPackage(
          options.packages,
          architecture,
        ),
        'Linux' when running == target => linux?.recommended(options.packages),
        _ => null,
      };
      var package = target == 'macOS'
          ? options.recommended(architecture)
          : options.packages.length == 1 && options.stores.isEmpty
          ? options.packages.single
          : null;
      if (package == null) {
        if (options.stores.isEmpty && options.packages.isEmpty) {
          throw FormatException(
            '暂未找到可识别的 ${downloadPlatformLabel(target)} 安装包，请使用官方渠道。',
          );
        }
        final selected = await _chooseDownload<Object>(
          title: '下载 ${detail.app.name} · ${downloadPlatformLabel(target)}',
          initialValue: recommendation,
          description: linux == null
              ? null
              : [
                  if (linux.distribution != null) linux.distribution!,
                  if (linux.architecture != null) linux.architecture!,
                  linux.packageKind == null
                      ? '软件包格式未确认，优先推荐 AppImage'
                      : '优先推荐 ${linux.packageKind!.toUpperCase()}，也可选择 AppImage',
                ].join(' · '),
          choices: [
            for (final store in options.stores)
              _DownloadChoice(
                value: store,
                icon: Icons.apple_rounded,
                title: 'App Store',
                subtitle: '在商店中下载',
              ),
            for (final candidate in options.packages)
              _DownloadChoice(
                value: candidate,
                icon: Icons.download_rounded,
                title: _label(candidate, architecture),
                subtitle: candidate.label,
              ),
          ],
        );
        if (!mounted || selected == null) return;
        if (selected is String) {
          await openLink(context, selected, downloadPlatform: target);
          return;
        }
        package = selected as DownloadLink;
      }
      await _startDownload(detail, package, target, running);
    } catch (error) {
      if (!mounted) return;
      final fallback =
          detail?.releaseUrl ?? detail?.officialUrl ?? widget.app.url;
      await _showChoice(
        () => showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('暂时无法开始下载'),
            content: Text(
              error is FormatException ? error.message : '无法读取下载信息，请检查网络后重试。',
            ),
            actions: [
              DialogActionsRow(
                cancelLabel: '关闭',
                confirmLabel: '打开官方页面',
                onCancel: () => Navigator.pop(context),
                onConfirm: () {
                  Navigator.pop(context);
                  openLink(this.context, fallback);
                },
              ),
            ],
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _startDownload(
    AppDetails detail,
    DownloadLink package,
    String target,
    String? running, {
    AndroidSigningKey? resignKey,
    String? resignPackageName,
  }) async {
    if (running == 'iOS' ||
        running == 'Android' &&
            (package.platform != 'Android' || package.kind != 'apk')) {
      await openLink(
        context,
        package.url,
        downloadPlatform: package.platform ?? target,
      );
    } else {
      await widget.manager.download(
        detail.app,
        DownloadLink(
          url: package.url,
          label: package.label,
          platform: package.platform,
          architecture: package.architecture,
          kind: package.kind,
          sha256: package.sha256,
          checksumSource: package.checksumSource,
          version:
              package.version ??
              (package.isPackage
                  ? detail.versionForPlatform(package.platform ?? target)
                  : null),
          releaseUrl: package.releaseUrl,
        ),
        resignKey: resignKey,
        resignPackageName: resignPackageName,
      );
      if (mounted) widget.onStarted();
    }
  }
}
