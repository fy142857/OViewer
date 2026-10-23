package com.oviewer.oviewer

import android.app.Activity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class AutomaticLoginCheckTest {
    private class Result : MethodChannel.Result {
        var value: Any? = null
        override fun success(result: Any?) { value = result }
        override fun error(code: String, message: String?, details: Any?) { value = code }
        override fun notImplemented() { value = "notImplemented" }
    }
    private fun call(bridge: AutomaticLoginCheck, name: String, id: Int): Any? {
        val result = Result()
        bridge.onMethodCall(MethodCall(name, mapOf("id" to id)), result)
        return result.value
    }
    @Test fun requestsAreExclusiveAndStaleCloseCannotReleaseAnotherRequest() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val bridge = AutomaticLoginCheck(activity)
        assertEquals(true, call(bridge,"begin",1))
        assertEquals(false, call(bridge,"begin",2))
        call(bridge,"close",2)
        assertEquals(false, call(bridge,"begin",2))
        call(bridge,"close",1)
        assertEquals(true, call(bridge,"begin",2))
        call(bridge,"close",1)
        assertEquals(false, call(bridge,"begin",3))
        bridge.dispose()
    }
    @Test fun hostDisposalReleasesAnAbandonedRequest() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val bridge = AutomaticLoginCheck(activity)
        assertEquals(true, call(bridge,"begin",1))
        bridge.dispose()
        assertEquals(true, call(bridge,"begin",2))
        bridge.dispose()
    }
}
