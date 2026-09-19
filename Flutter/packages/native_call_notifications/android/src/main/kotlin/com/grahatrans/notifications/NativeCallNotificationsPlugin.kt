package com.grahatrans.notifications

import android.app.Service
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.IBinder
import android.os.Bundle
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

private const val CHANNEL = "tms/native_call_notifications"
private const val PREFERENCES = "tms_native_call_notifications"
private const val TAG = "tms-incoming-call"
private const val PAYLOAD = "tms.call.payload"
private const val ACTION = "tms.call.action"
private const val ID = "tms.call.id"
private const val EXPIRES = "tms.call.expires"

class NativeCallNotificationsPlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    ActivityAware, PluginRegistry.NewIntentListener {
    private lateinit var context: Context
    private lateinit var channel: MethodChannel
    private var activityBinding: ActivityPluginBinding? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }
    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "setWebRingtoneOwner" -> {
                    IncomingCallService.webOwnsRingtone = call.argument<Boolean>("active") == true
                    if (IncomingCallService.webOwnsRingtone) IncomingCallService.cancel(context)
                    result.success(null)
                }
                "show" -> { show(call); result.success(null) }
                "cancel" -> { IncomingCallService.cancel(context, call.argument<Int>("id")); result.success(null) }
                "clear" -> {
                    IncomingCallService.cancel(context)
                    result.success(null)
                }
                "configure" -> {
                    prefs().edit().putString("token", call.argument<String>("token"))
                        .putString("baseUrl", call.argument<String>("baseUrl")).apply()
                    result.success(null)
                }
                "takeAction" -> {
                    val pending = prefs().getString("pending", null)
                    prefs().edit().remove("pending").apply()
                    result.success(pending)
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error("call_notification", error.message, null)
        }
    }
    private fun manager() = context.getSystemService(NotificationManager::class.java)
    private fun prefs() = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

    private fun show(call: MethodCall) {
        if (IncomingCallService.webOwnsRingtone) return
        val id = call.argument<Int>("id")!!
        val payload = call.argument<String>("payload")!!
        val title = call.argument<String>("title")!!.ifBlank { "Incoming call" }
        val channelId = call.argument<String>("channelId")!!
        val duration = call.argument<Int>("timeoutMs")!!.toLong()
        val expires = System.currentTimeMillis() + duration
        if (Build.VERSION.SDK_INT >= 26) {
            val notificationChannel = NotificationChannel(channelId,
                "Panggilan masuk", NotificationManager.IMPORTANCE_HIGH)
            notificationChannel.setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE),
                AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE).build())
            notificationChannel.enableVibration(true)
            notificationChannel.setShowBadge(false)
            manager().createNotificationChannel(notificationChannel)
        }
        fun activityIntent(action: String): PendingIntent {
            val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)!!
                .setAction("$CHANNEL.$action")
                .setData(Uri.parse("tms-call://$action/$id"))
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                .putExtra(PAYLOAD, payload).putExtra(ACTION, action)
                .putExtra(ID, id).putExtra(EXPIRES, expires)
            return PendingIntent.getActivity(context, id, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        }
        val reject = Intent(context, RejectCallReceiver::class.java)
            .setData(Uri.parse("tms-call://reject/$id"))
            .putExtra(PAYLOAD, payload).putExtra(ID, id).putExtra(EXPIRES, expires)
        val rejectIntent = PendingIntent.getBroadcast(context, id, reject,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val person = Person.Builder().setName(title).setImportant(true).build()
        val notification = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(context.applicationInfo.icon)
            .setContentTitle(title).setContentText(call.argument<String>("body"))
            .setStyle(NotificationCompat.CallStyle.forIncomingCall(person, rejectIntent, activityIntent("accept"))
                .setIsVideo(call.argument<Boolean>("isVideo") == true))
            .setContentIntent(activityIntent("open"))
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            // Used on Android 7; Android 8+ reads sound from the call channel.
            .setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE))
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .addExtras(Bundle().apply { putBoolean(TAG, true) })
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setOngoing(true).setAutoCancel(false).setTimeoutAfter(duration)
            .build()
        // Android owns playback and stops it when this notification is removed.
        notification.flags = notification.flags or Notification.FLAG_INSISTENT
        prefs().edit().putInt("ringingId", id).apply()
        ContextCompat.startForegroundService(context, Intent(context, IncomingCallService::class.java)
            .putExtra(ID, id).putExtra(EXPIRES, expires).putExtra("notification", notification))
    }

    private fun capture(intent: Intent?) : Boolean {
        val payload = intent?.getStringExtra(PAYLOAD) ?: return false
        val id = intent.getIntExtra(ID, 0)
        val active = manager().activeNotifications.any { it.notification.extras.getBoolean(TAG) && it.id == id }
        val action = intent.getStringExtra(ACTION)
        val valid = active && System.currentTimeMillis() < intent.getLongExtra(EXPIRES, 0)
        IncomingCallService.cancel(context, id)
        intent.removeExtra(PAYLOAD)
        // A stale Accept must never answer a different/newer call by this caller.
        if (action == "accept" && !valid) return true
        prefs().edit().putString("pending", JSONObject()
            .put("action", action).put("payload", payload).toString()).apply()
        channel.invokeMethod("actionAvailable", null)
        return true
    }
    override fun onNewIntent(intent: Intent) = capture(intent)
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addOnNewIntentListener(this)
        capture(binding.activity.intent)
    }
    override fun onDetachedFromActivity() {
        IncomingCallService.webOwnsRingtone = false
        activityBinding?.removeOnNewIntentListener(this)
        activityBinding = null
    }
    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)
}

