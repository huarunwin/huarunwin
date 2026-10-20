package win.huarun.huarunwin

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.bouncycastle.jce.provider.BouncyCastleProvider
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.security.KeyStore
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class ApkSigningKeyDocumentsTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val base = instrumentation.targetContext
    private val token = System.nanoTime().toString()
    private val wrappingAlias = "huarun-qa-documents-$token"
    private val worker = Executors.newSingleThreadExecutor()
    private lateinit var folder: File
    private lateinit var isolated: Context
    private lateinit var keys: ApkSigningKeys
    private lateinit var documents: ApkSigningKeyDocuments
    private lateinit var key: Map<String, Any>
    private val requests = LinkedBlockingQueue<Pair<Intent, Int>>()
    private val password = "Signing backup test 2026!"

    private class Reply : MethodChannel.Result {
        private val done = CountDownLatch(1)
        var value: Any? = null
        var error: String? = null
        override fun success(result: Any?) { value = result; done.countDown() }
        override fun error(code: String, message: String?, details: Any?) { error = code; done.countDown() }
        override fun notImplemented() { error = "notImplemented"; done.countDown() }
        fun await(): Reply { assertTrue("Native reply timed out", done.await(30, TimeUnit.SECONDS)); return this }
    }

    @Before fun prepare() {
        folder = File(base.filesDir, "downloads/key-documents-qa-$token").apply { mkdirs() }
        isolated = object : ContextWrapper(base) {
            override fun getNoBackupFilesDir() = File(folder, "private").apply { mkdirs() }
            override fun getSharedPreferences(name: String, mode: Int) = base.getSharedPreferences("documents-qa-$token", mode)
        }
        keys = ApkSigningKeys(isolated, wrappingAlias)
        key = keys.create()
        instrumentation.runOnMainSync {
            val activity = object : Activity() {
                init { attachBaseContext(isolated) }
                override fun startActivityForResult(intent: Intent, requestCode: Int) {
                    requests.add(intent to requestCode)
                }
            }
            documents = ApkSigningKeyDocuments(activity, worker, keys)
        }
    }

    @After fun clean() {
        if (::documents.isInitialized) instrumentation.runOnMainSync { documents.dispose() }
        worker.shutdownNow()
        worker.awaitTermination(10, TimeUnit.SECONDS)
        KeyStore.getInstance("AndroidKeyStore").apply { load(null); deleteEntry(wrappingAlias) }
        base.deleteSharedPreferences("documents-qa-$token")
        if (::folder.isInitialized) folder.deleteRecursively()
    }

    private fun call(exporting: Boolean): Reply {
        val reply = Reply()
        val arguments = if (exporting) mapOf("password" to password, "keyId" to key["id"], "expectedCertificateSha256" to key["certificateSha256"])
            else mapOf("password" to password)
        instrumentation.runOnMainSync {
            assertTrue(documents.handle(MethodCall(if (exporting) "exportApkSigningKey" else "importApkSigningKey", arguments), reply))
        }
        return reply
    }

    // PKCS#12 derives three keys with 210,000 iterations; cold emulators can need longer.
    private fun request() = requireNotNull(requests.poll(120, TimeUnit.SECONDS)) { "System document request timed out" }
    private fun respond(code: Int, result: Int, uri: Uri? = null) = instrumentation.runOnMainSync {
        assertTrue(documents.onActivityResult(code, result, uri?.let { Intent().setData(it) }))
    }

    @Test fun exportUsesSystemDocumentAndRecordsTimeOnlyAfterSuccessfulWrite() {
        val reply = call(true)
        val (intent, code) = request()
        assertEquals(Intent.ACTION_CREATE_DOCUMENT, intent.action)
        assertEquals("application/x-pkcs12", intent.type)
        assertTrue(intent.hasCategory(Intent.CATEGORY_OPENABLE))
        assertTrue(intent.getStringExtra(Intent.EXTRA_TITLE)!!.endsWith(".p12"))
        assertNull(keys.keys().single { it["id"] == key["id"] }["lastExportedAt"])
        val backup = File(folder, "user-selected.p12")
        val uri = FileProvider.getUriForFile(base, "${base.packageName}.apkfiles", backup)
        respond(code, Activity.RESULT_OK, uri)
        val result = reply.await()
        assertNull(result.error)
        assertTrue((result.value as Map<*, *>)["lastExportedAt"] is Long)
        val standard = KeyStore.getInstance("PKCS12", BouncyCastleProvider()).apply {
            backup.inputStream().use { load(it, password.toCharArray()) }
        }
        assertTrue(standard.aliases().toList().any { standard.isKeyEntry(it) })
    }

    @Test fun cancellingEitherSystemPickerPreservesKeyAndDoesNotMarkExported() {
        val exporting = call(true)
        val (_, exportCode) = request()
        respond(exportCode, Activity.RESULT_CANCELED)
        assertNull(exporting.await().value)
        assertNull(exporting.error)
        val importing = call(false)
        val (intent, importCode) = request()
        assertEquals(Intent.ACTION_OPEN_DOCUMENT, intent.action)
        respond(importCode, Activity.RESULT_CANCELED)
        assertNull(importing.await().value)
        assertNull(importing.error)
        assertEquals(key, keys.keys().single { it["id"] == key["id"] })
    }

    @Test fun invalidDestinationAndMalformedImportAreRetryableWithoutChangingKeys() {
        val exporting = call(true)
        val (_, exportCode) = request()
        respond(exportCode, Activity.RESULT_OK, Uri.parse("file:///ungranted-backup.p12"))
        assertEquals("signing_key", exporting.await().error)
        val corrupt = File(folder, "corrupt.p12").apply { writeBytes(ByteArray(200)) }
        val importing = call(false)
        val (_, importCode) = request()
        respond(importCode, Activity.RESULT_OK, FileProvider.getUriForFile(base, "${base.packageName}.apkfiles", corrupt))
        assertEquals("signing_key", importing.await().error)
        assertEquals(key, keys.keys().single { it["id"] == key["id"] })
    }
}
