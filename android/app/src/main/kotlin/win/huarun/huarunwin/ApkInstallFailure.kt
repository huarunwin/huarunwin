package win.huarun.huarunwin

import android.content.Intent
import android.content.pm.PackageInstaller

data class ApkInstallFailure(
    val code: String,
    val message: String,
    val details: Map<String, Any?>,
) {
    companion object {
        // These extras are returned by Android installers but are not SDK constants.
        private const val LEGACY_STATUS = "android.content.pm.extra.LEGACY_STATUS"
        private const val INSTALL_RESULT = "android.intent.extra.INSTALL_RESULT"
        private val errorName = Regex("\\bINSTALL_(?:FAILED|PARSE_FAILED)_[A-Z0-9_]+\\b")
        private val legacyErrors = mapOf(
            -2 to "INSTALL_FAILED_INVALID_APK",
            -4 to "INSTALL_FAILED_INSUFFICIENT_STORAGE",
            -7 to "INSTALL_FAILED_UPDATE_INCOMPATIBLE",
            -12 to "INSTALL_FAILED_OLDER_SDK",
            -14 to "INSTALL_FAILED_NEWER_SDK",
            -25 to "INSTALL_FAILED_VERSION_DOWNGRADE",
            -28 to "INSTALL_FAILED_MISSING_SPLIT",
            -111 to "INSTALL_FAILED_USER_RESTRICTED",
            -113 to "INSTALL_FAILED_NO_MATCHING_ABIS",
            -115 to "INSTALL_FAILED_ABORTED",
        )

        fun fromIntent(intent: Intent?, fallbackStatus: Int = PackageInstaller.STATUS_FAILURE): ApkInstallFailure {
            val legacyKey = listOf(LEGACY_STATUS, INSTALL_RESULT).firstOrNull { intent?.hasExtra(it) == true }
            val legacy = legacyKey?.let { intent?.getIntExtra(it, 0) }
            val reportedStatus = intent?.takeIf { it.hasExtra(PackageInstaller.EXTRA_STATUS) }
                ?.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
            // An unrecognized native error is still a failure, even if the
            // installer's Activity result uses RESULT_CANCELED for all errors.
            val status = reportedStatus ?: if (legacy != null && legacy != -115)
                PackageInstaller.STATUS_FAILURE else fallbackStatus
            val systemMessage = intent?.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
                ?.trim()?.take(2048)?.takeIf { it.isNotEmpty() }
            val name = systemMessage?.let { errorName.find(it)?.value } ?: legacy?.let(legacyErrors::get)
            val (code, reason) = when {
                name == "INSTALL_FAILED_VERSION_DOWNGRADE" -> "version_downgrade" to
                    "无法覆盖安装旧版本，请选择与本机相同或更高版本的安装包。"
                name == "INSTALL_FAILED_UPDATE_INCOMPATIBLE" -> "signature_conflict" to
                    "安装包签名与已安装应用不一致，无法覆盖安装，请选择同一签名的版本。"
                name == "INSTALL_FAILED_NO_MATCHING_ABIS" -> "architecture" to
                    "安装包架构与设备不兼容，请选择适合当前设备的安装包。"
                name == "INSTALL_FAILED_INSUFFICIENT_STORAGE" -> "storage" to
                    "设备空间不足，请清理空间后再安装。"
                name == "INSTALL_FAILED_OLDER_SDK" || name == "INSTALL_FAILED_NEWER_SDK" -> "compatibility" to
                    "安装包不支持当前 Android 版本，请选择兼容的版本。"
                name == "INSTALL_FAILED_MISSING_SPLIT" -> "package" to
                    "安装包缺少必需的拆分 APK，请选择完整安装包。"
                name == "INSTALL_FAILED_INVALID_APK" || name?.startsWith("INSTALL_PARSE_FAILED_") == true -> "package" to
                    "系统无法验证或解析安装包，请重新获取完整且签名有效的 APK。"
                name == "INSTALL_FAILED_USER_RESTRICTED" -> "installation_blocked" to
                    "系统限制了本次安装，请检查安装来源权限或设备安装限制。"
                name == "INSTALL_FAILED_ABORTED" -> "installation_cancelled" to "安装已取消。"
                else -> when (status) {
                    PackageInstaller.STATUS_FAILURE_ABORTED -> "installation_cancelled" to "安装已取消。"
                    PackageInstaller.STATUS_FAILURE_CONFLICT -> "package_conflict" to
                        "安装包与已安装应用存在冲突，请展开失败详情查看系统原因。"
                    PackageInstaller.STATUS_FAILURE_STORAGE -> "storage" to "设备空间不足，请清理空间后再安装。"
                    PackageInstaller.STATUS_FAILURE_INCOMPATIBLE -> "compatibility" to
                        "安装包与设备或系统不兼容，请选择适合当前设备的安装包。"
                    PackageInstaller.STATUS_FAILURE_INVALID -> "package" to "系统无法验证或解析这个 APK。"
                    PackageInstaller.STATUS_FAILURE_BLOCKED -> "installation_blocked" to
                        "系统阻止了本次安装，请检查安装来源权限或设备安装限制。"
                    else -> "installation" to if (systemMessage != null || legacy != null)
                        "系统未完成安装，请展开失败详情查看系统返回的原因。"
                    else "系统未完成安装，且未返回具体失败原因。"
                }
            }
            return ApkInstallFailure(code, "$reason APK 已保留。", buildMap {
                if (reportedStatus != null) put("status", reportedStatus)
                if (legacy != null) put("legacyStatus", legacy)
                if (name != null) put("systemError", name)
                if (systemMessage != null) put("systemMessage", systemMessage)
            })
        }
    }
}
