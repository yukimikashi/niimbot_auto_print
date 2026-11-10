package com.example.niimbot_auto_print

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class PrintCommandReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != BackgroundPrintService.ACTION_PRINT) return
        val path = intent.getStringExtra(BackgroundPrintService.EXTRA_PATH)
        if (path.isNullOrBlank()) {
            Log.w("NiimbotAutoPrint", "Print broadcast ignored: empty path")
            return
        }
        // 枚数(Extra名 "copies")。数値でも文字列でも受け取る。未指定・不正は1枚。
        val rawCopies = intent.extras?.get(BackgroundPrintService.EXTRA_COPIES)
        val copies = when (rawCopies) {
            is Number -> rawCopies.toInt()
            is String -> rawCopies.trim().toIntOrNull()
            else -> null
        }?.coerceIn(1, BackgroundPrintService.MAX_COPIES) ?: 1

        // The foreground print service should already have been started from the app UI.
        // startService delivers the command to that running service without opening an Activity.
        val serviceIntent = Intent(context, BackgroundPrintService::class.java).apply {
            action = BackgroundPrintService.ACTION_PRINT
            putExtra(BackgroundPrintService.EXTRA_PATH, path)
            putExtra(BackgroundPrintService.EXTRA_COPIES, copies)
        }
        try {
            context.startService(serviceIntent)
        } catch (error: Exception) {
            Log.e("NiimbotAutoPrint", "Could not deliver print command; start the foreground service in the app first", error)
        }
    }
}