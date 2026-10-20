package win.huarun.huarunwin

import android.app.Activity
import android.content.Intent
import android.content.IntentSender
import android.content.pm.PackageInstaller
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class ApkInstallSessionsTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val base = instrumentation.targetContext
    private lateinit var sessions: ApkInstallSessions
    private lateinit var sender: IntentSender
    private var sessionId = -1
    private val confirmations = LinkedBlockingQueue<Intent>()
    private val results = LinkedBlockingQueue<String>()
    private val stages = LinkedBlockingQueue<String>()
    private val fixture get() = File(instrumentation.context.applicationInfo.sourceDir)
    private val installer get() = base.packageManager.packageInstaller
    private fun digest(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    @Before fun prepare() {
        instrumentation.runOnMainSync {
            val activity = object : Activity() {
                init { attachBaseContext(base) }
                override fun startActivity(intent: Intent) { confirmations.add(intent) }
            }
            sessions = ApkInstallSessions(activity, { stages.add(it) }, { results.add(it ?: "success") }, { id, _, response ->
                sessionId = id
                sender = response
            })
        }
        awaitSessions(emptySet())
    }
    @After fun clean() {
        if (::sessions.isInitialized) instrumentation.runOnMainSync { sessions.dispose() }
        if (sessionId >= 0) runCatching { installer.abandonSession(sessionId) }
    }
    private fun stage() {
        sessions.install(fixture, "win.huarun.huarunwin.test", digest(fixture.readBytes()))
        assertTrue(sessionId >= 0)
    }
    private fun awaitSessions(expected: Set<Int>) {
        // Abandonment removes the session asynchronously on newer Android versions.
        val deadline = android.os.SystemClock.uptimeMillis() + 5000
        var actual = installer.mySessions.map { it.sessionId }.toSet()
        while (actual != expected && android.os.SystemClock.uptimeMillis() < deadline) {
            android.os.SystemClock.sleep(25)
            actual = installer.mySessions.map { it.sessionId }.toSet()
        }
        assertEquals(expected, actual)
    }
    private fun status(code: Int, id: Int = sessionId, confirm: Boolean = false) {
        val intent = Intent().putExtra(PackageInstaller.EXTRA_SESSION_ID, id).putExtra(PackageInstaller.EXTRA_STATUS, code)
        if (confirm) intent.putExtra(Intent.EXTRA_INTENT, Intent("qa.confirm"))
        sender.sendIntent(base, 0, intent, null, null)
        instrumentation.waitForIdleSync()
    }

    @Test fun sessionContainsExactCheckedBytesAndOnlySystemSuccessCompletesInstallation() {
        stage()
        installer.openSession(sessionId).use { session ->
            assertArrayEquals(fixture.readBytes(), session.openRead("base.apk").use { it.readBytes() })
        }
        status(PackageInstaller.STATUS_SUCCESS, id = sessionId + 1)
        assertTrue(results.isEmpty())
        status(PackageInstaller.STATUS_PENDING_USER_ACTION, confirm = true)
        assertEquals("qa.confirm", confirmations.poll(10, TimeUnit.SECONDS)?.action)
        assertTrue(stages.contains("waiting_confirmation"))
        assertTrue(results.isEmpty())
        status(PackageInstaller.STATUS_SUCCESS)
        assertEquals("success", results.poll(10, TimeUnit.SECONDS))
    }
    @Test fun cancelledConfirmationReturnsFailureAndAbandonsSession() {
        stage()
        status(PackageInstaller.STATUS_FAILURE_ABORTED)
        assertTrue(results.poll(10, TimeUnit.SECONDS)!!.contains("取消"))
        awaitSessions(emptySet())
        assertNull(installer.getSessionInfo(sessionId))
        assertTrue(fixture.isFile)
    }
    @Test fun changedDigestNeverCommitsAndLeavesNoSession() {
        val before = installer.mySessions.map { it.sessionId }.toSet()
        try {
            sessions.install(fixture, "win.huarun.huarunwin.test", "0".repeat(64))
            fail("Changed APK must be refused")
        } catch (expected: IllegalStateException) {
            assertTrue(expected.message!!.contains("已变化"))
        }
        assertFalse(::sender.isInitialized)
        awaitSessions(before)
    }
    @Test fun realCommitRequestsSystemConfirmationWithoutInstallingAnything() {
        instrumentation.runOnMainSync {
            sessions.dispose()
            val activity = object : Activity() {
                init { attachBaseContext(base) }
                override fun startActivity(intent: Intent) { confirmations.add(intent) }
            }
            sessions = ApkInstallSessions(activity, { stages.add(it) }, { results.add(it ?: "success") })
        }
        sessions.install(fixture, "win.huarun.huarunwin.test", digest(fixture.readBytes()))
        assertNotNull("System confirmation was not requested; result=$results", confirmations.poll(30, TimeUnit.SECONDS))
        assertTrue(stages.contains("waiting_confirmation"))
        assertTrue(results.isEmpty())
        // No confirmation activity was opened; dispose abandons the real session.
    }
}
