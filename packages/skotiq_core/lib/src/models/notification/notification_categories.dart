// Notification routing categories and per-transport configuration models.
//
// PushNotificationService carries the critical-event push path, but only a
// fixed set of toggles. Routing per event type across multiple transports
// ("send target-complete to Pushover, send weather-unsafe to Telegram +
// Discord, send disk-low to email") is what this vocabulary exists for.
//
// Single source of truth: `NotificationCategory` is the canonical enum
// everything else keys off. Adding a new category here surfaces a switch
// exhaustiveness warning at every dispatch site (router event mapper,
// settings UI rows, default-routing-rules table) so we can never forget
// to handle a new event class.

import 'package:equatable/equatable.dart';
import '../backend/event_types.dart';

/// One semantic class of sequencer / system event the user can route.
///
/// These intentionally do NOT mirror Rust `EventCategory` 1:1 — that enum
/// is too coarse (a single `sequencer` value covers start, complete, fail,
/// target start, target complete, meridian flip…). The router maps from
/// the raw [SkotiqEvent] stream onto these finer-grained categories;
/// users see only these labels in the settings UI.
enum NotificationCategory {
  // Sequence lifecycle
  sequenceStarted('Sequence Started'),
  sequenceCompleted('Sequence Completed'),
  sequenceFailed('Sequence Failed'),
  sequenceStopped('Sequence Stopped'),
  sequencePaused('Sequence Paused'),
  sequenceResumed('Sequence Resumed'),

  // Target lifecycle
  targetStarted('Target Started'),
  targetCompleted('Target Completed'),

  // Mount / hardware milestones
  meridianFlipPerformed('Meridian Flip Performed'),
  autofocusCompleted('Autofocus Completed'),
  autofocusFailed('Autofocus Failed'),

  /// An autofocus (a trigger's refocus, an Autofocus node, a recovery or
  /// post-flip refocus) failed to converge and the run CONTINUES on the
  /// restored last-good focus; a failed autofocus never parks or ends a run.
  /// Info, not error: the night goes on slightly soft, and an error here would
  /// train the operator to ignore the alerts that do end a run.
  autofocusContinued('Autofocus Continued'),

  // Imaging
  frameCaptured('Frame Captured'),

  /// A streak of frames failed grading and reached the operator's limit. Told
  /// once per streak; the run keeps imaging and the rejects are kept.
  frameRejected('Frames Being Rejected'),

  /// A quality problem the sequencer judged — a Center that could not solve,
  /// guiding RMS over a limit, a dither that did not settle, a post-flip
  /// check — and carried on through, because the operator has not asked for
  /// such problems to stop the run (owner decision 2026-10-06).
  problemNoticed('Problem Noticed'),
  exposureFailed('Exposure Failed'),

  // Recovery / executor health
  recoveryStarted('Recovery Started'),
  recoveryRecovered('Recovery Recovered'),
  recoveryGaveUp('Recovery Gave Up'),

  // Guiding
  guidingLost('Guiding Lost'),
  guidingRecovered('Guiding Recovered'),

  // Weather / safety
  weatherUnsafe('Weather Unsafe'),
  weatherSafeAgain('Weather Safe Again'),
  cloudArriving('Cloud Arriving'),
  cloudOpening('Cloud Clearing'),

  // Astronomical discovery (First Light / Pillar B)
  transientDiscovered('Transient Discovered'),

  /// The dawn autopilot finished a night's Darkroom pass and there is a first
  /// draft to look at.
  ///
  /// Its own category rather than a `sequenceCompleted` reuse because it is the
  /// one notification that carries a deep link: the tap opens the draft's recipe
  /// in the Darkroom, and a category shared with the end of a run would send
  /// every run-completion push to the same place.
  darkroomDraftReady('Darkroom Draft Ready'),

  // System / operational
  diskSpaceLow('Disk Space Low'),
  equipmentDisconnected('Equipment Disconnected'),
  triggerFired('Sequencer Trigger Fired'),

