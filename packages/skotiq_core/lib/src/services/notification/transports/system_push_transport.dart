// System (mobile) push transport — the SINGLE systemPush producer.
//
// Architecture-unification, Subsystem 3 (collapsed): all mobile pushes now
// flow through this transport. The [NotificationRouter] routes a category to
// this transport per the routing matrix; this transport then applies the
// per-event [PushNotificationConfig] toggle, the historical priority, and
// the per-category event kind, and broadcasts a [PushNotification] via
// [PushNotificationService] (now a pure broadcaster). Paired phones receive
// it over the same WebSocket envelope they already listen to.
//
// This is the single systemPush producer: the per-category toggle gate and the
// priority both live here, so the push service classifies nothing itself.

import '../../../models/backend/event_types.dart' as core;
import '../../../models/notification/notification_categories.dart';
import '../../push_notification_service.dart';
import 'notification_transport.dart';

class SystemPushTransport extends NotificationTransport {
  final PushNotificationService _service;

  SystemPushTransport(this._service);

  @override
  NotificationTransportKind get kind => NotificationTransportKind.systemPush;

  @override
  String get name => 'Mobile push';

  /// Configured only while the authoritative master gate is enabled. This
  /// keeps a disabled/fail-closed push feed from consuming router debounce and
  /// rate-limit slots for messages that cannot actually leave the service.
  @override
  bool get isConfigured => _service.config.enabled;

  /// [deepLink] is the optional `type[:arg]` payload the phone routes the tap
  /// with. Declared here and nowhere else because this is the only transport
  /// that reaches a device with a route table; the base signature stays as it
  /// is so the eight other transports are untouched by a mobile concern.
  @override
  Future<NotificationResult> send({
    required NotificationCategory category,
    required String title,
    required String body,
    String? deepLink,
  }) async {
    final spec = _pushSpecFor(category);
    if (spec == null) {
      // The matrix routed a category to systemPush that the mobile feed does
      // not escalate. Treat as a no-op success so the matrix can list
      // systemPush on the rule without this transport double-guessing intent.
      return NotificationResult.ok();
    }
    if (!spec.enabled(_service.config)) {
      // Per-event toggle is off — honour it. (The master `enabled` gate is
      // additionally enforced inside the broadcaster.)
      return NotificationResult.ok();
    }

    _service.enqueue(
      PushNotification(
        title: title,
        body: body,
        priority: spec.priority,
        eventType: category.storageKey,
        category: _mapCategory(category),
        timestamp: DateTime.now(),
        deepLink: deepLink,
      ),
    );
    return NotificationResult.ok();
  }

  /// Enqueue an EXPLICIT, forced-priority phone push with already-rendered
  /// copy, bypassing the per-category toggle/priority inference.
  ///
  /// Used only by the router's dashboard-bridge path: the Run Dashboard
  /// escalates `isCriticalEvent` events (some of which — e.g. generic system
  /// errors / FITS save failures — have no [NotificationCategory] and must
  /// still page the operator at `critical` priority). The master `enabled`
  /// gate is still enforced inside [PushNotificationService.enqueue].
  void enqueueExplicit({
    required String title,
    required String body,
    required String eventType,
    required core.EventCategory eventCategory,
    PushNotificationPriority priority = PushNotificationPriority.critical,
  }) {
    _service.enqueue(
      PushNotification(
        title: title,
        body: body,
        priority: priority,
        eventType: eventType,
        category: eventCategory,
        timestamp: DateTime.now(),
      ),
    );
  }

