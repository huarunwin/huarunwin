import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/android_package.dart';
import '../services/downloads.dart';
import 'adaptive_dialog.dart';
import 'page_components.dart';

class AndroidSigningKeyTransferDialog extends StatefulWidget {
  const AndroidSigningKeyTransferDialog({
    super.key,
    required this.installer,
    this.signingKey,
    this.newlyCreated = false,
  });
  final NativeInstaller installer;
  final AndroidSigningKey? signingKey;
  final bool newlyCreated;

  @override
  State<AndroidSigningKeyTransferDialog> createState() =>
      _SigningKeyTransferDialogState();
}

class _SigningKeyTransferDialogState
    extends State<AndroidSigningKeyTransferDialog> {
  final _form = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _repeat = TextEditingController();
  bool _busy = false, _attempted = false;
  bool _showPassword = false, _showRepeat = false;
  String? _error;
  bool get _exporting => widget.signingKey != null;

  @override
  void dispose() {
    _password.dispose();
    _repeat.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!_form.currentState!.validate()) {
      setState(() => _attempted = true);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final key = _exporting
          ? await widget.installer.exportApkSigningKey(
              widget.signingKey!,
              password: _password.text,
            )
          : await widget.installer.importApkSigningKey(
              password: _password.text,
            );
      if (!mounted) return;
      if (key != null) Navigator.pop(context, key);
    } catch (error) {
      if (mounted) setState(() => _error = _message(error, '密钥操作失败，请重试。'));
    } finally {
      if (mounted) {
        _password.clear();
        _repeat.clear();
        setState(() {
          _busy = false;
          _attempted = false;
          _showPassword = false;
          _showRepeat = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AdaptiveDialog(
      title: _exporting ? '备份签名密钥' : '导入签名密钥',
      showDragHandle: false,
      content: SizedBox(
        width: 500,
        child: Form(
          key: _form,
          autovalidateMode: _attempted
              ? AutovalidateMode.onUserInteraction
              : AutovalidateMode.disabled,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _exporting
                    ? '请保存密钥备份并牢记密码。重装华润赢或换机后，导入同一密钥才能继续更新重签应用。'
                    : '选择包含签名私钥和证书的 PKCS#12（.p12）备份，并输入备份密码。导入不会替换其他密钥。',
              ),
              const SizedBox(height: 20),
              if (widget.signingKey case final key?)
                PageSection(
                  title: '将要备份的密钥',
                  footer: '备份使用密码加密，请保存到应用之外的目录或网盘。只有 APK 或证书无法恢复签名私钥。',
                  children: [
                    PageRow(
                      title: key.label,
                      subtitle: '包含签名私钥与证书',
                      icon: Icons.key_rounded,
                    ),
                  ],
                ),
              PageSection(
                title: _exporting ? '设置备份密码' : '输入备份密码',
                dividerIndent: 16,
                footer: _exporting ? '至少 8 个字符，密码不会保存。' : '密码不会保存。',
                children: [
                  _passwordField(),
                  if (_exporting) _passwordField(repeat: true),
                ],
              ),
              if (_error != null) ...[
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: DialogActionsRow(
        busy: _busy,
        cancelLabel: widget.newlyCreated ? '稍后' : '取消',
        confirmLabel: _busy
            ? '正在处理…'
            : _exporting
            ? '立即备份'
            : '选择文件并导入',
        onCancel: () => Navigator.pop(context),
        onConfirm: _busy ? null : _submit,
      ),
    ),
  );

  Widget _passwordField({bool repeat = false}) {
    final visible = repeat ? _showRepeat : _showPassword;
    return TextFormField(
      key: ValueKey(
        repeat ? 'signing-backup-repeat' : 'signing-backup-password',
      ),
      controller: repeat ? _repeat : _password,
      enabled: !_busy,
      obscureText: !visible,
      keyboardType: TextInputType.visiblePassword,
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      decoration: InputDecoration(
        labelText: repeat ? '再次输入密码' : '备份密码',
        floatingLabelBehavior: FloatingLabelBehavior.never,
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        errorMaxLines: 3,
        contentPadding: const EdgeInsets.all(16),
        suffixIcon: IconButton(
          tooltip: visible ? '隐藏密码' : '显示密码',
          onPressed: _busy
              ? null
              : () => setState(() {
                  if (repeat) {
                    _showRepeat = !_showRepeat;
                  } else {
                    _showPassword = !_showPassword;
                  }
                }),
          icon: Icon(
            visible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
          ),
        ),
      ),
      textInputAction: _exporting && !repeat
          ? TextInputAction.next
          : TextInputAction.done,
      validator: (value) => repeat
          ? value != _password.text
                ? '两次输入的密码不一致'
                : null
          : _exporting && (value?.length ?? 0) < 8
          ? '备份密码至少需要 8 个字符'
          : null,
      onChanged: (_) {
        if (_error != null) setState(() => _error = null);
      },
      onFieldSubmitted: (_) {
        if (repeat || !_exporting) _submit();
      },
    );
  }
}

String _message(Object error, String fallback) =>
    error is PlatformException ? error.message ?? fallback : fallback;
