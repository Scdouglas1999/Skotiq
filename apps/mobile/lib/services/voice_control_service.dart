// Voice Control Service
//
// Bridges the running sequence state to platform-native voice assistants:
//
//   * iOS: Siri Shortcuts / AppIntents (iOS 16+). The App Intents extension
//     reads a JSON snapshot from a shared App Group UserDefaults suite each
//     time Siri asks "What's Skotiq doing?". Control intents
//     (pause/resume) come back to Dart through the same MethodChannel as an
//     inbound action.
//
//   * Android: App Actions / Assistant Shortcuts. The ShortcutManagerCompat
//     "dynamic shortcut" carrying the latest snapshot is pushed each time
//     Dart calls `publishSequenceStatus`. When Assistant dispatches one of
//     the shortcuts back to the app, MainActivity decodes the intent and
//     forwards it through the channel as an inbound action.
//
// JSON keys here are the source of truth for both sides. Touch them only
// in lockstep with `apps/mobile/ios/SkotiqAppIntents/*.swift` and
// `apps/mobile/android/app/src/main/kotlin/.../MainActivity.kt`.
//
// Every PlatformException from the host bridge propagates, and an unsupported
// platform throws a typed exception, so a caller never believes it published a
// snapshot the assistant will never see.

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

/// Channel name shared with the iOS AppDelegate and Android MainActivity.
/// Kept here as the single source of truth.
const String _voiceControlChannelName = 'skotiq/voice_control';

/// Thrown when [VoiceControlService] is invoked on a platform that does
/// not (and cannot) support a voice assistant integration. The mobile app
/// only ships iOS + Android targets, so any other platform — including a
/// future caller reaching this service from desktop code — becomes a visible
/// failure rather than a silent no-op.
class VoiceControlUnsupportedPlatformException implements Exception {
  VoiceControlUnsupportedPlatformException(this.message);

  final String message;

  @override
  String toString() => 'VoiceControlUnsupportedPlatformException: $message';
}

/// The set of control actions the voice assistant can dispatch back to
/// the app. Mirrors the AppIntent / shortcut identifier strings declared
/// on the native side.
///
/// We use an explicit enum (not strings) at the Dart boundary so callers
/// pattern-match exhaustively. The wire-level identifier comes from
/// [VoiceControlAction.wireId].
enum VoiceControlAction {
  /// "Pause Skotiq sequence" — confirmed by Siri / Assistant before
  /// dispatching.
  pauseSequence('pause_sequence'),

  /// "Resume Skotiq sequence".
  resumeSequence('resume_sequence'),

  /// "Show the last image Skotiq captured" — surface intent for deep
  /// linking. The Dart side opens the gallery route.
  openLastImage('open_last_image'),

  /// "What's Skotiq doing?" — read-only intent. The Dart side does
  /// not have to handle this (the AppIntents extension answers directly
  /// from the cached UserDefaults snapshot), but we still emit it when
  /// the user invokes the intent while the app is foregrounded so we can
  /// guarantee the cache is fresh.
  refreshStatus('refresh_status');

  const VoiceControlAction(this.wireId);

  /// Identifier sent over the MethodChannel. Matches the AppIntent's
  /// identifier on iOS and the shortcut id on Android.
  final String wireId;

  /// Reverse-lookup for inbound dispatches. Throws if the wire id is
  /// unknown — preferable to silently dropping an action and leaving the
  /// user wondering why Siri did nothing.
  static VoiceControlAction fromWireId(String wireId) {
    for (final v in VoiceControlAction.values) {
      if (v.wireId == wireId) return v;
    }
    throw ArgumentError.value(
      wireId,
      'wireId',
      'Unknown VoiceControlAction wire id; check parity with native side.',
    );
  }
}

/// Immutable snapshot of the data the voice assistant intents read.
///
/// All fields are required for the snapshot to be considered "complete".
/// We expose factory constructors instead of named parameters with
/// defaults so that callers can't accidentally publish a half-filled
/// snapshot (which would surface to the user as Siri saying "no frames
/// completed" mid-sequence).
class SequenceStatusSnapshot {
  const SequenceStatusSnapshot({
    required this.sequenceId,
    required this.sequenceName,
    required this.targetName,
    required this.executionState,
    required this.framesCompleted,
    required this.framesTotal,
    required this.elapsedSeconds,
    required this.estimatedRemainingSeconds,
    required this.currentFilter,
    required this.currentNodeName,
    required this.updatedAtMillis,
  });

  /// Sequence identifier (matches the row id in the desktop database).
  final String sequenceId;

  /// Human-readable sequence name (e.g. "M31 — Bortle 4 narrowband").
  final String sequenceName;

  /// Currently imaging target. Distinct from `sequenceName` because a
  /// multi-target sequence cycles through targets but the sequence name
  /// stays constant.
  final String targetName;

