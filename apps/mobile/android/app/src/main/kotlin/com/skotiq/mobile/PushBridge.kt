package com.skotiq.mobile

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import android.util.Log
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Android half of the `skotiq/push` MethodChannel. The iOS half lives in
 * ios/Runner/AppDelegate.swift and speaks APNs; this side speaks FCM with the
 * same contract so apps/mobile/lib/services/push_registration_service.dart can
 * drive both platforms through one flow:
 *
 *   * `registerForRemoteNotifications` — kicks off an async FCM token fetch;
 *     the token lands in Dart via `onFcmToken` (or an error via
 *     `onFcmRegistrationError`), mirroring the APNs callback pair.
 *   * `getFcmToken` — the most recent token this process has seen, so a token
 *     issued before Dart attached its handler is never dropped.
 *
 * Provisioning gate: without `app/google-services.json` the Google-services
 * Gradle plugin is not applied (see build.gradle.kts) and
 * `FirebaseApp.initializeApp` returns null. Every entry point checks that and
 * reports `fcm_unconfigured` instead of throwing, so a LAN-only build with no
 * Firebase project keeps working unchanged.
 */
object PushBridge {
    private const val TAG = "SkotiqPush"
    const val CHANNEL = "skotiq/push"

    /**
     * Channel id the host's FCM sender targets (`buildFcmMessage` in
     * skotiq_remote_protocol sets `android.notification.channel_id` to
     * this). It must exist client-side before the first push arrives or
     * Android renders background notifications on a synthesized
     * default-importance channel with no sound.
     */
    private const val NOTIFICATION_CHANNEL_ID = "skotiq_critical"

    @Volatile private var cachedToken: String? = null
    @Volatile private var dartChannel: MethodChannel? = null

    fun attach(context: Context, channel: MethodChannel) {
        dartChannel = channel
        ensureNotificationChannel(context)
        channel.setMethodCallHandler { call, result ->
            handle(context, call, result)
        }
    }

    /** Called by [SkotiqPushService] when FCM rotates the token. */
    fun onTokenRefreshed(token: String) {
        cachedToken = token
        dartChannel?.invokeMethod("onFcmToken", token)
    }

    private fun firebaseReady(context: Context): Boolean =
        FirebaseApp.getApps(context).isNotEmpty() ||
            FirebaseApp.initializeApp(context) != null

    private fun handle(
        context: Context,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "registerForRemoteNotifications" -> {
                if (!firebaseReady(context)) {
                    Log.i(
                        TAG,
                        "FCM not configured (no google-services.json); " +
                            "push registration dormant",
                    )
                    result.error(
                        "fcm_unconfigured",
                        "Firebase is not provisioned in this build",
                        null,
                    )
                    return
                }
                FirebaseMessaging.getInstance().token
                    .addOnSuccessListener { token ->
                        cachedToken = token
                        dartChannel?.invokeMethod("onFcmToken", token)
                    }
                    .addOnFailureListener { e ->
                        Log.w(TAG, "FCM token fetch failed", e)
                        dartChannel?.invokeMethod(
                            "onFcmRegistrationError",
                            e.message ?: "token fetch failed",
                        )
                    }
                result.success(true)
            }
            "getFcmToken" -> result.success(cachedToken)
            else -> result.notImplemented()
        }
    }

    private fun ensureNotificationChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE)
            as NotificationManager
        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            "Critical imaging alerts",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description =
                "Sequence failures, safety warnings, and other alerts " +
                    "from the imaging host"
        }
        // Idempotent: re-creating an existing channel is a no-op that never
        // downgrades user-chosen importance.
        manager.createNotificationChannel(channel)
    }
}
