// How each notification category is presented, in one table.
//
// A new [NotificationCategory] is one entry in [NotificationPresentation.of]:
// the switch is exhaustive, so the compiler names the missing entry.

import '../../models/backend/event_types.dart';
import '../../models/notification/notification_categories.dart';
import '../push_notification_service.dart';

/// The color family a message is shown in.
enum NotificationTone {
  alert(0xEF4444),
  caution(0xF59E0B),
  good(0x22C55E),
  neutral(0x6366F1);

  /// Discord embed side-bar color.
  final int discordColor;
  const NotificationTone(this.discordColor);

  static NotificationTone ofSeverity(EventSeverity severity) =>
      switch (severity) {
        EventSeverity.critical || EventSeverity.error => alert,
        EventSeverity.warning => caution,
        EventSeverity.info => neutral,
      };
}

/// What a category sends to paired phones: the wire priority, and the
/// per-event switch in [PushNotificationConfig] that can mute it (null when
/// the routing-matrix row is its only control).
class PhonePush {
  final PushNotificationPriority priority;
  final PushToggle? toggle;

  const PhonePush(this.priority, [this.toggle]);
}

class NotificationPresentation {
  /// Default title and body templates, used when the routing rule carries no
  /// template of its own.
  final String title;
  final String body;

  /// Fixed tone, or null when the tone follows the message's own severity
  /// (the sender of a `custom` message decides what it is).
  final NotificationTone? tone;

  /// Shown as a success banner in-app rather than a plain info banner.
  final bool inAppSuccess;

  /// Null for the categories the phone feed does not escalate.
  final PhonePush? push;

  /// The coarse event category a phone push carries on the wire.
  final EventCategory eventCategory;

  const NotificationPresentation({
    required this.title,
    required this.body,
    required this.eventCategory,
    this.tone = NotificationTone.neutral,
    bool? inAppSuccess,
    this.push,
  }) : inAppSuccess = inAppSuccess ?? identical(tone, NotificationTone.good);

  NotificationTone toneAt(EventSeverity severity) =>
      tone ?? NotificationTone.ofSeverity(severity);

  static const _critical = PushNotificationPriority.critical;
  static const _normal = PushNotificationPriority.normal;

