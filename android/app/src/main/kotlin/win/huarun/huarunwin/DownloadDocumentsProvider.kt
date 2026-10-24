package win.huarun.huarunwin

import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.CancellationSignal
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import android.system.Os
import android.system.OsConstants
import android.webkit.MimeTypeMap
import java.io.File
import java.io.FileNotFoundException

/** A read-only view of download files, not of the application's other data. */
class DownloadDocumentsProvider : DocumentsProvider() {
    companion object {
        private const val PREFERENCES = "download-browser"
        private const val ACTIVE_ROOT = "root"
        private val DOCUMENT_COLUMNS = arrayOf(Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE, Document.COLUMN_FLAGS, Document.COLUMN_SIZE, Document.COLUMN_LAST_MODIFIED)
        private val ROOT_COLUMNS = arrayOf(Root.COLUMN_ROOT_ID, Root.COLUMN_DOCUMENT_ID, Root.COLUMN_TITLE,
            Root.COLUMN_SUMMARY, Root.COLUMN_FLAGS, Root.COLUMN_ICON, Root.COLUMN_MIME_TYPES)

        private fun roots(context: Context): Map<String, File> = buildMap {
            put("internal", File(context.filesDir, "downloads"))
            context.getExternalFilesDir(null)?.let {
                put("external", File(it, Environment.DIRECTORY_DOWNLOADS))
                put("external-legacy", File(it, "downloads"))
            }
        }

        private fun root(context: Context, id: String): File {
            val folder = roots(context)[id] ?: throw FileNotFoundException("Unknown download root")
            val expected = File(folder.parentFile!!.canonicalFile, folder.name)
            if (folder.canonicalFile != expected) throw FileNotFoundException("Invalid download root")
            return expected
        }

        fun directoryUri(context: Context, path: String?): Uri {
            if (path.isNullOrBlank()) throw FileNotFoundException("Missing download directory")
            val folder = File(path).canonicalFile
            val id = roots(context).keys.firstOrNull { root(context, it) == folder }
                ?: throw FileNotFoundException("Not a managed download directory")
            if (!folder.isDirectory) throw FileNotFoundException("Download directory unavailable")
            if (!context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit()
                    .putString(ACTIVE_ROOT, id).commit()) throw FileNotFoundException("Cannot save download root")
            context.contentResolver.notifyChange(DocumentsContract.buildRootsUri(authority(context)), null)
            return DocumentsContract.buildTreeDocumentUri(authority(context), id)
        }

        private fun authority(context: Context) = "${context.packageName}.downloads"
    }

    override fun onCreate() = true

    override fun queryRoots(projection: Array<out String>?): Cursor {
        val context = requireNotNull(context)
        val cursor = MatrixCursor(projection ?: ROOT_COLUMNS)
        val id = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).getString(ACTIVE_ROOT, null)
            ?: return cursor
        val folder = try { root(context, id) } catch (_: FileNotFoundException) { return cursor }
        if (folder.isDirectory) cursor.newRow().apply {
            add(Root.COLUMN_ROOT_ID, id)
            add(Root.COLUMN_DOCUMENT_ID, id)
            add(Root.COLUMN_TITLE, "华润赢")
            add(Root.COLUMN_SUMMARY, "下载目录")
            add(Root.COLUMN_FLAGS, Root.FLAG_LOCAL_ONLY)
            add(Root.COLUMN_ICON, context.applicationInfo.icon)
            add(Root.COLUMN_MIME_TYPES, "*/*")
        }
        return cursor
    }

    private fun file(documentId: String): File {
        val segments = documentId.split('/')
        val folder = root(requireNotNull(context), segments.first())
        val relative = segments.drop(1)
        if (relative.any { it.isEmpty() || it == "." || it == ".." || it.startsWith('.') } ||
            relative.firstOrNull() == "history-recovery") throw FileNotFoundException("Invalid document")
        val file = relative.fold(folder) { parent, child -> File(parent, child) }
        if (file.canonicalFile != file || !file.exists()) throw FileNotFoundException("Document unavailable")
        // Root-level files are history/index data. Partial downloads and private
        // staging files must not be readable even when their IDs are guessed.
        if (!file.isDirectory && (relative.size < 2 || file.name.endsWith(".part") ||
                file.name.endsWith(".part.json") || file.name.endsWith(".part.json.tmp") ||
                file.name.endsWith(".tmp") || file.name.endsWith(".unsigned"))) {
            throw FileNotFoundException("Not a completed download")
        }
        return file
    }

    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor =
        MatrixCursor(projection ?: DOCUMENT_COLUMNS).apply { addDocument(documentId, file(documentId)) }

    override fun queryChildDocuments(parentDocumentId: String, projection: Array<out String>?, sortOrder: String?): Cursor {
        val parent = file(parentDocumentId)
        if (!parent.isDirectory) throw FileNotFoundException("Not a directory")
        return MatrixCursor(projection ?: DOCUMENT_COLUMNS).apply {
            for (child in parent.listFiles().orEmpty().sortedBy { it.name.lowercase() }) {
                val id = "$parentDocumentId/${child.name}"
                try { addDocument(id, file(id)) } catch (_: FileNotFoundException) { /* Not a public download. */ }
            }
        }
    }

    override fun isChildDocument(parentDocumentId: String, documentId: String): Boolean = try {
        val parent = file(parentDocumentId)
        val child = file(documentId)
        parent.isDirectory && child.path.startsWith(parent.path + File.separator)
    } catch (_: FileNotFoundException) { false }

    override fun getDocumentType(documentId: String): String = mimeType(file(documentId))

    @android.annotation.TargetApi(26)
    override fun findDocumentPath(parentDocumentId: String?, childDocumentId: String): DocumentsContract.Path {
        file(childDocumentId)
        if (parentDocumentId != null && parentDocumentId != childDocumentId &&
            !isChildDocument(parentDocumentId, childDocumentId)) throw FileNotFoundException("Not a child document")
        val segments = childDocumentId.split('/')
        val path = segments.indices.map { segments.take(it + 1).joinToString("/") }
        return if (parentDocumentId == null) DocumentsContract.Path(segments.first(), path)
            else DocumentsContract.Path(null, path.dropWhile { it != parentDocumentId })
    }

    override fun openDocument(documentId: String, mode: String, signal: CancellationSignal?): ParcelFileDescriptor {
        if (mode != "r") throw FileNotFoundException("Downloads are read-only")
        signal?.throwIfCanceled()
        val file = file(documentId)
        if (!file.isFile) throw FileNotFoundException("Not a file")
        val fd = Os.open(file.path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW, 0)
        try { return ParcelFileDescriptor.dup(fd) } finally { Os.close(fd) }
    }

    private fun mimeType(file: File): String = when {
        file.isDirectory -> Document.MIME_TYPE_DIR
        file.extension.equals("apk", true) -> "application/vnd.android.package-archive"
        else -> MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase())
            ?: "application/octet-stream"
    }

    private fun MatrixCursor.addDocument(id: String, file: File) {
        newRow().apply {
            add(Document.COLUMN_DOCUMENT_ID, id)
            add(Document.COLUMN_DISPLAY_NAME, if ('/' in id) file.name else "下载目录")
            add(Document.COLUMN_MIME_TYPE, mimeType(file))
            add(Document.COLUMN_FLAGS, 0)
            add(Document.COLUMN_SIZE, if (file.isFile) file.length() else null)
            add(Document.COLUMN_LAST_MODIFIED, file.lastModified())
        }
    }
}
