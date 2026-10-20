import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/android_package.dart';
import '../services/downloads.dart';
import 'adaptive_dialog.dart';
import 'android_signing_key_transfer_dialog.dart';
import 'page_components.dart';

class AndroidSigningKeyDialog extends StatefulWidget {
  const AndroidSigningKeyDialog({
    super.key,
    required this.installer,
    this.selected,
  });
  final NativeInstaller installer;
  final AndroidSigningKey? selected;

  @override
  State<AndroidSigningKeyDialog> createState() =>
      _AndroidSigningKeyDialogState();
}

class _AndroidSigningKeyDialogState extends State<AndroidSigningKeyDialog> {
  List<AndroidSigningKey> _keys = [];
  AndroidSigningKey? _selected;
  bool _loading = true, _working = false, _loaded = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final keys = await widget.installer.apkSigningKeys();
      if (!mounted) return;
      setState(() {
        _keys = keys;
        _loaded = true;
        _selected =
            keys.where((key) => key.id == widget.selected?.id).firstOrNull ??
            keys.firstOrNull;
      });
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取本机密钥，可重试或导入备份恢复。');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _remember(AndroidSigningKey key) {
    setState(() {
      _keys = [key, ..._keys.where((value) => value.id != key.id)];
      _selected = key;
      _loaded = true;
      _error = null;
    });
  }

  Future<AndroidSigningKey?> _transfer({
    AndroidSigningKey? key,
    bool created = false,
  }) => showAdaptiveForm<AndroidSigningKey>(
    context: context,
    enableDrag: false,
    builder: (context) => AndroidSigningKeyTransferDialog(
      installer: widget.installer,
      signingKey: key,
      newlyCreated: created,
    ),
  );

  Future<void> _manage({bool importing = false}) async {
    if (_working) return;
    setState(() => _working = true);
    final key = await _transfer(key: importing ? null : _selected);
    if (!mounted) return;
    if (key != null) _remember(key);
    setState(() => _working = false);
  }

  Future<void> _confirm() async {
    if (_working) return;
    if (_selected?.available == false) return;
    if (_selected != null) {
      Navigator.pop(context, _selected);
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      var key = await widget.installer.createApkSigningKey();
      if (!mounted) return;
      _remember(key);
      if (key.exportable) {
        key = await _transfer(key: key, created: true) ?? key;
      }
      if (mounted) Navigator.pop(context, key);
    } catch (error) {
      if (mounted) setState(() => _error = _message(error, '无法创建签名密钥，请重试。'));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_working,
    child: AdaptiveDialog(
      title: '选择重签密钥',
      showDragHandle: false,
      content: SizedBox(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '后续更新需使用同一密钥。重签版通常无法覆盖官方原版，也可能影响应用的签名校验或部分功能。',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                  child: CircularProgressIndicator(semanticsLabel: '正在读取密钥'),
                ),
              )
            else if (_error != null) ...[
              Semantics(
                liveRegion: true,
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
              TextButton(
                onPressed: _working ? null : _load,
                child: const Text('重试读取密钥'),
              ),
            ],
            if (!_loading && _loaded)
              PageSection(
                title: '签名身份',
                children: [
                  for (final key in _keys)
                    _keyChoice(
                      label: key.label,
                      description: !key.available
                          ? '本机副本不可用'
                          : key.exportable
                          ? '可备份'
                          : '仅本机 · 不可备份',
                      icon: Icons.key_rounded,
                      selected: _selected?.id == key.id,
                      onTap: () => setState(() => _selected = key),
                    ),
                  _keyChoice(
                    label: '新建个人密钥',
                    description: '支持加密备份，仅在需要新的签名身份时创建',
                    icon: Icons.add_rounded,
                    selected: _selected == null,
                    onTap: () => setState(() => _selected = null),
                  ),
                ],
              ),
            if (_selected case final key?) ...[
              PageSection(
                title: '所选密钥',
                footer: !key.available
                    ? '此密钥的本机副本不可用，请重试读取或导入备份恢复。新建密钥不能替代它更新已有重签版。'
                    : key.exportable
                    ? '导出记录不代表备份文件仍可用，请妥善保存文件和密码。'
                    : '此旧密钥保存在 Android Keystore，无法导出。卸载华润赢、清除数据或换机后将无法继续使用；新建密钥也不能替代它更新已有重签版。',
                children: [
                  if (key.available && key.exportable)
                    PageRow(
                      key: const ValueKey('export-signing-key'),
                      title: '导出密钥备份',
                      subtitle: key.lastExportedAt == null
                          ? '尚未在本机导出备份'
                          : '上次导出：${_formatTime(key.lastExportedAt!)}',
                      icon: Icons.save_alt_rounded,
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: _working ? null : _manage,
                    ),
                  ExpansionTile(
                    key: ValueKey('signing-certificate-${key.id}'),
                    shape: const Border(),
                    collapsedShape: const Border(),
                    textColor: Theme.of(context).colorScheme.onSurface,
                    iconColor: Theme.of(context).colorScheme.onSurfaceVariant,
                    tilePadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    leading: const IconWell(Icons.fingerprint_rounded),
                    title: const Text('证书信息'),
                    subtitle: const Text('SHA-256 · 用于核对签名身份'),
                    childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    children: [
                      SelectableText(
                        key.certificateSha256,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ],
              ),
            ],
            if (!_loading)
              PageSection(
                title: '已有备份',
                children: [
                  PageRow(
                    key: const ValueKey('import-signing-key'),
                    title: '导入密钥备份',
                    subtitle: '从 .p12 文件恢复原来的签名身份',
                    icon: Icons.file_open_outlined,
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: _working ? null : () => _manage(importing: true),
                  ),
                ],
              ),
          ],
        ),
      ),
      actions: DialogActionsRow(
        busy: _working,
        confirmLabel: _working
            ? '正在处理…'
            : _selected == null
            ? '创建并使用'
            : '使用此密钥',
        onCancel: () => Navigator.pop(context),
        onConfirm:
            _loading || _working || !_loaded || _selected?.available == false
            ? null
            : _confirm,
      ),
    ),
  );

  Widget _keyChoice({
    required String label,
    required String description,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    horizontalTitleGap: 12,
    leading: IconWell(icon),
    title: Text(label),
    subtitle: Text(description),
    selected: selected,
    selectedColor: Theme.of(context).colorScheme.onSurface,
    selectedTileColor: Colors.transparent,
    trailing: SizedBox.square(
      dimension: 24,
      child: selected
          ? Icon(
              Icons.check_rounded,
              color: Theme.of(context).colorScheme.primary,
            )
          : null,
    ),
    onTap: _working ? null : onTap,
  );
}

String _message(Object error, String fallback) =>
    error is PlatformException ? error.message ?? fallback : fallback;

String _formatTime(DateTime time) =>
    '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')} '
    '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
