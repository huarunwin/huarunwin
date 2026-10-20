import 'dart:async';

import 'package:flutter/material.dart';

import '../services/android_package.dart';
import '../services/downloads.dart';
import 'adaptive_dialog.dart';
import 'android_resigning_options.dart';
import 'page_components.dart';

class AndroidInstallSelection {
  const AndroidInstallSelection(
    this.method, {
    this.resignKey,
    this.resignPackageName,
  });
  final AndroidInstallMethod method;
  final AndroidSigningKey? resignKey;
  final String? resignPackageName;
}

class AndroidInstallDialog extends StatefulWidget {
  const AndroidInstallDialog({
    super.key,
    required this.task,
    required this.info,
    required this.installer,
    this.package,
    this.repackOnly = false,
  });
  final DownloadTask task;
  final AndroidPackageInfo info;
  final NativeInstaller installer;
  final DownloadPackage? package;
  final bool repackOnly;

  @override
  State<AndroidInstallDialog> createState() => _AndroidInstallDialogState();
}

class _AndroidInstallDialogState extends State<AndroidInstallDialog> {
  AndroidInstallMethod _method = AndroidInstallMethod.huarun;
  late final _signing = AndroidResigningController(
    widget.installer,
    originalPackageName: widget.info.packageName,
    suggestedPackageName:
        widget.task.resignedPackageName != widget.info.packageName
        ? widget.task.resignedPackageName
        : null,
    suggestedKey: widget.task.resignKey,
  );

  @override
  void initState() {
    super.initState();
    _signing.addListener(_signingChanged);
    if (widget.repackOnly) unawaited(_signing.setEnabled(true));
  }

  void _signingChanged() => setState(() {});

  @override
  void dispose() {
    _signing.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    if (!_signing.canConfirm || widget.repackOnly && !_signing.enabled) return;
    final key = _signing.enabled ? await _signing.confirm(context) : null;
    if (!mounted || _signing.enabled && key == null) return;
    Navigator.pop(
      context,
      AndroidInstallSelection(
        _method,
        resignKey: key,
        resignPackageName: _signing.targetPackageName,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final colors = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_signing.busy,
      child: AdaptiveDialog(
        title: widget.repackOnly ? '修改包名／重新签名' : '安装 ${widget.task.appName}',
        showDragHandle: false,
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.task.packageLabel(
                widget.package ?? widget.task.defaultPackage,
              ),
            ),
            SelectableText(info.packageName),
            if (info.version != null) Text('安装包版本：${info.version}'),
            if (info.installedVersion != null)
              Text('本机版本：${info.installedVersion}'),
            if (info.minimumSdk != null)
              Text('最低 Android API：${info.minimumSdk}'),
            if (info.nativeAbis.isNotEmpty)
              Text('安装包架构：${info.nativeAbis.join(' / ')}'),
            if (info.certificateSha256.isNotEmpty)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('签名证书 SHA-256'),
                children: [SelectableText(info.certificateSha256.join('\n'))],
              ),
            if (!widget.repackOnly) ...[
              const SizedBox(height: 20),
              PageSection(
                title: '安装方式',
                children: [
                  for (final (method, title, subtitle, icon) in [
                    (
                      AndroidInstallMethod.huarun,
                      '华润赢安装',
                      '在应用内管理安装进度和结果',
                      Icons.install_mobile_rounded,
                    ),
                    (
                      AndroidInstallMethod.system,
                      '系统安装器',
                      '打开系统安装界面',
                      Icons.android_rounded,
                    ),
                    (
                      AndroidInstallMethod.other,
                      '其他安装器',
                      '选择设备上的其他安装应用',
                      Icons.open_in_new_rounded,
                    ),
                  ])
                    Semantics(
                      selected: _method == method,
                      child: PageRow(
                        key: ValueKey('installer-${method.name}'),
                        title: title,
                        subtitle: subtitle,
                        icon: icon,
                        trailing: _method == method
                            ? Icon(Icons.check_rounded, color: colors.primary)
                            : null,
                        onTap: _signing.busy
                            ? null
                            : () => setState(() {
                                if (_method != method) {
                                  _method = method;
                                  _signing.reset();
                                }
                              }),
                      ),
                    ),
                ],
              ),
            ],
            if (_method == AndroidInstallMethod.huarun)
              AndroidResigningOptions(
                controller: _signing,
                toggleKey: const ValueKey('install-resign-apk'),
                title: widget.repackOnly ? '重新签名' : '安装前重签',
              ),
            if (!widget.repackOnly &&
                (widget.package ?? widget.task.defaultPackage) ==
                    DownloadPackage.resigned)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  widget.task.isRenamedPackage(DownloadPackage.resigned)
                      ? '本次安装为修改包名后的重签副本，应用数据独立。后续更新须沿用相同包名和密钥。'
                      : '本次安装为重签副本，通常无法覆盖官方原版。后续更新须沿用同一密钥，请妥善备份。',
                ),
              ),
            const SizedBox(height: 12),
            Text(
              widget.repackOnly
                  ? '确认后生成独立副本，所选包与其他包会保留。'
                  : _method == AndroidInstallMethod.other
                  ? '交接后安装结果保持未确认，安装包会保留。'
                  : '继续后仍需在 Android 系统窗口确认安装。',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          ],
        ),
        actions: DialogActionsRow(
          busy: _signing.busy,
          confirmLabel: widget.repackOnly
              ? '生成副本'
              : _signing.enabled
              ? '重签并安装'
              : '继续安装',
          onCancel: () => Navigator.pop(context),
          onConfirm:
              _signing.canConfirm && (!widget.repackOnly || _signing.enabled)
              ? _confirm
              : null,
        ),
      ),
    );
  }
}
