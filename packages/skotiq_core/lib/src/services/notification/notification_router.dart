// Central notification dispatcher.
//
// NotificationRouter sits between two worlds:
//   - INPUT:  the Rust event stream (SkotiqEvent) and the sequence
//             executor's high-level events.
//   - OUTPUT: per-transport NotificationTransport implementations.
//
// Responsibilities, in order they happen for each input event:
//   1. Classify the event into a NotificationCategory. Some categories
//      have a 1:1 mapping (`Completed` -> sequenceCompleted), some are
//      derived from data fields (`InstructionProgress` with
//      "meridian" -> meridianFlipPerformed).
//   2. Look up the routing rule for that category in the matrix.
//   3. Apply min-severity, rate-limit, debounce filters.
//   4. Render title + body templates from the per-rule template (or the
//      built-in default) with the context map extracted from the event.
//   5. Fan out to each enabled transport in parallel.
//
// All work is async and non-blocking. A transport that takes 20 s to
// time out cannot stall sequence execution because the router never
// awaits the transport futures from inside the event handler — it
// schedules them via `Future.microtask` and surfaces failures via the
// per-transport [lastResult] surface for the UI.

import 'dart:async';
import 'dart:developer' as developer;

import '../../models/backend/event_types.dart';
import '../../models/notification/notification_categories.dart';
import '../../providers/sequence/run_stop_classification.dart';
import 'event_classifier.dart';
import 'notification_presentation.dart';
import 'notification_signature.dart';
import 'notification_template.dart';
import 'stop_push_arbiter.dart';
import 'transports/notification_transport.dart';
import 'transports/system_push_transport.dart';

/// What one routed message actually did.
///
/// The router has seven legitimate reasons to send nothing — routing off, the
/// row off, below the row's severity floor, debounced, rate-limited, no
/// configured transport, and already-said — and a producer that reports
/// "notified" needs to know which one happened. [dispatched] names the
/// transports the message was HANDED TO (never one that declines it, such as
/// Mobile push for an event switched off there); each transport's own success or
/// failure lands later in [NotificationRouter.lastResults], because the sends
/// are deliberately not awaited.
class NotificationRouteOutcome {
  /// The transports the message was handed to, in routing order.
  final List<NotificationTransportKind> dispatched;

  /// Why nothing was sent, naming the gate that decided. Null when something
  /// was.
  final String? dropReason;

  const NotificationRouteOutcome.dispatched(this.dispatched)
    : dropReason = null;

  const NotificationRouteOutcome.dropped(String this.dropReason)
    : dispatched = const [];

  /// True when the message reached at least one transport.
  bool get anyDispatched => dispatched.isNotEmpty;

  /// The transports named for an operator-facing sentence.
  String get dispatchedNames => dispatched.map((k) => k.name).join(', ');
}

/// Public entry point the router uses to fan out a single notification.
/// Tests can construct a router with an in-memory transport set and
/// call [route] directly with a synthetic context.
class NotificationRouter {
  final Map<NotificationTransportKind, NotificationTransport> _transports;
  NotificationRoutingMatrix _matrix;

  /// Last successful / failed result per transport (for the settings UI).
  final Map<NotificationTransportKind, NotificationResult> _lastResults = {};

  /// Per-category rate-limit window state.
  final Map<NotificationCategory, _RateWindow> _rateWindows = {};

  /// Per-category last fire time (for debouncing).
  final Map<NotificationCategory, DateTime> _lastFireTime = {};