  /// Per-category push spec: the toggle gate + priority for each
  /// [NotificationCategory] this mobile feed escalates. Returns `null` for
  /// categories the feed intentionally does NOT push (they surface in-app
  /// only), matching the historical [PushNotificationService] coverage.
  ///
  /// Title/body are NOT built here any more — the router renders them from
  /// the per-category templates before calling [send], so the operator's
  /// custom templates apply to the phone push too.
  _PushSpec? _pushSpecFor(NotificationCategory category) {
    switch (category) {
      // Critical-by-default categories (priority: critical)
      // The exactly-once canary pins that every critical category pushes at
      // `critical` priority through this single producer.
      case NotificationCategory.sequenceFailed:
        return _PushSpec(
          enabled: (c) => c.notifySequenceFailed,
          priority: PushNotificationPriority.critical,
        );
      case NotificationCategory.exposureFailed:
        return _PushSpec(
          enabled: (c) => c.notifyExposureFailed,
          priority: PushNotificationPriority.critical,
        );
      case NotificationCategory.guidingLost:
        return _PushSpec(
          enabled: (c) => c.notifyGuidingLost,
          priority: PushNotificationPriority.critical,
        );
      case NotificationCategory.weatherUnsafe:
        return _PushSpec(
          enabled: (c) => c.notifyWeatherUnsafe,
          priority: PushNotificationPriority.critical,
        );
      case NotificationCategory.autofocusFailed:
        return _PushSpec(
          enabled: (c) => c.notifyAutofocusFailed,
          priority: PushNotificationPriority.critical,
        );
      case NotificationCategory.equipmentDisconnected:
        return _PushSpec(
          enabled: (c) => c.notifyEquipmentDisconnected,
          priority: PushNotificationPriority.critical,
        );
      case NotificationCategory.recoveryGaveUp:
      case NotificationCategory.diskSpaceLow:
      // A possible new transient is time-critical for a discovery imager — the
      // chase window closes by morning — so it always escalates to the phone
      // when push is enabled, like the other no-dedicated-toggle critical
      // categories.
      case NotificationCategory.transientDiscovered:
        // No dedicated PushNotificationConfig toggle: critical by default,
        // escalating whenever push is enabled.
        return const _PushSpec(
          enabled: _always,
          priority: PushNotificationPriority.critical,
        );

      // Non-critical categories that still push
      case NotificationCategory.sequenceCompleted:
        return _PushSpec(
          enabled: (c) => c.notifySequenceCompleted,
          priority: PushNotificationPriority.normal,
        );
      case NotificationCategory.targetCompleted:
        return _PushSpec(
          enabled: (c) => c.notifySequenceCompleted,
          priority: PushNotificationPriority.low,
        );
      case NotificationCategory.meridianFlipPerformed:
        return _PushSpec(
          enabled: (c) => c.notifyMeridianFlip,
          priority: PushNotificationPriority.normal,
        );
      // A run that ended without the operator asking — a safety abort, the
      // autopilot's re-plan, a subsystem stop — is exactly what someone asleep
      // needs to hear (owner decision 2, 2026-08-14). The operator's own press
      // never gets here: the router's [StopPushArbiter] withholds it.
      //
      // No legacy per-event toggle ever existed for a stop, so the control is
      // the routing matrix's own sequenceStopped row. Priority is the ordinary
      // non-alarm tier the other run-lifecycle milestones use — the run ending
      // is news, never an emergency.
      case NotificationCategory.sequenceStopped:
        return const _PushSpec(
          enabled: _always,
          priority: PushNotificationPriority.normal,
        );
      // A failed interval autofocus that CONTINUES the run (owner decision 10,
      // 2026-08-14): the night went on at the last good focus, and the person
      // asleep must hear it or the degradation stays invisible until morning.
      // Same toggle as autofocusFailed — muting one mutes the family — but at
      // the ordinary tier: the run surviving is news, not an emergency.
      case NotificationCategory.autofocusContinued:
        return _PushSpec(
          enabled: (c) => c.notifyAutofocusFailed,
          priority: PushNotificationPriority.normal,
        );
      // A quality problem the run carried on through (owner decision
      // 2026-10-06). No legacy per-event toggle exists; the routing-matrix row
      // is its control. Ordinary tier: the run going on is news, not an alarm.
      case NotificationCategory.problemNoticed:
        return const _PushSpec(
          enabled: _always,
          priority: PushNotificationPriority.normal,
        );
      // The morning draft. No legacy per-event toggle ever existed for it, so
      // the control is its own routing-matrix row; priority is the ordinary
      // tier because it arrives after the night is over and nothing is at risk.
      case NotificationCategory.darkroomDraftReady:
        return const _PushSpec(
          enabled: _always,
          priority: PushNotificationPriority.normal,
        );

      // Custom (user-defined NotificationNode / forwarded errors)
      // Always allowed when push is enabled; the user explicitly opted a
      // `custom` notification into systemPush via the matrix, so there is no
      // separate toggle to consult.
      case NotificationCategory.custom:
        return const _PushSpec(
          enabled: _always,
          priority: PushNotificationPriority.high,
        );

      // Categories the mobile push feed intentionally does NOT escalate
      // (they surface in-app only): sequence start/pause/resume, target
      // start, frame captured/rejected, trigger fired, recovery
      // started/recovered, guiding recovered, weather-safe-again, cloud,
      // autofocus-completed.
      case NotificationCategory.sequenceStarted:
      case NotificationCategory.sequencePaused:
      case NotificationCategory.sequenceResumed:
      case NotificationCategory.targetStarted:
      case NotificationCategory.autofocusCompleted:
      case NotificationCategory.frameCaptured:
      case NotificationCategory.frameRejected:
      case NotificationCategory.recoveryStarted:
      case NotificationCategory.recoveryRecovered:
      case NotificationCategory.guidingRecovered:
      case NotificationCategory.weatherSafeAgain:
      case NotificationCategory.cloudArriving:
      case NotificationCategory.cloudOpening:
      case NotificationCategory.triggerFired:
        return null;
    }
  }

