package win.huarun.huarunwin

import android.content.Intent
import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import androidx.core.content.ContextCompat

class MainActivity : FlutterActivity() {
    private var installer: ApkInstaller? = null
    private var installerChannel: MethodChannel? = null
    private var incoming: IncomingApks? = null
    private var incomingChannel: MethodChannel? = null
    private var downloadChannel: MethodChannel? = null
    private var openDownloads = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        incoming?.accept(intent)
        openDownloads = intent.action == DownloadForegroundService.OPEN
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        incoming?.accept(intent)
        if (intent.action == DownloadForegroundService.OPEN) {
            downloadChannel?.invokeMethod("openDownloads", null)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        installerChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "win.huarun/installer",
        )
        installer = ApkInstaller(this) { file, stage ->
            installerChannel?.invokeMethod("installProgress", mapOf("package" to file, "stage" to stage))
        }
        installerChannel?.setMethodCallHandler(installer)
        incomingChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "win.huarun/incoming_apks")
        incoming = IncomingApks(this) { incomingChannel?.invokeMethod("pendingApksChanged", null) }
        incomingChannel?.setMethodCallHandler(incoming)
        downloadChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "win.huarun/download_foreground")
        DownloadForegroundService.onStopped = { downloadChannel?.invokeMethod("downloadsStopped", it) }
        downloadChannel?.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "consumeOpen" -> { result.success(openDownloads); openDownloads = false }
                    "stop" -> {
                        DownloadForegroundService.stop(this)
                        result.success(null)
                    }
                    "start", "update" -> {
                        val service = Intent(this, DownloadForegroundService::class.java)
                            .putExtra("count", call.argument<Number>("count")?.toInt() ?: 0)
                            .putExtra("received", call.argument<Number>("received")?.toLong() ?: 0)
                            .putExtra("total", call.argument<Number>("total")?.toLong() ?: 0)
                            .putExtra("name", call.argument<String>("name"))
                        if (call.method == "start") {
                            ContextCompat.startForegroundService(this, service)
                            val preferences = getSharedPreferences("download-notifications", MODE_PRIVATE)
                            if (Build.VERSION.SDK_INT >= 33 && !preferences.getBoolean("requested", false) &&
                                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                                preferences.edit().putBoolean("requested", true).apply()
                                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1201)
                            }
                        } else if (DownloadForegroundService.active) startService(service)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                result.error("download_service", "无法启动后台下载，请返回应用后重试。", null)
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        installer?.onActivityResult(requestCode, resultCode, data)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        DownloadForegroundService.stop(this)
        DownloadForegroundService.onStopped = null
        downloadChannel?.setMethodCallHandler(null)
        downloadChannel = null
        installerChannel?.setMethodCallHandler(null)
        installerChannel = null
        installer?.dispose()
        installer = null
        incomingChannel?.setMethodCallHandler(null)
        incomingChannel = null
        incoming?.dispose()
        incoming = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