  // Custom (user-script / NotificationNode-defined)
  custom('Custom');

  final String label;
  const NotificationCategory(this.label);

  /// Stable string key for JSON / DAO storage. Uses the enum `name` so a
  /// future label rewording (English wording is the `label`) never changes
  /// the persisted key.
  String get storageKey => name;

  /// Default severity for the category. Used as the lower bound for
  /// "min severity" filters when the user hasn't customised the rule.
  EventSeverity get defaultSeverity {
    switch (this) {
      case NotificationCategory.sequenceStarted:
      case NotificationCategory.sequenceResumed:
      case NotificationCategory.sequencePaused:
      case NotificationCategory.targetStarted:
      case NotificationCategory.targetCompleted:
      case NotificationCategory.meridianFlipPerformed:
      case NotificationCategory.autofocusCompleted:
      case NotificationCategory.autofocusContinued:
      case NotificationCategory.frameCaptured:
      case NotificationCategory.recoveryRecovered:
      case NotificationCategory.guidingRecovered:
      case NotificationCategory.weatherSafeAgain:
      case NotificationCategory.cloudOpening:
      case NotificationCategory.triggerFired:
      case NotificationCategory.custom:
      // An operator (or safety trigger) chose to stop: worth telling a phone,
      // never worth an alarm.
      case NotificationCategory.sequenceStopped:
        return EventSeverity.info;
      case NotificationCategory.sequenceCompleted:
      // The morning draft is good news waiting to be looked at, never an
      // alarm — it fires hours after the rig has finished and parked.
      case NotificationCategory.darkroomDraftReady:
        return EventSeverity.info;
      case NotificationCategory.frameRejected:
      case NotificationCategory.problemNoticed:
      case NotificationCategory.cloudArriving:
      case NotificationCategory.recoveryStarted:
        return EventSeverity.warning;
      case NotificationCategory.sequenceFailed:
      case NotificationCategory.autofocusFailed:
      case NotificationCategory.exposureFailed:
      case NotificationCategory.guidingLost:
      case NotificationCategory.weatherUnsafe:
      case NotificationCategory.diskSpaceLow:
      case NotificationCategory.equipmentDisconnected:
        return EventSeverity.error;
      // A possible new transient is a time-critical, must-not-miss event: the
      // chase window closes by morning. Severity `critical` so it clears the
      // default min-severity bar on the systemPush transport.
      case NotificationCategory.transientDiscovered:
      case NotificationCategory.recoveryGaveUp:
        return EventSeverity.critical;
    }
  }

  /// Single source of truth for "is this category operationally critical?".
  ///
  /// Critical categories are the ones an unattended operator must not miss:
  /// they default into the `systemPush` (mobile) transport in the routing
  /// matrix and drive the Run Dashboard's persistent critical banner. Both
  /// the matrix defaults ([_criticalByDefault]) and any criticality check
  /// elsewhere derive from this one list so they can never drift.
  bool get isCritical {
    switch (this) {
      case NotificationCategory.sequenceFailed:
      case NotificationCategory.recoveryGaveUp:
      case NotificationCategory.weatherUnsafe:
      case NotificationCategory.guidingLost:
      case NotificationCategory.diskSpaceLow:
      case NotificationCategory.equipmentDisconnected:
      case NotificationCategory.autofocusFailed:
      case NotificationCategory.exposureFailed:
      // A possible new transient is operationally critical for a discovery
      // imager: it pushes to the phone by default so the chase happens tonight.
      case NotificationCategory.transientDiscovered:
        return true;
      default:
        return false;
    }
  }

  static NotificationCategory? fromStorageKey(String key) {
    for (final c in NotificationCategory.values) {
      if (c.name == key) return c;
    }
    return null;
  }
}

