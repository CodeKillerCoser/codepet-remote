package com.codepet.remote

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null
    private var multicastLockHolders = 0

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.codepet.remote/mdns",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquireMulticastLock" -> {
                    acquireMulticastLock()
                    result.success(null)
                }
                "releaseMulticastLock" -> {
                    releaseMulticastLock()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    @Synchronized
    private fun acquireMulticastLock() {
        if (multicastLockHolders == 0) {
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val lock = wifiManager.createMulticastLock("codepet_remote_mdns")
            lock.setReferenceCounted(false)
            lock.acquire()
            multicastLock = lock
        }
        multicastLockHolders += 1
    }

    @Synchronized
    private fun releaseMulticastLock() {
        if (multicastLockHolders == 0) return
        multicastLockHolders -= 1
        if (multicastLockHolders == 0) {
            multicastLock?.let { if (it.isHeld) it.release() }
            multicastLock = null
        }
    }

    override fun onDestroy() {
        synchronized(this) {
            multicastLockHolders = 0
            multicastLock?.let { if (it.isHeld) it.release() }
            multicastLock = null
        }
        super.onDestroy()
    }
}
