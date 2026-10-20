package win.huarun.huarunwin

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.net.Uri
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class IncomingApksTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val base = instrumentation.targetContext
    private val token = System.nanoTime().toString()
    private lateinit var folder: File
    private lateinit var activity: Activity
    private lateinit var incoming: IncomingApks
    private val updates = LinkedBlockingQueue<Boolean>()

    @Before fun prepare() {
        folder = File(base.cacheDir, "incoming-qa-$token").apply { mkdirs() }
        val isolated = object : ContextWrapper(base) {
            override fun getFilesDir() = folder
            override fun getSharedPreferences(name: String, mode: Int) = base.getSharedPreferences("incoming-qa-$token", mode)
        }
        instrumentation.runOnMainSync {
            activity = object : Activity() { init { attachBaseContext(isolated) } }
            incoming = IncomingApks(activity) { updates.add(true) }
        }
    }
    @After fun clean() {
        if (::incoming.isInitialized) instrumentation.runOnMainSync { incoming.dispose() }
        base.deleteSharedPreferences("incoming-qa-$token")
        folder.deleteRecursively()
    }
    private fun call(method: String, args: Any? = null): Any? {
        var result: Any? = null
        instrumentation.runOnMainSync {
            incoming.onMethodCall(MethodCall(method, args), object : MethodChannel.Result {
                override fun success(value: Any?) { result = value }
                override fun error(code: String, message: String?, details: Any?) { fail("$code: $message") }
                override fun notImplemented() { fail("notImplemented") }
            })
        }
        return result
    }
    private fun pending() = call("pendingApks") as List<*>
    private fun accept(path: String, send: Boolean = false) {
        val uri = Uri.parse("content://${instrumentation.context.packageName}.incomingfixtures/$path")
        val intent = if (send) Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, uri)
            else Intent(Intent.ACTION_VIEW).setData(uri)
        instrumentation.runOnMainSync { incoming.accept(intent) }
        assertNotNull("Import timed out", updates.poll(30, TimeUnit.SECONDS))
    }

    @Test fun viewAndShareCopyApkPersistUntilAcknowledgedAndSurviveReceiverRecreation() {
        accept("valid")
        val entry = pending().single() as Map<*, *>
        val copy = File(entry["path"] as String)
        assertEquals("fixture.apk", copy.name)
        assertNotNull(base.packageManager.getPackageArchiveInfo(copy.path, 0))
        assertEquals(Intent.ACTION_MAIN, activity.intent.action)
        instrumentation.runOnMainSync {
            incoming.dispose()
            incoming = IncomingApks(activity) { updates.add(true) }
        }
        assertEquals(entry, pending().single())
        call("ackApk", mapOf("id" to entry["id"]))
        assertTrue(pending().isEmpty())
        assertTrue(copy.isFile)
        accept("valid", send = true)
        val second = pending().single() as Map<*, *>
        assertNotEquals(entry["id"], second["id"])
        assertNotEquals(entry["path"], second["path"])
    }

    @Test fun malformedUnreadableAndSelfUrisCannotBecomePendingInstallations() {
        accept("valid")
        val successful = pending().single()
        for (path in listOf("invalid", "denied")) {
            accept(path)
            assertEquals(successful, pending().first())
            val error = pending().last() as Map<*, *>
            assertNotNull(error["error"])
            assertNull(error["path"])
        }
        instrumentation.runOnMainSync {
            incoming.accept(Intent(Intent.ACTION_VIEW).setData(Uri.parse("content://${base.packageName}.apkfiles/downloads/fixture.apk")))
        }
        assertNotNull(updates.poll(30, TimeUnit.SECONDS))
        assertTrue(((pending().last() as Map<*, *>)["error"] as String).contains("下载管理"))
        instrumentation.runOnMainSync {
            incoming.accept(Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, Intent(Intent.ACTION_MAIN)))
        }
        assertNotNull(updates.poll(30, TimeUnit.SECONDS))
        assertNotNull((pending().last() as Map<*, *>)["error"])
        assertNull((pending().last() as Map<*, *>)["path"])
        assertEquals(1, File(folder, "downloads").listFiles()!!.size)
    }
}