/// Transport channels a routing rule may target.
///
/// `inApp` and `systemPush` exist for completeness so the routing matrix
/// can replace the legacy `PushNotificationConfig` boolean grid wholesale;
/// the actual implementations of those two predate this file and live in
/// `UiNotificationNotifier` / `PushNotificationService`.
enum NotificationTransportKind {
  inApp('In-app banner'),
  systemPush('Mobile push'),
  email('Email (SMTP)'),
  webhookGeneric('Generic webhook'),
  pushover('Pushover'),
  telegram('Telegram'),
  discord('Discord'),
  mqtt('MQTT');

  final String label;
  const NotificationTransportKind(this.label);

  String get storageKey => name;

  static NotificationTransportKind? fromStorageKey(String key) {
    for (final t in NotificationTransportKind.values) {
      if (t.name == key) return t;
    }
    return null;
  }
}

/// Outcome of a single transport send attempt. Surfaced back to the UI
/// (test-send button shows status, router logs persist last-result per
/// transport).
class NotificationResult extends Equatable {
  final bool success;
  final String? error;
  final int? statusCode;
  final DateTime timestamp;

  NotificationResult.ok({this.statusCode})
    : success = true,
      error = null,
      timestamp = DateTime.now();

  NotificationResult.fail(this.error, {this.statusCode})
    : success = false,
      timestamp = DateTime.now();

  @override
  List<Object?> get props => [success, error, statusCode, timestamp];

  @override
  String toString() =>
      success ? 'NotificationResult.ok' : 'NotificationResult.fail($error)';
}

/// Per-category routing rule: which transports fire, with optional
/// filtering / rate-limiting / templating.
///
/// Persisted as JSON inside the [NotificationRoutingMatrix].
class NotificationRoutingRule extends Equatable {
  /// Transports that should fire for this category. Order matters for the
  /// settings UI summary line ("→ In-app + Pushover").
  final List<NotificationTransportKind> transports;

  /// Minimum event severity required to fire. Events below this are
  /// dropped (e.g. user sets "errors only" for Telegram on the
  /// targetCompleted row → success events are silently dropped).
  final EventSeverity minSeverity;

  /// Maximum number of notifications per hour for this category. `0`
  /// disables rate limiting.
  final int maxPerHour;

  /// Suppress repeated fires for the same category within this many
  /// seconds. `0` disables debouncing.
  final int debounceSeconds;

  /// Custom message template (uses the interpolation engine).
  /// `null` falls back to the per-category default template baked into
  /// the router.
  final String? titleTemplate;
  final String? bodyTemplate;

  /// Whether the rule is enabled. Disabling drops a category from the
  /// dispatcher without losing its configuration.
  final bool enabled;

  const NotificationRoutingRule({
    this.transports = const [NotificationTransportKind.inApp],
    this.minSeverity = EventSeverity.info,
    this.maxPerHour = 0,
    this.debounceSeconds = 0,
    this.titleTemplate,
    this.bodyTemplate,
    this.enabled = true,
  });

