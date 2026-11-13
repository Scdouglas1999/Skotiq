import 'dart:async';

import 'package:flutter/services.dart';

import '../models/backend/event_types.dart' show EventSeverity;
import '../models/notification/notification_categories.dart'
    show NotificationCategory;
import 'notification/notification_router.dart';
import '../settings/app_settings_state.g.dart';
import 'logging_service.dart';

/// Plays a short audible alert via the platform's built-in beep channel.
///
/// Users who run Skotiq unattended on a workstation expect an audible cue
/// when a sequence completes or an error fires; the "Sound alerts" toggle in
/// Settings → Notifications gates this playback.
typedef NotificationSoundPlayer = Future<void> Function();

Future<void> _defaultPlayAlertSound() async {
  // Why: SystemSound.alert is the one cross-platform short tone Flutter
  // exposes without an external audio dependency. It is the same UX
  // affordance Windows/macOS/Linux apps use for "ding" cues. Failures here
  // (e.g., a headless host without an audio device) must not break the
  // notification pipeline, but they should be logged so the operator can
  // diagnose missing audio output.
  try {
    await SystemSound.play(SystemSoundType.alert);
  } catch (e) {
    Log.warning(
      '[Notification] SystemSound.play failed: $e',
      source: 'NotificationService',
    );
  }
}

/// The families of built-in alert Skotiq raises itself. Three of them have an
/// on/off switch in Settings → Notifications ("Built-in event alerts").
enum NotificationEvent { sequenceComplete, error, meridianFlip, custom }

/// What one [NotificationService.notify] did.
class NotificationDispatch {
  /// What the routing matrix did, or null when the service's own gates
  /// refused the message before it reached the router.
  final NotificationRouteOutcome? routed;

  /// Why the service sent nothing at all, naming its own gate. Null when the
  /// send was attempted.
  final String? refusedReason;

  const NotificationDispatch(NotificationRouteOutcome this.routed)
    : refusedReason = null;

  const NotificationDispatch.refused(String this.refusedReason) : routed = null;

  /// True when the message was handed to at least one transport — the only
  /// honest basis for telling an operator it was sent.
  bool get anyDelivered => routed?.anyDispatched ?? false;

  /// One sentence naming what happened, for a report the operator reads.
  String describe() {
    if (refusedReason != null) return '$refusedReason, so nothing was sent.';
    final route = routed!;
    return route.anyDispatched
        ? 'Sent to ${route.dispatchedNames}.'
        : 'Nothing was sent: ${route.dropReason}.';
  }
}

/// The entry point for alerts Skotiq raises itself (a failed save, a lost
/// device, the morning message) rather than classifies from the backend event
/// stream. It applies the Settings → Notifications switches and the alert
/// sound, then hands the message to the [NotificationRouter], which is the
/// only thing that sends.
class NotificationService {
  final AppSettingsState? Function() _readSettings;
  final NotificationRouter? Function() _readRouter;
  final NotificationSoundPlayer _playAlertSound;

  NotificationService({
    required AppSettingsState? Function() readSettings,
    required NotificationRouter? Function() readRouter,
    NotificationSoundPlayer? soundPlayer,
  }) : _readSettings = readSettings,
       _readRouter = readRouter,
       _playAlertSound = soundPlayer ?? _defaultPlayAlertSound;

  /// Send one alert.
  ///
  /// [event] picks the Settings switch that can silence it and its severity
  /// (`error` is an error, everything else is info). [routeAs] is the
  /// routing-matrix row it is sent under: `custom` unless the message is its
  /// own kind of event with a row the operator can configure. No classifier
  /// arm may fire for the same happening, or it would be sent twice.
  ///
  /// [deepLink] is the phone's `type[:arg]` tap payload.
  Future<NotificationDispatch> notify({
    required NotificationEvent event,
    required String title,
    required String message,
    NotificationCategory routeAs = NotificationCategory.custom,
    String? deepLink,
  }) async {
    final settings = _readSettings();
    if (settings == null) {
      return const NotificationDispatch.refused(
        'The notification settings have not loaded, so no gate could be read',
      );
    }
    if (!settings.notificationsEnabled) {
      return const NotificationDispatch.refused(
        'Notifications are switched off in Settings',
      );
    }
    if (!_shouldNotifyForEvent(event, settings)) {
      return NotificationDispatch.refused(
        'The ${event.name} event alert is switched off in Settings',
      );
    }

    final router = _readRouter();
    if (router == null) {
      return const NotificationDispatch.refused(
        'The notification router is not available',
      );
    }

    if (settings.soundEnabled) {
      // Not awaited: the sound is short and errors are logged inside the
      // default player.
      unawaited(_playAlertSound());
    }

    return NotificationDispatch(
      router.routeRendered(
        category: routeAs,
        title: title,
        body: message,
        severity: event == NotificationEvent.error
            ? EventSeverity.error
            : EventSeverity.info,
        deepLink: deepLink,
      ),
    );
  }

  Future<NotificationDispatch> notifyError({
    required String errorTitle,
    required String errorMessage,
    String? source,
  }) {
    return notify(
      event: NotificationEvent.error,
      title: 'Error: $errorTitle',
      message: source != null ? 'Source: $source\n$errorMessage' : errorMessage,
    );
  }

  Future<NotificationDispatch> notifyMeridianFlip({
    required bool isStarting,
    String? targetName,
  }) {
    final message = targetName != null
        ? 'Target: $targetName'
        : isStarting
        ? 'Mount is flipping...'
        : 'Mount flip completed successfully';
    return notify(
      event: NotificationEvent.meridianFlip,
      title: isStarting ? 'Meridian Flip Starting' : 'Meridian Flip Complete',
      message: message,
    );
  }

  /// Per-family opt-out gate for [notify].
  ///
  /// Three `AppSettingsState` flags are live delivery gates: a `false` here
  /// aborts the whole dispatch (no alert sound, nothing routed) for that
  /// family. They are persisted and synced to remote controllers, so a
  /// controller can silence a family on the host.
  ///
  /// `notifyOnMeridianFlip` defaults to **false** (unlike its two siblings),
  /// so out of the box a meridian-flip alert raised by the flip monitor is
  /// dropped right here. That default is deliberate and the settings row says
  /// so; do not "fix" it by returning true when the operator has left it off.
  ///
  /// The router's own backend event-stream subscription is a separate
  /// producer and is not gated by any of this.
  bool _shouldNotifyForEvent(
    NotificationEvent event,
    AppSettingsState settings,
  ) {
    switch (event) {
      case NotificationEvent.sequenceComplete:
        return settings.notifyOnSequenceComplete;
      case NotificationEvent.error:
        return settings.notifyOnError;
      case NotificationEvent.meridianFlip:
        return settings.notifyOnMeridianFlip;
      case NotificationEvent.custom:
        return true;
    }
  }
}
