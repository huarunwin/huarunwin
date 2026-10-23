import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../services/android_package.dart';
import '../services/downloads.dart';
import '../services/download_platform.dart';
import '../services/github_debug.dart';
import '../services/github_releases.dart';
import 'adaptive_dialog.dart';
import 'android_resigning_options.dart';
import 'page_components.dart';
import 'theme.dart';

class ReleaseDownloadSelection {
  const ReleaseDownloadSelection(
    this.resource, {
    this.resignKey,
    this.resignPackageName,
  }) : websiteFallback = false;
  const ReleaseDownloadSelection.website()
    : resource = null,
      websiteFallback = true,
      resignKey = null,
      resignPackageName = null;
  final DownloadLink? resource;
  final bool websiteFallback;
  final AndroidSigningKey? resignKey;
  final String? resignPackageName;
}

class ReleaseDownloadDialog extends StatefulWidget {
  const ReleaseDownloadDialog({
    super.key,
    required this.appName,
    required this.source,
    required this.resolver,
    required this.preferences,
    this.deviceDescription,
    this.installer,
    this.suggestedPackageName,
    this.suggestedSigningKey,
  });
  final String appName;
  final Uri source;
  final GitHubReleaseResolver resolver;
  final ReleaseDownloadPreferences preferences;
  final String? deviceDescription;
  final NativeInstaller? installer;
  final String? suggestedPackageName;
  final AndroidSigningKey? suggestedSigningKey;

  @override
  State<ReleaseDownloadDialog> createState() => _ReleaseDownloadDialogState();
}

class _ReleaseDownloadDialogState extends State<ReleaseDownloadDialog> {
  final _releases = <GitHubRelease>[];
  final _visited = <Uri>{};
  Uri? _next;
  GitHubRelease? _release;
  List<DownloadLink> _resources = [];
  DownloadLink? _selected;
  bool _loading = true, _showAll = false;
  String? _error;
  int _request = 0;
  late final _signing = AndroidResigningController(
    widget.installer ?? NativeInstaller(),
    suggestedPackageName: widget.suggestedPackageName,
    suggestedKey: widget.suggestedSigningKey,
  );
  bool get _canResign =>
      widget.preferences.running == 'Android' &&
      _selected?.platform == 'Android' &&
      _selected?.kind == 'apk';

  void _signingChanged() => setState(() {});