  NotificationRoutingRule copyWith({
    List<NotificationTransportKind>? transports,
    EventSeverity? minSeverity,
    int? maxPerHour,
    int? debounceSeconds,
    String? titleTemplate,
    String? bodyTemplate,
    bool? enabled,
    bool clearTitleTemplate = false,
    bool clearBodyTemplate = false,
  }) {
    return NotificationRoutingRule(
      transports: transports ?? this.transports,
      minSeverity: minSeverity ?? this.minSeverity,
      maxPerHour: maxPerHour ?? this.maxPerHour,
      debounceSeconds: debounceSeconds ?? this.debounceSeconds,
      titleTemplate: clearTitleTemplate
          ? null
          : (titleTemplate ?? this.titleTemplate),
      bodyTemplate: clearBodyTemplate
          ? null
          : (bodyTemplate ?? this.bodyTemplate),
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => {
    'transports': transports.map((t) => t.storageKey).toList(),
    'minSeverity': minSeverity.name,
    'maxPerHour': maxPerHour,
    'debounceSeconds': debounceSeconds,
    'titleTemplate': titleTemplate,
    'bodyTemplate': bodyTemplate,
    'enabled': enabled,
  };

  factory NotificationRoutingRule.fromJson(Map<String, dynamic> json) {
    final transportsRaw = json['transports'];
    final transports = <NotificationTransportKind>[];
    if (transportsRaw != null) {
      if (transportsRaw is! List) {
        throw const FormatException('transports must be a list');
      }
      for (final entry in transportsRaw) {
        if (entry is! String) {
          throw const FormatException('transport names must be strings');
        }
        final transport = NotificationTransportKind.fromStorageKey(entry);
        if (transport == null) {
          throw FormatException('unknown notification transport: $entry');
        }
        if (transports.contains(transport)) {
          throw FormatException('duplicate notification transport: $entry');
        }
        transports.add(transport);
      }
    }
    final severityRaw = json['minSeverity'];
    final sevName = severityRaw == null
        ? 'info'
        : severityRaw is String
        ? severityRaw
        : throw const FormatException('minSeverity must be a string');
    final severity = EventSeverity.values.where((e) => e.name == sevName);
    if (severity.isEmpty) {
      throw FormatException('unknown notification severity: $sevName');
    }
    final enabledRaw = json['enabled'];
    if (enabledRaw != null && enabledRaw is! bool) {
      throw const FormatException('enabled must be a boolean');
    }
    return NotificationRoutingRule(
      transports: transports.isEmpty
          ? const [NotificationTransportKind.inApp]
          : transports,
      minSeverity: severity.single,
      maxPerHour: _nonNegativeWholeNumber(json, 'maxPerHour'),
      debounceSeconds: _nonNegativeWholeNumber(json, 'debounceSeconds'),
      titleTemplate: json['titleTemplate'] as String?,
      bodyTemplate: json['bodyTemplate'] as String?,
      enabled: enabledRaw as bool? ?? true,
    );
  }

  @override
  List<Object?> get props => [
    transports,
    minSeverity,
    maxPerHour,
    debounceSeconds,
    titleTemplate,
    bodyTemplate,
    enabled,
  ];
}

/// The full per-category routing table.
///
/// Persisted under a single settings key (`notification_routing_matrix`)
/// as JSON. Missing categories fall back to a built-in default that the
/// router seeds on first access.
class NotificationRoutingMatrix extends Equatable {
  /// Master "notifications enabled" switch. Mirrors the existing
  /// `AppSettingsState.notificationsEnabled` flag, but stays local to the
  /// router so the matrix is self-contained.
  final bool enabled;

  final Map<NotificationCategory, NotificationRoutingRule> rules;

  const NotificationRoutingMatrix({this.enabled = true, this.rules = const {}});

  NotificationRoutingRule ruleFor(NotificationCategory category) {
    return rules[category] ?? _defaultRuleFor(category);
  }

  NotificationRoutingMatrix copyWith({
    bool? enabled,
    Map<NotificationCategory, NotificationRoutingRule>? rules,
  }) {
    return NotificationRoutingMatrix(
      enabled: enabled ?? this.enabled,
      rules: rules ?? this.rules,
    );
  }

  NotificationRoutingMatrix withRule(
    NotificationCategory category,
    NotificationRoutingRule rule,
  ) {
    final next = Map<NotificationCategory, NotificationRoutingRule>.from(rules);
    next[category] = rule;
    return copyWith(rules: next);
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'rules': {
      for (final entry in rules.entries)
        entry.key.storageKey: entry.value.toJson(),
    },
  };

  factory NotificationRoutingMatrix.fromJson(Map<String, dynamic> json) {
    final rulesRaw = json['rules'];
    final parsed = <NotificationCategory, NotificationRoutingRule>{};
    if (rulesRaw != null) {
      if (rulesRaw is! Map) {
        throw const FormatException('rules must be an object');
      }
      rulesRaw.forEach((key, value) {
        if (key is! String) {
          throw const FormatException('routing rule keys must be strings');
        }
        final cat = NotificationCategory.fromStorageKey(key);
        // Unknown categories are ignored for forward compatibility when an
        // older controller reads a matrix written by a newer host.
        if (cat == null) return;
        if (value is! Map) {
          throw FormatException('rule for $key must be an object');
        }
        parsed[cat] = NotificationRoutingRule.fromJson(
          Map<String, dynamic>.from(value),
        );
      });
    }
    final enabledRaw = json['enabled'];
    if (enabledRaw != null && enabledRaw is! bool) {
      throw const FormatException('enabled must be a boolean');
    }
    return NotificationRoutingMatrix(
      enabled: enabledRaw as bool? ?? true,
      rules: parsed,
    );
  }

  /// Built-in defaults: in-app for everything; the categories the mobile
  /// push feed escalates also opt into systemPush.
  ///
  /// [SystemPushTransport] is the single mobile-push producer, so the default
  /// matrix routes every push-worthy category to systemPush or that category
  /// silently stops reaching phones. That is the 8 critical-by-default
  /// categories PLUS the three non-critical completion milestones
  /// (sequenceCompleted, targetCompleted, meridianFlipPerformed). The
  /// per-event toggle still gates each of those inside the transport via
  /// [PushNotificationConfig].
  factory NotificationRoutingMatrix.defaults() {
    const inApp = [NotificationTransportKind.inApp];
    const inAppPush = [
      NotificationTransportKind.inApp,
      NotificationTransportKind.systemPush,
    ];
    final rules = <NotificationCategory, NotificationRoutingRule>{
      for (final c in NotificationCategory.values)
        c: NotificationRoutingRule(
          transports: _systemPushByDefault(c) ? inAppPush : inApp,
          minSeverity: c.defaultSeverity,
        ),
    };
    return NotificationRoutingMatrix(enabled: true, rules: rules);
  }

  @override
  List<Object?> get props => [enabled, rules];
}

/// Categories routed to systemPush by default. The 8 critical-by-default
/// categories plus the three non-critical completion milestones the legacy
/// mobile feed escalated, so the single-producer collapse loses no push.
bool _systemPushByDefault(NotificationCategory c) {
  if (c.isCritical) return true;
  switch (c) {
    case NotificationCategory.sequenceCompleted:
    case NotificationCategory.targetCompleted:
    case NotificationCategory.meridianFlipPerformed:
    // A run that stopped without the operator asking is the other way a night
    // ends, and the person it matters to is asleep (owner decision 2,
    // 2026-08-14). Their own press is withheld further down the pipeline —
    // see [StopPushArbiter] — so this default cannot buzz for a deliberate
    // Stop.
    case NotificationCategory.sequenceStopped:
    // A failed interval autofocus keeps the run going on the last good focus
    // (owner decision 10, 2026-08-14) — the person asleep next to the rig
    // must hear that the night continued degraded, or the decision row is
    // invisible until morning.
    case NotificationCategory.autofocusContinued:
    // A quality problem the run carried on through is the same kind of news:
    // the night went on, possibly degraded, and the person asleep should know.
    case NotificationCategory.problemNoticed:
    // The morning draft is the message this whole release exists to send, and
    // the person it is for is asleep in another room. In-app only would mean
    // the operator learns about it when they next open the desktop app.
    case NotificationCategory.darkroomDraftReady:
      return true;
    default:
      return false;
  }
}

int _nonNegativeWholeNumber(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return 0;
  if (value is! num ||
      !value.isFinite ||
      value.truncateToDouble() != value.toDouble() ||
      value < 0) {
    throw FormatException('$key must be a non-negative whole number');
  }
  return value.toInt();
}

NotificationRoutingRule _defaultRuleFor(NotificationCategory category) {
  return NotificationRoutingMatrix.defaults().ruleFor(category);
}
