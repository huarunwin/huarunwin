package win.huarun.huarunwin

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

class DownloadForegroundService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var expectedStop = false

    override fun onCreate() {
        super.onCreate()
        instance = this
        if (Build.VERSION.SDK_INT >= 26) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL, "下载进度", NotificationManager.IMPORTANCE_LOW),
            )
        }
        wakeLock = (getSystemService(POWER_SERVICE) as PowerManager)
            .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "HuarunWin:downloads")
            .apply { setReferenceCounted(false) }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == CANCEL) {
            stopDownloads("下载已取消，可返回应用重试。")
            return START_NOT_STICKY
        }
        if (intent == null || intent.getIntExtra("count", 0) <= 0) {
            expectedStop = true
            stopSelf()
            return START_NOT_STICKY
        }
        try {
            expectedStop = false
            val notification = notification(intent)
            ServiceCompat.startForeground(this, NOTIFICATION, notification,
                if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC else 0)
            active = true
            if (wakeLock?.isHeld != true) wakeLock?.acquire(10 * 60 * 1000L)
        } catch (_: Exception) {
            stopDownloads("无法启动后台下载服务，请返回应用后重试。")
        }
        return START_NOT_STICKY
    }

    private fun notification(intent: Intent): Notification {
        val count = intent.getIntExtra("count", 1)
        val received = intent.getLongExtra("received", 0)
        val total = intent.getLongExtra("total", 0)
        val open = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java).setAction(OPEN)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val cancel = PendingIntent.getService(this, 1,
            Intent(this, DownloadForegroundService::class.java).setAction(CANCEL),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(if (count == 1) intent.getStringExtra("name") ?: "下载应用" else "$count 个下载任务")
            .setContentText(if (total > 0) "已下载 ${received * 100 / total}%" else "正在下载或校验安装包")
            .setProgress(100, if (total > 0) (received * 100 / total).coerceIn(0, 100).toInt() else 0, total <= 0)
            .setOngoing(true).setOnlyAlertOnce(true).setContentIntent(open)
            .addAction(0, "取消下载", cancel).build()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        stopDownloads("应用已关闭，重新打开后可重试下载。")
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        stopDownloads("系统已停止长时间后台下载，请返回应用后重试。")
    }

    private fun stopDownloads(reason: String) {
        expectedStop = true
        active = false
        onStopped?.invoke(reason)
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        active = false
        if (wakeLock?.isHeld == true) wakeLock?.release()
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        if (!expectedStop) onStopped?.invoke("后台下载已停止，请重试。")
        super.onDestroy()
    }

    companion object {
        const val OPEN = "win.huarun.huarunwin.OPEN_DOWNLOADS"
        private const val CANCEL = "win.huarun.huarunwin.CANCEL_DOWNLOADS"
        private const val CHANNEL = "downloads"
        private const val NOTIFICATION = 1201
        var active = false
        var onStopped: ((String) -> Unit)? = null
        private var instance: DownloadForegroundService? = null

        fun stop(context: Context) {
            instance?.expectedStop = true
            active = false
            context.stopService(Intent(context, DownloadForegroundService::class.java))
        }
    }
}
