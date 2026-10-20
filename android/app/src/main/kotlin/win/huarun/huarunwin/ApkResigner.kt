package win.huarun.huarunwin

import android.content.Context
import android.os.Build
import com.android.apksig.ApkSigner
import com.android.apksig.ApkVerifier
import java.io.File
import java.security.MessageDigest

/** Builds and verifies a separate copy; installation always uses system confirmation. */
class ApkResigner(private val context: Context, private val signingKeys: ApkSigningKeys = ApkSigningKeys(context)) {
    fun keys() = signingKeys.keys()
    fun createKey() = signingKeys.create()
    fun resolveKey(keyId: String?, expectedCertificate: String?) = signingKeys.resolve(keyId, expectedCertificate)

    // Input/output paths have already been restricted to this task's managed directory.
    fun resign(input: File, output: File, keyId: String, expectedSource: String, expectedCertificate: String,
               packageName: String? = null): Map<String, String> {
        val temporary = File(output.parentFile, output.name + ".part")
        val rewritten = File(output.parentFile, output.name + ".unsigned")
        val folder = requireNotNull(output.absoluteFile.parentFile).canonicalFile
        require(output.canonicalFile == File(folder, output.name) &&
            temporary.canonicalFile == File(folder, temporary.name) &&
            rewritten.canonicalFile == File(folder, rewritten.name) && input.canonicalFile != output.canonicalFile) {
            "重签文件位置无效。"
        }
        packageName?.let(ApkPackageEditor::requireValidPackageName)
        val sourceInfo = packageInfo(input)
        require(packageName == null || packageName != sourceInfo.packageName) { "新包名必须与原始包名不同。" }
        val identity = signingKeys.identity(keyId, expectedCertificate)
        val certificate = identity.certificate
        val key = identity.privateKey
        require(sha256(input) == expectedSource) { "原始 APK 已变化，请重新下载后重签。" }
        require(verify(input).isVerified) { "原始 APK 签名验证失败，未进行重签。" }
        try {
            check(!temporary.exists() || temporary.delete()) { "无法清理上次重签的临时文件。" }
            check(!rewritten.exists() || rewritten.delete()) { "无法清理上次修改包名的临时文件。" }
            require(!output.exists()) { "重签文件已存在，请删除下载记录后重试。" }
            val signingInput = if (packageName != null) {
                val original = ApkPackageEditor().rewrite(input, rewritten, packageName)
                require(original == sourceInfo.packageName) { "原始包名已变化，请重新检查。" }
                rewritten
            } else { input }
            val signer = ApkSigner.SignerConfig.Builder("huarunwin", key, listOf(certificate)).build()
            ApkSigner.Builder(listOf(signer)).setInputApk(signingInput).setOutputApk(temporary)
                .setOtherSignersSignaturesPreserved(false)
                .setV1SigningEnabled(true).setV2SigningEnabled(true).setV3SigningEnabled(true)
                .setV4SigningEnabled(false).build().sign()
            val verified = verify(temporary)
            require(verified.isVerified && verified.signerCertificates.size == 1 &&
                digest(verified.signerCertificates.single().encoded) == expectedCertificate) {
                "重签后的 APK 验证失败，原始 APK 已保留。"
            }
            val outputInfo = packageInfo(temporary)
            require(outputInfo.packageName == (packageName ?: sourceInfo.packageName) &&
                outputInfo.versionName == sourceInfo.versionName &&
                versionCode(outputInfo) == versionCode(sourceInfo)) {
                "重签副本的包名或版本验证失败，原始 APK 已保留。"
            }
            require(sha256(input) == expectedSource) { "原始 APK 在重签期间已变化，请重新下载。" }
            check(!Thread.currentThread().isInterrupted) { "重签已中断。" }
            val hash = sha256(temporary)
            signingKeys.prefer(keyId, onlyIfUnset = true)
            check(temporary.renameTo(output)) { "无法保存重签 APK，请检查可用空间。" }
            return mapOf("sha256" to hash, "certificateSha256" to expectedCertificate,
                "packageName" to outputInfo.packageName, "sourcePackageName" to sourceInfo.packageName)
        } finally {
            temporary.delete()
            rewritten.delete()
        }
    }

    @Suppress("DEPRECATION")
    private fun packageInfo(file: File) = requireNotNull(context.packageManager.getPackageArchiveInfo(file.path, 0)) {
        "无法读取 APK 的包名或版本，原始 APK 已保留。"
    }

    @Suppress("DEPRECATION")
    private fun versionCode(info: android.content.pm.PackageInfo) =
        if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

    private fun verify(file: File) = ApkVerifier.Builder(file)
        .setMinCheckedPlatformVersion(Build.VERSION.SDK_INT)
        .setMaxCheckedPlatformVersion(Build.VERSION.SDK_INT).build().verify()

    companion object {
        fun outputFile(input: File) = File(input.parentFile, input.nameWithoutExtension + "-huarun-sign.apk")

        private fun digest(bytes: ByteArray) = MessageDigest.getInstance("SHA-256")
            .digest(bytes).joinToString("") { "%02x".format(it) }
        fun sha256(file: File): String {
            val hash = MessageDigest.getInstance("SHA-256")
            file.inputStream().buffered().use { input ->
                val buffer = ByteArray(65536)
                while (true) {
                    check(!Thread.currentThread().isInterrupted) { "重签已中断。" }
                    val count = input.read(buffer)
                    if (count < 0) break
                    hash.update(buffer, 0, count)
                }
            }
            return hash.digest().joinToString("") { "%02x".format(it) }
        }
    }
}
