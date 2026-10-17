package com.skotiq.mobile

import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * FCM service entry points.
 *
 * Displaying a background push needs no code here: the host sends a
 * `notification` payload targeting the `skotiq_critical` channel
 * (created by [PushBridge]), which Android renders automatically while the
 * app is backgrounded or dead — the exact situation FCM exists for.
 *
 * Foreground messages are deliberately NOT re-surfaced as notifications:
 * on-LAN the UDP receiver (lan_push_notification_receiver.dart) already
 * alerts in the foreground, so rendering the FCM copy would double-notify.
 * This mirrors iOS, where foreground APNs banners are likewise suppressed.
 */
class SkotiqPushService : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        Log.i("SkotiqPush", "FCM token rotated")
        PushBridge.onTokenRefreshed(token)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        // Notification-payload messages in the foreground are intentionally
        // dropped (see class doc). Data-only messages are not sent today.
    }
}
