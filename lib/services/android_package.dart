enum AndroidInstallMethod { huarun, system, other }

String? androidPackageNameError(String value, {String? original}) {
  if (value.length > 127 ||
      !RegExp(r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$')
          .hasMatch(value)) {
    return '至少两段，以点分隔；每段以英文字母开头，只能含字母、数字和下划线，最长 127 字符。';
  }
  return value == original ? '新包名必须与原始包名不同。' : null;
}

class AndroidApkDetails {
  const AndroidApkDetails({
    required this.info,
    required this.bytes,
    this.error,
  });

  final AndroidPackageInfo? info;
  final int bytes;
  final String? error;
}

class AndroidApkIdentity {
  const AndroidApkIdentity({
    required this.packageName,
    this.label,
    this.version,
    this.versionCode,
    this.certificates = const [],
  });

  factory AndroidApkIdentity.fromMap(Map<Object?, Object?> value) =>
      AndroidApkIdentity(
        packageName: value['packageName'] as String,
        label: value['label'] as String?,
        version: value['version'] as String?,
        versionCode: value['versionCode'] as int?,
        certificates: List<String>.from(
          value['certificateSha256'] as List? ?? [],
        ),
      );

  final String packageName;
  final String? label, version;
  final int? versionCode;
  final List<String> certificates;

  Map<String, Object?> toJson() => {
    'packageName': packageName,
    'label': label,
    'version': version,
    'versionCode': versionCode,
    'certificateSha256': certificates,
  };
}

class AndroidPackageInfo {
  AndroidPackageInfo.fromMap(Map<Object?, Object?> values)
    : packageName = values['packageName'] as String,
      version = values['version'] as String?,
      installedVersion = values['installedVersion'] as String?,
      versionCode = values['versionCode'] as int?,
      installedVersionCode = values['installedVersionCode'] as int?,
      fileSha256 = values['fileSha256'] as String?,
      minimumSdk = values['minimumSdk'] as int?,
      nativeAbis = List<String>.from(values['nativeAbis'] as List? ?? []),
      certificateSha256 = List<String>.from(
        values['certificateSha256'] as List? ?? [],
      ),
      installedCertificateSha256 = List<String>.from(
        values['installedCertificateSha256'] as List? ?? [],
      );

  final String packageName;
  final String? version, installedVersion, fileSha256;
  final int? minimumSdk, versionCode, installedVersionCode;
  final List<String> nativeAbis, certificateSha256, installedCertificateSha256;

  bool get isDowngrade =>
      versionCode != null &&
      installedVersionCode != null &&
      versionCode! < installedVersionCode!;

  String get downgradeMessage {
    final current = installedVersion?.trim().isNotEmpty == true
        ? installedVersion!.trim()
        : '版本码 $installedVersionCode';
    final target = version?.trim().isNotEmpty == true
        ? version!.trim()
        : '版本码 $versionCode';
    final currentLabel = current == target
        ? '$current（版本码 $installedVersionCode）'
        : current;
    final targetLabel = current == target
        ? '$target（版本码 $versionCode）'
        : target;
    return '当前已安装 $currentLabel，无法覆盖安装 $targetLabel。'
        '请选择相同或更高版本的安装包，APK 已保留。';
  }
}

class AndroidSigningKey {
  const AndroidSigningKey({
    required this.id,
    required this.label,
    required this.certificateSha256,
    this.exportable = false,
    this.available = true,
    this.lastExportedAt,
  });

  factory AndroidSigningKey.fromMap(Map<Object?, Object?> values) =>
      AndroidSigningKey(
        id: values['id'] as String,
        label: values['label'] as String,
        certificateSha256: values['certificateSha256'] as String,
        exportable: values['exportable'] as bool? ?? false,
        available: values['available'] as bool? ?? true,
        lastExportedAt: values['lastExportedAt'] is int
            ? DateTime.fromMillisecondsSinceEpoch(
                values['lastExportedAt'] as int,
              )
            : null,
      );

  final String id, label, certificateSha256;
  final bool exportable, available;
  final DateTime? lastExportedAt;
  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'certificateSha256': certificateSha256,
    'exportable': exportable,
    if (!available) 'available': false,
    if (lastExportedAt != null)
      'lastExportedAt': lastExportedAt!.millisecondsSinceEpoch,
  };
}

class AndroidResignResult {
  AndroidResignResult.fromMap(Map<Object?, Object?> values)
    : sha256 = values['sha256'] as String,
      certificateSha256 = values['certificateSha256'] as String,
      packageName = values['packageName'] as String?,
      sourcePackageName = values['sourcePackageName'] as String?;

  final String sha256, certificateSha256;
  final String? packageName, sourcePackageName;
}
