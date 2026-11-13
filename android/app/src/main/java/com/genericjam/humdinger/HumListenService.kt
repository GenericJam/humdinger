package com.genericjam.humdinger

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * Keeps the microphone running while another app (FMutate) is in front: a
 * foreground service of type microphone with an ongoing notification that
 * shows what Humdinger hears ("A4 −12¢ → FMutate A · ch 1") and carries
 * Pause / Record / Stop buttons.
 *
 * Driven from the `hum_audio` NIF (c_src/hum_audio.c) through
 * [HumListenBridge]: `Humdinger.Background.start/2`, `update/1`, `stop/0`.
 * A button press reaches the BEAM through [HumListenBridge.nativeAction],
 * which the NIF registers, as `{:background, action}`.
 *
 * Android only lets an app start a microphone foreground service while it is
 * in the foreground (Android 14+ enforces it), and the microphone keeps
 * working in the background only under one (Android 11+).
 */
class HumListenService : Service() {

    override fun onCreate() {
        super.onCreate()
        HumListenBridge.attach(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == HumListenBridge.ACTION_BUTTON) {
            val button = intent.getStringExtra(HumListenBridge.EXTRA_BUTTON) ?: return START_NOT_STICKY
            val delivered = try {
                HumListenBridge.nativeAction(button)
            } catch (e: UnsatisfiedLinkError) {
                false
            }
            // Nobody listening for the buttons (the BEAM restarted): Stop must
            // still take the notification away.
            if (!delivered && button == "stop") stopSelf()
            return START_NOT_STICKY
        }
        try {
            val notification = HumListenBridge.build(this)
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(HumListenBridge.NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(HumListenBridge.NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            // Android 14+: not allowed now (the app isn't in the foreground,
            // or RECORD_AUDIO was revoked).
            Log.e(TAG, "startForeground refused", e)
            try {
                HumListenBridge.nativeAction("failed")
            } catch (_: UnsatisfiedLinkError) {
            }
            stopSelf()
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        HumListenBridge.detach(this)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    companion object {
        private const val TAG = "HumListenService"
    }
}

/**
 * The service's JNI face: static methods the NIF calls, and the native
 * callback it registers. Notice updates are coalesced on the main thread to
 * at most one post every [MIN_POST_MS] (Android drops notifications posted
 * faster than about 5 a second).
 */
object HumListenBridge {
    const val NOTIFICATION_ID = 4410
    const val ACTION_BUTTON = "com.genericjam.humdinger.listen.BUTTON"
    const val EXTRA_BUTTON = "button"
    private const val CHANNEL_ID = "humdinger_listening"
    private const val MIN_POST_MS = 250L
    private const val STATE_PAUSED = 1
    private const val STATE_RECORDING = 2

    private val main = Handler(Looper.getMainLooper())

    @Volatile private var title = "Humdinger · listening"
    @Volatile private var text = ""
    @Volatile private var state = 0

    // Main thread only.
    private var service: HumListenService? = null
    private var lastPost = 0L
    private var postPending = false

    /** A notification button: true if a BEAM process took it. Registered by the NIF. */
    @JvmStatic external fun nativeAction(action: String): Boolean

    /**
     * Start the service with this notice. null on success, else "permission"
     * (no RECORD_AUDIO) or "refused" (Android won't start it now).
     */
    @JvmStatic
    fun start(context: Context, title: String, text: String, state: Int): String? {
        if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            return "permission"
        }
        setNotice(title, text, state)
        val intent = Intent(context, HumListenService::class.java)
        return try {
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
            main.post { requestPost() }
            null
        } catch (e: Exception) {
            Log.e("HumListenService", "startForegroundService refused", e)
            "refused"
        }
    }

    @JvmStatic
    fun update(title: String, text: String, state: Int) {
        setNotice(title, text, state)
        main.post { requestPost() }
    }

    @JvmStatic
    fun stop(context: Context) {
        context.stopService(Intent(context, HumListenService::class.java))
    }

    private fun setNotice(title: String, text: String, state: Int) {
        this.title = title
        this.text = text
        this.state = state
    }

    fun attach(s: HumListenService) {
        service = s
    }

    fun detach(s: HumListenService) {
        if (service === s) service = null
    }

    private fun requestPost() {
        if (service == null || postPending) return
        val wait = lastPost + MIN_POST_MS - SystemClock.uptimeMillis()
        if (wait <= 0) {
            post()
        } else {
            postPending = true
            main.postDelayed({
                postPending = false
                post()
            }, wait)
        }
    }

    private fun post() {
        val s = service ?: return
        lastPost = SystemClock.uptimeMillis()
        val nm = s.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, build(s))
    }

    fun build(context: Context): Notification {
        if (Build.VERSION.SDK_INT >= 26) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(CHANNEL_ID, "Listening", NotificationManager.IMPORTANCE_LOW).apply {
                        description = "Shown while Humdinger listens in the background"
                        setShowBadge(false)
                    }
                )
            }
        }
        val open = context.packageManager.getLaunchIntentForPackage(context.packageName)?.let {
            PendingIntent.getActivity(context, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }
        val s = state
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_hum_listening)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .addAction(0, if (s == STATE_PAUSED) "Resume" else "Pause", button(context, if (s == STATE_PAUSED) "resume" else "pause", 1))
            .addAction(0, if (s == STATE_RECORDING) "Stop rec" else "Record", button(context, if (s == STATE_RECORDING) "record_stop" else "record", 2))
            .addAction(0, "Stop", button(context, "stop", 3))
        if (open != null) builder.setContentIntent(open)
        return builder.build()
    }

    private fun button(context: Context, action: String, code: Int): PendingIntent {
        val intent = Intent(context, HumListenService::class.java)
            .setAction(ACTION_BUTTON)
            .putExtra(EXTRA_BUTTON, action)
        return PendingIntent.getService(context, code, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }
}
