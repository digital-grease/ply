package com.digitalgrease.ply

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedReader
import java.io.InputStreamReader

class MainActivity : FlutterActivity() {
    private val diagnosticsChannel = "com.digitalgrease.ply/diagnostics"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, diagnosticsChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getPlatformLog" -> {
                        val lines = call.argument<Int>("lines") ?: 500
                        result.success(readOwnLogcat(lines))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Read THIS app's recent logcat. Since Android 4.1 a non-system app only sees its own logs via
     * logcat (the system native-crash tombstone, logged by debuggerd, needs READ_LOGS and is NOT
     * included — Ply does not request that permission). So this captures the Flutter engine / plugin
     * lines and warnings leading up to a crash, not the system tombstone.
     *
     * Best-effort: returns null if logcat can't be run (some restricted devices). The line count is a
     * trusted Int from the method channel and is clamped to a sane range; arguments are passed as a
     * fixed argv to ProcessBuilder (no shell), so there is no command-injection surface.
     */
    private fun readOwnLogcat(lines: Int): String? = try {
        val count = lines.coerceIn(1, 2000)
        val process = ProcessBuilder("logcat", "-d", "-v", "time", "-t", count.toString())
            .redirectErrorStream(true)
            .start()
        BufferedReader(InputStreamReader(process.inputStream)).use { it.readText() }
    } catch (e: Exception) {
        null
    }
}