  static bool _always(PushNotificationConfig _) => true;

  core.EventCategory _mapCategory(NotificationCategory category) {
    switch (category) {
      case NotificationCategory.sequenceStarted:
      case NotificationCategory.sequenceCompleted:
      case NotificationCategory.sequenceFailed:
      case NotificationCategory.sequencePaused:
      case NotificationCategory.sequenceStopped:
      case NotificationCategory.sequenceResumed:
      case NotificationCategory.targetStarted:
      case NotificationCategory.targetCompleted:
      case NotificationCategory.meridianFlipPerformed:
      case NotificationCategory.autofocusCompleted:
      case NotificationCategory.autofocusContinued:
      case NotificationCategory.autofocusFailed:
      case NotificationCategory.frameCaptured:
      case NotificationCategory.frameRejected:
      case NotificationCategory.problemNoticed:
      case NotificationCategory.recoveryStarted:
      case NotificationCategory.recoveryRecovered:
      case NotificationCategory.recoveryGaveUp:
      case NotificationCategory.triggerFired:
        return core.EventCategory.sequencer;
      case NotificationCategory.exposureFailed:
      case NotificationCategory.transientDiscovered:
      // The draft is a picture the rig made, which is what the imaging
      // category means on the wire.
      case NotificationCategory.darkroomDraftReady:
        return core.EventCategory.imaging;
      case NotificationCategory.guidingLost:
      case NotificationCategory.guidingRecovered:
        return core.EventCategory.guiding;
      case NotificationCategory.weatherUnsafe:
      case NotificationCategory.weatherSafeAgain:
      case NotificationCategory.cloudArriving:
      case NotificationCategory.cloudOpening:
        return core.EventCategory.safety;
      case NotificationCategory.equipmentDisconnected:
        return core.EventCategory.equipment;
      case NotificationCategory.diskSpaceLow:
      case NotificationCategory.custom:
        return core.EventCategory.system;
    }
  }
}

/// Per-category systemPush spec: which [PushNotificationConfig] toggle gates
/// it and the priority the phone push carries.
class _PushSpec {
  final bool Function(PushNotificationConfig) enabled;
  final PushNotificationPriority priority;

  const _PushSpec({required this.enabled, required this.priority});
}
