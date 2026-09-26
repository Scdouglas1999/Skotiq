package com.example.nightshade_mobile

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.util.Log
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Voice Control bridge for Google Assistant App Actions.
 *
 * Two flows meet here:
 *
 *   * Outbound: Dart calls the `nightshade/voice_control` MethodChannel
 *     with the latest sequence snapshot. We push that as a dynamic
 *     ShortcutManagerCompat shortcut so Assistant + launcher can surface
 *     the current target / frame count.
 *
 *   * Inbound: the Assistant fires `nightshade://voice-action/<wireId>`
 *     intents (declared in res/xml/shortcuts.xml). onNewIntent / the
 *     launch intent decode the wire id from the URI and forward it to
 *     Dart over the same MethodChannel as a `voice_control.onAction`
 *     call.
 *
 * Channel name, JSON schema, and wire ids must stay in lockstep with:
 *   * apps/mobile/lib/services/voice_control_service.dart
 *   * apps/mobile/android/app/src/main/res/xml/shortcuts.xml
 */
class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "VoiceControl"
        private const val CHANNEL = "nightshade/voice_control"
        private const val DYNAMIC_SHORTCUT_ID = "current_status"
        private const val VOICE_ACTION_HOST = "voice-action"
        private const val VOICE_ACTION_SCHEME = "nightshade"

        // Wire ids — MUST match VoiceControlAction.wireId in
        // apps/mobile/lib/services/voice_control_service.dart.
        private val KNOWN_WIRE_IDS = setOf(
            "pause_sequence",
            "resume_sequence",
            "open_last_image",
            "refresh_status",
        )
    }

    private var methodChannel: MethodChannel? = null

    /**
     * Holds the wire id parsed from the launch intent so it can be
     * dispatched as soon as Flutter sets up its inbound method handler.
     * Without this, an intent that launches the app cold would have its
     * action dropped because Dart isn't listening yet.
     */
    private var pendingLaunchAction: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        )
        channel.setMethodCallHandler { call, result ->
            handleVoiceControlCall(call, result)
        }
        methodChannel = channel

        // FCM push registration bridge — the Android counterpart of the APNs
        // wiring in ios/Runner/AppDelegate.swift. Dormant (reports
        // `fcm_unconfigured`) until google-services.json is provisioned.
        PushBridge.attach(
            applicationContext,
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                PushBridge.CHANNEL,
            ),
        )

        // OTA update installs. Dart verifies the APK against a vendor-signed
        // manifest and then asks this bridge to hand it to Android's package
        // installer, which is the only thing permitted to replace the app.
        UpdateInstallerBridge.attach(
            applicationContext,
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                UpdateInstallerBridge.CHANNEL,
            ),
        )

        // If onCreate parsed a launch intent before the channel existed,
        // flush it now. Dart's handler attaches to the channel during
        // VoiceControlService construction; this happens once
        // ProviderScope materialises the lifecycle controller. To avoid
        // racing, we keep retrying via a short post until the inbound
        // side ACKs OR we give up. In practice the first post lands
        // because the lifecycle provider is constructed eagerly by main.
        pendingLaunchAction?.let { wireId ->
            dispatchInboundAction(wireId)
            pendingLaunchAction = null
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Parse the launch intent so a cold start via an Assistant
        // shortcut still carries the action through to Dart. The actual
        // dispatch happens in configureFlutterEngine once the channel
        // is ready.
        intent?.let { incoming ->
            extractWireId(incoming)?.let { wireId ->
                pendingLaunchAction = wireId
                Log.i(TAG, "onCreate: queued voice action '$wireId' for dispatch")
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Warm-start path: app was already running, Assistant fired a
        // shortcut at us. Forward immediately.
        extractWireId(intent)?.let { wireId ->
            Log.i(TAG, "onNewIntent: dispatching voice action '$wireId'")
            if (methodChannel != null) {
                dispatchInboundAction(wireId)
            } else {
                pendingLaunchAction = wireId
            }
        }
    }

    /**
     * Decode the `nightshade://voice-action/<wireId>` URI into the wire id.
     * Returns null if the intent isn't a voice-control URI or the wire id
     * is unknown. Unrecognised ids are never forwarded, so a typo fails here
     * instead of silently no-opping on the Dart side.
     */
    private fun extractWireId(intent: Intent): String? {
        if (intent.action != Intent.ACTION_VIEW) return null
        val data: Uri = intent.data ?: return null
        if (data.scheme != VOICE_ACTION_SCHEME) return null
        if (data.host != VOICE_ACTION_HOST) return null
        val path = data.pathSegments?.firstOrNull() ?: return null
        if (path !in KNOWN_WIRE_IDS) {
            Log.w(TAG, "Ignoring unknown voice action wire id: '$path'")
            return null
        }
        return path
    }

    private fun dispatchInboundAction(wireId: String) {
        methodChannel?.invokeMethod(
            "onAction",
            mapOf("action" to wireId),
        )
    }

    private fun handleVoiceControlCall(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "publishStatus" -> {
                val args = call.arguments as? Map<*, *>
                if (args == null) {
                    result.error(
                        "invalid_arguments",
                        "publishStatus expected a Map argument, got ${call.arguments?.javaClass?.name}",
                        null,
                    )
                    return
                }
                try {
                    publishDynamicStatusShortcut(args)
                    result.success(null)
                } catch (e: Throwable) {
                    Log.e(TAG, "publishStatus failed", e)
                    result.error(
                        "publish_status_failed",
                        e.message ?: "Unknown error pushing voice status shortcut",
                        e.toString(),
                    )
                }
            }
            "clearStatus" -> {
                try {
                    ShortcutManagerCompat.removeDynamicShortcuts(
                        applicationContext,
                        listOf(DYNAMIC_SHORTCUT_ID),
                    )
                    result.success(null)
                } catch (e: Throwable) {
                    Log.e(TAG, "clearStatus failed", e)
                    result.error(
                        "clear_status_failed",
                        e.message ?: "Unknown error clearing voice status shortcut",
                        e.toString(),
                    )
                }
            }
            "isSupported" -> {
                // ShortcutManagerCompat works back to API 14, but
                // pushDynamicShortcut is more useful from API 25+ where
                // the launcher actually exposes long-press shortcuts. We
                // return true on all supported platforms (minSdk is set
                // in build.gradle.kts) — the cache write itself never
                // throws on older OS versions, it just produces no
                // visible UI element.
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Push or update the dynamic "current_status" shortcut with the
     * latest snapshot. The shortcut's short label carries the spoken
     * summary so Assistant can quote it back without launching the app.
     *
     * Keys read from `args` mirror `SequenceStatusSnapshot.toJson()` in
     * voice_control_service.dart.
     */
    private fun publishDynamicStatusShortcut(args: Map<*, *>) {
        val ctx: Context = applicationContext
        val sequenceName = (args["sequenceName"] as? String).orEmptyTrimmed()
        val targetName = (args["targetName"] as? String).orEmptyTrimmed()
        val executionState = (args["executionState"] as? String).orEmptyTrimmed()
        val framesCompleted = (args["framesCompleted"] as? Number)?.toInt() ?: 0
        val framesTotal = (args["framesTotal"] as? Number)?.toInt() ?: 0
        val etaSeconds = (args["estimatedRemainingSeconds"] as? Number)?.toInt()

        val summary = composeSpokenSummary(
            executionState = executionState,
            targetName = targetName.ifBlank { sequenceName },
            framesCompleted = framesCompleted,
            framesTotal = framesTotal,
            etaSeconds = etaSeconds,
        )

        // Short label is what Assistant speaks; long label is what the
        // launcher shows on long-press. Both have ~25 and ~50 char
        // ceilings — we trim with explicit ellipsis to keep ourselves
        // honest.
        val shortLabel = summary.take(25)
        val longLabel = summary.take(80)

        val launchIntent = Intent(ctx, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            data = Uri.parse("nightshade://voice-action/refresh_status")
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_CLEAR_TOP
        }

        val info = ShortcutInfoCompat.Builder(ctx, DYNAMIC_SHORTCUT_ID)
            .setShortLabel(shortLabel)
            .setLongLabel(longLabel)
            .setIcon(IconCompat.createWithResource(ctx, R.mipmap.ic_launcher))
            .setIntent(launchIntent)
            .setLongLived(true)
            .build()

        // pushDynamicShortcut is the right call for "replace if exists,
        // else add (within the per-app quota)". On API 30+ it backs
        // directly to ShortcutManager#pushDynamicShortcut which also
        // hints the launcher to refresh.
        ShortcutManagerCompat.pushDynamicShortcut(ctx, info)
    }

    /**
     * Mirror the Dart `SequenceStatusSnapshot.toSpokenSummary` logic so
     * the user hears consistent language across iOS and Android.
     */
    private fun composeSpokenSummary(
        executionState: String,
        targetName: String,
        framesCompleted: Int,
        framesTotal: Int,
        etaSeconds: Int?,
    ): String {
        val target = targetName.ifBlank { "the current target" }
        return when (executionState) {
            "idle" -> "No sequence is active."
            "completed" ->
                "Sequence finished. $framesCompleted of $framesTotal frames captured on $target."
            "failed" -> "Sequence failed on target $target."
            "paused" ->
                "Sequence is paused on target $target. $framesCompleted of $framesTotal frames complete."
            "stopping" ->
                "Sequence is stopping. $framesCompleted of $framesTotal frames complete on $target."
            "recovering" -> "Sequence is recovering on target $target."
            "running" -> {
                val eta = formatEta(etaSeconds)
                "Sequence is running on $target. " +
                    "$framesCompleted of $framesTotal frames complete.$eta"
            }
            else -> "Nightshade is in an unknown state: $executionState."
        }
    }

    private fun formatEta(seconds: Int?): String {
        if (seconds == null || seconds <= 0) return ""
        if (seconds < 60) return " Less than a minute remaining."
        val totalMinutes = (seconds + 30) / 60
        if (totalMinutes < 60) return " About $totalMinutes minutes remaining."
        val hours = totalMinutes / 60
        val remMinutes = totalMinutes % 60
        val hourWord = if (hours == 1) "hour" else "hours"
        return if (remMinutes == 0) {
            " About $hours $hourWord remaining."
        } else {
            " About $hours $hourWord $remMinutes minutes remaining."
        }
    }

    private fun String?.orEmptyTrimmed(): String = this?.trim() ?: ""
}
