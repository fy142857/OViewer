package com.oviewer.oviewer

import android.os.Build
import android.os.Bundle
import android.content.Context
import android.content.Intent
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val runtime get() = application as OViewerApplication
    override fun provideFlutterEngine(context: Context): FlutterEngine = runtime.acquireEngine()
    override fun shouldDestroyEngineWithHost(): Boolean = false
    private var exporter: PageImageExporter? = null
    private var sponsor: SponsorBridge? = null
    private var automaticLoginCheck: AutomaticLoginCheck? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        AppTaskIdentity.apply(this)
        runtime.attach(this)
        if (intent?.action == OfflineDownloadService.OPEN) runtime.openDownloads()
        if (intent?.action == ApkDownloadService.OPEN) runtime.updates?.open(intent)
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
        automaticLoginCheck = AutomaticLoginCheck(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "oviewer/automatic_login_check")
            .setMethodCallHandler(automaticLoginCheck)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "oviewer/release_link")
            .setMethodCallHandler(ReleaseLinkOpener(this))
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "oviewer/account_registration")
            .setMethodCallHandler { call, result ->
                if (call.method != "open") { result.notImplemented() }
                else {
                    try {
                        val uri = android.net.Uri.parse("https://forums.e-hentai.org/index.php?act=Reg&CODE=00")
                        val intent = Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE)
                        intent.selector = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_APP_BROWSER)
                        startActivity(intent)
                        result.success(true)
                    } catch (_: android.content.ActivityNotFoundException) { result.success(false) }
                      catch (_: SecurityException) { result.success(false) }
                }
            }
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
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.action == OfflineDownloadService.OPEN) runtime.openDownloads()
        if (intent.action == ApkDownloadService.OPEN) runtime.updates?.open(intent)
    }
    override fun onResume() { super.onResume(); runtime.setForeground(this, true) }
    override fun onPause() { runtime.setForeground(this, false); super.onPause() }
    override fun onDestroy() {
        sponsor?.dispose(); exporter?.dispose()
        automaticLoginCheck?.dispose()
        flutterEngine?.let { engine ->
            for (name in listOf("oviewer/release_link", "oviewer/account_registration", "oviewer/automatic_login_check", "oviewer/sponsor", "oviewer/page_image_export")) {
                MethodChannel(engine.dartExecutor.binaryMessenger, name).setMethodCallHandler(null)
            }
        }
        super.onDestroy()
        runtime.detach(this)
    }
}
