package com.oviewer.oviewer

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.os.Bundle
import org.json.JSONObject
import java.io.File

/** A dependency-free instrumented check of the real OS/Keystore path. */
class UploadTransferInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }
    override fun onStart() {
        val status = Bundle().apply {
            putString("class", this@UploadTransferInstrumentation.javaClass.name); putString("test", "nativeUidtAndKeystore")
            putInt("numtests", 1); putInt("current", 1)
        }
        sendStatus(1, status)
        try {
            val activity = startActivitySync(Intent(targetContext, UploadValidationActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as UploadValidationActivity
            waitForIdleSync()
            val fixture = context.assets.open("uploaded.html").use { it.readBytes() }
            val report = activity.validate(fixture)
            File(targetContext.cacheDir, "issue83-native-device.json").writeText(JSONObject(report).toString(2))
            status.putString("stream", "Native UIDT, AndroidKeyStore and background batch checks passed.\n")
            sendStatus(0, status)
            finish(Activity.RESULT_OK, Bundle().apply { putString("stream", "OK (1 instrumented test)\n") })
        } catch (error: Throwable) {
            status.putString("stack", error.stackTraceToString())
            status.putString("stream", "Native upload validation failed.\n")
            sendStatus(-2, status)
            finish(Activity.RESULT_CANCELED, Bundle().apply { putString("stream", "FAILURES!!!\n") })
        }
    }
}
