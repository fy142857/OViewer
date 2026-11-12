package com.oviewer.oviewer

import android.app.Activity
import android.content.Context
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.LinearLayout
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
@Config(sdk = [28, 35])
class FloatingBackKeyboardBridgeTest {
    @Test fun dismissesFocusedInputWithoutFinishingActivity() {
        val host = Robolectric.buildActivity(Activity::class.java).setup()
        val activity = host.get()
        val root = LinearLayout(activity).apply { isFocusableInTouchMode = true }
        val input = EditText(activity)
        root.addView(input)
        activity.setContentView(root)
        input.requestFocus()
        assertTrue(input.hasFocus())
        val inputManager = activity.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        inputManager.showSoftInput(input, InputMethodManager.SHOW_IMPLICIT)
        assertTrue(Shadows.shadowOf(inputManager).isSoftInputVisible)
        var completed = false
        val result = object : MethodChannel.Result {
            override fun success(value: Any?) { completed = true }
            override fun error(code: String, message: String?, details: Any?) { fail(message) }
            override fun notImplemented() { fail("method missing") }
        }
        FloatingBackKeyboardBridge(activity).onMethodCall(MethodCall("hideKeyboard", null), result)
        assertTrue(completed)
        assertFalse(Shadows.shadowOf(inputManager).isSoftInputVisible)
        assertFalse(activity.isFinishing)
        host.pause().stop().destroy()
    }
}
