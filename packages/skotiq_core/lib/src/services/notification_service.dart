import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../models/backend/event_types.dart' show EventSeverity;
import '../models/notification/notification_categories.dart'
    show NotificationCategory;
import '../providers/notification_router_provider.dart';
import '../providers/settings_provider.dart';
import '../utils/duration_format.dart';
import 'notification/notification_router.dart';

/// Plays a short audible alert via the platform's built-in beep channel.
///
/// Why: the desktop `NotificationService` ships notifications through
/// HTTP-based webhooks (Discord/Pushover) which are visual-only. Users who
/// run Skotiq unattended on a workstation expect an audible cue when a
/// sequence completes or an error fires; the "Sound alerts" toggle in
/// notification settings exposed by Settings → Notifications is what gates
/// this playback
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
    developer.log(
      '[Notification] SystemSound.play failed: $e',
      name: 'NotificationService',
      level: 900,
    );
  }
}

/// Notification event types
enum NotificationEvent {
  sequenceComplete,
  error,
  meridianFlip,
  captureComplete,
  autofocusComplete,
  custom,
}

/// Notification priority levels for Pushover
enum NotificationPriority {
  lowest(-2),
  low(-1),
  normal(0),
  high(1),
  emergency(2);

  final int value;
  const NotificationPriority(this.value);
}

/// What one [NotificationService.notifyDetailed] send actually did.
///
/// Three independent outcomes hide behind the old single bool: the service's
/// own gates (settings loaded, notifications on, this event family on), the
/// router fan-out that carries the in-app surfaces and the phone, and the two
/// AppSettings webhooks. Only the last one was ever reported.
class NotificationDispatch {
  /// What the routing matrix did, or null when there was no router to forward
  /// to (the `.testing` service, or a container without the notification
  /// graph).
  final NotificationRouteOutcome? routed;

  /// Whether Discord or Pushover accepted it.
  final bool webhookAccepted;

  /// Why the service sent nothing at all, naming its own gate. Null when the
  /// send was attempted.
  final String? refusedReason;

  const NotificationDispatch({
    required this.routed,
    required this.webhookAccepted,
  }) : refusedReason = null;

  const NotificationDispatch.refused(String this.refusedReason)
    : routed = null,
      webhookAccepted = false;

  /// True when the message reached at least one transport or webhook — the
  /// only honest basis for telling an operator it was sent.
  bool get anyDelivered => webhookAccepted || (routed?.anyDispatched ?? false);

  /// One sentence naming what happened, for a report the operator reads.
  String describe() {
    if (refusedReason != null) return '$refusedReason, so nothing was sent.';
    final route = routed;
    if (route != null && route.anyDispatched) {
      final also = webhookAccepted
          ? ', and a configured webhook accepted it'
          : '';
      return 'Sent to ${route.dispatchedNames}$also.';
    }
    if (webhookAccepted) {
      final why = route?.dropReason;
      return 'Sent to a configured webhook'
          '${why == null ? '' : '; the routed transports sent nothing: $why'}.';
    }
    final why = route?.dropReason;
    return why == null
        ? 'Nothing was sent: no routed transport and no webhook took it.'
        : 'Nothing was sent: $why, and no webhook accepted it either.';
  }
}

/// Service for sending notifications via Discord and Pushover
class NotificationService {
  static const Duration defaultRequestTimeout = Duration(seconds: 15);

  final Ref? _ref;
  final AppSettingsState? Function()? _settingsReader;
  final http.Client _httpClient;
  final Duration _requestTimeout;
  final bool _ownsHttpClient;
  final NotificationSoundPlayer _playAlertSound;

  NotificationService(
    Ref ref, {
    http.Client? httpClient,
    Duration requestTimeout = defaultRequestTimeout,
    NotificationSoundPlayer? soundPlayer,
  }) : _ref = ref,
       _settingsReader = null,
       _httpClient = httpClient ?? http.Client(),
       _requestTimeout = requestTimeout,
       _ownsHttpClient = httpClient == null,
       _playAlertSound = soundPlayer ?? _defaultPlayAlertSound;

  NotificationService.testing({
    required AppSettingsState? Function() settingsReader,
    http.Client? httpClient,
    Duration requestTimeout = defaultRequestTimeout,
    NotificationSoundPlayer? soundPlayer,
  }) : _ref = null,
       _settingsReader = settingsReader,
       _httpClient = httpClient ?? http.Client(),
       _requestTimeout = requestTimeout,
       _ownsHttpClient = httpClient == null,
       _playAlertSound = soundPlayer ?? _defaultPlayAlertSound;

