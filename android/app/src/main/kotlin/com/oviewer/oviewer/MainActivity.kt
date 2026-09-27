package com.oviewer.oviewer

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private var exporter: PageImageExporter? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        exporter = PageImageExporter(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "oviewer/page_image_export")
            .setMethodCallHandler(exporter)
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (exporter?.permissionResult(requestCode, grantResults) != true) {
            super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        }
    }
    override fun onDestroy() { exporter?.dispose(); super.onDestroy() }
}