  static NotificationPresentation of(
    NotificationCategory category,
  ) => switch (category) {
    NotificationCategory.sequenceStarted => const NotificationPresentation(
      title: 'Sequence started',
      body: 'Sequence started at \${time.clock}.',
      eventCategory: EventCategory.sequencer,
    ),
    NotificationCategory.sequenceCompleted => const NotificationPresentation(
      title: 'Sequence complete',
      body: 'Sequence completed successfully at \${time.clock}.',
      eventCategory: EventCategory.sequencer,
      tone: NotificationTone.good,
      push: PhonePush(_normal, PushToggle.sequenceCompleted),
    ),
    NotificationCategory.sequenceFailed => const NotificationPresentation(
      title: 'Sequence failed',
      body: 'Sequence aborted at \${time.clock}.',
      eventCategory: EventCategory.sequencer,
      tone: NotificationTone.alert,
      push: PhonePush(_critical, PushToggle.sequenceFailed),
    ),
    // Only the wire may name the author: `stop.cause` reads "Sequence
    // stopped", "Sequence stopped by request", "Sequence stopped by autopilot"
    // or "Sequence stopped by the disk-space watchdog" depending on what the
    // executor's decision row proved. A fixed "by request" here would have a
    // weather abort at 3 a.m. claim a human asked for it.
    //
    // The phone hears about a run that ended without the operator asking
    // (owner decision 2, 2026-08-14); their own press never gets that far,
    // the router's StopPushArbiter withholds it.
    NotificationCategory.sequenceStopped => const NotificationPresentation(
      title: 'Sequence stopped',
      body: '\${stop.cause} at \${time.clock}.',
      eventCategory: EventCategory.sequencer,
      push: PhonePush(_normal),
    ),
    NotificationCategory.sequencePaused => const NotificationPresentation(
      title: 'Sequence paused',
      body: 'Sequence paused at \${time.clock}.',
      eventCategory: EventCategory.sequencer,
      tone: NotificationTone.caution,
    ),
    NotificationCategory.sequenceResumed => const NotificationPresentation(
      title: 'Sequence resumed',
      body: 'Sequence resumed at \${time.clock}.',
      eventCategory: EventCategory.sequencer,
    ),
    NotificationCategory.targetStarted => const NotificationPresentation(
      title: 'Target started: \${target.name}',
      body: 'Starting target \${target.name} at \${time.clock}.',
      eventCategory: EventCategory.sequencer,
    ),
    NotificationCategory.targetCompleted => const NotificationPresentation(
      title: 'Target complete: \${target.name}',
      body: 'Finished imaging \${target.name} at \${time.clock}.',
      eventCategory: EventCategory.sequencer,
      tone: NotificationTone.good,
      push: PhonePush(
        PushNotificationPriority.low,
        PushToggle.sequenceCompleted,
      ),
    ),
    NotificationCategory.meridianFlipPerformed =>
      const NotificationPresentation(
        title: 'Meridian flip performed',
        body: 'Meridian flip completed.',
        eventCategory: EventCategory.sequencer,
        push: PhonePush(_normal, PushToggle.meridianFlip),
      ),
    NotificationCategory.autofocusCompleted => const NotificationPresentation(
      title: 'Autofocus complete',
      body: 'Autofocus run completed.',
      eventCategory: EventCategory.sequencer,
      inAppSuccess: true,
    ),
    // The run continues on the last good focus (owner decision 10,
    // 2026-08-14). Muted by the same switch as autofocusFailed, but at the
    // ordinary tier: the run surviving is news, not an emergency.
    NotificationCategory.autofocusContinued => const NotificationPresentation(
      title: 'Autofocus failed — continuing',
      body:
          'Autofocus could not converge; the sequence continues on the '
          'restored last-good focus.',
      eventCategory: EventCategory.sequencer,
      push: PhonePush(_normal, PushToggle.autofocusFailed),
    ),
    NotificationCategory.autofocusFailed => const NotificationPresentation(
      title: 'Autofocus failed',
      body: 'Autofocus run failed.',
      eventCategory: EventCategory.sequencer,
      tone: NotificationTone.alert,
      push: PhonePush(_critical, PushToggle.autofocusFailed),
    ),
    NotificationCategory.frameCaptured => const NotificationPresentation(
      title: 'Frame captured',
      body: 'Frame \${frame} captured (\${exposure.duration}s).',
      eventCategory: EventCategory.sequencer,
    ),
    NotificationCategory.frameRejected => const NotificationPresentation(
      title: 'Frames being rejected',
      body:
          '\${frame.streak} frames in a row were rejected '
          '(\${frame.reason}). The run continues.',
      eventCategory: EventCategory.sequencer,
      tone: NotificationTone.caution,
    ),
    // A quality problem the run carried on through (owner decision
    // 2026-10-06): news for the person asleep, not an alarm.
    NotificationCategory.problemNoticed => const NotificationPresentation(
      title: 'Problem noticed — the run continues',
      body: '\${problem.source}: \${problem.message}',
      eventCategory: EventCategory.sequencer,
      push: PhonePush(_normal),
    ),
    NotificationCategory.exposureFailed => const NotificationPresentation(
      title: 'Exposure failed',
      body: 'Exposure failed: \${frame.reason}.',
      eventCategory: EventCategory.imaging,
      tone: NotificationTone.alert,
      push: PhonePush(_critical, PushToggle.exposureFailed),
    ),
    NotificationCategory.recoveryStarted => const NotificationPresentation(
      title: 'Recovery started',
      body: 'Executor entered recovery at \${time.clock}.',
      eventCategory: EventCategory.sequencer,
      tone: NotificationTone.caution,
    ),
    NotificationCategory.recoveryRecovered => const NotificationPresentation(
      title: 'Recovery succeeded',
      body: 'Executor recovered at \${time.clock}.',
      eventCategory: EventCategory.sequencer,
      tone: NotificationTone.good,
    ),
    NotificationCategory.recoveryGaveUp => const NotificationPresentation(
      title: 'Recovery gave up',
      body: 'Executor exhausted recovery attempts.',
      eventCategory: EventCategory.sequencer,
      tone: NotificationTone.alert,
      push: PhonePush(_critical),
    ),
    NotificationCategory.guidingLost => const NotificationPresentation(
      title: 'Guiding lost',
      body: 'Guide star lost; guiding stopped.',
      eventCategory: EventCategory.guiding,
      tone: NotificationTone.alert,
      push: PhonePush(_critical, PushToggle.guidingLost),
    ),
    NotificationCategory.guidingRecovered => const NotificationPresentation(
      title: 'Guiding recovered',
      body: 'Guiding recovered.',
      eventCategory: EventCategory.guiding,
      tone: NotificationTone.good,
    ),
    NotificationCategory.weatherUnsafe => const NotificationPresentation(
      title: 'Weather unsafe',
      body: 'Safety monitor reports unsafe conditions.',
      eventCategory: EventCategory.safety,
      tone: NotificationTone.alert,
      push: PhonePush(_critical, PushToggle.weatherUnsafe),
    ),
    NotificationCategory.weatherSafeAgain => const NotificationPresentation(
      title: 'Weather safe again',
      body: 'Conditions safe again.',
      eventCategory: EventCategory.safety,
      tone: NotificationTone.good,
    ),
    // An equipment safety fault has no off switch on the phone: the mount may
    // be pointing at the ground.
    NotificationCategory.mountFault => const NotificationPresentation(
      title: 'Mount fault',
      body: '\${mount.message}',
      eventCategory: EventCategory.safety,
      tone: NotificationTone.alert,
      push: PhonePush(_critical),
    ),
    NotificationCategory.cloudArriving => const NotificationPresentation(
      title: 'Clouds arriving',
      body: 'Cloud cover increasing.',
      eventCategory: EventCategory.safety,
      tone: NotificationTone.caution,
    ),
    NotificationCategory.cloudOpening => const NotificationPresentation(
      title: 'Sky is clearing',
      body: 'Cloud cover decreasing.',
      eventCategory: EventCategory.safety,
      tone: NotificationTone.good,
    ),
    // Time-critical for a discovery imager: the chase window closes by
    // morning, so it always reaches the phone when push is on.
    NotificationCategory.transientDiscovered => const NotificationPresentation(
      title: 'Possible new transient',
      body:
          'First Light caught something at \${transient.coords} '
          '(SNR \${transient.snr}). Chase it before it fades.',
      eventCategory: EventCategory.imaging,
      push: PhonePush(_critical),
    ),
    // The dawn autopilot composes its own title and body from the night it
    // processed and routes them already rendered; these defaults are what a
    // matrix test-send shows.
    NotificationCategory.darkroomDraftReady => const NotificationPresentation(
      title: 'Your draft is ready',
      body:
          'The dawn Darkroom pass finished; open the draft to see what '
          'it did.',
      eventCategory: EventCategory.imaging,
      push: PhonePush(_normal),
    ),
    NotificationCategory.diskSpaceLow => const NotificationPresentation(
      title: 'Disk space low',
      body: 'Storage usage exceeded safe threshold.',
      eventCategory: EventCategory.system,
      tone: NotificationTone.alert,
      push: PhonePush(_critical),
    ),
    // Names the device, never its wire id: the classifier resolves
    // `equipment.device_name` to a friendly name and falls back to the device
    // type, so the sentence always has a subject.
    NotificationCategory.equipmentDisconnected =>
      const NotificationPresentation(
        title: 'Equipment disconnected',
        body: '\${equipment.device_name} disconnected.',
        eventCategory: EventCategory.equipment,
        tone: NotificationTone.alert,
        push: PhonePush(_critical, PushToggle.equipmentDisconnected),
      ),
    NotificationCategory.triggerFired => const NotificationPresentation(
      title: 'Trigger fired',
      body: 'The \${trigger.name} trigger fired.',
      eventCategory: EventCategory.sequencer,
    ),
    // Reaches the phone only when the user put Mobile push on the Custom row.
    NotificationCategory.custom => const NotificationPresentation(
      title: 'Skotiq notification',
      body: 'Skotiq fired a custom notification.',
      eventCategory: EventCategory.system,
      tone: null,
      push: PhonePush(PushNotificationPriority.high),
    ),
  };
}
