package com.oviewer.oviewer

import android.app.Application
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkInfo
import android.os.Build
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowNetwork
import org.robolectric.shadows.ShadowNetworkCapabilities
import org.robolectric.shadows.ShadowNetworkInfo
import java.io.Closeable
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], application = Application::class)
class UploadWifiGateTest {
    private class Observer : UploadWifiGate.Observer {
        lateinit var changed: () -> Unit
        var registered = false
        var closed = 0
        override fun watch(onChanged: () -> Unit): Closeable {
            changed = onChanged
            registered = true
            return Closeable { closed++ }
        }
    }
    private fun wifi(route: Any = "wifi-route") = UploadWifiGate.Observation(UploadWifiGate.State.ALLOWED, route)
    private fun nonWifi() = UploadWifiGate.Observation(UploadWifiGate.State.NON_WIFI, "cell-route")

    @Test fun registersBeforeInitialProbeAndClosesExactlyOnce() {
        val observer = Observer()
        val notices = mutableListOf<String>()
        val gate = UploadWifiGate({ assertTrue(observer.registered); wifi() }, observer, notices::add)
        assertNull(gate.start())
        assertNull(gate.start())
        assertNull(gate.check())
        assertNull(gate.currentViolation())
        gate.close(); gate.close()
        assertEquals(1, observer.closed)
        assertEquals(UploadWifiGate.UNKNOWN, gate.check())
        assertTrue(notices.isEmpty())
    }

    @Test fun firstViolationIsLatchedAndDisconnectCallbackRunsOnlyOnce() {
        var observed = wifi()
        val observer = Observer()
        val notices = mutableListOf<String>()
        val gate = UploadWifiGate({ observed }, observer, notices::add)
        assertNull(gate.start())
        observed = nonWifi()
        observer.changed()
        assertEquals(listOf(UploadWifiGate.WAITING), notices)
        assertEquals(UploadWifiGate.WAITING, gate.currentViolation())
        observed = wifi()
        observer.changed()
        assertEquals(UploadWifiGate.WAITING, gate.check())
        gate.onNetworkChanged()
        assertEquals(1, notices.size)
        gate.close()
    }

    @Test fun directBoundaryChecksNoticeChangesWithoutWaitingForCallback() {
        var observed = wifi()
        val observer = Observer()
        val notices = mutableListOf<String>()
        val gate = UploadWifiGate({ observed }, observer, notices::add)
        assertNull(gate.start())
        observed = nonWifi()
        assertEquals(UploadWifiGate.WAITING, gate.check())
        assertEquals(listOf(UploadWifiGate.WAITING), notices)
        gate.close()
    }

    @Test fun anotherWifiRouteStillStopsTheCurrentTransmission() {
        var observed = wifi("first")
        val observer = Observer()
        val notices = mutableListOf<String>()
        val gate = UploadWifiGate({ observed }, observer, notices::add)
        assertNull(gate.start())
        observed = wifi("second")
        gate.onNetworkChanged()
        assertEquals(UploadWifiGate.CHANGED, gate.currentViolation())
        assertEquals(listOf(UploadWifiGate.CHANGED), notices)
        gate.close()
    }

    @Test fun unknownOrMissingRouteCannotAuthorizeTheFirstRequest() {
        for (observation in listOf(UploadWifiGate.Observation(UploadWifiGate.State.UNKNOWN),
            UploadWifiGate.Observation(UploadWifiGate.State.ALLOWED))) {
            val notices = mutableListOf<String>()
            val gate = UploadWifiGate({ observation }, Observer(), notices::add)
            assertEquals(UploadWifiGate.UNKNOWN, gate.start())
            assertEquals(listOf(UploadWifiGate.UNKNOWN), notices)
            gate.close()
        }
    }

    @Test fun probeAndRegistrationFailuresRemainUnknownAndNeverAllowSending() {
        val failingObserver = UploadWifiGate.Observer { throw SecurityException("Test-only observer failure") }
        val first = UploadWifiGate({ wifi() }, failingObserver, {})
        assertEquals(UploadWifiGate.UNKNOWN, first.start())
        assertEquals(UploadWifiGate.UNKNOWN, first.check())
        first.close()
        val observer = Observer()
        val second = UploadWifiGate({ throw SecurityException("Test-only probe failure") }, observer, {})
        assertEquals(UploadWifiGate.UNKNOWN, second.start())
        second.close()
        assertEquals(1, observer.closed)
    }

