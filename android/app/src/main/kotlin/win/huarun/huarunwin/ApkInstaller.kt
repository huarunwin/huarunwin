package win.huarun.huarunwin

import android.app.Activity
import android.content.ClipData
import android.content.ComponentName
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import com.android.apksig.ApkVerifier
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.zip.ZipFile

class ApkInstaller(
    private val activity: Activity,
    private val progress: (String, String) -> Unit = { _, _ -> },
) : MethodChannel.MethodCallHandler {
    private data class Installation(
        val file: File,
        val packageName: String,
        val sha256: String,
        val result: MethodChannel.Result,
        val useSystem: Boolean,
        val selfUpdateVersion: String? = null,
    )
    private class ApkFailure(val code: String, message: String, val details: Map<String, Any?>? = null) : Exception(message)
    private val worker = Executors.newSingleThreadExecutor()
    private val resigner = ApkResigner(activity)
    private val keyDocuments = ApkSigningKeyDocuments(activity, worker)
    private var disposed = false
    private var pendingResult: MethodChannel.Result? = null
    private var uninstallResult: MethodChannel.Result? = null
    private var installation: Installation? = null
    private val sessions = ApkInstallSessions(activity,
        { stage -> installation?.let { progress(it.file.path, stage) } },
        { error ->
            if (error != null) finishError("installation", error)
            else installation?.let { pending ->
                installation = null
                pendingResult = null
                pending.result.success(pending.packageName)
            }
        }, failed = { error -> finishError(error.code, error.message, error.details) })

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            if (keyDocuments.handle(call, result)) return
            when (call.method) {
                "apkSigningKeys" -> background(result) { resigner.keys() }
                "createApkSigningKey" -> background(result) { resigner.createKey() }
                "resolveApkSigningKey" -> background(result) {
                    resigner.resolveKey(call.argument<String>("keyId"), call.argument<String>("expectedCertificateSha256"))
                }
                "resignApk" -> background(result) {
                    val source = managedApk(call.argument<String>("path"))
                    archiveInfo(source)
                    resigner.resign(source, ApkResigner.outputFile(source),
                        requireNotNull(call.argument<String>("keyId")),
                        requireNotNull(call.argument<String>("expectedSourceSha256")),
                        requireNotNull(call.argument<String>("expectedCertificateSha256")),
                        call.argument<String>("packageName"))
                }
                "architecture" -> result.success(Build.SUPPORTED_ABIS.firstOrNull()?.let {
                    when (it) {
                        "arm64-v8a" -> "arm64"
                        "armeabi-v7a", "armeabi" -> "armv7"
                        "x86_64" -> "x64"
                        "x86" -> "x86"
                        else -> null
                    }
                })
                "inspectApk" -> background(result) {
                    val file = managedApk(call.argument<String>("path"))
                    val info = archiveInfo(file)
                    val abis = nativeAbis(file)
                    val installed = installedInfo(info.packageName)
                    @Suppress("DEPRECATION")
                    val certificates = if (Build.VERSION.SDK_INT >= 28) {
                        info.signingInfo?.apkContentsSigners
                    } else { info.signatures }
                    mapOf(
                        "packageName" to info.packageName,
                        "version" to info.versionName,
                        "installedVersion" to installed?.versionName,
                        "versionCode" to versionCode(info),
                        "installedVersionCode" to installed?.let(::versionCode),
                        "minimumSdk" to info.applicationInfo?.minSdkVersion,
                        "nativeAbis" to abis.toList(),
                        "fileSha256" to sha256(file),
                        "certificateSha256" to certificates.orEmpty().map { digest(it.toByteArray()) },
                    )
                }
                "apkIdentity" -> background(result) {
                    val file = managedApk(call.argument<String>("path"))
                    @Suppress("DEPRECATION")
                    val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
                    @Suppress("DEPRECATION")
                    val info = activity.packageManager.getPackageArchiveInfo(file.path, flags)
                        ?: throw ApkFailure("package", "无法读取 APK 的应用信息。")
                    val application = info.applicationInfo?.apply {
                        sourceDir = file.path
                        publicSourceDir = file.path
                    }
                    @Suppress("DEPRECATION")
                    val certificates = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures
                    mapOf(
                        "packageName" to info.packageName,
                        "label" to application?.let { activity.packageManager.getApplicationLabel(it).toString() },
                        "version" to info.versionName,
                        "versionCode" to versionCode(info),
                        "certificateSha256" to certificates.orEmpty().map { digest(it.toByteArray()) },
                    )
                }
                "androidAppStatus" -> background(result) {
                    val path = call.argument<String>("path")
                    @Suppress("DEPRECATION")
                    val archive = path?.let {
                        activity.packageManager.getPackageArchiveInfo(managedApk(it).path, 0)
                            ?: throw ApkFailure("package", "无法读取 APK 的应用信息。")
                    }
                    val name = archive?.packageName ?: requireNotNull(call.argument<String>("packageName"))
                    require(name.isNotBlank()) { "应用包名无效。" }
                    val installed = installedInfo(name, if (Build.VERSION.SDK_INT >= 28)
                        PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES)
                    mapOf(
                        "packageName" to name,
                        "version" to archive?.versionName,
                        "versionCode" to archive?.let(::versionCode),
                        "installedVersion" to installed?.versionName,
                        "installedVersionCode" to installed?.let(::versionCode),
                        "installedCertificateSha256" to installed?.let(::certificateDigests).orEmpty(),
                    )
                }
                "installedApplications" -> background(result) { installedApplications() }
                "installApk", "installSelfUpdate" -> install(call, result)
                "openPackage" -> worker.execute {
                    try {
                        val file = managedApk(call.argument<String>("path"))
                        val info = archiveInfo(file)
                        val expected = call.argument<String>("expectedSha256")
                        if (expected != null && sha256(file) != expected) throw ApkFailure("changed", "APK 在确认后已变化，请重新检查。")
                        checkNotDowngrade(info)
                        val choices = otherInstallers(viewIntent(file))
                        check(choices.isNotEmpty()) { "没有找到其他可用的安装器。" }
                        val intent = Intent.createChooser(choices.first(), "选择安装器").apply {
                            putExtra(Intent.EXTRA_INITIAL_INTENTS, choices.drop(1).toTypedArray())
                        }
                        activity.runOnUiThread {
                            if (!disposed) {
                                try { activity.startActivity(intent); result.success(true) }
                                catch (error: Exception) { report(result, error) }
                            }
                        }
                    } catch (error: Exception) { activity.runOnUiThread { if (!disposed) report(result, error) } }
                }
                "isPackageInstalled" -> {
                    val name = requireNotNull(call.argument<String>("packageName"))
                    result.success(isInstalled(name))
                }
                "openAndroidApp" -> {
                    val name = requireNotNull(call.argument<String>("packageName"))
                    val intent = activity.packageManager.getLaunchIntentForPackage(name)
                        ?: throw IllegalArgumentException("应用未安装或不支持直接打开。")
                    activity.startActivity(intent)
                    result.success(null)
                }
                "uninstallAndroidApp" -> uninstall(call, result)
                "reveal" -> {
                    val file = managedApk(call.argument<String>("path"))
                    val uri = contentUri(file)
                    val intent = Intent(Intent.ACTION_SEND).apply {
                        type = APK_TYPE
                        putExtra(Intent.EXTRA_STREAM, uri)
                        clipData = ClipData.newRawUri("APK", uri)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    activity.startActivity(Intent.createChooser(intent, "分享安装包"))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) { report(result, error) }
    }

    private fun background(result: MethodChannel.Result, operation: () -> Any?) {
        worker.execute {
            try {
                val value = operation()
                activity.runOnUiThread { if (!disposed) result.success(value) }
            } catch (error: Exception) {
                activity.runOnUiThread { if (!disposed) report(result, error) }
            }
        }
    }

    private fun report(result: MethodChannel.Result, error: Exception) {
        android.util.Log.e("HuarunInstaller", "Native installer request failed", error)
        if (pendingResult === result) { installation = null; pendingResult = null }
        if (uninstallResult === result) uninstallResult = null
        result.error((error as? ApkFailure)?.code ?: "installation", error.message ?: "无法处理安装包，请重试。", (error as? ApkFailure)?.details)
    }

    @Suppress("DEPRECATION")
    private fun installedInfo(packageName: String, flags: Int = 0): PackageInfo? = try {
        activity.packageManager.getPackageInfo(packageName, flags)
    } catch (_: PackageManager.NameNotFoundException) { null }

    @Suppress("DEPRECATION")
    private fun certificateDigests(info: PackageInfo): List<String> =
        (if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures)
            .orEmpty().map { digest(it.toByteArray()) }

    @Suppress("DEPRECATION")
    private fun installedApplications(): List<Map<String, Any?>> {
        val manager = activity.packageManager
        val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        // The manifest already declares launcher visibility. Do not require
        // QUERY_ALL_PACKAGES or infer package names from catalog names.
        return manager.queryIntentActivities(launcher, 0)
            .groupBy { it.activityInfo.packageName }
            .mapNotNull { (packageName, activities) ->
                val info = installedInfo(packageName) ?: return@mapNotNull null
                val application = info.applicationInfo ?: return@mapNotNull null
                if (!application.enabled) return@mapNotNull null
                val names = buildSet {
                    add(manager.getApplicationLabel(application).toString().trim())
                    activities.forEach { add(it.loadLabel(manager).toString().trim()) }
                }.filter { it.isNotEmpty() }
                if (names.isEmpty()) return@mapNotNull null
                mapOf(
                    "packageName" to packageName,
                    "version" to info.versionName,
                    "names" to names,
                )
            }
    }

    @Suppress("DEPRECATION")
    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

    private fun checkNotDowngrade(info: PackageInfo) {
        val installed = installedInfo(info.packageName) ?: return
        val targetCode = versionCode(info)
        val installedCode = versionCode(installed)
        if (targetCode < installedCode) {
            val current = installed.versionName?.takeIf { it.isNotBlank() } ?: "版本码 $installedCode"
            val target = info.versionName?.takeIf { it.isNotBlank() } ?: "版本码 $targetCode"
            val currentLabel = if (current == target) "$current（版本码 $installedCode）" else current
            val targetLabel = if (current == target) "$target（版本码 $targetCode）" else target
            throw ApkFailure("version_downgrade",
                "当前已安装 $currentLabel，无法覆盖安装 $targetLabel。请选择相同或更高版本的安装包，APK 已保留。",
                mapOf("versionCode" to targetCode, "installedVersionCode" to installedCode))
        }
    }

    private fun managedApk(path: String?): File {
        require(!path.isNullOrBlank()) { "安装包路径无效。" }
        val file = File(path).canonicalFile
        val roots = listOfNotNull(
            File(activity.filesDir, "downloads"),
            activity.getExternalFilesDir(null)?.let { File(it, "downloads") },
        ).map { it.canonicalFile }
        require(roots.any { file.path.startsWith(it.path + File.separator) } &&
            file.isFile && file.extension.equals("apk", ignoreCase = true)) {
            "请选择华润赢下载管理中的 APK 安装包。"
        }
        return file
    }

    @Suppress("DEPRECATION")
    private fun archiveInfo(file: File): PackageInfo {
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        val info = activity.packageManager.getPackageArchiveInfo(file.path, flags)
            ?: throw ApkFailure("package", "无法识别这个 APK，请重新下载。")
        if ((info.applicationInfo?.minSdkVersion ?: 0) > Build.VERSION.SDK_INT) {
            throw ApkFailure("compatibility", "这个 APK 需要更高版本的 Android，请选择适合当前系统的版本。")
        }
        val abis = nativeAbis(file)
        if (abis.isNotEmpty() && abis.none { it in Build.SUPPORTED_ABIS }) {
            throw ApkFailure("architecture", "这个 APK 的原生架构不适合当前设备，请选择其他安装包。")
        }
        return info
    }

    private fun nativeAbis(file: File): Set<String> = ZipFile(file).use { zip ->
        zip.entries().asSequence().mapNotNull { entry ->
            val parts = entry.name.split('/')
            if (!entry.isDirectory && parts.size >= 3 && parts[0] == "lib" && parts.last().endsWith(".so")) parts[1] else null
        }.toSortedSet()
    }

    private fun digest(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    private fun sha256(file: File): String {
        val hash = MessageDigest.getInstance("SHA-256")
        file.inputStream().buffered().use { input ->
            val buffer = ByteArray(65536)
            while (true) {
                if (Thread.currentThread().isInterrupted) throw InterruptedException()
                val read = input.read(buffer)
                if (read < 0) break
                hash.update(buffer, 0, read)
            }
        }
        return hash.digest().joinToString("") { "%02x".format(it) }
    }

    private fun contentUri(file: File): Uri = FileProvider.getUriForFile(activity, "${activity.packageName}.apkfiles", file)
    private fun viewIntent(file: File): Intent {
        val uri = contentUri(file)
        return Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, APK_TYPE)
            clipData = ClipData.newRawUri("APK", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
    }

    @Suppress("DEPRECATION")
    private fun otherInstallers(intent: Intent): List<Intent> = activity.packageManager
        .queryIntentActivities(intent, PackageManager.MATCH_DEFAULT_ONLY)
        .filter { it.activityInfo.packageName != activity.packageName && it.activityInfo.exported }
        .map { Intent(intent).setComponent(ComponentName(it.activityInfo.packageName, it.activityInfo.name)) }

    @Suppress("DEPRECATION")
    private fun systemInstaller(file: File): Intent {
        val intent = viewIntent(file).apply {
            action = Intent.ACTION_INSTALL_PACKAGE
            putExtra(Intent.EXTRA_RETURN_RESULT, true)
        }
        val candidates = activity.packageManager.queryIntentActivities(intent, PackageManager.MATCH_DEFAULT_ONLY)
            .filter { it.activityInfo.packageName != activity.packageName && it.activityInfo.exported &&
                it.activityInfo.applicationInfo.flags and ApplicationInfo.FLAG_SYSTEM != 0 }
        val preferred = activity.packageManager.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY)?.activityInfo
        val target = candidates.firstOrNull { it.activityInfo.packageName == preferred?.packageName && it.activityInfo.name == preferred?.name }
            ?: candidates.singleOrNull() ?: throw ApkFailure("installer", "无法确定系统安装器，请选择华润赢安装或其他安装器。")
        return intent.setComponent(ComponentName(target.activityInfo.packageName, target.activityInfo.name))
    }

    @Suppress("DEPRECATION")
    private fun checkSelfUpdate(file: File, info: PackageInfo, expectedVersion: String) {
        if (info.packageName != activity.packageName || info.versionName != expectedVersion) {
            throw ApkFailure("update_identity", "更新包的应用标识或版本与当前更新不匹配。")
        }
        val verified = ApkVerifier.Builder(file).build().verify()
        if (!verified.isVerified) throw ApkFailure("update_signature", "更新包签名验证失败。")
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        val current = activity.packageManager.getPackageInfo(activity.packageName, flags)
        val signatures = if (Build.VERSION.SDK_INT >= 28) current.signingInfo?.apkContentsSigners else current.signatures
        val installed = signatures.orEmpty().map { digest(it.toByteArray()) }.toSet()
        val incoming = verified.signerCertificates.map { digest(it.encoded) }.toSet()
        if (installed.isEmpty() || installed != incoming) {
            throw ApkFailure("update_signature", "更新包与当前客户端签名不同，不能覆盖更新。")
        }
    }

    private fun install(call: MethodCall, result: MethodChannel.Result) {
        if (pendingResult != null || uninstallResult != null) {
            result.error("installation_busy", "请先完成当前的系统安装或卸载操作。", null)
            return
        }
        pendingResult = result
        worker.execute {
            try {
                val file = managedApk(call.argument<String>("path"))
                val info = archiveInfo(file)
                val hash = sha256(file)
                val expected = call.argument<String>("expectedSha256")
                if (expected != null && hash != expected) throw ApkFailure("changed", "APK 在确认后已变化，请重新检查后安装。")
                checkNotDowngrade(info)
                val selfVersion = if (call.method == "installSelfUpdate")
                    requireNotNull(call.argument<String>("version")) else null
                if (selfVersion != null) checkSelfUpdate(file, info, selfVersion)
                val method = call.argument<String>("method") ?: "huarun"
                require(method == "huarun" || method == "system") { "安装方式无效。" }
                val pending = Installation(file, info.packageName, hash, result, method == "system", selfVersion)
                activity.runOnUiThread {
                    if (disposed || pendingResult !== result) return@runOnUiThread
                    installation = pending
                    try {
                        if (!canInstall()) {
                            activity.startActivityForResult(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:${activity.packageName}")), SOURCE_PERMISSION)
                        } else { launchInstaller() }
                    } catch (error: Exception) { report(result, error) }
                }
            } catch (error: Exception) { activity.runOnUiThread { if (!disposed) report(result, error) } }
        }
    }

    private fun canInstall(): Boolean = Build.VERSION.SDK_INT < Build.VERSION_CODES.O || activity.packageManager.canRequestPackageInstalls()

    private fun launchInstaller() {
        val pending = installation ?: return
        worker.execute {
            try {
                val file = managedApk(pending.file.path)
                val info = archiveInfo(file)
                if (info.packageName != pending.packageName || sha256(file) != pending.sha256) {
                    throw ApkFailure("changed", "APK 在授权期间已变化，请重新检查后安装。")
                }
                checkNotDowngrade(info)
                pending.selfUpdateVersion?.let { checkSelfUpdate(file, info, it) }
                if (!pending.useSystem) {
                    sessions.install(file, pending.packageName, pending.sha256)
                    return@execute
                }
                activity.runOnUiThread {
                    if (disposed || installation !== pending) return@runOnUiThread
                    try {
                        activity.startActivityForResult(systemInstaller(file), INSTALL_PACKAGE)
                    } catch (error: Exception) { report(pending.result, error) }
                }
            } catch (error: Exception) { activity.runOnUiThread { if (!disposed) report(pending.result, error) } }
        }
    }

    @Suppress("DEPRECATION")
    private fun uninstall(call: MethodCall, result: MethodChannel.Result) {
        if (pendingResult != null || uninstallResult != null) {
            throw ApkFailure("uninstall_busy", "请先完成当前的系统安装或卸载操作。")
        }
        val name = requireNotNull(call.argument<String>("packageName"))
        require(name.isNotBlank()) { "应用包名无效。" }
        if (installedInfo(name) == null) throw ApkFailure("not_installed", "应用已不在本机，请刷新后查看。")
        val intent = Intent(Intent.ACTION_UNINSTALL_PACKAGE, Uri.fromParts("package", name, null))
            .putExtra(Intent.EXTRA_RETURN_RESULT, true)
        val manager = activity.packageManager
        val candidates = manager.queryIntentActivities(intent, PackageManager.MATCH_DEFAULT_ONLY)
            .filter { it.activityInfo.packageName != activity.packageName && it.activityInfo.exported &&
                it.activityInfo.applicationInfo.flags and ApplicationInfo.FLAG_SYSTEM != 0 }
        val preferred = manager.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY)?.activityInfo
        val target = candidates.firstOrNull { it.activityInfo.packageName == preferred?.packageName && it.activityInfo.name == preferred?.name }
            ?: candidates.singleOrNull() ?: throw ApkFailure("uninstaller", "无法打开系统卸载界面，请在系统设置中卸载应用。")
        intent.component = ComponentName(target.activityInfo.packageName, target.activityInfo.name)
        uninstallResult = result
        activity.startActivityForResult(intent, UNINSTALL_PACKAGE)
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (keyDocuments.onActivityResult(requestCode, resultCode, data)) return
        if (requestCode == UNINSTALL_PACKAGE) {
            val result = uninstallResult ?: return
            uninstallResult = null
            // Returning from system UI (including cancellation) is not proof
            // of uninstallation. Flutter re-queries the selected package.
            if (resultCode == Activity.RESULT_FIRST_USER) {
                result.error("uninstall_failed", "系统未能卸载应用，请在系统设置中查看。", null)
            } else result.success(null)
            return
        }
        if (requestCode != SOURCE_PERMISSION && requestCode != INSTALL_PACKAGE) return
        val pending = installation ?: return
        if (requestCode == SOURCE_PERMISSION) {
            if (!canInstall()) finishError("install_permission_denied", "尚未允许华润赢安装应用，安装包已保留，可稍后重试。")
            else launchInstaller()
        } else {
            installation = null
            pendingResult = null
            if (resultCode == Activity.RESULT_OK) pending.result.success(pending.packageName)
            else {
                val fallback = if (resultCode == Activity.RESULT_CANCELED)
                    PackageInstaller.STATUS_FAILURE_ABORTED
                else PackageInstaller.STATUS_FAILURE
                val error = ApkInstallFailure.fromIntent(data, fallback)
                pending.result.error(error.code, error.message, error.details)
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun isInstalled(name: String): Boolean = try {
        activity.packageManager.getPackageInfo(name, 0)
        true
    } catch (_: PackageManager.NameNotFoundException) { false }

    private fun finishError(code: String, message: String, details: Any? = null) {
        val result = pendingResult ?: return
        installation = null
        pendingResult = null
        result.error(code, message, details)
    }
    fun dispose() {
        disposed = true
        keyDocuments.dispose()
        sessions.dispose()
        finishError("installation_interrupted", "安装已中断，安装包已保留，请重试。")
        uninstallResult?.error("uninstall_interrupted", "卸载结果尚未确认，请刷新应用状态。", null)
        uninstallResult = null
        worker.shutdownNow()
    }
    companion object {
        private const val APK_TYPE = "application/vnd.android.package-archive"
        private const val SOURCE_PERMISSION = 18513
        private const val INSTALL_PACKAGE = 18514
        private const val UNINSTALL_PACKAGE = 18515
    }
}
