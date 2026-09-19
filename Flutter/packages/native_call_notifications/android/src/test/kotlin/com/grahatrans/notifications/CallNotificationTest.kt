package com.grahatrans.notifications

import android.app.Notification
import android.app.NotificationManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.BinaryMessenger
import java.lang.reflect.Proxy
import org.junit.Assert.*
import org.junit.Before
import org.junit.After
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Robolectric
import org.robolectric.android.controller.ServiceController
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class CallNotificationTest {
    private lateinit var plugin: NativeCallNotificationsPlugin
    private lateinit var manager: NotificationManager
    private lateinit var serviceController: ServiceController<IncomingCallService>
    private var lastResult: Any? = null
    private val result = object : MethodChannel.Result {
        override fun success(value: Any?) { lastResult = value }
        override fun error(code: String, message: String?, details: Any?) { fail("$code: $message") }
        override fun notImplemented() { fail("Not implemented") }
    }
    @Before fun setup() {
        IncomingCallService.webOwnsRingtone = false
        val context = RuntimeEnvironment.getApplication()
        context.applicationInfo.icon = android.R.drawable.sym_call_incoming
        manager = context.getSystemService(NotificationManager::class.java)
        plugin = NativeCallNotificationsPlugin()
        plugin.javaClass.getDeclaredField("context").apply { isAccessible = true }.set(plugin, context)
        val messenger = Proxy.newProxyInstance(BinaryMessenger::class.java.classLoader,
            arrayOf(BinaryMessenger::class.java)) { _, _, _ -> null } as BinaryMessenger
        plugin.javaClass.getDeclaredField("channel").apply { isAccessible = true }
            .set(plugin, MethodChannel(messenger, "test"))
        // The test application needs a launchable activity for notification taps.
        val activity = android.content.pm.ActivityInfo().apply {
            packageName = context.packageName
            name = "android.app.Activity"
            exported = true
        }
        shadowOf(context.packageManager).addActivityIfNotPresent(android.content.ComponentName(activity.packageName, activity.name))
        val intent = android.content.Intent(android.content.Intent.ACTION_MAIN).addCategory(android.content.Intent.CATEGORY_LAUNCHER).setPackage(context.packageName)
        shadowOf(context.packageManager).addResolveInfoForIntent(intent, android.content.pm.ResolveInfo().apply { activityInfo = activity })
        serviceController = Robolectric.buildService(IncomingCallService::class.java).create()
    }
    @After fun cleanup() { serviceController.destroy(); IncomingCallService.webOwnsRingtone = false }
    private fun show(id: Int) {
        plugin.onMethodCall(MethodCall("show", mapOf(
        "id" to id, "title" to "Budi", "payload" to "{\"data\":{\"callId\":\"call-1\"}}",
        "channelId" to "test-calls", "timeoutMs" to 40000, "isVideo" to true
        )), result)
        val start = shadowOf(RuntimeEnvironment.getApplication()).nextStartedService
        assertEquals(IncomingCallService::class.java.name, start.component!!.className)
        serviceController.get().onStartCommand(start, 0, id)
    }

    @Test fun incomingCallHasOngoingStyleAndDistinctActions() {
        show(1)
        val notification = manager.activeNotifications.single().notification
        assertFalse(shadowOf(serviceController.get()).isForegroundStopped)
        assertTrue(notification.flags and Notification.FLAG_ONGOING_EVENT != 0)
        assertTrue(notification.flags and Notification.FLAG_INSISTENT != 0)
        val channel = manager.getNotificationChannel(notification.channelId)
        assertEquals(android.media.RingtoneManager.getDefaultUri(android.media.RingtoneManager.TYPE_RINGTONE), channel.sound)
        assertEquals(android.media.AudioAttributes.USAGE_NOTIFICATION_RINGTONE, channel.audioAttributes.usage)
        assertTrue(channel.shouldVibrate())
        assertEquals(0, notification.flags and Notification.FLAG_AUTO_CANCEL)
        assertEquals(40000L, notification.timeoutAfter)
        assertEquals("android.app.Notification\$CallStyle", notification.extras.getString(Notification.EXTRA_TEMPLATE))
        assertEquals("open", shadowOf(notification.contentIntent).savedIntent.getStringExtra("tms.call.action"))
        assertEquals(2, notification.actions.size)
        val intents = notification.actions.map { shadowOf(it.actionIntent).savedIntent }
        assertTrue(intents.any { it.getStringExtra("tms.call.action") == "accept" })
        assertTrue(intents.any { it.component?.className == RejectCallReceiver::class.java.name })
    }
    @Test fun cancellationTargetsOneCallAndPageOpeningClearsRemainingCalls() {
        show(1); show(2)
        plugin.onMethodCall(MethodCall("cancel", mapOf("id" to 1)), result)
        assertEquals(2, manager.activeNotifications.single().id)
        plugin.onMethodCall(MethodCall("clear", null), result)
        assertTrue(manager.activeNotifications.isEmpty())
    }
    @Test fun browserOwnershipClearsNativeSoundAndSuppressesOtherEngines() {
        show(1)
        plugin.onMethodCall(MethodCall("setWebRingtoneOwner", mapOf("active" to true)), result)
        assertTrue(manager.activeNotifications.isEmpty())
        plugin.onMethodCall(MethodCall("show", emptyMap<String, Any>()), result)
        assertNull(shadowOf(RuntimeEnvironment.getApplication()).nextStartedService)
        plugin.onMethodCall(MethodCall("setWebRingtoneOwner", mapOf("active" to false)), result)
        show(2)
        assertEquals(2, manager.activeNotifications.single().id)
    }
    @Test fun queuedNativeStartCannotRingAfterBrowserTakesOwnership() {
        show(1)
        val notification = manager.activeNotifications.single().notification
        plugin.onMethodCall(MethodCall("setWebRingtoneOwner", mapOf("active" to true)), result)
        serviceController.get().onStartCommand(android.content.Intent().putExtra("notification", notification), 0, 2)
        assertTrue(manager.activeNotifications.isEmpty())
        assertTrue(shadowOf(serviceController.get()).isForegroundStopped)
    }
    @Test fun answerIsQueuedOnceAndClearsTheNotification() {
        show(1)
        val notification = manager.activeNotifications.single().notification
        val accept = notification.actions.map { shadowOf(it.actionIntent).savedIntent }
            .single { it.getStringExtra("tms.call.action") == "accept" }
        assertTrue(plugin.onNewIntent(accept))
        assertTrue(manager.activeNotifications.isEmpty())
        plugin.onMethodCall(MethodCall("takeAction", null), result)
        assertEquals("accept", org.json.JSONObject(lastResult as String).getString("action"))
        plugin.onMethodCall(MethodCall("takeAction", null), result)
        assertNull(lastResult)
        assertFalse(plugin.onNewIntent(accept))
    }
    @Test fun cancelledCallCannotBeAnsweredFromAStaleIntent() {
        show(1)
        val accept = manager.activeNotifications.single().notification.actions
            .map { shadowOf(it.actionIntent).savedIntent }
            .single { it.getStringExtra("tms.call.action") == "accept" }
        plugin.onMethodCall(MethodCall("cancel", mapOf("id" to 1)), result)
        plugin.onNewIntent(accept)
        plugin.onMethodCall(MethodCall("takeAction", null), result)
        assertNull(lastResult)
    }
    @Test fun bodyTapQueuesOpenWithoutAnswering() {
        show(1)
        val intent = shadowOf(manager.activeNotifications.single().notification.contentIntent).savedIntent
        plugin.onNewIntent(intent)
        assertTrue(manager.activeNotifications.isEmpty())
        plugin.onMethodCall(MethodCall("takeAction", null), result)
        assertEquals("open", org.json.JSONObject(lastResult as String).getString("action"))
    }
    @Test fun expiredAnswerIsIgnored() {
        show(1)
        val accept = manager.activeNotifications.single().notification.actions
            .map { shadowOf(it.actionIntent).savedIntent }
            .single { it.getStringExtra("tms.call.action") == "accept" }
        accept.putExtra("tms.call.expires", System.currentTimeMillis() - 1)
        plugin.onNewIntent(accept)
        assertTrue(manager.activeNotifications.isEmpty())
        plugin.onMethodCall(MethodCall("takeAction", null), result)
        assertNull(lastResult)
    }
    @Test fun unansweredCallStopsForegroundServiceAfterFortySeconds() {
        show(1)
        shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(39))
        assertFalse(shadowOf(serviceController.get()).isForegroundStopped)
        shadowOf(android.os.Looper.getMainLooper()).idleFor(java.time.Duration.ofSeconds(1))
        assertTrue(shadowOf(serviceController.get()).isForegroundStopped)
        assertTrue(manager.activeNotifications.isEmpty())
    }
}
