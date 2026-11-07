package com.codepet.remote

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address

class MdnsBridge(private val applicationContext: Context, flutterEngine: FlutterEngine) {
    private var multicastLock: WifiManager.MulticastLock? = null
    private var multicastLockHolders = 0
    private var activeDiscovery: NsdDiscoverySession? = null
    private var lastDiagnostics: Map<String, Any?> = emptyMap()

    init {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.codepet.remote/mdns",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "diagnostics" -> result.success(activeDiscovery?.diagnostics() ?: lastDiagnostics)
                "acquireMulticastLock" -> {
                    acquireMulticastLock()
                    result.success(null)
                }
                "releaseMulticastLock" -> {
                    releaseMulticastLock()
                    result.success(null)
                }
                "discoverServices" -> {
                    val serviceType = call.argument<String>("serviceType")
                    val timeoutMillis = call.argument<Number>("timeoutMillis")?.toLong()
                    if (serviceType.isNullOrBlank() || timeoutMillis == null) {
                        result.error("invalid_arguments", "serviceType and timeoutMillis are required", null)
                    } else if (activeDiscovery != null) {
                        result.error("discovery_already_active", "An NSD scan is already running", null)
                    } else {
                        val session = NsdDiscoverySession(
                            serviceType = serviceType,
                            timeoutMillis = timeoutMillis.coerceIn(500L, 15_000L),
                            result = result,
                        )
                        activeDiscovery = session
                        session.start()
                    }
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

    fun dispose() {
        activeDiscovery?.cancel()
        activeDiscovery = null
        synchronized(this) {
            multicastLockHolders = 0
            multicastLock?.let { if (it.isHeld) it.release() }
            multicastLock = null
        }
    }

    private inner class NsdDiscoverySession(
        private val serviceType: String,
        private val timeoutMillis: Long,
        private val result: MethodChannel.Result,
    ) : NsdManager.DiscoveryListener {
        private val nsdManager = applicationContext.getSystemService(Context.NSD_SERVICE) as NsdManager
        private val handler = Handler(Looper.getMainLooper())
        private val pending = ArrayDeque<NsdServiceInfo>()
        private var discoveryStarted = false
        private var resolving = false
        private var finished = false
        private val startedAt = SystemClock.elapsedRealtime()
        private var phase = "created"
        private var foundCount = 0
        private var resolveFailures = 0
        private var lastErrorCode: Int? = null
        fun diagnostics(): Map<String, Any?> = mapOf(
            "phase" to phase, "elapsedMs" to (SystemClock.elapsedRealtime() - startedAt),
            "timeoutMs" to timeoutMillis, "discoveryStarted" to discoveryStarted,
            "resolving" to resolving, "pendingCount" to pending.size,
            "foundCount" to foundCount, "resolveFailures" to resolveFailures,
            "lastErrorCode" to lastErrorCode, "finished" to finished)
        private val timeout = Runnable { phase = "timerExpired"; finish(emptyList()) }

        fun start() {
            phase = "startRequested"
            handler.postDelayed(timeout, timeoutMillis)
            try {
                nsdManager.discoverServices(serviceType, NsdManager.PROTOCOL_DNS_SD, this)
            } catch (error: Exception) {
                fail("nsd_start_failed", error.message ?: "Unable to start NSD discovery")
            }
        }

        fun cancel() {
            if (finished) return
            finished = true
            handler.removeCallbacks(timeout)
            stopDiscovery()
        }

        override fun onDiscoveryStarted(regType: String) {
            discoveryStarted = true
            phase = "discoveryStarted"
            // A late callback after the timeout must not leave an NSD scan alive.
            if (finished) stopDiscovery()
        }

        override fun onServiceFound(service: NsdServiceInfo) {
            if (finished || normalizeType(service.serviceType) != normalizeType(serviceType)) return
            pending.addLast(service)
            foundCount++
            resolveNext()
        }

        override fun onServiceLost(service: NsdServiceInfo) = Unit

        override fun onDiscoveryStopped(serviceType: String) {
            discoveryStarted = false
        }

        override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
            lastErrorCode = errorCode
            fail("nsd_start_failed", "Android NSD failed to start: $errorCode")
        }

        override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
            lastErrorCode = errorCode
            discoveryStarted = false
        }

        @Suppress("DEPRECATION")
        private fun resolveNext() {
            if (finished || resolving || pending.isEmpty()) return
            resolving = true
            phase = "resolving"
            val service = pending.removeFirst()
            try {
                nsdManager.resolveService(service, object : NsdManager.ResolveListener {
                    override fun onServiceResolved(resolved: NsdServiceInfo) {
                        resolving = false
                        phase = "resolved"
                        val record = resolved.toDiscoveryRecord()
                        if (record != null) {
                            finish(listOf(record))
                        } else {
                            resolveNext()
                        }
                    }

                    override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                        resolving = false
                        resolveFailures++
                        lastErrorCode = errorCode
                        resolveNext()
                    }
                })
            } catch (_: Exception) {
                resolving = false
                resolveNext()
            }
        }

        @Suppress("DEPRECATION")
        private fun NsdServiceInfo.toDiscoveryRecord(): Map<String, Any>? {
            val addresses = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                hostAddresses
            } else {
                listOfNotNull(host)
            }
            val address = addresses.firstOrNull { it is Inet4Address } ?: addresses.firstOrNull()
            val hostAddress = address?.hostAddress ?: return null
            if (port !in 1..65535) return null
            val txt = attributes.mapValues { (_, value) -> value.toString(Charsets.UTF_8) }
            return mapOf(
                "instanceName" to serviceName,
                "host" to hostAddress,
                "port" to port,
                "txt" to txt,
            )
        }

        private fun finish(records: List<Map<String, Any>>) {
            if (finished) return
            finished = true
            lastDiagnostics = diagnostics()
            handler.removeCallbacks(timeout)
            stopDiscovery()
            if (activeDiscovery === this) activeDiscovery = null
            result.success(records)
        }

        private fun fail(code: String, message: String) {
            if (finished) return
            finished = true
            phase = code
            lastDiagnostics = diagnostics()
            handler.removeCallbacks(timeout)
            stopDiscovery()
            if (activeDiscovery === this) activeDiscovery = null
            result.error(code, message, null)
        }

        private fun stopDiscovery() {
            if (!discoveryStarted) return
            discoveryStarted = false
            try {
                nsdManager.stopServiceDiscovery(this)
            } catch (_: Exception) {}
        }

        private fun normalizeType(value: String): String = value.trimEnd('.').lowercase()
    }
}