    @Test fun callbackAlreadyProbingAtCloseCannotDisconnectTheNextTransfer() {
        val observer = Observer()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val calls = AtomicInteger()
        var delay = false
        val gate = UploadWifiGate({
            if (delay) {
                entered.countDown()
                check(release.await(5, TimeUnit.SECONDS))
                nonWifi()
            } else wifi()
        }, observer) { calls.incrementAndGet() }
        assertNull(gate.start())
        delay = true
        val callback = Thread { observer.changed() }.apply { start() }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            gate.close()
        } finally { release.countDown(); callback.join(5000) }
        assertFalse(callback.isAlive)
        observer.changed()
        assertEquals(0, calls.get())
        assertEquals(1, observer.closed)
    }

    @Test fun closeDuringRegistrationClosesTheLateSubscriptionWithoutProbing() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val closed = AtomicInteger()
        val probed = AtomicInteger()
        val observer = UploadWifiGate.Observer {
            entered.countDown()
            check(release.await(5, TimeUnit.SECONDS))
            Closeable { closed.incrementAndGet() }
        }
        val gate = UploadWifiGate({ probed.incrementAndGet(); wifi() }, observer, {})
        val start = Thread { gate.start() }.apply { start() }
        try {
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            gate.close()
        } finally { release.countDown(); start.join(5000) }
        assertFalse(start.isAlive)
        assertEquals(1, closed.get())
        assertEquals(0, probed.get())
    }

    @Test fun policySeparatesWifiFromCostAndFailsClosedForMixedOrOldVpnRoutes() {
        val wifi = NetworkCapabilities.TRANSPORT_WIFI
        val vpn = NetworkCapabilities.TRANSPORT_VPN
        val cell = NetworkCapabilities.TRANSPORT_CELLULAR
        val ethernet = NetworkCapabilities.TRANSPORT_ETHERNET
        for (sdk in listOf(21, 23, 27, 28, 35)) {
            assertEquals(UploadWifiGate.State.ALLOWED, UploadWifiGate.classify(sdk, setOf(wifi), true))
            assertEquals(UploadWifiGate.State.NON_WIFI, UploadWifiGate.classify(sdk, setOf(cell), true))
            assertEquals(UploadWifiGate.State.NON_WIFI, UploadWifiGate.classify(sdk, setOf(ethernet), true))
            assertEquals(UploadWifiGate.State.UNKNOWN, UploadWifiGate.classify(sdk, setOf(wifi, cell), true))
            assertEquals(UploadWifiGate.State.UNKNOWN, UploadWifiGate.classify(sdk, setOf(wifi, 40), true))
            assertEquals(UploadWifiGate.State.UNKNOWN, UploadWifiGate.classify(sdk, setOf(vpn), true))
            assertEquals(UploadWifiGate.State.UNKNOWN, UploadWifiGate.classify(sdk, setOf(wifi), false))
            assertEquals(if (sdk >= 28) UploadWifiGate.State.ALLOWED else UploadWifiGate.State.UNKNOWN,
                UploadWifiGate.classify(sdk, setOf(wifi, vpn), true))
            assertEquals(UploadWifiGate.State.UNKNOWN, UploadWifiGate.classify(sdk, setOf(wifi, vpn, cell), true))
        }
    }

    private fun capabilities(vararg transports: Int): NetworkCapabilities =
        ShadowNetworkCapabilities.newInstance().also { caps ->
            Shadows.shadowOf(caps).clearCapabilities()
            Shadows.shadowOf(caps).addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            transports.forEach { Shadows.shadowOf(caps).addTransportType(it) }
        }

    @Suppress("DEPRECATION")
    private fun setupWifi(): Pair<ConnectivityManager, Network> {
        val context = RuntimeEnvironment.getApplication()
        val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val shadow = Shadows.shadowOf(manager)
        shadow.clearAllNetworks()
        shadow.setDefaultNetworkActive(true)
        shadow.setActiveNetworkInfo(ShadowNetworkInfo.newInstance(NetworkInfo.DetailedState.CONNECTED,
            ConnectivityManager.TYPE_WIFI, 0, true, true))
        val network = ShadowNetwork.newInstance(ConnectivityManager.TYPE_WIFI)
        // Deliberately metered Wi-Fi: cost is independent of this policy.
        shadow.setNetworkCapabilities(network, capabilities(NetworkCapabilities.TRANSPORT_WIFI))
        return manager to network
    }

    @Test @Config(sdk = [21, 23, 24, 28, 35])
    fun platformWatcherRegistersAndRemovesCallbacksAndLegacyDefaultChangeReceiver() {
        val (manager, network) = setupWifi()
        val context = RuntimeEnvironment.getApplication()
        val shadow = Shadows.shadowOf(manager)
        val app = Shadows.shadowOf(context)
        val action = Intent(ConnectivityManager.CONNECTIVITY_ACTION)
        val originalCallbacks = shadow.networkCallbacks.toSet()
        val originalReceivers = app.getReceiversForIntent(action).size
        val notices = mutableListOf<String>()
        val gate = UploadWifiGate(context, notices::add)
        assertNull(gate.start())
        val callback = (shadow.networkCallbacks - originalCallbacks).single()
        assertEquals(originalReceivers + if (Build.VERSION.SDK_INT <= 23) 1 else 0,
            app.getReceiversForIntent(action).size)
        gate.close()
        assertEquals(originalCallbacks, shadow.networkCallbacks)
        assertEquals(originalReceivers, app.getReceiversForIntent(action).size)
        callback.onLost(network)
        assertTrue(notices.isEmpty())
    }

    @Test @Config(sdk = [21, 28, 35])
    fun unsafeCapabilityEventStopsEvenIfSynchronousSnapshotStillSaysWifi() {
        val (manager, network) = setupWifi()
        val original = Shadows.shadowOf(manager).networkCallbacks.toSet()
        val notices = mutableListOf<String>()
        val gate = UploadWifiGate(RuntimeEnvironment.getApplication(), notices::add)
        assertNull(gate.start())
        val callback = (Shadows.shadowOf(manager).networkCallbacks - original).single()
        callback.onCapabilitiesChanged(network, capabilities(NetworkCapabilities.TRANSPORT_CELLULAR))
        assertEquals(listOf(UploadWifiGate.WAITING), notices)
        assertEquals(UploadWifiGate.WAITING, gate.check())
        gate.close()
    }

    @Test @Config(sdk = [28, 35])
    fun newDefaultAvailableEventStopsWhileSynchronousDefaultStillSaysOldWifi() {
        val (manager, oldWifi) = setupWifi()
        val shadow = Shadows.shadowOf(manager)
        val original = shadow.networkCallbacks.toSet()
        val notices = mutableListOf<String>()
        val gate = UploadWifiGate(RuntimeEnvironment.getApplication(), notices::add)
        assertNull(gate.start())
        val newDefault = ShadowNetwork.newInstance(100)
        val callback = (shadow.networkCallbacks - original).single()
        assertEquals(oldWifi, manager.activeNetwork)
        callback.onAvailable(newDefault)
        // The violation callback is what disconnects blocked IO; it must run
        // before another worker-side check or a synchronous snapshot catches up.
        assertEquals(listOf(UploadWifiGate.UNKNOWN), notices)
        assertEquals(UploadWifiGate.UNKNOWN, gate.currentViolation())
        callback.onCapabilitiesChanged(newDefault, capabilities(NetworkCapabilities.TRANSPORT_CELLULAR))
        assertEquals(1, notices.size)
        assertEquals(oldWifi, manager.activeNetwork)
        gate.close()
    }

    @Test @Config(sdk = [28, 35])
    fun newDefaultCapabilityEventCannotValidateUsingOldWifiSnapshot() {
        val (manager, oldWifi) = setupWifi()
        val shadow = Shadows.shadowOf(manager)
        val original = shadow.networkCallbacks.toSet()
        val notices = mutableListOf<String>()
        val gate = UploadWifiGate(RuntimeEnvironment.getApplication(), notices::add)
        assertNull(gate.start())
        val newDefault = ShadowNetwork.newInstance(100)
        (shadow.networkCallbacks - original).single().onCapabilitiesChanged(newDefault,
            capabilities(NetworkCapabilities.TRANSPORT_CELLULAR))
        assertEquals(oldWifi, manager.activeNetwork)
        assertEquals(listOf(UploadWifiGate.UNKNOWN), notices)
        assertEquals(UploadWifiGate.UNKNOWN, gate.currentViolation())
        gate.close()
    }

    @Test @Config(sdk = [21, 23])
    fun legacyAllNetworkEventsForUnrelatedCellularDoNotStopWifiUpload() {
        val (manager, _) = setupWifi()
        val shadow = Shadows.shadowOf(manager)
        val original = shadow.networkCallbacks.toSet()
        val notices = mutableListOf<String>()
        val gate = UploadWifiGate(RuntimeEnvironment.getApplication(), notices::add)
        assertNull(gate.start())
        val cellular = ShadowNetwork.newInstance(100)
        shadow.addNetwork(cellular, ShadowNetworkInfo.newInstance(NetworkInfo.DetailedState.CONNECTED,
            ConnectivityManager.TYPE_MOBILE, 0, true, true))
        val cellCapabilities = capabilities(NetworkCapabilities.TRANSPORT_CELLULAR)
        shadow.setNetworkCapabilities(cellular, cellCapabilities)
        val callback = (shadow.networkCallbacks - original).single()
        callback.onAvailable(cellular)
        callback.onCapabilitiesChanged(cellular, cellCapabilities)
        assertNull(gate.check())
        callback.onLost(cellular)
        assertNull(gate.check())
        assertTrue(notices.isEmpty())
        gate.close()
    }

    @Test @Config(sdk = [21, 28, 35])
    fun lostRouteIsUnknownEvenBeforeSynchronousNetworkStateUpdates() {
        val (manager, network) = setupWifi()
        val original = Shadows.shadowOf(manager).networkCallbacks.toSet()
        val notices = mutableListOf<String>()
        val gate = UploadWifiGate(RuntimeEnvironment.getApplication(), notices::add)
        assertNull(gate.start())
        (Shadows.shadowOf(manager).networkCallbacks - original).single().onLost(network)
        assertEquals(listOf(UploadWifiGate.UNKNOWN), notices)
        assertEquals(UploadWifiGate.UNKNOWN, gate.check())
        gate.close()
    }

    @Test @Config(sdk = [35])
    fun blockedDefaultNetworkStopsBeforeAnyFurtherWrite() {
        val (manager, network) = setupWifi()
        val original = Shadows.shadowOf(manager).networkCallbacks.toSet()
        val gate = UploadWifiGate(RuntimeEnvironment.getApplication(), {})
        assertNull(gate.start())
        (Shadows.shadowOf(manager).networkCallbacks - original).single().onBlockedStatusChanged(network, true)
        assertEquals(UploadWifiGate.UNKNOWN, gate.check())
        gate.close()
    }

    @Test @Config(sdk = [21])
    fun legacyUnderlyingWifiInformationDoesNotProveVpnUsesOnlyWifi() {
        val (manager, _) = setupWifi()
        val vpn = ShadowNetwork.newInstance(17)
        Shadows.shadowOf(manager).addNetwork(vpn, ShadowNetworkInfo.newInstance(NetworkInfo.DetailedState.CONNECTED,
            ConnectivityManager.TYPE_VPN, 0, true, true))
        Shadows.shadowOf(manager).setNetworkCapabilities(vpn, capabilities(NetworkCapabilities.TRANSPORT_VPN))
        val gate = UploadWifiGate(RuntimeEnvironment.getApplication(), {})
        assertEquals(UploadWifiGate.UNKNOWN, gate.start())
        gate.close()
    }

    @Test @Config(sdk = [21, 23])
    fun legacyConnectivityBroadcastRechecksDefaultEvenWhenOldWifiRemainsConnected() {
        val (manager, _) = setupWifi()
        val context = RuntimeEnvironment.getApplication()
        val gate = UploadWifiGate(context, {})
        assertNull(gate.start())
        Shadows.shadowOf(manager).setActiveNetworkInfo(ShadowNetworkInfo.newInstance(NetworkInfo.DetailedState.CONNECTED,
            ConnectivityManager.TYPE_MOBILE, 0, true, true))
        val mobile = ShadowNetwork.newInstance(ConnectivityManager.TYPE_MOBILE)
        Shadows.shadowOf(manager).setNetworkCapabilities(mobile, capabilities(NetworkCapabilities.TRANSPORT_CELLULAR))
        val intent = Intent(ConnectivityManager.CONNECTIVITY_ACTION)
        Shadows.shadowOf(context).getReceiversForIntent(intent).forEach { it.onReceive(context, intent) }
        assertEquals(UploadWifiGate.WAITING, gate.currentViolation())
        gate.close()
    }
}
