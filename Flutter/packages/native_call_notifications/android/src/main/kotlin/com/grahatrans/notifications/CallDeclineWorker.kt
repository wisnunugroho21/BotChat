package com.grahatrans.notifications

import android.content.Context
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.work.*
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.TimeUnit

/** Delivers a notification decline even after the receiver/Flutter process exits. */
class CallDeclineWorker(context: Context, parameters: WorkerParameters) : Worker(context, parameters) {
    override fun doWork(): Result {
        val endpoint = inputData.getString("endpoint") ?: return Result.failure()
        val token = inputData.getString("token") ?: return Result.failure()
        var connection: HttpURLConnection? = null
        try {
            connection = URL(endpoint).openConnection() as HttpURLConnection
            connection.apply {
                requestMethod = "POST"
                connectTimeout = 15000
                readTimeout = 15000
                instanceFollowRedirects = false
                doOutput = true
                setRequestProperty("Content-Type", "application/json")
                outputStream.use {
                    it.write(JSONObject().put("deviceToken", token).toString().toByteArray(Charsets.UTF_8))
                }
            }
            val status = connection.responseCode
            if (status in 200..299) return Result.success()
            Log.w(TAG, "Call rejection failed: HTTP $status (attempt ${runAttemptCount + 1})")
            return if (status >= 500 || status == 408 || status == 429) retryOrFail() else Result.failure()
        } catch (error: IOException) {
            // Do not log URLs or tokens; they can contain credentials.
            Log.w(TAG, "Call rejection network failure (attempt ${runAttemptCount + 1}): ${error.javaClass.simpleName}")
            return retryOrFail()
        } finally {
            connection?.disconnect()
        }
    }

    private fun retryOrFail(): Result = if (runAttemptCount < 5) Result.retry() else Result.failure()

    companion object {
        private const val TAG = "tms-incoming-call"

        fun enqueue(context: Context, callId: String, baseUrl: String, token: String): Operation {
            require(callId.isNotBlank())
            val endpoint = Uri.parse(baseUrl).buildUpon().appendPath("api")
                .appendPath("calls").appendPath(callId).appendPath("native-decline").build().toString()
            val request = OneTimeWorkRequest.Builder(CallDeclineWorker::class.java)
                .setInputData(Data.Builder().putString("endpoint", endpoint).putString("token", token).build())
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .setBackoffCriteria(BackoffPolicy.LINEAR, 10, TimeUnit.SECONDS)
            // Older Android versions run ordinary work immediately when possible;
            // expedited work there would require another foreground notification.
            if (Build.VERSION.SDK_INT >= 31) {
                request.setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            }
            return WorkManager.getInstance(context).enqueueUniqueWork(
                "decline-call:$callId", ExistingWorkPolicy.KEEP, request.build())
        }
    }
}
