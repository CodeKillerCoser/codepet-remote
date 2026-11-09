package com.codepet.remote

import android.app.UiModeManager
import android.content.Context
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Keep Android's next system splash in sync with the Flutter appearance choice. */
class ThemeBridge(context: Context, engine: FlutterEngine) {
    init {
        MethodChannel(engine.dartExecutor.binaryMessenger,
            "com.codepet.remote/appearance").setMethodCallHandler { call, result ->
            if (call.method != "setThemeMode") {
                result.notImplemented()
            } else {
                val mode = call.arguments as? String
                if (mode !in listOf("system", "light", "dark")) {
                    result.error("invalid_theme", "Unknown appearance mode", null)
                } else {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        val nightMode = when (mode) {
                            "light" -> UiModeManager.MODE_NIGHT_NO
                            "dark" -> UiModeManager.MODE_NIGHT_YES
                            // Application AUTO clears the app-specific night qualifier.
                            else -> UiModeManager.MODE_NIGHT_AUTO
                        }
                        context.getSystemService(UiModeManager::class.java)
                            .setApplicationNightMode(nightMode)
                    }
                    result.success(null)
                }
            }
        }
    }
}
