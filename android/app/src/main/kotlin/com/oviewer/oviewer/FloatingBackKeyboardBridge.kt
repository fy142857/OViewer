package com.oviewer.oviewer

import android.app.Activity
import android.content.Context
import android.view.inputmethod.InputMethodManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Dismiss input within this Activity, including embedded WebViews. Never navigates. */
class FloatingBackKeyboardBridge(private val activity: Activity) : MethodChannel.MethodCallHandler {
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "hideKeyboard") { result.notImplemented(); return }
        val token = activity.window.decorView.windowToken
        activity.currentFocus?.clearFocus()
        val input = activity.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        input.hideSoftInputFromWindow(token, 0)
        result.success(null)
    }
}