  void dispose() {
    if (_ownsHttpClient) {
      _httpClient.close();
    }
  }

  AppSettingsState? _readSettings() {
    return _settingsReader?.call() ??
        _ref?.read(appSettingsProvider).valueOrNull;
  }

  /// Send a notification based on the event type
  /// Returns true if at least one notification was sent successfully
  ///
  /// [routeAs] selects the routing-matrix row the message is fanned out under.
  /// It defaults to `custom`, which is what every legacy caller has always
  /// used; a caller whose message is its own kind of event names its category
  /// so the operator gets a row to configure instead of sharing `custom` with
  /// everything else. It does NOT replace [event] — that still decides the
  /// AppSettings per-event gate above.
  ///
  /// [deepLink] is the phone's `type[:arg]` tap payload, carried through to
  /// the systemPush transport. Null for a message whose event type alone says
  /// where a tap should land.
  Future<bool> notify({
    required NotificationEvent event,
    required String title,
    required String message,
    NotificationPriority priority = NotificationPriority.normal,
    NotificationCategory routeAs = NotificationCategory.custom,
    String? deepLink,
  }) async {
    final dispatch = await notifyDetailed(
      event: event,
      title: title,
      message: message,
      priority: priority,
      routeAs: routeAs,
      deepLink: deepLink,
    );
    return dispatch.webhookAccepted;
  }

