package com.oviewer.oviewer

import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private var exporter: PageImageExporter? = null
    private var sponsor: SponsorBridge? = null
    private var updater: ApkUpdateBridge? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            // Keep the same window bounds when the reader toggles system bars.
            // DEFAULT excludes the cutout only in fullscreen on some devices,
            // moving every page when switching to/from edge-to-edge.
            window.attributes = window.attributes.apply {
                layoutInDisplayCutoutMode =
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
            }
        }
    }
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        updater = ApkUpdateBridge(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "oviewer/apk_update")
            .setMethodCallHandler(updater)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "oviewer/release_link")
            .setMethodCallHandler(ReleaseLinkOpener(this))
        sponsor = SponsorBridge(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "oviewer/sponsor")
            .setMethodCallHandler(sponsor)
        exporter = PageImageExporter(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "oviewer/page_image_export")
            .setMethodCallHandler(exporter)
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (sponsor?.permissionResult(requestCode, grantResults) != true && exporter?.permissionResult(requestCode, grantResults) != true) {
            super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        }
    }
    override fun onDestroy() { updater?.dispose(); sponsor?.dispose(); exporter?.dispose(); super.onDestroy() }
}
