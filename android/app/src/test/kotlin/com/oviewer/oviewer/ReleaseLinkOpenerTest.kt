package com.oviewer.oviewer

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28])
class ReleaseLinkOpenerTest {
    private class Result : MethodChannel.Result {
        var value: Any? = null
        override fun success(result: Any?) { value = result }
        override fun error(code: String, message: String?, details: Any?) { value = code }
        override fun notImplemented() { value = "notImplemented" }
    }
    class NoBrowserActivity : Activity() {
        override fun startActivity(intent: Intent) { throw ActivityNotFoundException() }
    }
    private val url = "https://github.com/fy142857/OViewer/releases/tag/v1.2.0"

    @Test fun opensReleaseWithBrowserSelector() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val result = Result()
        ReleaseLinkOpener(activity).onMethodCall(MethodCall("open", url), result)
        assertEquals(true, result.value)
        val intent = Shadows.shadowOf(activity).nextStartedActivity
        assertEquals(url, intent.data.toString())
        assertEquals(Intent.ACTION_VIEW, intent.action)
        assertTrue(intent.selector?.hasCategory(Intent.CATEGORY_APP_BROWSER) == true)
    }
    @Test fun missingBrowserReturnsFalse() {
        val activity = Robolectric.buildActivity(NoBrowserActivity::class.java).setup().get()
        val result = Result()
        ReleaseLinkOpener(activity).onMethodCall(MethodCall("open", url), result)
        assertEquals(false, result.value)
    }
    @Test fun invalidUrlDoesNotLaunch() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        for (invalid in listOf("https://example.com", url.replace("https:", "http:"), "$url?x=1")) {
            val result = Result()
            ReleaseLinkOpener(activity).onMethodCall(MethodCall("open", invalid), result)
            assertEquals(false, result.value)
            assertNull(Shadows.shadowOf(activity).nextStartedActivity)
        }
    }
}