  Future<void> _confirm() async {
    if (_loading ||
        _error != null ||
        _selected == null ||
        !_signing.canConfirm) {
      return;
    }
    final key = _canResign && _signing.enabled
        ? await _signing.confirm(context)
        : null;
    if (!mounted || _signing.enabled && key == null) return;
    Navigator.pop(
      context,
      ReleaseDownloadSelection(
        _selected,
        resignKey: key,
        resignPackageName: _signing.targetPackageName,
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _signing.addListener(_signingChanged);
    _initialize();
  }

  @override
  void dispose() {
    _request++;
    _signing.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    final request = ++_request;
    final trace = GitHubDebugTrace.start(
      'dialog.initialize',
      widget.source,
      fields: {
        'platform': widget.preferences.platform,
        'architecture': widget.preferences.architecture,
      },
    );
    setState(() {
      _loading = true;
      _error = null;
      _release = null;
      _resources = [];
      _selected = null;
      _signing.reset();
    });
    try {
      await _loadInitialRelease(request).timeout(const Duration(seconds: 45));
      trace?.log(
        mounted && request == _request ? 'dialog.ready' : 'dialog.discarded',
      );
    } catch (error) {
      trace?.log('dialog.failed', error: error);
      if (!mounted || request != _request) return;
      // A timed-out operation can finish later; it must not replace this error
      // or a newer selection. Individual HTTP requests have their own deadline.
      _request++;
      setState(() {
        _loading = false;
        _error = githubReleaseErrorMessage(error);
      });
    }
  }

  Future<void> _loadInitialRelease(int request) async {
    final index = GitHubReleaseResolver.indexFor(widget.source);
    final page = await widget.resolver.loadInitialPage(widget.source);
    if (!mounted || request != _request) return;
    setState(() {
      _releases
        ..clear()
        ..addAll(page.releases);
      if (!page.fromCatalog) _visited.add(index);
      _next = page.next;
    });
    if (!page.fromCatalog && !_releases.any((r) => r.latest && !r.prerelease)) {
      final latest = await widget.resolver.loadLatest(widget.source);
      if (!mounted || request != _request) return;
      if (latest != null) {
        setState(() {
          _releases.removeWhere((r) => r.page == latest.page);
          _releases.insert(0, latest);
        });
      }
    }
    final stable = _releases.where((r) => !r.prerelease);
    final ordered = [
      ...stable.where((r) => r.latest),
      ...stable.where((r) => !r.latest),
      ..._releases.where((r) => r.prerelease),
    ];
    (GitHubRelease, List<DownloadLink>)? fallback;
    for (final release in ordered.take(10)) {
      if (!mounted || request != _request) return;
      // A failed request must not silently recommend an older version.
      setState(() => _release = release);
      final resources = await widget.resolver.loadResources(release);
      if (!mounted || request != _request) return;
      fallback ??= (release, resources);
      final suitable = widget.preferences.hasSuitableResource(resources);
      githubDebugLog(
        'selection.candidate',
        uri: release.page,
        fields: {
          'resources': resources.length,
          'platformPackages': widget.preferences.packages(resources).length,
          'hasSuitableResource': suitable,
        },
      );
      if (suitable) {
        _apply(release, resources);
        return;
      }
      if (widget.preferences.packages(resources).isNotEmpty &&
          widget.preferences.packages(fallback.$2).isEmpty) {
        fallback = (release, resources);
      }
    }
    if (fallback == null) {
      throw const FormatException('暂未读取到可用版本，请重试或使用网站提供的下载入口。');
    }
    if (mounted && request == _request) _apply(fallback.$1, fallback.$2);
  }

  void _apply(GitHubRelease release, List<DownloadLink> resources) {
    setState(() {
      _release = release;
      _resources = resources;
      _selected = widget.preferences.initialResource(resources);
      _signing.reset();
      _loading = false;
      _error = null;
    });
    githubDebugLog(
      'selection.applied',
      uri: release.page,
      fields: {
        'resources': resources.length,
        'selectedUrl': _selected == null
            ? null
            : githubDebugUrl(Uri.parse(_selected!.url)),
      },
    );
  }

  Future<void> _selectRelease(GitHubRelease release) async {
    final request = ++_request;
    final trace = GitHubDebugTrace.start('dialog.selectRelease', release.page);
    setState(() {
      _release = release;
      _resources = [];
      _selected = null;
      _signing.reset();
      _loading = true;
      _error = null;
    });
    try {
      final resources = await widget.resolver
          .loadResources(release)
          .timeout(const Duration(seconds: 45));
      if (mounted && request == _request) {
        _apply(release, resources);
        trace?.log('dialog.ready');
      } else {
        trace?.log('dialog.discarded');
      }
    } catch (error) {
      trace?.log('dialog.failed', error: error);
      if (!mounted || request != _request) return;
      _request++;
      setState(() {
        _loading = false;
        _error = githubReleaseErrorMessage(error);
      });
    }
  }

  Future<void> _pickVersion() async {
    final selected = await showAdaptiveForm<GitHubRelease>(
      context: context,
      builder: (context) => _VersionDialog(
        releases: _releases,
        selected: _release,
        next: _next,
        visited: _visited,
        resolver: widget.resolver,
        onPage: (page) {
          if (!mounted) return;
          setState(() {
            final known = _releases.map((r) => r.page).toSet();
            _releases.addAll(page.releases.where((r) => known.add(r.page)));
            _next = page.next;
          });
        },
      ),
    );
    if (!mounted || selected == null) return;
    if (selected.page != _release?.page || _error != null || _loading) {
      await _selectRelease(selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final resources = _showAll
        ? _resources
        : widget.preferences.packages(_resources);
    final recommended = widget.preferences.recommended(_resources);
    return PopScope(
      canPop: !_signing.busy,
      child: AdaptiveDialog(
        title: '下载 ${widget.appName}',
        scrollable: false,
        content: AbsorbPointer(
          absorbing: _signing.busy,
          child: SizedBox(
            width: 540,
            height: math.min(440, MediaQuery.sizeOf(context).height * .55),
            child: ListView.builder(
              itemCount:
                  2 +
                  (_loading || _error != null
                      ? 1
                      : resources.length + 2 + (_canResign ? 1 : 0)),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        [
                          downloadPlatformLabel(widget.preferences.platform),
                          ?widget.deviceDescription,
                        ].join(' · '),
                      ),
                      const SizedBox(height: 12),
                      Material(
                        color: colors.surfaceContainer,
                        shape: surfaceShape(16),
                        clipBehavior: Clip.antiAlias,
                        child: ListTile(
                          key: const ValueKey('release-version'),
                          title: const Text('版本'),
                          subtitle: Text(
                            _release == null
                                ? _loading
                                      ? '正在读取版本'
                                      : '版本读取失败'
                                : '${_release!.tag} · ${_release!.prerelease ? '预发布' : '稳定版'}',
                          ),
                          trailing: const Icon(Icons.unfold_more_rounded),
                          onTap: _releases.isEmpty ? null : _pickVersion,
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  );
                }
                if (index == 1) {
                  final switchTile = usesMobileDesign(context)
                      ? SwitchListTile.new
                      : SwitchListTile.adaptive;
                  return switchTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('显示全部资源'),
                    subtitle: Text(
                      '默认显示 ${downloadPlatformLabel(widget.preferences.platform)} 安装包',
                    ),
                    value: _showAll,
                    onChanged: (value) => setState(() {
                      _showAll = value;
                      if (!value &&
                          _selected != null &&
                          !widget.preferences
                              .packages(_resources)
                              .contains(_selected)) {
                        _selected = widget.preferences.initialResource(
                          _resources,
                        );
                      }
                      if (!_canResign) _signing.reset();
                    }),
                  );
                }
                if (_loading) {
                  return Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 16),
                        Text(
                          _release == null
                              ? '正在读取 GitHub 版本列表…'
                              : '正在读取 ${_release!.tag} 的安装包…',
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  );
                }
                if (_error != null) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_error!),
                      TextButton.icon(
                        onPressed: () => _release == null
                            ? _initialize()
                            : _selectRelease(_release!),
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('重试'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(
                          context,
                          const ReleaseDownloadSelection.website(),
                        ),
                        child: const Text('使用网站提供的下载入口'),
                      ),
                    ],
                  );
                }
                if (index == 2) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Text(
                      resources.isEmpty
                          ? '此版本暂无对应资源，可切换版本或显示全部资源。'
                          : _selected == null
                          ? '未找到匹配当前设备的资源，请选择其他版本或手动选择资源。'
                          : '优先稳定版与适合当前设备的资源，确认后开始下载。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  );
                }
                if (_canResign && index == resources.length + 3) {
                  return _resigningOptions();
                }
                if (index >= resources.length + 3) {
                  return TextButton(
                    onPressed: () => Navigator.pop(
                      context,
                      const ReleaseDownloadSelection.website(),
                    ),
                    child: const Text('使用网站提供的下载入口'),
                  );
                }
                final resource = resources[index - 3];
                final selected = _selected?.url == resource.url;
                final description = [
                  resource.sizeLabel ?? '大小未知',
                  if (recommended?.url == resource.url) '推荐',
                  ?resource.platform,
                  if (resource.kind != 'resource') resource.kind!.toUpperCase(),
                  if (resource.isPackage) resource.architecture ?? '架构未确认',
                  if (!resource.isPackage ||
                      resource.platform != widget.preferences.running)
                    '仅下载',
                ].join(' · ');
                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Material(
                    color: colors.surfaceContainer,
                    shape: surfaceShape(14),
                    clipBehavior: Clip.antiAlias,
                    child: ListTile(
                      key: ValueKey(resource.url),
                      title: Text(resource.label),
                      subtitle: Text(description),
                      selected: selected,
                      selectedColor: colors.onSurface,
                      trailing: SizedBox.square(
                        dimension: 24,
                        child: selected
                            ? Icon(Icons.check_rounded, color: colors.primary)
                            : null,
                      ),
                      onTap: () => setState(() {
                        if (_selected?.url != resource.url) _signing.reset();
                        _selected = resource;
                      }),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        actions: DialogActionsRow(
          busy: _signing.busy,
          confirmLabel: _canResign && _signing.enabled ? '下载并重签' : '确认下载',
          onCancel: () => Navigator.pop(context),
          onConfirm:
              _loading ||
                  _error != null ||
                  _selected == null ||
                  !_signing.canConfirm
              ? null
              : _confirm,
        ),
      ),
    );
  }

  Widget _resigningOptions() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: AndroidResigningOptions(
      controller: _signing,
      toggleKey: const ValueKey('resign-apk'),
      title: '下载后重签',
    ),
  );
}

class _VersionDialog extends StatefulWidget {
  const _VersionDialog({
    required this.releases,
    required this.selected,
    required this.next,
    required this.visited,
    required this.resolver,
    required this.onPage,
  });
  final List<GitHubRelease> releases;
  final GitHubRelease? selected;
  final Uri? next;
  final Set<Uri> visited;
  final GitHubReleaseResolver resolver;
  final ValueChanged<GitHubReleasePage> onPage;

  @override
  State<_VersionDialog> createState() => _VersionDialogState();
}

class _VersionDialogState extends State<_VersionDialog> {
  late final _releases = List.of(widget.releases);
  late GitHubRelease? _selected = widget.selected;
  late Uri? _next = widget.next;
  bool _loading = false;
  String? _error;

  Future<void> _loadMore() async {
    final next = _next;
    if (_loading || next == null || widget.visited.contains(next)) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.resolver
          .loadPage(next)
          .timeout(const Duration(seconds: 30));
      if (!mounted) return;
      widget.visited.add(next);
      final known = _releases.map((r) => r.page).toSet();
      setState(() {
        _releases.addAll(page.releases.where((r) => known.add(r.page)));
        _next = page.next;
      });
      widget.onPage(page);
    } catch (error) {
      githubDebugLog('pagination.failed', uri: next, error: error);
      if (mounted) {
        setState(
          () => _error = '${githubReleaseErrorMessage(error)} 已载入版本仍可选择。',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AdaptiveDialog(
      title: '选择版本',
      scrollable: false,
      content: SizedBox(
        width: 540,
        height: math.min(430, MediaQuery.sizeOf(context).height * .55),
        child: ListView.builder(
          itemCount: _releases.length + 1,
          itemBuilder: (context, index) {
            if (index == _releases.length) {
              return Column(
                children: [
                  if (_error != null) Text(_error!),
                  if (_next != null &&
                      !widget.visited.contains(_next) &&
                      widget.visited.length < 100)
                    TextButton(
                      onPressed: _loading ? null : _loadMore,
                      child: _loading
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(_error == null ? '载入更多版本' : '重试载入更多版本'),
                    )
                  else
                    const Text('已显示载入的全部版本'),
                ],
              );
            }
            final release = _releases[index];
            final selected = _selected?.page == release.page;
            return ListTile(
              title: Text(release.tag),
              subtitle: Text(
                [
                  if (release.name != release.tag) release.name,
                  release.prerelease
                      ? '预发布'
                      : release.latest
                      ? '最新稳定版'
                      : '稳定版',
                  if (release.publishedAt != null)
                    release.publishedAt!.toIso8601String().split('T').first,
                ].join(' · '),
              ),
              selected: selected,
              selectedColor: colors.onSurface,
              trailing: SizedBox.square(
                dimension: 24,
                child: selected
                    ? Icon(Icons.check_rounded, color: colors.primary)
                    : null,
              ),
              onTap: () => setState(() => _selected = release),
            );
          },
        ),
      ),
      actions: DialogActionsRow(
        confirmLabel: '确认',
        onCancel: () => Navigator.pop(context),
        onConfirm: _selected == null
            ? null
            : () => Navigator.pop(context, _selected),
      ),
    );
  }
}