  /// Recently-emitted content signatures per transport kind, for
  /// cross-producer de-duplication.
  ///
  /// The router is the single producer for every transport, but it is driven
  /// from several converging inputs that describe one physical happening:
  ///   * its own [attachEventStream] subscription (core event stream), which
  ///     the classifier may map to the same category from more than one wire
  ///     event — an operator Stop arrives as BOTH a sequencer `Error` carrying
  ///     the "Sequence cancelled" notice AND the `Stopped` lifecycle event, and
  ///   * an explicit [route] / [routeCriticalPush] call from the Run
  ///     Dashboard critical-events bridge (which observes the bridge-typed
  ///     event history — a different representation of the SAME backend events
  ///     with no shared id to dedup on).
  ///
  /// The converging inputs share no id, so the key is what the operator SEES,
  /// not the producer: the router is the one place they all pass through, and
  /// without the dedup one operator Stop reaches the operator three times.
  ///
  /// Per transport kind, never global: an at-idle external alert (webhook,
  /// e-mail, MQTT) must not be swallowed because the UI already said it.
  final Map<NotificationTransportKind, Map<String, DateTime>>
  _recentSignatures = {};

  /// How long a systemPush content signature suppresses an identical repeat.
  /// Long enough to absorb the small skew between the core stream and the
  /// bridge's event-history update, short enough that a genuinely repeated
  /// alert minutes later still fires.
  static const Duration _pushDedupeWindow = Duration(seconds: 15);

  /// The same window for every other transport. Shorter than the push window
  /// because the converging producers fire in the same millisecond, and a
  /// repeat the operator can plausibly read as new information should still
  /// get through.
  static const Duration _contentDedupeWindow = Duration(seconds: 5);

  /// Injectable clock. Production uses `DateTime.now`; tests drive the dedupe
  /// windows and the rendered clock time deterministically.
  final DateTime Function() _now;

  /// Event stream subscription.
  StreamSubscription<SkotiqEvent>? _subscription;

  /// Decides the ONE phone push a stop episode is allowed, and whether the
  /// operator's own press gets one at all (it does not). Built lazily so a
  /// router that never sees a stop arms no timer.
  StopPushArbiter? _stopPushes;

  /// Optional per-sequence overrides. When `_activeSequenceId` matches
  /// the executor's current sequence id (set by the executor bridge),
  /// rules in `_sequenceOverrides[activeId]` take precedence over the
  /// global matrix for that category.
  String? _activeSequenceId;
  final Map<String, Map<NotificationCategory, NotificationRoutingRule>>
  _sequenceOverrides = {};

  NotificationRouter({
    required List<NotificationTransport> transports,
    NotificationRoutingMatrix matrix = const NotificationRoutingMatrix(
      enabled: true,
    ),
    DateTime Function()? clock,
  }) : _transports = {for (final t in transports) t.kind: t},
       _now = clock ?? DateTime.now,
       _matrix = matrix.rules.isEmpty
           ? NotificationRoutingMatrix.defaults().copyWith(
               enabled: matrix.enabled,
             )
           : matrix;

  // Public surface

  NotificationRoutingMatrix get matrix => _matrix;

  Map<NotificationTransportKind, NotificationResult> get lastResults =>
      Map.unmodifiable(_lastResults);

  /// Update the matrix in-place. Cheap — used by the Riverpod provider
  /// when the user toggles a setting.
  void updateMatrix(NotificationRoutingMatrix matrix) {
    _matrix = matrix.rules.isEmpty
        ? NotificationRoutingMatrix.defaults().copyWith(enabled: matrix.enabled)
        : matrix;
  }

  /// Set per-sequence routing overrides. `null` clears them.
  void setSequenceOverrides(
    String sequenceId,
    Map<NotificationCategory, NotificationRoutingRule>? overrides,
  ) {
    if (overrides == null) {
      _sequenceOverrides.remove(sequenceId);
    } else {
      _sequenceOverrides[sequenceId] = Map.of(overrides);
    }
  }

  /// Tell the router which sequence is currently running. Pass `null`
  /// when no sequence is active.
  void setActiveSequence(String? sequenceId) {
    _activeSequenceId = sequenceId;
  }

  /// Register an event stream and start dispatching. Calling twice
  /// cancels the previous subscription.
  void attachEventStream(Stream<SkotiqEvent> events) {
    _subscription?.cancel();
    _subscription = events.listen(
      _onEvent,
      onError: (e) {
        developer.log(
          '[NotificationRouter] Event stream error: $e',
          name: 'NotificationRouter',
          level: 1000,
          error: e,
        );
      },
    );
  }

