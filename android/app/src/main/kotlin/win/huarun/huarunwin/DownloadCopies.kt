package win.huarun.huarunwin

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.storage.StorageManager
import android.provider.DocumentsContract
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileNotFoundException
import java.io.InputStream
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Downloads stay app-owned; only completed copies cross the SAF boundary. */
class DownloadCopies(private val activity: Activity) : MethodChannel.MethodCallHandler {
    private class Failure(val code: String, message: String) : Exception(message)
    private val resolver = activity.contentResolver
    private val preferences = activity.getSharedPreferences("download-copies", Activity.MODE_PRIVATE)
    private val worker = Executors.newSingleThreadExecutor()
    private val cancellations = ConcurrentHashMap<String, AtomicBoolean>()
    private var picker: MethodChannel.Result? = null
    private var disposed = false

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "chooseDirectory" -> {
                if (picker != null) {
                    result.error("copy_busy", "请先完成当前的文件夹选择。", null)
                    return
                }
                picker = result
                try {
                    activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                            Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                    }, PICK_DIRECTORY)
                } catch (_: Exception) {
                    picker = null
                    result.error("copy_picker", "无法打开系统文件夹选择器，请重试。", null)
                }
            }
            "cancel" -> {
                call.argument<String>("id")?.let { cancellations[it]?.set(true) }
                result.success(null)
            }
            "settings" -> execute(result) {
                val validate = call.argument<Boolean>("validate") != false
                if (validate) cleanupPartial()
                settings(validate)
            }
            "resetDirectory" -> execute(result) {
                val old = preferences.getString("treeUri", null)
                checkSaved(preferences.edit().putBoolean("enabled", false)
                    .remove("treeUri").remove("label").commit())
                cleanupPartial()
                if (old != null && partials().isEmpty()) {
                    try { resolver.releasePersistableUriPermission(Uri.parse(old),
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION) }
                    catch (_: Exception) { /* The folder may already be unavailable. */ }
                }
                settings(false)
            }
            "copy" -> {
                val id = call.argument<String>("id")
                if (id.isNullOrBlank() || cancellations.putIfAbsent(id, AtomicBoolean(false)) != null) {
                    result.error("copy_busy", "此文件正在保存，请稍候。", null)
                    return
                }
                val cancelled = cancellations.getValue(id)
                execute(result) {
                    try {
                        copy(call.argument<String>("path"), call.argument<String>("sha256"),
                            call.argument<String>("treeUri"), cancelled)
                    } finally { cancellations.remove(id) }
                }
            }
            else -> result.notImplemented()
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_DIRECTORY) return false
        val result = picker ?: return true
        picker = null
        if (resultCode != Activity.RESULT_OK) { result.success(null); return true }
        val uri = data?.data
        execute(result) {
            if (uri == null || uri.scheme != "content" || !DocumentsContract.isTreeUri(uri)) {
                throw Failure("copy_permission", "未取得文件夹权限，请重新选择。")
            }
            val flags = (data?.flags ?: 0) and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            val previouslyGranted = resolver.persistedUriPermissions.any { it.uri == uri }
            resolver.takePersistableUriPermission(uri, flags)
            try {
                val label = requireFolder(uri)
                val old = preferences.getString("treeUri", null)
                checkSaved(preferences.edit().putString("treeUri", uri.toString())
                    .putString("label", label).putBoolean("enabled", true).commit())
                // Copy jobs and preference changes share a worker, so an old
                // grant is never released while it is being used by a copy.
                cleanupPartial()
                if (old != null && old != uri.toString() && partials().isEmpty()) {
                    try { resolver.releasePersistableUriPermission(Uri.parse(old),
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION) }
                    catch (_: Exception) { /* A removed provider may already have revoked it. */ }
                }
                settings()
            } catch (error: Exception) {
                if (!previouslyGranted) {
                    try { resolver.releasePersistableUriPermission(uri, flags) } catch (_: Exception) {}
                }
                throw error
            }
        }
        return true
    }

    private fun selectedTree(): Uri = preferences.getString("treeUri", null)?.let(Uri::parse)
        ?: throw Failure("copy_permission", "请先选择保存副本的文件夹。")

    private fun document(tree: Uri): Uri = DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))

    private fun requireFolder(tree: Uri): String {
        if (tree.scheme != "content" || !DocumentsContract.isTreeUri(tree) ||
            resolver.persistedUriPermissions.none { it.uri == tree && it.isReadPermission && it.isWritePermission }) {
            throw Failure("copy_permission", "文件夹授权已失效，请在下载目录设置中重新选择。")
        }
        resolver.query(document(tree), arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_FLAGS), null, null, null)?.use {
            if (it.moveToFirst() && it.getString(1) == DocumentsContract.Document.MIME_TYPE_DIR &&
                it.getInt(2) and DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE != 0) {
                return it.getString(0) ?: "已选择的文件夹"
            }
        }
        throw Failure("copy_permission", "文件夹不可写或已被移除，请重新选择。")
    }

    private fun settings(validate: Boolean = true): Map<String, Any?> {
        val tree = preferences.getString("treeUri", null)
        val enabled = preferences.getBoolean("enabled", false)
        var warning: String? = null
        // Startup only reads preferences. A remote document provider must not
        // prevent the app from showing its first page.
        if (enabled && tree != null && validate) {
            try { requireFolder(Uri.parse(tree)) }
            catch (_: Exception) { warning = "文件夹不可用或授权已失效，请重新选择。" }
        }
        if (warning == null && partials().isNotEmpty()) warning = "上次中断的临时副本尚未清理；请恢复原文件夹授权后刷新。"
        return mapOf("enabled" to enabled, "treeUri" to tree,
            "label" to preferences.getString("label", null),
            "location" to tree?.let { folderLocation(Uri.parse(it)) }, "warning" to warning)
    }

    @Suppress("DEPRECATION")
    private fun folderLocation(tree: Uri): String {
        // Display only: every operation on the selected folder still uses SAF.
        // Other providers, including cloud storage, need not have a local path.
        if (tree.authority != "com.android.externalstorage.documents") return tree.toString()
        return try {
            val parts = DocumentsContract.getTreeDocumentId(tree).split(':', limit = 2)
            if (parts.size != 2) return tree.toString()
            val (volumeId, relative) = parts
            val root = if (Build.VERSION.SDK_INT >= 30) {
                activity.getSystemService(StorageManager::class.java)?.storageVolumes?.firstOrNull {
                    if (volumeId == "primary") it.isPrimary else it.uuid.equals(volumeId, true)
                }?.directory
            } else if (volumeId == "primary") {
                Environment.getExternalStorageDirectory()
            } else null
            if (root == null || relative.startsWith('/') ||
                relative.split('/').any { it == "." || it == ".." }) return tree.toString()
            if (relative.isEmpty()) root.absolutePath else File(root, relative).absolutePath
        } catch (_: Exception) {
            tree.toString()
        }
    }

    private fun managedFile(path: String?): File {
        if (path.isNullOrBlank()) throw Failure("copy_source", "安装包路径无效。")
        val file = File(path).canonicalFile
        val roots = listOfNotNull(File(activity.filesDir, "downloads"),
            activity.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS),
            activity.getExternalFilesDir(null)?.let { File(it, "downloads") }).map { it.canonicalFile }
        if (roots.none { file.path.startsWith(it.path + File.separator) } ||
            !file.isFile || !file.extension.equals("apk", true) || file.length() !in 1..MAX_BYTES) {
            throw Failure("copy_source", "原始 APK 不可用，请检查应用库中的文件。")
        }
        return file
    }

    private fun checkCancelled(cancelled: AtomicBoolean) {
        if (cancelled.get()) throw Failure("copy_cancelled", "保存副本已取消，可稍后重试。")
    }

    private fun digest(input: InputStream, cancelled: AtomicBoolean): String {
        val hash = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(128 * 1024)
        var total = 0L
        while (true) {
            checkCancelled(cancelled)
            val count = input.read(buffer)
            if (count < 0) break
            total += count
            if (total > MAX_BYTES) throw Failure("copy_size", "安装包大小超出支持范围。")
            hash.update(buffer, 0, count)
        }
        return hash.digest().joinToString("") { "%02x".format(it) }
    }

    private fun copy(path: String?, expected: String?, treeValue: String?, cancelled: AtomicBoolean): Map<String, String> {
        cleanupPartial()
        val tree = selectedTree()
        if (treeValue != tree.toString()) throw Failure("copy_directory_changed", "保存文件夹已更改，请重试保存副本。")
        val label = requireFolder(tree)
        val source = managedFile(path)
        val hash = source.inputStream().use { digest(it, cancelled) }
        if (expected != null && !hash.equals(expected, true)) throw Failure("copy_changed", "原始 APK 已变化，未保存副本，请重新下载。")
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree))
        val existing = mutableMapOf<String, Uri>()
        resolver.query(children, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_DOCUMENT_ID), null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) existing[cursor.getString(0)] = DocumentsContract.buildDocumentUriUsingTree(tree, cursor.getString(1))
        } ?: throw Failure("copy_permission", "无法读取保存文件夹，请重新选择。")
        val base = source.nameWithoutExtension
        var name = source.name
        var suffix = 0
        while (existing.containsKey(name)) {
            checkCancelled(cancelled)
            val found = existing.getValue(name)
            val matches = try { resolver.openInputStream(found)?.use { digest(it, cancelled) } == hash }
                catch (error: Exception) { checkCancelled(cancelled); false }
            if (matches) return mapOf("uri" to found.toString(), "directory" to label)
            suffix++
            if (suffix > 1000) throw Failure("copy_names", "此文件夹中的同名文件过多，请选择其他文件夹。")
            name = "$base ($suffix).apk"
        }
        var output: Uri? = null
        var temporaryName = ".HuaRunWin-${UUID.randomUUID()}.partial.apk"
        try {
            checkCancelled(cancelled)
            output = DocumentsContract.createDocument(resolver, document(tree), "application/vnd.android.package-archive",
                temporaryName)
                ?: throw Failure("copy_write", "无法创建副本，请检查文件夹权限和可用空间。")
            savePartial(output, temporaryName)
            // Providers may adjust the requested name. Record the actual name
            // so recovery never deletes a document that has since been renamed.
            val actualName = displayName(output)
                ?: throw Failure("copy_write", "无法确认副本文件，请重新选择文件夹。")
            if (actualName != temporaryName) {
                temporaryName = actualName
                savePartial(output, temporaryName)
            }
            resolver.openOutputStream(output, "w")?.use { target ->
                source.inputStream().use { input ->
                    val buffer = ByteArray(128 * 1024)
                    var total = 0L
                    while (true) {
                        checkCancelled(cancelled)
                        val count = input.read(buffer)
                        if (count < 0) break
                        total += count
                        if (total > MAX_BYTES) throw Failure("copy_size", "安装包大小超出支持范围。")
                        target.write(buffer, 0, count)
                    }
                    target.flush()
                }
            } ?: throw Failure("copy_write", "无法写入副本，请检查文件夹权限和可用空间。")
            val copiedHash = resolver.openInputStream(output)?.use { digest(it, cancelled) }
            if (copiedHash != hash) throw Failure("copy_changed", "副本校验失败，原始 APK 已保留，请重试。")
            checkCancelled(cancelled)
            val pending = output
            output = DocumentsContract.renameDocument(resolver, pending, name)
                ?: throw Failure("copy_write", "此文件夹无法完成文件保存，请选择其他文件夹。")
            // Once published, a preference-write failure must not remove the
            // completed copy. Recovery also checks its recorded temporary name.
            try { removePartial(pending) } catch (_: Exception) {}
            return mapOf("uri" to output.toString(), "directory" to label)
        } catch (error: Exception) {
            output?.let {
                try {
                    cleanupDocument(it, temporaryName)
                } catch (_: Exception) { /* Keep the receipt for cleanup on the next attempt. */ }
            }
            throw error
        }
    }

    private fun partials(): Set<String> = preferences.getStringSet("partialUris", emptySet())!!.toSet()

    private fun savePartial(uri: Uri, name: String) {
        checkSaved(preferences.edit().putStringSet("partialUris", partials() + uri.toString())
            .putString("partialName:$uri", name).commit())
    }

    private fun removePartial(uri: Uri) {
        checkSaved(preferences.edit().putStringSet("partialUris", partials() - uri.toString())
            .remove("partialName:$uri").commit())
    }

    private fun displayName(uri: Uri): String? {
        val cursor = resolver.query(uri, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)
            ?: throw Failure("copy_read", "暂时无法读取副本文件，请稍后重试。")
        return cursor.use {
            if (it.moveToFirst()) it.getString(0)
                ?: throw Failure("copy_read", "无法读取副本文件名，请稍后重试。")
            else null
        }
    }

    private fun cleanupDocument(uri: Uri, temporaryName: String?) {
        try {
            if (temporaryName == null || displayName(uri) != temporaryName || DocumentsContract.deleteDocument(resolver, uri)) {
                removePartial(uri)
            }
        } catch (_: FileNotFoundException) {
            removePartial(uri)
        }
    }

    private fun cleanupPartial() {
        for (pending in partials()) {
            val uri = Uri.parse(pending)
            try {
                cleanupDocument(uri, preferences.getString("partialName:$uri", null))
            } catch (_: Exception) { /* Keep only our own unfinished files for a later cleanup. */ }
        }
    }

    private fun checkSaved(saved: Boolean) {
        if (!saved) throw Failure("copy_settings", "保存设置失败，请重试。")
    }

    private fun execute(result: MethodChannel.Result, block: () -> Any?) {
        worker.execute {
            try {
                val value = block()
                activity.runOnUiThread { if (!disposed) result.success(value) }
            } catch (error: Exception) {
                activity.runOnUiThread {
                    if (!disposed) result.error(if (error is Failure) error.code else "copy_failed",
                        if (error is Failure) error.message else "保存副本失败，请检查文件夹授权、可用空间和存储连接后重试。", null)
                }
            }
        }
    }

    fun dispose() {
        disposed = true
        cancellations.values.forEach { it.set(true) }
        picker?.error("copy_interrupted", "文件夹选择已中断，请重试。", null)
        picker = null
        worker.shutdown()
    }

    companion object {
        private const val PICK_DIRECTORY = 18517
        private const val MAX_BYTES = 4L * 1024 * 1024 * 1024
    }
}