  /// The same send, reporting what actually left the process.
  ///
  /// [notify]'s bool has only ever described the two AppSettings webhooks —
  /// the router fan-out that carries the phone was `void` and every one of its
  /// drop paths was silent. A caller that STATES an outcome (the dawn
  /// autopilot's morning message says whether the night's report was sent, and
  /// it is the only surface that lists delivery problems) has to be able to
  /// name the gate that stopped it.
  Future<NotificationDispatch> notifyDetailed({
    required NotificationEvent event,
    required String title,
    required String message,
    NotificationPriority priority = NotificationPriority.normal,
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

    // Why: the user can independently enable/disable the audible alert from
    // Settings → Notifications → "Sound alerts". The toggle is local to the
    // host running the notification service; webhooks ship regardless of
    // the local sound preference.
    if (settings.soundEnabled) {
      // Fire-and-forget; SystemSound is short and we don't gate webhook
      // dispatch on it. Errors are logged inside the default player.
      unawaited(_playAlertSound());
    }

    // Architecture-unification, Subsystem 3: re-point this legacy service
    // through the single NotificationRouter so its callers (imaging save /
    // calibration failures, device-reconnect, meridian-flip) fan out to the
    // unified transport set (in-app + the configurable external transports,
    // and mobile push when the user routes `custom` there) instead of only
    // the two AppSettings-stored webhooks below. The webhook + sound path is
    // preserved for backward compatibility so nothing that worked before goes
    // dark; the router adds the new transports on top. Only available when
    // constructed with a Riverpod `Ref` (the `.testing` constructor has none,
    // and the webhook/sound assertions there are unaffected).
    final routed = _forwardToRouter(
      event: event,
      title: title,
      message: message,
      routeAs: routeAs,
      deepLink: deepLink,
    );

    final results = await Future.wait([
      _sendDiscordNotification(title, message, event, settings),
      _sendPushoverNotification(title, message, priority, settings),
    ]);

    return NotificationDispatch(
      routed: routed,
      webhookAccepted: results.any((success) => success),
    );
  }

  /// Send a notification for sequence completion
  Future<bool> notifySequenceComplete({
    required String sequenceName,
    required int imagesCapured,
    required Duration totalTime,
    String? targetName,
  }) async {
    final timeStr = DurationFormat.of(totalTime);
    final message = targetName != null
        ? 'Target: $targetName\nImages: $imagesCapured\nTotal time: $timeStr'
        : 'Images: $imagesCapured\nTotal time: $timeStr';

    return notify(
      event: NotificationEvent.sequenceComplete,
      title: 'Sequence Complete: $sequenceName',
      message: message,
    );
  }

  /// Send a notification for errors
  Future<bool> notifyError({
    required String errorTitle,
    required String errorMessage,
    String? source,
  }) async {
    final message = source != null
        ? 'Source: $source\n$errorMessage'
        : errorMessage;

    return notify(
      event: NotificationEvent.error,
      title: 'Error: $errorTitle',
      message: message,
      priority: NotificationPriority.high,
    );
  }

  /// Send a notification for meridian flip
  Future<bool> notifyMeridianFlip({
    required bool isStarting,
    String? targetName,
  }) async {
    final title = isStarting
        ? 'Meridian Flip Starting'
        : 'Meridian Flip Complete';
    final message = targetName != null
        ? 'Target: $targetName'
        : isStarting
        ? 'Mount is flipping...'
        : 'Mount flip completed successfully';

    return notify(
      event: NotificationEvent.meridianFlip,
      title: title,
      message: message,
    );
  }

  /// Send a custom notification
  Future<bool> notifyCustom({
    required String title,
    required String message,
    NotificationPriority priority = NotificationPriority.normal,
  }) async {
    return notify(
      event: NotificationEvent.custom,
      title: title,
      message: message,
      priority: priority,
    );
  }

  /// Forward a legacy notification through the unified [NotificationRouter].
  ///
  /// Routed as [routeAs] — `custom` by default — with the already-rendered
  /// title/message so the operator's transport wiring for that row (in-app plus
  /// any external transports / mobile push they opted in) applies. We do NOT
  /// re-map a legacy caller to a finer category (e.g. sequenceCompleted): the
  /// router's own backend event-stream subscription already classifies and
  /// pushes those real events, so re-mapping here would double-fire systemPush
  /// for the same milestone. `custom` defaults to in-app only, so this strictly
  /// ADDS to — never duplicates — the classifier path while still flowing
  /// through the single router producer.
  ///
  /// A caller that passes its OWN [routeAs] is stating that no classifier arm
  /// fires for it, which is why the dawn autopilot's morning message can carry
  /// one: nothing on the backend event stream describes a finished Darkroom
  /// pass.
  NotificationRouteOutcome? _forwardToRouter({
    required NotificationEvent event,
    required String title,
    required String message,
    NotificationCategory routeAs = NotificationCategory.custom,
    String? deepLink,
  }) {
    final ref = _ref;
    // `.testing` has no Ref; nothing to forward to.
    if (ref == null) return null;
    final NotificationRouter router;
    try {
      router = ref.read(notificationRouterProvider);
    } catch (e) {
      // The router provider is unavailable (e.g. a minimal test container
      // without the notification graph). Surface, don't swallow — but never
      // break the legacy webhook/sound path on account of it.
      developer.log(
        '[Notification] Router forward skipped: $e',
        name: 'NotificationService',
        level: 900,
      );
      return null;
    }
    return router.routeRendered(
      category: routeAs,
      title: title,
      body: message,
      severity: event == NotificationEvent.error
          ? EventSeverity.error
          : EventSeverity.info,
      deepLink: deepLink,
    );
  }

  /// Per-family opt-out gate for [notify].
  ///
  /// Three `AppSettingsState` flags are live delivery gates, not bookkeeping:
  /// a `false` here aborts the whole dispatch — no alert sound, no router
  /// forward, no Discord, no Pushover — for that event family. Settings →
  /// Notifications renders them under "Built-in event alerts"; they are also
  /// persisted and synced to remote controllers, so a controller can silence
  /// a family on the host.
  ///
  /// `notifyOnMeridianFlip` defaults to **false** (unlike its two siblings,
  /// which default to true), so out of the box a meridian-flip alert raised by
  /// the flip monitor is dropped right here. That default is deliberate and
  /// the settings row says so out loud; do not "fix" it by returning true for
  /// [NotificationEvent.meridianFlip] when the operator has left it off.
  ///
  /// The remaining families have no flag of their own and always pass. The
  /// unified [NotificationRouter]'s own backend event-stream subscription is a
  /// separate producer and is not gated by any of this.
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
      case NotificationEvent.captureComplete:
      case NotificationEvent.autofocusComplete:
      case NotificationEvent.custom:
        return true;
    }
  }

  /// Send a Discord webhook notification
  Future<bool> _sendDiscordNotification(
    String title,
    String message,
    NotificationEvent event,
    AppSettingsState settings,
  ) async {
    if (settings.discordWebhook.isEmpty) {
      return false;
    }

    try {
      final response = await _httpClient
          .post(
            Uri.parse(settings.discordWebhook),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'embeds': [
                {
                  'title': title,
                  'description': message,
                  'color': _getDiscordColor(event),
                  'timestamp': DateTime.now().toUtc().toIso8601String(),
                  'footer': {'text': 'Skotiq'},
                },
              ],
            }),
          )
          .timeout(_requestTimeout);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        developer.log(
          '[Notification] Discord notification sent successfully',
          name: 'NotificationService',
          level: 800,
        );
        return true;
      }

      developer.log(
        '[Notification] Discord notification failed: ${response.statusCode} ${response.body}',
        name: 'NotificationService',
        level: 900,
      );
      return false;
    } on TimeoutException {
      developer.log(
        '[Notification] Discord notification timed out after ${_requestTimeout.inSeconds}s',
        name: 'NotificationService',
        level: 900,
      );
      return false;
    } catch (e) {
      developer.log(
        '[Notification] Discord notification error: $e',
        name: 'NotificationService',
        level: 1000,
        error: e,
      );
      return false;
    }
  }

  /// Send a Pushover notification
  Future<bool> _sendPushoverNotification(
    String title,
    String message,
    NotificationPriority priority,
    AppSettingsState settings,
  ) async {
    if (settings.pushoverKey.isEmpty || settings.pushoverUser.isEmpty) {
      return false;
    }

    try {
      final response = await _httpClient
          .post(
            Uri.parse('https://api.pushover.net/1/messages.json'),
            body: {
              'token': settings.pushoverKey,
              'user': settings.pushoverUser,
              'title': title,
              'message': message,
              'priority': priority.value.toString(),
            },
          )
          .timeout(_requestTimeout);

      if (response.statusCode == 200) {
        developer.log(
          '[Notification] Pushover notification sent successfully',
          name: 'NotificationService',
          level: 800,
        );
        return true;
      }

      developer.log(
        '[Notification] Pushover notification failed: ${response.statusCode} ${response.body}',
        name: 'NotificationService',
        level: 900,
      );
      return false;
    } on TimeoutException {
      developer.log(
        '[Notification] Pushover notification timed out after ${_requestTimeout.inSeconds}s',
        name: 'NotificationService',
        level: 900,
      );
      return false;
    } catch (e) {
      developer.log(
        '[Notification] Pushover notification error: $e',
        name: 'NotificationService',
        level: 1000,
        error: e,
      );
      return false;
    }
  }

  int _getDiscordColor(NotificationEvent event) {
    switch (event) {
      case NotificationEvent.sequenceComplete:
        return 0x22C55E;
      case NotificationEvent.error:
        return 0xEF4444;
      case NotificationEvent.meridianFlip:
        return 0x3B82F6;
      case NotificationEvent.captureComplete:
        return 0x6EB3EC;
      case NotificationEvent.autofocusComplete:
        return 0x7AB8D4;
      case NotificationEvent.custom:
        return 0x6EB3EC;
    }
  }

  /// Test Discord webhook connection
  Future<bool> testDiscordWebhook(String webhookUrl) async {
    try {
      final response = await _httpClient
          .post(
            Uri.parse(webhookUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'embeds': [
                {
                  'title': 'Test Notification',
                  'description':
                      'This is a test notification from Skotiq. If you see this, your Discord webhook is configured correctly!',
                  'color': 0x22C55E,
                  'timestamp': DateTime.now().toUtc().toIso8601String(),
                  'footer': {'text': 'Skotiq - Test'},
                },
              ],
            }),
          )
          .timeout(_requestTimeout);

      return response.statusCode >= 200 && response.statusCode < 300;
    } on TimeoutException {
      developer.log(
        '[Notification] Discord test timed out after ${_requestTimeout.inSeconds}s',
        name: 'NotificationService',
        level: 900,
      );
      return false;
    } catch (e) {
      developer.log(
        '[Notification] Discord test failed: $e',
        name: 'NotificationService',
        level: 1000,
        error: e,
      );
      return false;
    }
  }

  /// Test Pushover connection
  Future<bool> testPushover(String token, String user) async {
    try {
      final response = await _httpClient
          .post(
            Uri.parse('https://api.pushover.net/1/messages.json'),
            body: {
              'token': token,
              'user': user,
              'title': 'Test Notification',
              'message':
                  'This is a test notification from Skotiq. If you see this, your Pushover is configured correctly!',
              'priority': '0',
            },
          )
          .timeout(_requestTimeout);

      return response.statusCode == 200;
    } on TimeoutException {
      developer.log(
        '[Notification] Pushover test timed out after ${_requestTimeout.inSeconds}s',
        name: 'NotificationService',
        level: 900,
      );
      return false;
    } catch (e) {
      developer.log(
        '[Notification] Pushover test failed: $e',
        name: 'NotificationService',
        level: 1000,
        error: e,
      );
      return false;
    }
  }
}

/// Provider for the notification service
final notificationServiceProvider = Provider<NotificationService>((ref) {
  final service = NotificationService(ref);
  ref.onDispose(service.dispose);
  return service;
});
