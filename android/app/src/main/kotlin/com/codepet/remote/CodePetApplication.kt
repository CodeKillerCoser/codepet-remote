package com.codepet.remote

import android.app.Application
import android.content.Intent
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/** One engine owns the authenticated sessions across Activity recreation. */
class CodePetApplication : Application() {
    private var flutterEngine: FlutterEngine? = null
    var activityResumed = false

    fun engine(): FlutterEngine {
        flutterEngine?.let { return it }
        val engine = FlutterEngine(this)
        flutterEngine = engine
        MdnsBridge(this, engine)
        MethodChannel(engine.dartExecutor.binaryMessenger,
            "com.codepet.remote/background_connection").setMethodCallHandler { call, result ->
            if (call.method != "setEnabled") {
                result.notImplemented()
            } else {
                try {
                    val enabled = call.arguments as? Boolean ?: false
                    val intent = Intent(this, BackgroundConnectionService::class.java)
                    if (enabled) {
                        if (!activityResumed && !BackgroundConnectionService.running) {
                            result.error("foreground_required", "Open the app to keep the connection", null)
                            return@setMethodCallHandler
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent)
                        else startService(intent)
                    } else {
                        stopService(intent)
                    }
                    result.success(null)
                } catch (error: Exception) {
                    result.error("connection_service_failed", error.message, null)
                }
            }
        }
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        return engine
    }
}
