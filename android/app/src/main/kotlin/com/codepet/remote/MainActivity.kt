package com.codepet.remote

import android.content.Context
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine =
        (application as CodePetApplication).engine()

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        (application as CodePetApplication).liveUpdates?.open(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        (application as CodePetApplication).liveUpdates?.open(intent)
    }

    override fun onResume() {
        super.onResume()
        (application as CodePetApplication).activityResumed = true
    }

    override fun onPause() {
        (application as CodePetApplication).activityResumed = false
        super.onPause()
    }
}
