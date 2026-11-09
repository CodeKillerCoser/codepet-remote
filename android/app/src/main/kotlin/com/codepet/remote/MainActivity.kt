package com.codepet.remote

import android.content.res.Configuration
import android.os.Build
import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun attachBaseContext(base: Context) {
        // Before API 31 there is no persisted per-app splash appearance API.
        // Apply the saved preference to the Activity's window resources.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            val mode = base.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                .getString("flutter.appearance_theme_mode_v1", "system")
            if (mode == "light" || mode == "dark") {
                val config = Configuration(base.resources.configuration)
                config.uiMode = (config.uiMode and Configuration.UI_MODE_NIGHT_MASK.inv()) or
                    if (mode == "dark") Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
                super.attachBaseContext(base.createConfigurationContext(config))
                return
            }
        }
        super.attachBaseContext(base)
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine =
        (application as CodePetApplication).engine()

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onResume() {
        super.onResume()
        (application as CodePetApplication).activityResumed = true
    }

    override fun onPause() {
        (application as CodePetApplication).activityResumed = false
        super.onPause()
    }
}
