package com.oviewer.oviewer

import android.app.Activity
import android.content.ClipData
import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.os.Build
import android.provider.MediaStore
import android.provider.OpenableColumns
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowContentResolver
import org.robolectric.shadows.ShadowStatFs
import java.io.File
import java.util.concurrent.Executor

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [21, 35])
class UploadFileImporterTest {
    private class Result : MethodChannel.Result {
        var value: Any? = null
        var error: String? = null
        var calls = 0
        override fun success(result: Any?) { value = result; calls++ }
        override fun error(code: String, message: String?, details: Any?) { error = code; calls++ }
        override fun notImplemented() { error = "notImplemented"; calls++ }
    }

    class Documents : ContentProvider() {
        lateinit var first: File
        lateinit var second: File
        override fun onCreate() = true
        override fun getType(uri: Uri): String = "image/gif"
        override fun query(uri: Uri, projection: Array<out String>?, selection: String?, args: Array<out String>?, order: String?): Cursor =
            MatrixCursor(arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)).apply {
                val file = if (uri.lastPathSegment == "1") first else second
                addRow(arrayOf("../../同名.gif", file.length()))
            }
        override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor =
            ParcelFileDescriptor.open(if (uri.lastPathSegment == "1") first else second, ParcelFileDescriptor.MODE_READ_ONLY)
        override fun insert(uri: Uri, values: ContentValues?): Uri? = null
        override fun update(uri: Uri, values: ContentValues?, selection: String?, args: Array<out String>?) = 0
        override fun delete(uri: Uri, selection: String?, args: Array<out String>?) = 0
    }

    private fun fixture(executor: Executor = Executor { it.run() }): Triple<Activity, UploadFileImporter, Documents> {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        ShadowStatFs.registerStats(activity.getDir("flutter", Context.MODE_PRIVATE).canonicalPath, 100_000, 90_000, 80_000)
        val provider = Documents().apply {
            first = File(activity.cacheDir, "first.gif").apply { writeBytes(byteArrayOf(71, 73, 70, 56, 57, 97, 1, 2, 3)) }
            second = File(activity.cacheDir, "second.gif").apply { writeBytes(byteArrayOf(71, 73, 70, 56, 57, 97, 9, 8, 7)) }
        }
        provider.attachInfo(activity, ProviderInfo().apply {
            authority = "upload-test"
            exported = true
            grantUriPermissions = true
        })
        ShadowContentResolver.registerProviderInternal("upload-test", provider)
        Shadows.shadowOf(activity.contentResolver).registerInputStreamSupplier(Uri.parse("content://upload-test/1")) { provider.first.inputStream() }
        Shadows.shadowOf(activity.contentResolver).registerInputStreamSupplier(Uri.parse("content://upload-test/2")) { provider.second.inputStream() }
        val importer = UploadFileImporter(activity, executor).apply { attach(activity) }
        return Triple(activity, importer, provider)
    }

    @Test fun opensMultiSelectDocumentsWithoutBroadStoragePermission() {
        val (activity, importer, _) = fixture()
        val result = Result()
        importer.onMethodCall(MethodCall("pickFiles", null), result)
        val started = Shadows.shadowOf(activity).nextStartedActivityForResult
        assertEquals(Intent.ACTION_OPEN_DOCUMENT, started.intent.action)
        assertTrue(started.intent.hasCategory(Intent.CATEGORY_OPENABLE))
        assertTrue(started.intent.getBooleanExtra(Intent.EXTRA_ALLOW_MULTIPLE, false))
        assertEquals(UploadFileImporter.REQUEST_CODE, started.requestCode)
        assertNull(result.error)
        importer.onActivityResult(UploadFileImporter.REQUEST_CODE, Activity.RESULT_CANCELED, null)
        assertEquals(true, (result.value as Map<*, *>)["cancelled"])
        assertEquals(1, result.calls)
        importer.dispose()
    }

    @Test fun importsOriginalBytesToUniqueSafeNamesAndPreservesOrder() {
        val (activity, importer, provider) = fixture()
        val result = Result()
        importer.onMethodCall(MethodCall("pickFiles", null), result)
        val clip = ClipData.newRawUri("files", Uri.parse("content://upload-test/1"))
        clip.addItem(ClipData.Item(Uri.parse("content://upload-test/2")))
        importer.onActivityResult(UploadFileImporter.REQUEST_CODE, Activity.RESULT_OK, Intent().apply { clipData = clip })
        Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
        val response = result.value as Map<*, *>
        val files = (response["files"] as List<*>).map { it as Map<*, *> }
        assertEquals(false, response["cancelled"])
        assertEquals(emptyList<Any>(), response["errors"])
        assertEquals(2, files.size)
        val root = File(activity.getDir("flutter", Context.MODE_PRIVATE), "uploads")
        val paths = files.map { File(root, it["relativePath"] as String).canonicalFile }
        assertNotEquals(paths[0], paths[1])
        paths.forEach { assertTrue(it.path.startsWith(root.canonicalPath + File.separator)); assertFalse(it.name.contains("同名")) }
        assertArrayEquals(provider.first.readBytes(), paths[0].readBytes())
        assertArrayEquals(provider.second.readBytes(), paths[1].readBytes())
        assertEquals("../../同名.gif", files[0]["displayName"])
        assertTrue(provider.first.exists()); assertTrue(provider.second.exists())
        assertEquals(1, result.calls)
        importer.dispose()
    }

    @Test fun cancellationBeforeWorkerStartsLeavesNoCopiesAndCanPickAgain() {
        val queued = mutableListOf<Runnable>()
        val (activity, importer, _) = fixture(Executor { queued.add(it) })
        val result = Result()
        importer.onMethodCall(MethodCall("pickFiles", null), result)
        importer.onActivityResult(UploadFileImporter.REQUEST_CODE, Activity.RESULT_OK,
            Intent().setData(Uri.parse("content://upload-test/1")))
        importer.onMethodCall(MethodCall("cancelImport", null), Result())
        queued.removeAt(0).run()
        Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
        assertEquals(true, (result.value as Map<*, *>)["cancelled"])
        assertEquals(emptyList<Any>(), (result.value as Map<*, *>)["files"])
        val imports = File(activity.getDir("flutter", Context.MODE_PRIVATE), "uploads/imports")
        assertEquals(0, imports.listFiles()?.size ?: 0)
        val retry = Result()
        importer.onMethodCall(MethodCall("pickPhotos", null), retry)
        assertNull(retry.error)
        importer.onActivityResult(UploadFileImporter.REQUEST_CODE, Activity.RESULT_CANCELED, null)
        importer.dispose()
    }

    @Test fun rejectsCallerPathsAndNonContentUrisWithoutReadingThem() {
        val (_, importer, _) = fixture()
        val invalid = Result()
        importer.onMethodCall(MethodCall("pickFiles", mapOf("root" to "/outside")), invalid)
        assertEquals("invalid_arguments", invalid.error)
        val result = Result()
        importer.onMethodCall(MethodCall("pickFiles", null), result)
        importer.onActivityResult(UploadFileImporter.REQUEST_CODE, Activity.RESULT_OK,
            Intent().setData(Uri.parse("file:///outside/secret.jpg")))
        val response = result.value as Map<*, *>
        assertEquals(emptyList<Any>(), response["files"])
        assertEquals("unsupported_uri", ((response["errors"] as List<*>)[0] as Map<*, *>)["reason"])
        importer.dispose()
    }

    @Test fun busyAndDuplicateCallbacksCannotCompleteAnotherSelection() {
        val (_, importer, _) = fixture()
        val first = Result()
        importer.onMethodCall(MethodCall("pickFiles", null), first)
        val second = Result()
        importer.onMethodCall(MethodCall("pickPhotos", null), second)
        assertEquals("busy", second.error)
        importer.onActivityResult(UploadFileImporter.REQUEST_CODE, Activity.RESULT_CANCELED, null)
        importer.onActivityResult(UploadFileImporter.REQUEST_CODE, Activity.RESULT_CANCELED, null)
        assertEquals(1, first.calls)
        importer.dispose()
    }

    @Test fun oldPickerResultAfterCancellationCannotCancelNewPicker() {
        val (activity, importer, _) = fixture()
        val first = Result()
        importer.onMethodCall(MethodCall("pickFiles", null), first)
        val firstCode = Shadows.shadowOf(activity).nextStartedActivityForResult.requestCode
        importer.onMethodCall(MethodCall("cancelImport", null), Result())
        val second = Result()
        importer.onMethodCall(MethodCall("pickFiles", null), second)
        val secondCode = Shadows.shadowOf(activity).nextStartedActivityForResult.requestCode
        assertNotEquals(firstCode, secondCode)
        importer.onActivityResult(firstCode, Activity.RESULT_CANCELED, null)
        assertEquals(0, second.calls)
        importer.onActivityResult(secondCode, Activity.RESULT_CANCELED, null)
        assertEquals(1, first.calls)
        assertEquals(1, second.calls)
        importer.dispose()
    }

    @Test fun insufficientStorageReportsFailureAndPreservesSource() {
        val (activity, importer, provider) = fixture()
        ShadowStatFs.registerStats(activity.getDir("flutter", Context.MODE_PRIVATE).canonicalPath, 100_000, 1, 1)
        val result = Result()
        importer.onMethodCall(MethodCall("pickFiles", null), result)
        importer.onActivityResult(UploadFileImporter.REQUEST_CODE, Activity.RESULT_OK,
            Intent().setData(Uri.parse("content://upload-test/1")))
        val response = result.value as Map<*, *>
        assertEquals(emptyList<Any>(), response["files"])
        assertEquals("insufficient_storage", ((response["errors"] as List<*>)[0] as Map<*, *>)["reason"])
        assertTrue(provider.first.exists())
        importer.dispose()
    }

    @Test fun activityRecreationKeepsPendingSelectionInOwner() {
        val (firstActivity, importer, _) = fixture()
        val result = Result()
        importer.onMethodCall(MethodCall("pickFiles", null), result)
        importer.detach(firstActivity)
        val replacement = Robolectric.buildActivity(Activity::class.java).setup().get()
        importer.attach(replacement)
        importer.onActivityResult(UploadFileImporter.REQUEST_CODE, Activity.RESULT_CANCELED, null)
        assertEquals(true, (result.value as Map<*, *>)["cancelled"])
        assertEquals(1, result.calls)
        importer.dispose()
    }

    @Test fun photoSelectionUsesSupportedPickerAtEachApiLevel() {
        val (activity, importer, _) = fixture()
        importer.onMethodCall(MethodCall("pickPhotos", null), Result())
        val started = Shadows.shadowOf(activity).nextStartedActivityForResult
        assertEquals(if (Build.VERSION.SDK_INT >= 33) MediaStore.ACTION_PICK_IMAGES else Intent.ACTION_OPEN_DOCUMENT, started.intent.action)
        assertEquals("image/*", started.intent.type)
        importer.onActivityResult(started.requestCode, Activity.RESULT_CANCELED, null)
        importer.dispose()
    }

    @Test fun pendingSelectionRetainsOwnerUntilCancellation() {
        val activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val states = mutableListOf<Boolean>()
        val importer = UploadFileImporter(activity, Executor { it.run() }, states::add).apply { attach(activity) }
        importer.onMethodCall(MethodCall("pickFiles", null), Result())
        assertEquals(listOf(true), states)
        importer.detach(activity)
        assertEquals(listOf(true), states)
        importer.onMethodCall(MethodCall("cancelImport", null), Result())
        assertEquals(listOf(true, false), states)
        importer.dispose()
    }
}
