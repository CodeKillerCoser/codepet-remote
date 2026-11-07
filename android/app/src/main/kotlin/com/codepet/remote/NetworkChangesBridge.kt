package com.codepet.remote

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel

/** Observation only: keep corporate VPN/Tailscale on ordinary system routes. */
class NetworkChangesBridge(context: Context, engine: FlutterEngine) : EventChannel.StreamHandler {
    private val manager = context.getSystemService(ConnectivityManager::class.java)
    private val handler = Handler(Looper.getMainLooper())
    private var sink: EventChannel.EventSink? = null
    private var revision = 0L
    private var signature = ""
    private var registered = false
    private val publish = Runnable {
        if (sink == null) return@Runnable
        @Suppress("DEPRECATION")
        val networks = manager.allNetworks
        val next = manager.activeNetwork.toString() + networks.sortedBy { it.toString() }.joinToString { network ->
            val caps = manager.getNetworkCapabilities(network)
            val types = listOf(NetworkCapabilities.TRANSPORT_WIFI, NetworkCapabilities.TRANSPORT_CELLULAR,
                NetworkCapabilities.TRANSPORT_ETHERNET, NetworkCapabilities.TRANSPORT_VPN).filter { caps?.hasTransport(it) == true }
            "$network:$types:${caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)}:${manager.getLinkProperties(network)}"
        }
        if (next != signature) {
            signature = next
            sink?.success(++revision)
        }
    }
    private fun changed() { handler.removeCallbacks(publish); handler.postDelayed(publish, 300) }
    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = changed()
        override fun onLost(network: Network) = changed()
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) = changed()
        override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) = changed()
    }
    private val defaultCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = changed()
        override fun onLost(network: Network) = changed()
    }
    init {
        EventChannel(engine.dartExecutor.binaryMessenger, "com.codepet.remote/network_changes").setStreamHandler(this)
    }
    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        onCancel(null)
        sink = events
        try {
            manager.registerNetworkCallback(NetworkRequest.Builder().clearCapabilities().build(), callback)
            registered = true
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) manager.registerDefaultNetworkCallback(defaultCallback)
            changed()
        } catch (error: Exception) {
            onCancel(null)
            events.error("network_observation_unavailable", error.javaClass.simpleName, null)
        }
    }
    override fun onCancel(arguments: Any?) {
        sink = null
        handler.removeCallbacks(publish)
        if (registered) {
            runCatching { manager.unregisterNetworkCallback(callback) }
            runCatching { manager.unregisterNetworkCallback(defaultCallback) }
        }
        registered = false
        signature = ""
    }
}