/** Keeps the ringing CallStyle valid on Android 12/13 without auto-opening UI. */
class IncomingCallService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    override fun onCreate() { super.onCreate(); running = this }
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // A queued service start must not briefly ring after the browser takes over.
        if (webOwnsRingtone) { finish(); return START_NOT_STICKY }
        @Suppress("DEPRECATION")
        val notification = intent?.getParcelableExtra<Notification>("notification")
        if (notification == null) { finish(); return START_NOT_STICKY }
        val id = intent.getIntExtra(ID, 0)
        handler.removeCallbacksAndMessages(null)
        stopForeground(STOP_FOREGROUND_REMOVE)
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(id, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SHORT_SERVICE)
        } else {
            startForeground(id, notification)
        }
        val prefs = getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        val remaining = intent.getLongExtra(EXPIRES, 0) - System.currentTimeMillis()
        // Cancellation can arrive between startForegroundService and onStartCommand.
        if (prefs.getInt("ringingId", -1) != id || remaining <= 0) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf(startId)
        } else {
            handler.postDelayed({ cancel(this, id) }, remaining)
        }
        return START_NOT_STICKY
    }
    fun finish() {
        handler.removeCallbacksAndMessages(null)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }
    override fun onTimeout(startId: Int) { cancel(this) }
    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        if (running === this) running = null
        super.onDestroy()
    }
    companion object {
        // Shared across Flutter engines/FCM isolates, reset on process death.
        @Volatile var webOwnsRingtone = false
        private var running: IncomingCallService? = null
        fun cancel(context: Context, id: Int? = null) {
            val prefs = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
            val currentId = prefs.getInt("ringingId", -1)
            if (id != null && id != currentId) return
            prefs.edit().remove("ringingId").apply()
            running?.finish()
        }
    }
}

/** Reject without opening the activity or requiring a running Flutter engine. */
class RejectCallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getIntExtra(ID, 0)
        val prefs = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        // System UI may already have removed the notification when delivering
        // the action. The service's persisted ID also survives a cold process.
        if (prefs.getInt("ringingId", -1) != id) return
        if (System.currentTimeMillis() >= intent.getLongExtra(EXPIRES, 0)) return
        val payload = intent.getStringExtra(PAYLOAD) ?: return
        val pending = goAsync()
        executor.execute {
            try {
                val token = prefs.getString("token", null)
                val baseUrl = prefs.getString("baseUrl", null)
                check(!token.isNullOrBlank() && !baseUrl.isNullOrBlank()) {
                    "Native call rejection has not been configured"
                }
                val callId = JSONObject(payload).getJSONObject("data").getString("callId")
                // Keep the broadcast alive only until the job is persisted.
                // Network delivery and retries must outlive this receiver.
                CallDeclineWorker.enqueue(context, callId, baseUrl, token)
                    .result.get(8, TimeUnit.SECONDS)
                IncomingCallService.cancel(context, id)
            } catch (error: Exception) {
                Log.e(TAG, "Call rejection could not be queued", error)
            } finally {
                pending?.finish()
            }
        }
    }
    companion object { private val executor = Executors.newSingleThreadExecutor() }
}