  /// One of `idle`, `running`, `paused`, `stopping`, `completed`,
  /// `failed`, `recovering` — mirroring `SequenceExecutionState` from
  /// skotiq_core so the Swift / Kotlin side can branch on it without
  /// having to know about freezed enums.
  final String executionState;

  final int framesCompleted;
  final int framesTotal;
  final int elapsedSeconds;

  /// `null` when the executor has no ETA yet (e.g. sequence just started
  /// before the first ExposureCompleted event has updated the rate).
  final int? estimatedRemainingSeconds;

  /// Empty string when no filter is in use.
  final String currentFilter;

  /// Friendly name of the running behaviour-tree node ("Expose 300s
  /// Ha", "Autofocus", "Center on target", …).
  final String currentNodeName;

  /// Wall-clock millis at the moment Dart captured this snapshot. Lets
  /// the iOS intent decide whether the cached snapshot is too stale
  /// (e.g. the app hasn't run in days) and ask the user to launch the
  /// app instead of speaking outdated numbers.
  final int updatedAtMillis;

  /// Encode to the JSON-compatible map the platform channel transmits.
  /// Keys here are the on-the-wire schema; do not rename without
  /// updating the native side.
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'sequenceId': sequenceId,
      'sequenceName': sequenceName,
      'targetName': targetName,
      'executionState': executionState,
      'framesCompleted': framesCompleted,
      'framesTotal': framesTotal,
      'elapsedSeconds': elapsedSeconds,
      'estimatedRemainingSeconds': estimatedRemainingSeconds,
      'currentFilter': currentFilter,
      'currentNodeName': currentNodeName,
      'updatedAtMillis': updatedAtMillis,
    };
  }

  /// Compose a one-line spoken-friendly summary the AppIntents extension
  /// can use verbatim. We pre-format on the Dart side so the wording
  /// stays in one place even though it's spoken by both iOS and Android.
  ///
  /// Examples:
  ///   "Currently running. Target M31. 17 of 60 frames complete. About 2
  ///    hours remaining."
  ///   "Sequence is paused on target NGC 891."
  ///   "No sequence is active."
  String toSpokenSummary() {
    switch (executionState) {
      case 'idle':
      case 'completed':
        if (executionState == 'completed') {
          return 'Sequence finished. $framesCompleted of $framesTotal frames captured on $targetName.';
        }
        return 'No sequence is active.';
      case 'failed':
        return 'Sequence failed on target $targetName.';
      case 'paused':
        return 'Sequence is paused on target $targetName. $framesCompleted of $framesTotal frames complete.';
      case 'stopping':
        return 'Sequence is stopping. $framesCompleted of $framesTotal frames complete on $targetName.';
      case 'recovering':
        return 'Sequence is recovering on target $targetName.';
      case 'running':
      default:
        final etaPart = _formatEta(estimatedRemainingSeconds);
        return 'Sequence is running on $targetName. '
            '$framesCompleted of $framesTotal frames complete.$etaPart';
    }
  }

  static String _formatEta(int? secs) {
    if (secs == null || secs <= 0) return '';
    if (secs < 60) return ' Less than a minute remaining.';
    final mins = (secs / 60).round();
    if (mins < 60) return ' About $mins minutes remaining.';
    final hours = mins ~/ 60;
    final remMins = mins % 60;
    if (remMins == 0) {
      return ' About $hours ${hours == 1 ? "hour" : "hours"} remaining.';
    }
    return ' About $hours ${hours == 1 ? "hour" : "hours"} '
        '$remMins minutes remaining.';
  }
}

/// Host-side bridge for the voice-assistant integration.
///
/// One instance lives for the lifetime of the app; the typical consumer
/// is [`voiceControlLifecycleProvider`](voice_control_lifecycle_provider.dart),
/// which wires the snapshot publisher into [sequenceProgressProvider].
///
/// The class is also unit-tested directly by injecting a mock channel.
class VoiceControlService {
  VoiceControlService({
    MethodChannel? channel,
    @visibleForTesting bool skipPlatformGuard = false,
  }) : _channel = channel ?? const MethodChannel(_voiceControlChannelName),
       _skipPlatformGuard = skipPlatformGuard {
    // Inbound action handler. We set it up eagerly because the native
    // side can fire actions any time the app is foregrounded — including
    // immediately at launch when the user opened the app via a Siri
    // intent or Assistant shortcut.
    _channel.setMethodCallHandler(_handleInboundCall);
  }

  /// Public for tests.
  static const String channelName = _voiceControlChannelName;

  final MethodChannel _channel;

  /// Set by tests that need to exercise the channel-encoding path on a
  /// non-iOS/Android host. Never set this in production code — the
  /// production guard exists to fail loud on accidental desktop calls.
  final bool _skipPlatformGuard;

