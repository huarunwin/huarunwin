package win.huarun.huarunwin

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

class IncomingApks(private val activity: Activity, private val changed: () -> Unit) : MethodChannel.MethodCallHandler {
    private val worker = Executors.newSingleThreadExecutor()
    @Volatile private var disposed = false
    private val inFlight = mutableSetOf<String>()
    private val preferences = activity.getSharedPreferences("incoming_apks", 0)

    private fun entries(): List<JSONObject> {
        val array = JSONArray(preferences.getString("pending", "[]"))
        return (0 until array.length()).map { array.getJSONObject(it) }
    }
    private fun save(entries: List<JSONObject>) {
        check(preferences.edit().putString("pending", JSONArray(entries).toString()).commit()) { "无法保存导入记录。" }
    }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            synchronized(lock) {
                when (call.method) {
                    "pendingApks" -> result.success(entries().map { item ->
                        item.keys().asSequence().associateWith { item.get(it) }
                    })
                    "ackApk" -> {
                        val id = call.argument<String>("id")
                        save(entries().filter { it.optString("id") != id })
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        } catch (error: Exception) { result.error("apk_import", error.message, null) }
    }

    fun accept(intent: Intent) {
        if (intent.action != Intent.ACTION_VIEW && intent.action != Intent.ACTION_SEND) return
        val uri = runCatching {
            @Suppress("DEPRECATION")
            if (intent.action == Intent.ACTION_SEND) intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM) else intent.data
        }.getOrNull()
        // Only the launch intent is consumed; configuration changes must not import twice.
        activity.intent = Intent(Intent.ACTION_MAIN)
        val identity = uri?.toString() ?: UUID.randomUUID().toString()
        synchronized(inFlight) { if (inFlight.size >= 8 || !inFlight.add(identity)) return }
        worker.execute {
            val id = "incoming-${UUID.randomUUID()}"
            var folder: File? = null
            try {
                require(uri != null && uri.scheme == "content") { "未取得 APK 的文件访问权限，请从文件管理器重新打开。" }
                require(uri.authority != "${activity.packageName}.apkfiles") { "请在下载管理中直接安装这个 APK。" }
                synchronized(lock) { check(entries().size < 8) { "待处理的 APK 较多，请先完成现有导入。" } }
                var name = activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) cursor.getString(0) else null
                } ?: "导入的安装包.apk"
                name = name.substringAfterLast('/').substringAfterLast('\\').replace(Regex("[\\p{Cntrl}]"), "").take(120)
                if (name.isBlank()) name = "导入的安装包.apk"
                if (!name.endsWith(".apk", ignoreCase = true)) name += ".apk"
                folder = File(activity.filesDir, "downloads/$id")
                check(folder.mkdirs()) { "无法创建 APK 导入目录。" }
                val partial = File(folder, ".incoming.apk")
                var bytes = 0L
                activity.contentResolver.openInputStream(uri)?.use { input ->
                    partial.outputStream().buffered().use { output ->
                        val buffer = ByteArray(65536)
                        while (true) {
                            check(!disposed && !Thread.currentThread().isInterrupted) { "导入已中断，请重新打开 APK。" }
                            val count = input.read(buffer)
                            if (count < 0) break
                            bytes += count
                            check(bytes <= MAX_BYTES) { "APK 超过 4 GB，无法导入。" }
                            output.write(buffer, 0, count)
                        }
                    }
                } ?: error("无法读取 APK，请重新授予文件访问权限。")
                check(bytes > 0 && activity.packageManager.getPackageArchiveInfo(partial.path, 0) != null) { "文件不是有效的单文件 APK。" }
                val file = File(folder, name)
                check(partial.renameTo(file)) { "无法保存导入的 APK。" }
                synchronized(lock) {
                    check(!disposed) { "导入已中断，请重新打开 APK。" }
                    save(entries() + JSONObject().put("id", id).put("path", file.path).put("name", name))
                }
                folder = null
            } catch (error: Exception) {
                synchronized(lock) {
                    if (!disposed) save(entries().filter { !it.has("error") } + JSONObject().put("id", id).put("error", error.message ?: "无法导入 APK。"))
                }
            } finally {
                folder?.deleteRecursively()
                synchronized(inFlight) { inFlight.remove(identity) }
                activity.runOnUiThread { if (!disposed) changed() }
            }
        }
    }
    fun dispose() { disposed = true; worker.shutdownNow() }
    companion object {
        private val lock = Any()
        const val MAX_BYTES = 4L * 1024 * 1024 * 1024
    }
}
