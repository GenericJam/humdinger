// Humdinger's file share and print on Android, for Humdinger.Export
// (Elixir side: Humdinger.Export.Android, through humdinger_file_share_nif.zig).
//
// shareFile: an ACTION_SEND chooser with the file as a content:// URI from the
// app's FileProvider (${applicationId}.fileprovider, whose <cache-path
// path="."> covers cache/exports), read permission granted to the target.
// printPdf: PrintManager.print with an adapter that copies the PDF as is.
//
// Both answer "" once the dialog is asked for, else an error reason the NIF
// turns into {:error, :reason}: not_found, no_activity, no_app, failed. They
// run on the UI thread; the caller (a dirty NIF thread) waits for it briefly.
package com.genericjam.humdinger.share

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.print.PageRange
import android.print.PrintAttributes
import android.print.PrintDocumentAdapter
import android.print.PrintDocumentInfo
import android.print.PrintManager
import android.util.Log
import androidx.core.content.FileProvider
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.lang.ref.WeakReference
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

object HumdingerFileShareBridge : io.mob.plugin.MobActivityAware {
    @JvmStatic external fun nativeRegister()

    private const val TAG = "HumdingerFileShare"

    // How long the caller waits for the UI thread before taking "asked for"
    // as success.
    private const val UI_WAIT_MS = 2000L

    private val main = Handler(Looper.getMainLooper())

    @Volatile private var activityRef: WeakReference<Activity>? = null

    @JvmStatic
    fun register() {
        nativeRegister()
    }

    // MobActivityAware: called from MainActivity.onCreate on the main thread.
    override fun setActivity(activity: Activity) {
        activityRef = WeakReference(activity)
    }

    @JvmStatic
    fun shareFile(path: String, mime: String, title: String): String {
        val file = File(path)
        if (!file.isFile) return "not_found"
        return onUi { activity ->
            val uri = FileProvider.getUriForFile(activity, activity.packageName + ".fileprovider", file)
            val send = Intent(Intent.ACTION_SEND).apply {
                type = mime
                putExtra(Intent.EXTRA_STREAM, uri)
                putExtra(Intent.EXTRA_TITLE, title)
                putExtra(Intent.EXTRA_SUBJECT, title)
                // The grant travels with the ClipData through the chooser to
                // the chosen app.
                clipData = ClipData.newUri(activity.contentResolver, title, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            activity.startActivity(Intent.createChooser(send, title))
        }
    }

    @JvmStatic
    fun printPdf(path: String, title: String): String {
        val file = File(path)
        if (!file.isFile) return "not_found"
        return onUi { activity ->
            val printManager = activity.getSystemService(Context.PRINT_SERVICE) as PrintManager
            printManager.print(title, PdfAdapter(file), PrintAttributes.Builder().build())
        }
    }

    // Runs block on the UI thread with the current Activity and waits up to
    // UI_WAIT_MS for its outcome.
    private fun onUi(block: (Activity) -> Unit): String {
        val activity = activityRef?.get()
        if (activity == null || activity.isFinishing || activity.isDestroyed) return "no_activity"
        val result = AtomicReference("")
        val done = CountDownLatch(1)
        main.post {
            try {
                block(activity)
            } catch (e: ActivityNotFoundException) {
                result.set("no_app")
            } catch (e: Exception) {
                Log.w(TAG, "share/print failed", e)
                result.set("failed")
            } finally {
                done.countDown()
            }
        }
        done.await(UI_WAIT_MS, TimeUnit.MILLISECONDS)
        return result.get()
    }

    // Hands the finished PDF to the print framework unchanged.
    private class PdfAdapter(private val file: File) : PrintDocumentAdapter() {
        override fun onLayout(
            oldAttributes: PrintAttributes?,
            newAttributes: PrintAttributes,
            cancellationSignal: CancellationSignal,
            callback: LayoutResultCallback,
            extras: Bundle?,
        ) {
            if (cancellationSignal.isCanceled) {
                callback.onLayoutCancelled()
                return
            }
            val info = PrintDocumentInfo.Builder(file.name)
                .setContentType(PrintDocumentInfo.CONTENT_TYPE_DOCUMENT)
                .setPageCount(PrintDocumentInfo.PAGE_COUNT_UNKNOWN)
                .build()
            // The PDF is fixed, so only the first layout changes anything.
            callback.onLayoutFinished(info, oldAttributes == null)
        }

        override fun onWrite(
            pages: Array<out PageRange>,
            destination: ParcelFileDescriptor,
            cancellationSignal: CancellationSignal,
            callback: WriteResultCallback,
        ) {
            try {
                FileInputStream(file).use { input ->
                    FileOutputStream(destination.fileDescriptor).use { output ->
                        val buf = ByteArray(16 * 1024)
                        while (true) {
                            if (cancellationSignal.isCanceled) {
                                callback.onWriteCancelled()
                                return
                            }
                            val n = input.read(buf)
                            if (n < 0) break
                            output.write(buf, 0, n)
                        }
                    }
                }
                callback.onWriteFinished(arrayOf(PageRange.ALL_PAGES))
            } catch (e: Exception) {
                Log.w(TAG, "print write failed", e)
                callback.onWriteFailed(e.message)
            }
        }
    }
}
