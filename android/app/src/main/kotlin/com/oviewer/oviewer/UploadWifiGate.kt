package com.oviewer.oviewer

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import java.io.Closeable
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap

/** Observes the existing app route. It never selects a network or bypasses a VPN.
 * A violation is terminal for this gate; a new transfer needs a new instance.
 * Notifications cannot revoke bytes already handed to the OS before a change. */
internal class UploadWifiGate internal constructor(
    private val probe: () -> Observation,
    private val observer: Observer,
    private val onViolation: (String) -> Unit
) : Closeable {
    internal enum class State { ALLOWED, NON_WIFI, UNKNOWN }
    internal data class Observation(val state: State, val routeKey: Any? = null)
    internal fun interface Observer {
        fun watch(onChanged: () -> Unit): Closeable
    }

    constructor(context: Context, onViolation: (String) -> Unit) :
        this(Platform(context.applicationContext), onViolation)
    private constructor(platform: Platform, onViolation: (String) -> Unit) :
        this(platform::probe, platform, onViolation)

    private val lock = Any()
    private var started = false
    private var closed = false
    private var generation = 0L
    private var subscription: Closeable? = null
    private var route: Any? = null
    private var violation: String? = null

    /** Registers first, then checks, so a change during setup is observable. */
    fun start(): String? {
        val token = synchronized(lock) {
            if (closed) return violation ?: UNKNOWN
            if (started) null else { started = true; ++generation }
        }
        if (token == null) return check()
        val registered = try {
            observer.watch { refresh(token) }
        } catch (_: Exception) {
            invalidate(token, UNKNOWN)
            return currentViolation() ?: UNKNOWN
        }
        val keep = synchronized(lock) {
            if (closed || generation != token) false
            else { subscription = registered; true }
        }
        if (!keep) {
            try { registered.close() } catch (_: Exception) {}
            return currentViolation() ?: UNKNOWN
        }
        refresh(token)
        return synchronized(lock) { violation ?: if (closed) UNKNOWN else null }
    }

    /** A fresh check for each transmission boundary; a previous failure stays. */
    fun check(): String? {
        val token = synchronized(lock) {
            if (closed || !started) return violation ?: UNKNOWN
            violation?.let { return it }
            generation
        }
        refresh(token)
        return synchronized(lock) { violation ?: if (closed) UNKNOWN else null }
    }

    fun currentViolation(): String? = synchronized(lock) { violation }

    /** JobScheduler may choose another network while a job is running. */
    fun onNetworkChanged() { check() }

    private fun refresh(token: Long) {
        synchronized(lock) {
            if (closed || token != generation || violation != null) return
        }
        val observed = try { probe() } catch (_: Exception) { Observation(State.UNKNOWN) }
        synchronized(lock) {
            if (closed || token != generation || violation != null) return
            val reason = when {
                observed.state == State.NON_WIFI -> WAITING
                observed.state == State.UNKNOWN || observed.routeKey == null -> UNKNOWN
                route != null && route != observed.routeKey -> CHANGED
                else -> null
            }
            if (reason == null) route = observed.routeKey
            else invalidate(token, reason)
        }
    }

    private fun invalidate(token: Long, reason: String) = synchronized(lock) {
        if (closed || token != generation || violation != null) return@synchronized
        violation = reason
        // Keep this final generation check and callback inside the lock: after
        // close returns, a delayed callback cannot disconnect a later transfer.
        // The owner callback only disconnects this gate's connection reference.
        try { onViolation(reason) } catch (_: Exception) {}
    }

    override fun close() {
        val registered = synchronized(lock) {
            if (closed) return
            closed = true
            generation++
            subscription.also { subscription = null }
        }
        try { registered?.close() } catch (_: Exception) {}
    }

    internal companion object {
        const val WAITING = "waiting_wifi"
        const val UNKNOWN = "wifi_network_unknown"
        const val CHANGED = "wifi_network_changed"

        internal fun classify(sdk: Int, transports: Set<Int>, internet: Boolean): State {
            if (!internet || transports.isEmpty()) return State.UNKNOWN
            val vpn = NetworkCapabilities.TRANSPORT_VPN in transports
            // VPN underlying transports were not reliably reported before P.
            if (vpn && sdk <= 27) return State.UNKNOWN
            val physical = transports - NetworkCapabilities.TRANSPORT_VPN
            if (physical.size != 1) return State.UNKNOWN
            return if (physical.single() == NetworkCapabilities.TRANSPORT_WIFI) State.ALLOWED
                else State.NON_WIFI
        }
    }

    private class Platform(context: Context) : Observer {
        private val app = context
        private val connectivity = app.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        private val lost = Collections.newSetFromMap(ConcurrentHashMap<Network, Boolean>())
        private val blocked = Collections.newSetFromMap(ConcurrentHashMap<Network, Boolean>())
        private val reportedViolations = ConcurrentHashMap<Network, State>()
        @Volatile private var reportedDefault: Network? = null
        @Volatile private var unavailable = false

        private fun observation(network: Network, capabilities: NetworkCapabilities): Observation {
            if (network in lost || network in blocked) return Observation(State.UNKNOWN, network)
            reportedViolations[network]?.let { return Observation(it, network) }
            return Observation(classification(capabilities), network)
        }

        private fun classification(capabilities: NetworkCapabilities): State {
            // hasTransport is public on API 21; getTransportTypes is not
            // consistently available across supported API levels. Include unknown
            // transport bits so a future mixed bearer cannot become Wi-Fi-only.
            val transports = (0..63).filter { capabilities.hasTransport(it) }.toSet()
            return classify(Build.VERSION.SDK_INT, transports,
                capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET))
        }

        @Suppress("DEPRECATION")
        fun probe(): Observation {
            if (unavailable) return Observation(State.UNKNOWN)
            if (Build.VERSION.SDK_INT >= 23) {
                val network = connectivity.activeNetwork ?: return Observation(State.UNKNOWN)
                // Default-network events can precede synchronous snapshots.
                // Never keep sending on A after the OS has reported default B.
                val reported = reportedDefault
                if (reported != null && reported != network) return Observation(State.UNKNOWN, reported)
                val capabilities = connectivity.getNetworkCapabilities(network) ?: return Observation(State.UNKNOWN)
                return observation(network, capabilities)
            }
            val active = connectivity.activeNetworkInfo ?: return Observation(State.UNKNOWN)
            if (!active.isConnected) return Observation(State.UNKNOWN)
            if (active.type == ConnectivityManager.TYPE_VPN) return Observation(State.UNKNOWN)
            if (active.type != ConnectivityManager.TYPE_WIFI) return Observation(State.NON_WIFI)
            // API 21/22 expose no public default Network handle. Require one
            // connected Wi-Fi candidate and no visible VPN/unknown candidate;
            // legacy NetworkInfo alone cannot establish a VPN's only bearer.
            val candidates = mutableListOf<Observation>()
            for (network in connectivity.allNetworks) {
                val capabilities = connectivity.getNetworkCapabilities(network) ?: return Observation(State.UNKNOWN)
                if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return Observation(State.UNKNOWN)
                if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                    val info = connectivity.getNetworkInfo(network) ?: return Observation(State.UNKNOWN)
                    if (info.isConnected) candidates.add(observation(network, capabilities))
                }
            }
            return candidates.singleOrNull() ?: Observation(State.UNKNOWN)
        }

        @Suppress("DEPRECATION")
        override fun watch(onChanged: () -> Unit): Closeable {
            val callback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    lost.remove(network)
                    if (Build.VERSION.SDK_INT >= 24) {
                        reportedDefault = network
                        onChanged()
                    }
                    // Before API 24 these are all-network events. An unrelated
                    // cellular network appearing does not change the app route.
                }
                override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) {
                    if (Build.VERSION.SDK_INT >= 24) reportedDefault = network
                    val state = try { classification(networkCapabilities) } catch (_: Exception) { State.UNKNOWN }
                    if (state == State.ALLOWED) reportedViolations.remove(network)
                    else reportedViolations[network] = state
                    onChanged()
                }
                override fun onLost(network: Network) { lost.add(network); onChanged() }
                override fun onUnavailable() { unavailable = true; onChanged() }
                override fun onBlockedStatusChanged(network: Network, isBlocked: Boolean) {
                    if (isBlocked) blocked.add(network) else blocked.remove(network)
                    onChanged()
                }
            }
            var watching = false
            var receiving = false
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) {
                    if (intent?.action == ConnectivityManager.CONNECTIVITY_ACTION) onChanged()
                }
            }
            val close = Closeable {
                if (watching) {
                    watching = false
                    try { connectivity.unregisterNetworkCallback(callback) } catch (_: Exception) {}
                }
                if (receiving) {
                    receiving = false
                    try { app.unregisterReceiver(receiver) } catch (_: Exception) {}
                }
            }
            try {
                if (Build.VERSION.SDK_INT >= 24) connectivity.registerDefaultNetworkCallback(callback)
                else connectivity.registerNetworkCallback(NetworkRequest.Builder()
                    .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    .removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build(), callback)
                watching = true
                if (Build.VERSION.SDK_INT <= 23) {
                    app.registerReceiver(receiver, IntentFilter(ConnectivityManager.CONNECTIVITY_ACTION))
                    receiving = true
                }
                return close
            } catch (error: Exception) {
                close.close()
                throw error
            }
        }
    }
}
