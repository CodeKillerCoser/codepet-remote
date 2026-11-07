package com.codepet.remote

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Read-only snapshots. Never bind sockets, request networks or change VPN routing. */
class NetworkDiagnosticsBridge(context: Context, engine: FlutterEngine) {
    init {
        val manager = context.getSystemService(ConnectivityManager::class.java)
        MethodChannel(engine.dartExecutor.binaryMessenger,
            "com.codepet.remote/network_diagnostics").setMethodCallHandler { call, result ->
            if (call.method != "snapshot") {
                result.notImplemented()
            } else try {
                val active = manager.activeNetwork
                val bound = manager.boundNetworkForProcess
                // A one-shot snapshot at connection boundaries, not a polling monitor.
                @Suppress("DEPRECATION")
                val networks = manager.allNetworks
                result.success(mapOf(
                    "source" to "androidConnectivityManager",
                    "defaultNetwork" to active?.toString(),
                    "boundNetwork" to bound?.toString(),
                    "httpProxyConfigured" to (manager.defaultProxy != null),
                    "networks" to networks.take(32).map { network ->
                        val caps = manager.getNetworkCapabilities(network)
                        val link = manager.getLinkProperties(network)
                        mapOf(
                            "network" to network.toString(),
                            "isDefault" to (network == active),
                            "isBound" to (network == bound),
                            "capabilitiesAvailable" to (caps != null),
                            "linkPropertiesAvailable" to (link != null),
                            "transports" to listOf(
                                NetworkCapabilities.TRANSPORT_VPN to "vpn",
                                NetworkCapabilities.TRANSPORT_WIFI to "wifi",
                                NetworkCapabilities.TRANSPORT_CELLULAR to "cellular",
                                NetworkCapabilities.TRANSPORT_ETHERNET to "ethernet",
                                NetworkCapabilities.TRANSPORT_BLUETOOTH to "bluetooth"
                            ).filter { caps?.hasTransport(it.first) == true }.map { it.second },
                            "internet" to caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET),
                            "validated" to caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
                            "notVpn" to caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN),
                            "interface" to link?.interfaceName,
                            "mtu" to link?.mtu,
                            "httpProxyConfigured" to link?.let { it.httpProxy != null },
                            "addresses" to link?.linkAddresses?.take(32)?.map {
                                mapOf("address" to it.address.hostAddress?.substringBefore('%'),
                                    "prefixLength" to it.prefixLength)
                            },
                            "routes" to link?.routes?.take(32)?.map {
                                mapOf("family" to if (it.destination.address.address.size == 16) "IPv6" else "IPv4",
                                    "isDefault" to it.isDefaultRoute,
                                    "type" to it.type)
                            }
                        )
                    },
                    "truncated" to (networks.size > 32)
                ))
            } catch (error: Exception) {
                // Do not send native exception text, which may contain addresses.
                result.error("snapshot_unavailable", error.javaClass.simpleName, null)
            }
        }
    }
}
