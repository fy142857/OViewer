package com.oviewer.oviewer

import android.app.Activity
import android.app.ActivityManager
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [21, 28, 35])
class AppTaskIdentityTest {
    class CapturingActivity : Activity() {
        var recorded: ActivityManager.TaskDescription? = null
        override fun setTaskDescription(description: ActivityManager.TaskDescription) {
            recorded = description
            super.setTaskDescription(description)
        }
    }
    @Test fun debugTaskUsesTheInstalledManifestLabel() {
        val activity = Robolectric.buildActivity(CapturingActivity::class.java).setup().get()
        activity.applicationInfo.nonLocalizedLabel = "OViewer Debug"
        AppTaskIdentity.apply(activity, debug = true)
        assertEquals("OViewer Debug", activity.recorded?.label)
    }

    @Suppress("DEPRECATION")
    @Test fun releaseTaskDescriptionIsNotChanged() {
        val activity = Robolectric.buildActivity(CapturingActivity::class.java).setup().get()
        activity.setTaskDescription(ActivityManager.TaskDescription("OViewer"))
        AppTaskIdentity.apply(activity, debug = false)
        assertEquals("OViewer", activity.recorded?.label)
    }
}
