package com.oviewer.oviewer

import android.app.Activity
import android.app.ActivityManager
import android.os.Build
import android.content.pm.ApplicationInfo

internal object AppTaskIdentity {
    @Suppress("DEPRECATION")
    fun apply(activity: Activity, debug: Boolean =
        (activity.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
        if (!debug) return
        val info = activity.applicationInfo
        val label = info.loadLabel(activity.packageManager).toString()
        // The retained Flutter engine may already have built its Title before
        // this Activity attaches. Give every new Debug task its manifest label.
        activity.setTaskDescription(if (Build.VERSION.SDK_INT >= 28) {
            ActivityManager.TaskDescription(label, info.icon)
        } else {
            ActivityManager.TaskDescription(label)
        })
    }
}