  /// Dispose all subscriptions + transports.
  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    _stopPushes?.dispose();
    _stopPushes = null;
    for (final t in _transports.values) {
      await t.dispose();
    }
  }

  /// Fire a notification directly. Public so the sequence executor (and
  /// the custom NotificationNode integration) can push events the raw
  /// stream doesn't carry.
  void route(
    NotificationCategory category,
    Map<String, String> contextValues, {
    EventSeverity severity = EventSeverity.info,
  }) {
    if (!_matrix.enabled) return;
    final rule = _ruleFor(category);
    if (!rule.enabled) return;
    if (severity.index < rule.minSeverity.index) return;

    if (_isDebounced(category, rule)) return;
    if (_isRateLimited(category, rule)) return;

    final configured = _eligibleTransports(rule.transports);
    if (configured.isEmpty) return;

    if (category == NotificationCategory.sequenceStopped) {
      _lastFireTime[category] = _now();
      _recordRateHit(category);
      _routeStopped(rule, contextValues, configured);
      return;
    }

    final message = _render(category, rule, contextValues);
    final eligible = _willing(configured, message);
    if (eligible.isEmpty) return;

    _lastFireTime[category] = _now();
    _recordRateHit(category);
    for (final transport in eligible) {
      _dispatch(transport, message);
    }
  }

  /// A classified event is presented at its category's severity; [severity]
  /// on [route] only decides whether the rule's floor lets it through.
  NotificationMessage _render(
    NotificationCategory category,
    NotificationRoutingRule rule,
    Map<String, String> values,
  ) {
    final ctx = NotificationContext(values);
    final defaults = NotificationPresentation.of(category);
    return NotificationMessage(
      category: category,
      title: renderNotificationTemplate(
        rule.titleTemplate ?? defaults.title,
        ctx,
        clock: _now,
      ),
      body: renderNotificationTemplate(
        rule.bodyTemplate ?? defaults.body,
        ctx,
        clock: _now,
      ),
    );
  }

  /// A stop is the one category whose copy depends on an event OTHER than the
  /// one being routed: the executor's decision row is the only thing that says
  /// WHO ended the run, and it can arrive after the cancel notice.
  ///
  /// The immediate transports (toast, external alerts) render with whatever the
  /// wire has proved by now — degrading to the cause-neutral sentence rather
  /// than inventing an author. The phone push is handed to [StopPushArbiter]:
  /// it waits out the authorship grace, fires at most once per stop episode,
  /// and stays silent when the operator pressed Stop themselves (owner
  /// decision 2, 2026-08-14).
  void _routeStopped(
    NotificationRoutingRule rule,
    Map<String, String> contextValues,
    List<NotificationTransport> eligible,
  ) {
    final episode = _stopPushArbiter.noteStopNotification(
      runId: int.tryParse(contextValues[kStopRunIdContextKey] ?? ''),
      values: contextValues,
    );
    // One stop is one toast: a stop publishes several events and the cause
    // learned between them must not raise a second, differently-worded copy of
    // the same statement (the content-signature dedup cannot collapse those —
    // they no longer read the same).
    if (episode.announced) return;
    for (final transport in eligible) {
      if (transport.kind == NotificationTransportKind.systemPush) continue;
      _dispatchStop(transport, rule, contextValues, episode.decision);
    }
  }

  StopPushArbiter get _stopPushArbiter =>
      _stopPushes ??= StopPushArbiter(clock: _now, onPush: _pushStop);

  /// The single phone push a non-operator stop earns, fired once the arbiter
  /// knows who is responsible for it.
  void _pushStop(SequenceStopDecision? decision, Map<String, String> values) {
    final transport = _transports[NotificationTransportKind.systemPush];
    if (transport == null || !transport.isConfigured) return;
    final rule = _ruleFor(NotificationCategory.sequenceStopped);
    if (!rule.enabled) return;
    if (!rule.transports.contains(NotificationTransportKind.systemPush)) return;
    developer.log(
      '[$kStopClassificationLogTag] notification_router: pushing a '
      '${decision?.author.name ?? 'cause-neutral'} stop to the phone',
      name: 'NotificationRouter',
    );
    _dispatchStop(transport, rule, values, decision);
  }

  void _dispatchStop(
    NotificationTransport transport,
    NotificationRoutingRule rule,
    Map<String, String> values,
    SequenceStopDecision? decision,
  ) {
    final clause = sequenceStopCauseClause(decision);
    _dispatch(
      transport,
      _render(NotificationCategory.sequenceStopped, rule, {
        ...values,
        kStopCauseContextKey: clause.isEmpty
            ? 'Sequence stopped'
            : 'Sequence stopped $clause',
      }),
    );
  }

  /// Page the phone at `critical` priority with copy the caller already
  /// rendered, for alerts that have no [NotificationCategory] of their own:
  /// the Run Dashboard's critical-events bridge (generic system errors, FITS
  /// save failures) and the recovery entry/exit pushes.
  ///
  /// When the classifier also recognizes the underlying event (a guiding
  /// StarLost, say) the router's own event-stream subscription pushes too; the
  /// systemPush content-signature dedup collapses the pair into one page.
  ///
  /// Respects the push master gate (inside the transport's broadcaster) and
  /// the matrix master `enabled` flag.
  void routeCriticalPush({
    required String title,
    required String body,
    required String eventType,
    required EventCategory eventCategory,
  }) {
    if (!_matrix.enabled) return;
    final transport = _transports[NotificationTransportKind.systemPush];
    if (transport is! SystemPushTransport) return;

    // Cross-stream dedup: the classifier path keys the same phone push on its
    // rendered (title + body). The operator only ever sees title + body, so a
    // shared (title + body) signature is exactly what must not page twice.
    if (_isDuplicate(NotificationTransportKind.systemPush, title, body)) return;

    transport.enqueueExplicit(
      title: title,
      body: body,
      eventType: eventType,
      eventCategory: eventCategory,
    );
  }

  /// Bridge for the in-sequence `NotificationNode`.
  ///
  /// The executor (Rust side) raises a `Custom` event whose data map
  /// carries the rendered title + message. UI callers that already have
  /// a rendered title/body can use this entry point to push the node
  /// through the routing matrix without going through the event stream
  /// classifier. The node itself supplies optional explicit transports;
  /// when non-empty those override the matrix entry for `custom`.
  void routeNotificationNode({
    required String title,
    required String body,
    EventSeverity severity = EventSeverity.info,
    List<NotificationTransportKind>? explicitTransports,
  }) {
    routeRendered(
      category: NotificationCategory.custom,
      title: title,
      body: body,
      severity: severity,
      explicitTransports: explicitTransports,
    );
  }

  /// Route copy that is ALREADY rendered, under [category]'s matrix row.
  ///
  /// [route] renders title and body from the category's templates; this entry
  /// point exists for the producers that have composed their own message — a
  /// `NotificationNode`'s script, the dawn autopilot's morning report — and
  /// would lose it to a template. Everything else is identical: the same
  /// enabled/severity/debounce/rate gates, on the row the operator can see and
  /// edit in Settings.
  ///
  /// [severity] is the message's own: it is checked against the row's floor
  /// and it is what the transports present (toast style, Pushover priority,
  /// the embed color of a `custom` message).
  ///
  /// Returns what was handed to a transport, or which gate sent nothing, so a
  /// caller that states an outcome (the dawn autopilot's morning message lists
  /// the night's delivery problems) can state the real one.
  NotificationRouteOutcome routeRendered({
    required NotificationCategory category,
    required String title,
    required String body,
    EventSeverity severity = EventSeverity.info,
    List<NotificationTransportKind>? explicitTransports,
    String? deepLink,
  }) {
    if (!_matrix.enabled) {
      return const NotificationRouteOutcome.dropped(
        'Notification routing is switched off in Settings',
      );
    }
    final baseRule = _ruleFor(category);
    if (!baseRule.enabled) {
      return NotificationRouteOutcome.dropped(
        'The ${category.name} routing row is switched off in Settings',
      );
    }
    if (severity.index < baseRule.minSeverity.index) {
      return NotificationRouteOutcome.dropped(
        'The ${category.name} routing row only sends '
        '${baseRule.minSeverity.name} and above, and this was ${severity.name}',
      );
    }
    if (_isDebounced(category, baseRule)) {
      return NotificationRouteOutcome.dropped(
        'Another ${category.name} notification went out inside this row\'s '
        'debounce window',
      );
    }
    if (_isRateLimited(category, baseRule)) {
      return NotificationRouteOutcome.dropped(
        'The ${category.name} routing row has spent its hourly rate limit',
      );
    }

    final configured = _eligibleTransports(
      explicitTransports ?? baseRule.transports,
    );
    if (configured.isEmpty) {
      return NotificationRouteOutcome.dropped(
        'No transport on the ${category.name} routing row is configured — '
        'nothing is paired or set up to receive it',
      );
    }
    final message = NotificationMessage(
      category: category,
      title: title,
      body: body,
      severity: severity,
      deepLink: deepLink,
    );
    final eligible = _willing(configured, message);
    if (eligible.isEmpty) {
      return NotificationRouteOutcome.dropped(
        configured.map((t) => t.declines(message)).nonNulls.join('; '),
      );
    }

    _lastFireTime[category] = _now();
    _recordRateHit(category);
    final dispatched = <NotificationTransportKind>[];
    for (final transport in eligible) {
      if (_dispatch(transport, message)) dispatched.add(transport.kind);
    }
    if (dispatched.isEmpty) {
      return const NotificationRouteOutcome.dropped(
        'The same message had already gone out on every routed transport '
        'moments earlier',
      );
    }
    return NotificationRouteOutcome.dispatched(dispatched);
  }

  /// Send a single test notification through one specific transport.
  /// Returns the result so the settings UI can render success / error
  /// inline next to the test-send button.
  Future<NotificationResult> sendTest(
    NotificationTransportKind kind, {
    String title = 'Skotiq test',
    String body = 'This is a test notification from Skotiq.',
    NotificationCategory category = NotificationCategory.custom,
  }) async {
    final transport = _transports[kind];
    if (transport == null) {
      return NotificationResult.fail('Transport not available');
    }
    if (!transport.isConfigured) {
      return NotificationResult.fail('${transport.name} is not configured');
    }
    late NotificationResult result;
    try {
      result = await transport.send(
        NotificationMessage(category: category, title: title, body: body),
      );
    } catch (error) {
      result = NotificationResult.fail(error.toString());
    }
    _lastResults[kind] = result;
    return result;
  }

  /// Read the live config from a typed transport, if registered.
  NotificationTransport? transportOf(NotificationTransportKind kind) =>
      _transports[kind];

  // Internal: event mapping

  void _onEvent(SkotiqEvent event) {
    if (!_matrix.enabled) return;

    // NotificationNode emits a sequencer event of type
    // `Notification` whose data carries title/message/level/transports.
    // It bypasses the auto-classifier because the user's chosen
    // explicit_transports must override the matrix's `custom` rule.
    if (event.category == EventCategory.sequencer &&
        event.eventType == 'Notification') {
      final title = (event.data['title'] as String?) ?? '';
      final body = (event.data['message'] as String?) ?? '';
      final transports = _parseExplicitTransportsFromEvent(event.data);
      routeNotificationNode(
        title: title,
        body: body,
        severity: event.severity,
        explicitTransports: transports,
      );
      return;
    }

    // OTA "update available" is an operator-driven system event the shared
    // classifier deliberately does not route to a notification category. The
    // router pushes it here instead, so paired phones still learn a new build
    // is available. Routed as `custom` with explicit in-app + systemPush
    // transports so it does not depend on the user's `custom` matrix wiring.
    if (event.category == EventCategory.system &&
        event.eventType == 'UpdateAvailable') {
      final latest =
          (event.data['latestVersion'] as String?) ?? 'a new version';
      final current =
          (event.data['currentVersion'] as String?) ?? 'the current build';
      final title = 'Skotiq $latest available';
      final body =
          'Open Settings > Updates to install the new build (currently on $current).';
      final message = NotificationMessage(
        category: NotificationCategory.custom,
        title: title,
        body: body,
      );
      for (final transport in _willing(
        _eligibleTransports(const [
          NotificationTransportKind.inApp,
          NotificationTransportKind.systemPush,
        ]),
        message,
      )) {
        _dispatch(transport, message);
      }
      return;
    }

    // The executor's stop decision raises no notification of its own, but it
    // is the ONLY event that names who ended the run — the phone push for a
    // stop is decided off it (and withheld when the author is the operator).
    final stopDecision = NotificationEventClassifier.stopDecisionOf(event);
    if (stopDecision != null) {
      _stopPushArbiter.noteDecision(
        stopDecision,
        runId: event.data['sequence_run_id'] as int?,
      );
      return;
    }
    if (event.category == EventCategory.sequencer &&
        event.eventType == 'Started') {
      // Run boundary: nothing published from here belongs to the previous
      // run's stop episode.
      _stopPushArbiter.noteRunBoundary();
    }

    // Single source of truth for event -> category classification, shared
    // with PushNotificationService (see event_classifier.dart).
    final classified = NotificationEventClassifier.classify(event);
    if (classified == null) return;
    final context = _buildContext(event, classified.context);
    route(classified.category, context, severity: classified.severity);
  }

  /// Pull `explicit_transports` out of a NotificationNode Rust event
  /// payload. Returns null if the field is missing or empty (which means
  /// "inherit the matrix's `custom` rule transports").
  List<NotificationTransportKind>? _parseExplicitTransportsFromEvent(
    Map<String, dynamic> data,
  ) {
    final raw = data['explicit_transports'];
    if (raw is! List) return null;
    final out = <NotificationTransportKind>[];
    for (final entry in raw) {
      if (entry is String) {
        final t = NotificationTransportKind.fromStorageKey(entry);
        if (t != null) out.add(t);
      }
    }
    return out.isEmpty ? null : out;
  }

  Map<String, String> _buildContext(
    SkotiqEvent event,
    Map<String, String> overrides,
  ) {
    final ctx = <String, String>{};
    // Pull common scalar fields from the event's data map. We never
    // override a value the classifier set (those are more specific).
    for (final entry in event.data.entries) {
      final value = entry.value;
      if (value is String || value is num || value is bool) {
        ctx[entry.key] = value.toString();
      }
    }
    ctx.addAll(overrides); // overrides win
    return ctx;
  }

  // Internal: filters / dispatch

  NotificationRoutingRule _ruleFor(NotificationCategory category) {
    final activeSeq = _activeSequenceId;
    if (activeSeq != null) {
      final overrides = _sequenceOverrides[activeSeq];
      if (overrides != null && overrides.containsKey(category)) {
        return overrides[category]!;
      }
    }
    return _matrix.ruleFor(category);
  }

  bool _isDebounced(
    NotificationCategory category,
    NotificationRoutingRule rule,
  ) {
    if (rule.debounceSeconds <= 0) return false;
    final last = _lastFireTime[category];
    if (last == null) return false;
    return _now().difference(last) < Duration(seconds: rule.debounceSeconds);
  }

  bool _isRateLimited(
    NotificationCategory category,
    NotificationRoutingRule rule,
  ) {
    if (rule.maxPerHour <= 0) return false;
    final window = _rateWindows.putIfAbsent(
      category,
      () => _RateWindow(maxAge: const Duration(hours: 1)),
    );
    window.prune(now: _now());
    return window.count >= rule.maxPerHour;
  }

  void _recordRateHit(NotificationCategory category) {
    final window = _rateWindows.putIfAbsent(
      category,
      () => _RateWindow(maxAge: const Duration(hours: 1)),
    );
    window.record(_now());
  }

  /// Hand one message to one transport. Returns false when the dedupe window
  /// swallowed it, which is the seventh way a routed message can send nothing.
  bool _dispatch(NotificationTransport transport, NotificationMessage message) {
    // Cross-producer de-duplication. Several converging inputs describe one
    // physical happening (see [_recentSignatures]); the operator must be told
    // once. The signature is per transport kind, so an external alert is never
    // swallowed because the UI already said it.
    if (_isDuplicate(transport.kind, message.title, message.body)) return false;

    // Fire and forget — the transport's own timeout caps the wait. We
    // record the result so the settings UI can show the latest status.
    Future.microtask(() async {
      late NotificationResult result;
      try {
        result = await transport.send(message);
      } catch (error, stackTrace) {
        result = NotificationResult.fail(error.toString());
        developer.log(
          '[NotificationRouter] ${transport.name} threw while sending: $error',
          name: 'NotificationRouter',
          level: 1000,
          error: error,
          stackTrace: stackTrace,
        );
      }
      _lastResults[transport.kind] = result;
      if (!result.success && !result.skipped) {
        developer.log(
          '[NotificationRouter] ${transport.name} send failed: ${result.error}',
          name: 'NotificationRouter',
          level: 900,
        );
      }
    });
    return true;
  }

  /// The transports of [configured] that will try to send [message].
  List<NotificationTransport> _willing(
    List<NotificationTransport> configured,
    NotificationMessage message,
  ) => [
    for (final transport in configured)
      if (transport.declines(message) == null) transport,
  ];

  List<NotificationTransport> _eligibleTransports(
    Iterable<NotificationTransportKind> kinds,
  ) {
    final eligible = <NotificationTransport>[];
    final seen = <NotificationTransportKind>{};
    for (final kind in kinds) {
      if (!seen.add(kind)) continue;
      final transport = _transports[kind];
      if (transport != null && transport.isConfigured) {
        eligible.add(transport);
      }
    }
    return eligible;
  }

  /// True if a notification with the same NORMALIZED (title + body) already
  /// went out on [kind] inside its dedupe window. Records the signature when
  /// it is not a duplicate so the next identical copy inside the window is
  /// suppressed.
  ///
  /// ## Why the key is normalized
  ///
  /// Trailing sentence punctuation, letter case and internal whitespace runs
  /// are differences between PRODUCERS of one statement, never differences the
  /// operator can act on, so they are stripped before keying: two producers of
  /// the same refusal can otherwise differ by a single full stop and both be
  /// shown.
  ///
  /// `?` is deliberately NOT stripped: a question and a statement are different
  /// notifications.
  bool _isDuplicate(NotificationTransportKind kind, String title, String body) {
    final window = kind == NotificationTransportKind.systemPush
        ? _pushDedupeWindow
        : _contentDedupeWindow;
    final now = _now();
    final seen = _recentSignatures.putIfAbsent(kind, () => {});
    seen.removeWhere((_, when) => now.difference(when) > window);
    // One shared rule, in `notification_signature.dart`: every surface that
    // asks "have I already said this?" calls the same implementation.
    final signature = notificationContentSignature(
      discriminator: kind.name,
      title: title,
      body: body,
    );
    final last = seen[signature];
    if (last != null && now.difference(last) < window) return true;
    seen[signature] = now;
    return false;
  }
}

/// Sliding rate-limit window for [_isRateLimited] / [_recordRateHit].
class _RateWindow {
  final Duration maxAge;
  final List<DateTime> _hits = [];
  _RateWindow({required this.maxAge});

  int get count => _hits.length;

  void record(DateTime now) {
    _hits.add(now);
    prune(now: now);
  }

  void prune({DateTime? now}) {
    final cutoff = (now ?? DateTime.now()).subtract(maxAge);
    while (_hits.isNotEmpty && _hits.first.isBefore(cutoff)) {
      _hits.removeAt(0);
    }
  }
}
