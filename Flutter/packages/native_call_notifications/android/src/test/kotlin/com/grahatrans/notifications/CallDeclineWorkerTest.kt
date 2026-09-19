package com.grahatrans.notifications

import android.content.Context
import android.content.Intent
import androidx.work.*
import androidx.work.testing.*
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.RecordedRequest
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class CallDeclineWorkerTest {
    private val context get() = RuntimeEnvironment.getApplication() as Context
    private val prefs get() = context.getSharedPreferences("tms_native_call_notifications", Context.MODE_PRIVATE)
    private lateinit var server: MockWebServer
    private var status = 204
    private val requests = java.util.concurrent.CopyOnWriteArrayList<String>()
    private lateinit var endpoint: String

    @Before fun setup() {
        WorkManagerTestInitHelper.initializeTestWorkManager(context,
            Configuration.Builder().setExecutor(SynchronousExecutor()).build())
        prefs.edit().clear().commit()
        server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                requests.add(request.method + " " + request.path)
                requests.add(request.body.readUtf8())
                return MockResponse().setResponseCode(status)
            }
        }
        server.start()
        endpoint = server.url("/api/calls/call-1/decline").toString()
    }

    @After fun cleanup() {
        server.shutdown()
        WorkManagerTestInitHelper.closeWorkDatabase()
    }

    private fun worker(attempt: Int = 0): CallDeclineWorker =
        TestListenableWorkerBuilder<CallDeclineWorker>(context)
            .setInputData(Data.Builder().putString("endpoint", endpoint).putString("token", "device-token").build())
            .setRunAttemptCount(attempt).build()

    @Test fun coldReceiverQueuesDeclineEvenIfSystemUiAlreadyRemovedTheNotification() {
        // Only disk state exists: no activity, Flutter engine, or notification.
        prefs.edit().putInt("ringingId", 7).putString("token", "device-token")
            .putString("baseUrl", server.url("/").toString()).commit()
        val intent = Intent().putExtra("tms.call.id", 7)
            .putExtra("tms.call.expires", System.currentTimeMillis() + 40000)
            .putExtra("tms.call.payload", "{\"data\":{\"callId\":\"call-1\"}}")
        RejectCallReceiver().onReceive(context, intent)
        val manager = WorkManager.getInstance(context)
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        var work = manager.getWorkInfosForUniqueWork("decline-call:call-1").get()
        while ((work.isEmpty() || prefs.contains("ringingId")) && System.nanoTime() < deadline) {
            Thread.sleep(10)
            work = manager.getWorkInfosForUniqueWork("decline-call:call-1").get()
        }
        assertEquals(1, work.size)
        assertEquals(WorkInfo.State.ENQUEUED, work.single().state)
        assertFalse(prefs.contains("ringingId"))
        assertTrue(requests.isEmpty())
        // Once a network is available, the queued job uses the saved credentials.
        WorkManagerTestInitHelper.getTestDriver(context)!!.setAllConstraintsMet(work.single().id)
        assertEquals(WorkInfo.State.SUCCEEDED, manager.getWorkInfoById(work.single().id).get()!!.state)
        assertEquals("POST /api/calls/call-1/native-decline", requests[0])
        assertEquals("device-token", JSONObject(requests[1]).getString("deviceToken"))
    }

    @Test fun transientServerFailureRetriesAndThenSucceedsWithoutFlutter() {
        status = 503
        assertEquals(ListenableWorker.Result.retry(), worker().doWork())
        status = 204
        assertEquals(ListenableWorker.Result.success(), worker(1).doWork())
        assertEquals(4, requests.size)
    }

    @Test fun lostNetworkIsRetriedButRetriesAreBounded() {
        server.shutdown()
        assertEquals(ListenableWorker.Result.retry(), worker().doWork())
        assertEquals(ListenableWorker.Result.failure(), worker(5).doWork())
    }

    @Test fun authenticationFailureAndRedirectAreNotTreatedAsSuccess() {
        status = 401
        assertEquals(ListenableWorker.Result.failure(), worker().doWork())
        status = 307
        assertEquals(ListenableWorker.Result.failure(), worker().doWork())
    }

    @Test fun cancelledNotificationDoesNotQueueADecline() {
        RejectCallReceiver().onReceive(context, Intent().putExtra("tms.call.id", 7)
            .putExtra("tms.call.expires", System.currentTimeMillis() + 40000)
            .putExtra("tms.call.payload", "{\"data\":{\"callId\":\"call-1\"}}"))
        assertTrue(WorkManager.getInstance(context).getWorkInfosForUniqueWork("decline-call:call-1").get().isEmpty())
    }
}
