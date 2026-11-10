package com.example.niimbot_auto_print

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque

class BackgroundPrintService : Service() {
    companion object {
        const val ACTION_PRINT = "com.example.niimbot_auto_print.PRINT"
        const val EXTRA_PATH = "path"
        const val EXTRA_COPIES = "copies"
        // 打ち間違い(例: 1000)でラベルを無駄にしないための上限。
        const val MAX_COPIES = 20
        private const val CHANNEL_ID = "niimbot_background_print"
        private const val NOTIFICATION_ID = 4101
        private const val DART_CHANNEL = "niimbot/background_print"
    }

    private var engine: FlutterEngine? = null
    private var dartChannel: MethodChannel? = null
    private var dartReady = false
    private var printInFlight = false
    private val pendingPaths = ArrayDeque<Pair<String, Int>>()

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification("待機中：画像更新からの印刷指示を待っています"))
        startBackgroundFlutterEngine()
    }

    private fun startBackgroundFlutterEngine() {
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(applicationContext)
        loader.ensureInitializationComplete(applicationContext, null)

        val backgroundEngine = FlutterEngine(applicationContext)
        engine = backgroundEngine
        // Register the same Flutter plugins used by the foreground Flutter engine.
        io.flutter.plugins.GeneratedPluginRegistrant.registerWith(backgroundEngine)

        dartChannel = MethodChannel(backgroundEngine.dartExecutor.binaryMessenger, DART_CHANNEL)
        dartChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "ready" -> {
                    dartReady = true
                    updateNotification("待機中：印刷指示を待っています")
                    drainQueue()
                    result.success(null)
                }
                "status" -> {
                    updateNotification(call.arguments?.toString() ?: "印刷処理中")
                    result.success(null)
                }
                "printResult" -> {
                    val message = call.argument<String>("message") ?: "処理が終了しました"
                    updateNotification(message)
                    printInFlight = false
                    drainQueue()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        val entrypoint = DartExecutor.DartEntrypoint(loader.findAppBundlePath(), "backgroundMain")
        backgroundEngine.dartExecutor.executeDartEntrypoint(entrypoint)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_PRINT) {
            val path = intent.getStringExtra(EXTRA_PATH)
            if (!path.isNullOrBlank()) {
                val copies = intent.getIntExtra(EXTRA_COPIES, 1).coerceIn(1, MAX_COPIES)
                pendingPaths.addLast(Pair(path, copies))
                drainQueue()
            } else {
                updateNotification("エラー：画像パスが指定されていません")
            }
        }
        return START_STICKY
    }

    private fun drainQueue() {
        if (!dartReady || printInFlight || pendingPaths.isEmpty()) return
        printInFlight = true
        val (path, copies) = pendingPaths.removeFirst()
        dartChannel?.invokeMethod("print", mapOf("path" to path, "copies" to copies))
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "NIIMBOTバックグラウンド印刷",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "NIIMBOT B1のバックグラウンド印刷状態"
                setShowBadge(false)
            }
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun buildNotification(message: String): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setContentTitle("NIIMBOT Auto Print")
            .setContentText(message)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    private fun updateNotification(message: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, buildNotification(message))
    }

    override fun onDestroy() {
        dartReady = false
        printInFlight = false
        engine?.destroy()
        engine = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}