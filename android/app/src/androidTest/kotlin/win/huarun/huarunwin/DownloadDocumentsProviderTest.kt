package win.huarun.huarunwin

import android.content.Context
import android.content.pm.ProviderInfo
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.system.Os
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.io.FileNotFoundException

@RunWith(AndroidJUnit4::class)
class DownloadDocumentsProviderTest {
    private val base = InstrumentationRegistry.getInstrumentation().targetContext
    private val preferences = base.getSharedPreferences("download-browser", Context.MODE_PRIVATE)
    private val previousRoot = preferences.getString("root", null)
    private val root = File(base.filesDir, "downloads")
    private val folder = File(root, "browser-qa-${System.nanoTime()}")
    private val indexFixture = File(root, "${folder.name}.json")
    private val provider = DownloadDocumentsProvider()
    private val id get() = "internal/${folder.name}"

    @Before fun prepare() {
        folder.mkdirs()
        File(folder, "fixture.apk").writeText("completed download fixture")
        indexFixture.writeText("private metadata fixture")
        provider.attachInfo(base, ProviderInfo().apply {
            authority = "${base.packageName}.downloads"
            exported = true
            grantUriPermissions = true
            readPermission = "android.permission.MANAGE_DOCUMENTS"
            writePermission = "android.permission.MANAGE_DOCUMENTS"
        })
    }

    @After fun clean() {
        folder.deleteRecursively()
        indexFixture.delete()
        preferences.edit().apply {
            if (previousRoot == null) remove("root") else putString("root", previousRoot)
        }.commit()
    }

    private fun denied(block: () -> Unit) {
        try { block(); fail("Expected access to be rejected") } catch (_: FileNotFoundException) { }
    }

    @Test fun browseAndReadCompletedFilesWithRequestedColumns() {
        val uri = DownloadDocumentsProvider.directoryUri(base, root.path)
        assertEquals("internal", DocumentsContract.getTreeDocumentId(uri))
        provider.queryRoots(null).use { assertEquals(1, it.count) }
        provider.queryChildDocuments(id, arrayOf(Document.COLUMN_DISPLAY_NAME), sortOrder = null).use {
            assertEquals(1, it.count)
            assertTrue(it.moveToFirst())
            assertEquals("fixture.apk", it.getString(0))
        }
        provider.queryDocument("$id/fixture.apk", null).use {
            assertTrue(it.moveToFirst())
            assertEquals(0, it.getInt(it.getColumnIndexOrThrow(Document.COLUMN_FLAGS)))
            assertEquals("application/vnd.android.package-archive",
                it.getString(it.getColumnIndexOrThrow(Document.COLUMN_MIME_TYPE)))
        }
        ParcelFileDescriptor.AutoCloseInputStream(provider.openDocument("$id/fixture.apk", "r", null)).use {
            assertEquals("completed download fixture", it.bufferedReader().readText())
        }
    }

    @Test fun cannotWriteDeleteOrCreateManagedFiles() {
        for (mode in listOf("w", "rw", "rwt", "wa")) {
            denied { provider.openDocument("$id/fixture.apk", mode, null) }
        }
        try { provider.deleteDocument("$id/fixture.apk"); fail() } catch (_: UnsupportedOperationException) { }
        try { provider.createDocument(id, "text/plain", "new.txt"); fail() } catch (_: UnsupportedOperationException) { }
        assertEquals("completed download fixture", File(folder, "fixture.apk").readText())
    }

    @Test fun historyPartialAndHiddenFilesAreNeitherListedNorReadable() {
        val hidden = listOf("fixture.apk.part", "fixture.apk.part.json", "fixture.apk.part.json.tmp",
            "fixture.apk.tmp", "fixture.apk.unsigned", ".private")
        hidden.forEach { File(folder, it).writeText("private") }
        provider.queryChildDocuments(id, null, sortOrder = null).use { assertEquals(1, it.count) }
        hidden.forEach { name -> denied { provider.openDocument("$id/$name", "r", null) } }
        denied { provider.openDocument("internal/${indexFixture.name}", "r", null) }
        denied { provider.queryDocument("internal/tasks.json", null) }
        denied { provider.queryDocument("internal/history-recovery", null) }
    }

    @Test fun traversalSymlinksAndSiblingPrefixesCannotEscapeGrantedFolder() {
        denied { provider.queryDocument("$id/../../shared_prefs", null) }
        denied { provider.queryDocument("$id/../${folder.name}/fixture.apk", null) }
        val link = File(folder, "linked.apk")
        Os.symlink(File(folder, "fixture.apk").path, link.path)
        try { denied { provider.openDocument("$id/linked.apk", "r", null) } } finally { link.delete() }
        assertTrue(provider.isChildDocument("internal", "$id/fixture.apk"))
        assertTrue(provider.isChildDocument(id, "$id/fixture.apk"))
        assertFalse(provider.isChildDocument("$id/fixture.apk", id))
        assertFalse(provider.isChildDocument("$id-sibling", "$id/fixture.apk"))
    }

    @Test fun directoryHandoffOnlyAcceptsExactManagedRoots() {
        denied { DownloadDocumentsProvider.directoryUri(base, base.filesDir.path) }
        denied { DownloadDocumentsProvider.directoryUri(base, folder.path) }
        denied { DownloadDocumentsProvider.directoryUri(base, null) }
        val external = requireNotNull(base.getExternalFilesDir(null))
        for ((name, expected) in listOf("Download" to "external", "downloads" to "external-legacy")) {
            val directory = File(external, name)
            val existed = directory.exists()
            directory.mkdirs()
            try {
                val uri = DownloadDocumentsProvider.directoryUri(base, directory.path)
                assertEquals(expected, DocumentsContract.getTreeDocumentId(uri))
            } finally { if (!existed) directory.delete() }
        }
    }

    @Test fun systemFileManagerCanResolveTheExactDirectoryAndItsAncestors() {
        if (android.os.Build.VERSION.SDK_INT < 26) return
        val path = provider.findDocumentPath(null, "$id/fixture.apk")
        assertEquals("internal", path.rootId)
        assertEquals(listOf("internal", id, "$id/fixture.apk"), path.path)
        assertEquals(listOf("internal"), provider.findDocumentPath(null, "internal").path)
        val subtree = provider.findDocumentPath(id, "$id/fixture.apk")
        assertNull(subtree.rootId)
        assertEquals(listOf(id, "$id/fixture.apk"), subtree.path)
        denied { provider.findDocumentPath("$id-sibling", "$id/fixture.apk") }
    }
}
