package com.oviewer.oviewer

import android.app.NotificationManager
import android.content.Context
import android.os.Build
import android.widget.Toast

class SponsorSavedToast(private val context: Context) {
    private var legacyCleared = false

    fun show(message: String) {
        if (message.isBlank()) return
        if (!legacyCleared) {
            legacyCleared = true
            // Remove only the previous sponsorship notification channel.
            runCatching {
                val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                if (Build.VERSION.SDK_INT >= 26) manager.deleteNotificationChannel("sponsor_image_saves")
                else if (Build.VERSION.SDK_INT >= 23) manager.activeNotifications
                    .filter { it.tag?.startsWith("sponsor-save-") == true }
                    .forEach { manager.cancel(it.tag, it.id) }
            }
        }
        // Use system text Toast without requesting notification or overlay access.
        // OEM background-popup controls can still block it (e.g. Huawei).
        Toast.makeText(context, message, Toast.LENGTH_SHORT).show()
    }
}
