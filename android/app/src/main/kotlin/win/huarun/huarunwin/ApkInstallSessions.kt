package win.huarun.huarunwin

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentSender
import android.content.pm.PackageInstaller
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.io.File
import java.security.MessageDigest
import java.util.UUID

class ApkInstallSessions(
    private val activity: Activity,
    private val progress: (String) -> Unit,
    private val complete: (String?) -> Unit,
    private val commitSession: (Int, PackageInstaller.Session, IntentSender) -> Unit = { _, session, sender -> session.commit(sender) },
    private val failed: (ApkInstallFailure) -> Unit = { complete(it.message) },
) {
    private val installer = activity.packageManager.packageInstaller
    private val sessionLock = Any()
    @Volatile private var sessionId = -1
    @Volatile private var token: String? = null
    @Volatile private var disposed = false
    private var waitingConfirmation = false
    @Volatile private var response: PendingIntent? = null
    private val callback = object : PackageInstaller.SessionCallback() {
        override fun onCreated(id: Int) {}
        override fun onBadgingChanged(id: Int) {}
        override fun onActiveChanged(id: Int, active: Boolean) {}
        override fun onFinished(id: Int, success: Boolean) {}
        override fun onProgressChanged(id: Int, value: Float) {
            if (id == sessionId && !disposed && !waitingConfirmation) progress("installing")
        }
    }

    init {
        // Sessions left by a terminated process must not keep staging files forever.
        installer.mySessions.forEach { session -> runCatching { installer.abandonSession(session.sessionId) } }
        installer.registerSessionCallback(callback, Handler(Looper.getMainLooper()))
        active = this
    }

    fun install(file: File, packageName: String, expectedSha256: String) {
        check(!disposed) { "安装已中断，请重试。" }
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(packageName)
            setSize(file.length())
            if (Build.VERSION.SDK_INT >= 31) setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_REQUIRED)
        }
        val id = installer.createSession(params)
        sessionId = id
        val nonce = UUID.randomUUID().toString()
        token = nonce
        try {
            installer.openSession(id).use { session ->
                val digest = MessageDigest.getInstance("SHA-256")
                file.inputStream().buffered().use { input ->
                    session.openWrite("base.apk", 0, file.length()).use { output ->
                        val buffer = ByteArray(65536)
                        while (true) {
                            check(!disposed && !Thread.currentThread().isInterrupted) { "安装已中断，请重试。" }
                            val count = input.read(buffer)
                            if (count < 0) break
                            digest.update(buffer, 0, count)
                            output.write(buffer, 0, count)
                        }
                        session.fsync(output)
                    }
                }
                val actual = digest.digest().joinToString("") { "%02x".format(it) }
                check(actual == expectedSha256) { "APK 在准备安装时已变化，请重新检查。" }
                check(!disposed) { "安装已中断，请重试。" }
                val resultIntent = Intent(activity, ApkInstallReceiver::class.java).apply {
                    action = "${activity.packageName}.APK_INSTALL_RESULT"
                    putExtra("token", nonce)
                }
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                    (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0)
                synchronized(sessionLock) {
                    check(!disposed) { "安装已中断，请重试。" }
                    val pending = PendingIntent.getBroadcast(activity, id, resultIntent, flags)
                    response = pending
                    commitSession(id, session, pending.intentSender)
                }
            }
        } catch (error: Exception) {
            abandon()
            throw error
        }
    }

    private fun status(intent: Intent): Boolean {
        val nonce = token ?: return false
        if (disposed || intent.getStringExtra("token") != nonce ||
            intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1) != sessionId) return false
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION")
                val confirmation = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                try {
                    check(confirmation != null) { "系统未返回安装确认，请重试。" }
                    waitingConfirmation = true
                    progress("waiting_confirmation")
                    activity.startActivity(confirmation)
                } catch (error: Exception) {
                    abandon()
                    complete(error.message ?: "无法打开系统安装确认，请重试。")
                }
            }
            PackageInstaller.STATUS_SUCCESS -> {
                sessionId = -1
                token = null
                response?.cancel()
                response = null
                waitingConfirmation = false
                complete(null)
            }
            else -> {
                val error = ApkInstallFailure.fromIntent(intent)
                abandon()
                failed(error)
            }
        }
        return true
    }

    private fun abandon() = synchronized(sessionLock) {
        val id = sessionId
        sessionId = -1
        token = null
        response?.cancel()
        response = null
        waitingConfirmation = false
        if (id >= 0) runCatching { installer.abandonSession(id) }
    }

    fun dispose() {
        disposed = true
        if (active === this) active = null
        installer.unregisterSessionCallback(callback)
        abandon()
    }

    companion object {
        private var active: ApkInstallSessions? = null
        fun receive(context: Context, intent: Intent) {
            if (active?.status(intent) == true) return
            // A process restart cannot safely resume an installation confirmation.
            if (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -1) == PackageInstaller.STATUS_PENDING_USER_ACTION) {
                val id = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
                if (id >= 0) runCatching { context.packageManager.packageInstaller.abandonSession(id) }
            }
        }
    }
}

class ApkInstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) = ApkInstallSessions.receive(context, intent)
}
