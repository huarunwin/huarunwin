import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/android_package.dart';
import '../services/downloads.dart';
import 'adaptive_dialog.dart';
import 'android_signing_key_dialog.dart';
import 'android_signing_key_transfer_dialog.dart';
import 'page_components.dart';

/// A draft: enabling signing never creates or replaces a signing identity.
class AndroidResigningController extends ChangeNotifier {
  AndroidResigningController(
    this.installer, {
    this.originalPackageName,
    this.suggestedPackageName,
    this.suggestedKey,
  }) {
    packageName.addListener(_nameChanged);
  }

  final NativeInstaller installer;
  final String? originalPackageName, suggestedPackageName;
  final AndroidSigningKey? suggestedKey;
  late final packageName = TextEditingController(
    text:
        suggestedPackageName ??
        (originalPackageName == null ? '' : '$originalPackageName.huarun'),
  );
  AndroidSigningKey? key;
  bool enabled = false, busy = false;
  bool changePackageName = false;
  String? error;
  bool _disposed = false;
  int _request = 0;

  String? get targetPackageName =>
      enabled && changePackageName ? packageName.text.trim() : null;
  String? get packageNameError => targetPackageName == null
      ? null
      : androidPackageNameError(
          targetPackageName!,
          original: originalPackageName,
        );
  bool get canConfirm =>
      !busy && (!enabled || error == null && packageNameError == null);

  void _nameChanged() {
    if (!_disposed) notifyListeners();
  }

  void setChangePackageName(bool value) {
    changePackageName = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _request++;
    packageName.dispose();
    super.dispose();
  }

  void reset() {
    _request++;
    enabled = busy = false;
    changePackageName = false;
    packageName.text =
        suggestedPackageName ??
        (originalPackageName == null ? '' : '$originalPackageName.huarun');
    key = null;
    error = null;
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    if (!value) {
      reset();
      return;
    }
    final request = ++_request;
    enabled = busy = true;
    error = null;
    notifyListeners();
    try {
      final keys = await installer.apkSigningKeys();
      if (_disposed || request != _request) return;
      final expected = key ?? suggestedKey;
      key = expected == null
          ? keys.firstOrNull
          : keys
                .where(
                  (candidate) =>
                      candidate.id == expected.id &&
                      candidate.certificateSha256 == expected.certificateSha256,
                )
                .firstOrNull;
      if (expected != null && key == null) {
        key = AndroidSigningKey(
          id: expected.id,
          label: expected.label,
          certificateSha256: expected.certificateSha256,
          exportable: expected.exportable,
          available: false,
        );
      }
      if (key?.available == false) {
        error = '签名密钥已不可用，请从“管理密钥”导入原备份恢复。';
      }
    } catch (_) {
      if (_disposed || request != _request) return;
      error = '无法读取本机密钥，请重试或从“管理密钥”导入备份。';
    } finally {
      if (!_disposed && request == _request) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<void> manage(BuildContext context) async {
    if (busy) return;
    busy = true;
    notifyListeners();
    try {
      final selected = await showAdaptiveForm<AndroidSigningKey>(
        context: context,
        enableDrag: false,
        builder: (_) =>
            AndroidSigningKeyDialog(installer: installer, selected: key),
      );
      if (!_disposed && selected != null) {
        key = selected;
        error = null;
      }
    } finally {
      if (!_disposed) {
        busy = false;
        notifyListeners();
      }
    }
  }

  Future<AndroidSigningKey?> confirm(BuildContext context) async {
    if (!enabled || !canConfirm) return null;
    busy = true;
    notifyListeners();
    try {
      final resolved = await installer.resolveApkSigningKey(selected: key);
      if (_disposed || !context.mounted) return null;
      key = resolved.key;
      if (resolved.created && resolved.key.exportable) {
        key =
            await showAdaptiveForm<AndroidSigningKey>(
              context: context,
              enableDrag: false,
              builder: (_) => AndroidSigningKeyTransferDialog(
                installer: installer,
                signingKey: resolved.key,
                newlyCreated: true,
              ),
            ) ??
            resolved.key;
      }
      return key;
    } catch (failure) {
      if (!_disposed) {
        error = failure is PlatformException
            ? failure.message ?? '无法取得签名密钥，请重试。'
            : '无法取得签名密钥，请重试。';
      }
      return null;
    } finally {
      if (!_disposed) {
        busy = false;
        notifyListeners();
      }
    }
  }
}

class AndroidResigningOptions extends StatelessWidget {
  const AndroidResigningOptions({
    super.key,
    required this.controller,
    required this.toggleKey,
    required this.title,
  });

  final AndroidResigningController controller;
  final Key toggleKey;
  final String title;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SurfacePanel(
        radius: 24,
        child: Column(
          children: [
            SwitchListTile.adaptive(
              key: toggleKey,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 4,
              ),
              title: Text(title),
              value: controller.enabled,
              onChanged: controller.busy ? null : controller.setEnabled,
            ),
            if (controller.enabled) ...[
              Divider(
                height: 1,
                indent: 16,
                endIndent: 16,
                thickness: 1 / MediaQuery.devicePixelRatioOf(context),
              ),
              PageRow(
                key: const ValueKey('manage-signing-key'),
                title: '管理密钥',
                subtitle: controller.busy
                    ? '正在处理…'
                    : controller.key == null
                    ? '个人密钥 · 首次确认重签时自动生成'
                    : '${controller.key!.label}\n${!controller.key!.available
                          ? '本机副本不可用，请导入备份'
                          : !controller.key!.exportable
                          ? '仅本机 · 不可备份'
                          : controller.key!.lastExportedAt == null
                          ? '尚未在本机导出备份'
                          : '已导出备份'}',
                icon: Icons.key_rounded,
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: controller.busy
                    ? null
                    : () => controller.manage(context),
              ),
              Divider(
                height: 1,
                indent: 16,
                endIndent: 16,
                thickness: 1 / MediaQuery.devicePixelRatioOf(context),
              ),
              SwitchListTile.adaptive(
                key: const ValueKey('change-apk-package-name'),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                title: const Text('修改包名'),
                subtitle: const Text('生成独立应用，尝试与原版共存'),
                value: controller.changePackageName,
                onChanged: controller.busy
                    ? null
                    : controller.setChangePackageName,
              ),
              if (controller.changePackageName)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: TextField(
                    key: const ValueKey('apk-package-name'),
                    controller: controller.packageName,
                    enabled: !controller.busy,
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      labelText: '新包名',
                      hintText: 'com.example.app.huarun',
                      helperText: controller.suggestedPackageName == null
                          ? '更新此应用时，需继续使用相同包名与密钥。'
                          : '已填入上次使用的包名；更新需沿用同一密钥。',
                      helperMaxLines: 3,
                      errorText: controller.packageNameError,
                      errorMaxLines: 4,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
      if (controller.enabled)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            controller.changePackageName
                ? '修改包名后应用数据独立，部分应用可能无法启动、登录或接收推送。仅支持普通单文件 APK；生成并验签成功不代表运行正常。请备份密钥，后续更新沿用相同包名与密钥。'
                : '重签版通常无法覆盖官方原版，后续更新需使用同一密钥。请妥善备份，重装华润赢或换机后导入恢复。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
        ),
      if (controller.error case final error?) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Semantics(
            liveRegion: true,
            child: Text(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: controller.busy
                ? null
                : () => controller.setEnabled(true),
            child: const Text('重试读取密钥'),
          ),
        ),
      ],
    ],
  );
}
