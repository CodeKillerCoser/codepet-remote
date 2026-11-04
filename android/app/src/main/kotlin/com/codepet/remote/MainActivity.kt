package com.codepet.remote

import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
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