  /// Broadcasts inbound voice actions to whichever Riverpod listener is
  /// subscribed. Broadcast (not single-subscription) because the
  /// lifecycle provider plus a debug overlay may both observe.
  final StreamController<VoiceControlAction> _actionController =
      StreamController<VoiceControlAction>.broadcast();

  /// Inbound actions from Siri / Assistant. Subscribers in the lifecycle
  /// provider translate these into calls on `sequenceExecutorProvider`.
  Stream<VoiceControlAction> get actionStream => _actionController.stream;

  /// Publish the latest sequence status to the platform-native cache the
  /// voice assistant reads.
  ///
  /// On iOS this writes the JSON-encoded snapshot to the shared App
  /// Group UserDefaults suite (`group.com.skotiq.app`) so the
  /// AppIntents extension can read it without launching the app.
  ///
  /// On Android this updates a dynamic ShortcutManagerCompat shortcut so
  /// Assistant can answer the status query from cached data and so the
  /// "What's Skotiq doing?" suggestion stays current in the
  /// Assistant launcher.
  ///
  /// Throws [VoiceControlUnsupportedPlatformException] on platforms that
  /// don't ship a voice integration (anything but iOS or Android).
  Future<void> publishSequenceStatus(SequenceStatusSnapshot snapshot) async {
    _assertSupportedPlatform('publishSequenceStatus');
    try {
      await _channel.invokeMethod<void>('publishStatus', snapshot.toJson());
    } on PlatformException catch (e, st) {
      developer.log(
        '[VoiceControlService] publishStatus failed: ${e.message}',
        name: 'VoiceControlService',
        level: 1000,
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }

  /// Clear the cached snapshot. Called when the app determines the
  /// status is no longer meaningful (e.g. backend disconnected, no
  /// sequence has ever run since launch). The native side either
  /// removes the UserDefaults key (iOS) or removes the dynamic shortcut
  /// (Android) so a follow-up "what's Skotiq doing?" question gets
  /// the canonical "no sequence is active" answer.
  Future<void> clearStatus() async {
    _assertSupportedPlatform('clearStatus');
    try {
      await _channel.invokeMethod<void>('clearStatus');
    } on PlatformException catch (e, st) {
      developer.log(
        '[VoiceControlService] clearStatus failed: ${e.message}',
        name: 'VoiceControlService',
        level: 1000,
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }

  /// True if the host platform reports the voice integration is
  /// available. The check is platform-specific: iOS confirms the App
  /// Group container is reachable; Android confirms ShortcutManagerCompat
  /// is supported on this OS version.
  Future<bool> isSupported() async {
    if (!Platform.isIOS && !Platform.isAndroid) {
      return false;
    }
    try {
      final result = await _channel.invokeMethod<bool>('isSupported');
      return result ?? false;
    } on PlatformException catch (e, st) {
      developer.log(
        '[VoiceControlService] isSupported failed: ${e.message}',
        name: 'VoiceControlService',
        level: 1000,
        error: e,
        stackTrace: st,
      );
      return false;
    }
  }

  Future<dynamic> _handleInboundCall(MethodCall call) async {
    switch (call.method) {
      case 'onAction':
        final args = call.arguments;
        if (args is! Map) {
          throw PlatformException(
            code: 'invalid_arguments',
            message:
                'voice_control.onAction expected a Map argument, got ${args.runtimeType}',
          );
        }
        final wireId = args['action'];
        if (wireId is! String || wireId.isEmpty) {
          throw PlatformException(
            code: 'missing_action',
            message:
                'voice_control.onAction requires a non-empty "action" string',
          );
        }
        try {
          final action = VoiceControlAction.fromWireId(wireId);
          _actionController.add(action);
          return true;
        } on ArgumentError {
          // Throw on an unknown id rather than dropping it: a silent drop
          // reads to the assistant as a command that was carried out.
          throw PlatformException(
            code: 'unknown_action',
            message:
                'Unknown voice action wire id: "$wireId". '
                'Check parity between Dart VoiceControlAction and the '
                'native AppIntents / shortcuts xml.',
          );
        }
      default:
        throw MissingPluginException(
          'voice_control: no inbound handler for method "${call.method}"',
        );
    }
  }

  void _assertSupportedPlatform(String method) {
    if (_skipPlatformGuard) return;
    if (!Platform.isIOS && !Platform.isAndroid) {
      throw VoiceControlUnsupportedPlatformException(
        'VoiceControlService.$method called on '
        '${Platform.operatingSystem} — voice control is iOS/Android only.',
      );
    }
  }

  /// Dispose: closes the inbound action stream and detaches the channel
  /// handler. Idempotent.
  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    if (!_actionController.isClosed) {
      await _actionController.close();
    }
  }
}
