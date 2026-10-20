package win.huarun.huarunwin

import android.app.Activity
import android.content.Intent
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService

/** Backup files are transferred only through user-selected system document URIs. */
class ApkSigningKeyDocuments(
    private val activity: Activity,
    private val worker: ExecutorService,
    private val keys: ApkSigningKeys = ApkSigningKeys(activity),
) {
    private class Request(
        val result: MethodChannel.Result,
        val password: CharArray,
        val keyId: String? = null,
        val certificate: String? = null,
        var encrypted: ByteArray? = null,
    ) {
        fun clear() { password.fill('\u0000'); encrypted?.fill(0); encrypted = null }
    }
    private var pending: Request? = null

    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        if (call.method != "exportApkSigningKey" && call.method != "importApkSigningKey") return false
        if (pending != null) {
            result.error("signing_key_busy", "请先完成当前的密钥导入或导出。", null)
            return true
        }
        val password = call.argument<String>("password")?.toCharArray() ?: charArrayOf()
        val exporting = call.method == "exportApkSigningKey"
        val request = Request(result, password,
            if (exporting) requireNotNull(call.argument<String>("keyId")) else null,
            if (exporting) requireNotNull(call.argument<String>("expectedCertificateSha256")) else null)
        pending = request
        if (exporting) {
            worker.execute {
                try {
                    request.encrypted = keys.export(request.keyId!!, request.certificate!!, password)
                    password.fill('\u0000')
                    activity.runOnUiThread {
                        if (pending !== request) { request.clear(); return@runOnUiThread }
                        try {
                            activity.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "application/x-pkcs12"
                                putExtra(Intent.EXTRA_TITLE, "huarunwin-signing-${request.certificate.take(12)}.p12")
                            }, EXPORT_KEY)
                        } catch (error: Exception) { fail(request, error) }
                    }
                } catch (error: Exception) { activity.runOnUiThread { fail(request, error) } }
            }
        } else {
            try {
                activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                }, IMPORT_KEY)
            } catch (error: Exception) { fail(request, error) }
        }
        return true
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != IMPORT_KEY && requestCode != EXPORT_KEY) return false
        val request = pending ?: return true
        if (resultCode != Activity.RESULT_OK) {
            pending = null; request.clear(); request.result.success(null)
            return true
        }
        val uri = data?.data
        if (uri == null || uri.scheme != "content") {
            fail(request, IllegalArgumentException("未取得文件访问权限，请重新选择。"))
            return true
        }
        worker.execute {
            try {
                val key = if (requestCode == EXPORT_KEY) {
                    activity.contentResolver.openOutputStream(uri, "wt")?.use { output ->
                        output.write(requireNotNull(request.encrypted))
                        output.flush()
                    } ?: error("无法写入备份，请重新选择保存位置。")
                    keys.exported(request.keyId!!, request.certificate!!)
                } else {
                    activity.contentResolver.openInputStream(uri)?.use { keys.import(it, request.password) }
                        ?: error("无法读取备份，请重新选择文件。")
                }
                activity.runOnUiThread {
                    if (pending === request) { pending = null; request.result.success(key) }
                }
            } catch (error: Exception) { activity.runOnUiThread { fail(request, error) } }
            finally { request.clear() }
        }
        return true
    }

    private fun fail(request: Request, error: Exception) {
        request.clear()
        if (pending !== request) return
        pending = null
        request.result.error("signing_key", error.message ?: "密钥操作失败，请重试。", null)
    }

    fun dispose() {
        pending?.let { fail(it, IllegalStateException("密钥操作已中断，请重新导入或导出。")) }
    }

    companion object {
        private const val IMPORT_KEY = 18515
        private const val EXPORT_KEY = 18516
    }
}
