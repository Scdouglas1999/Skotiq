// EXACTLY-ONCE CANARY (architecture-unification, Subsystem 3).
//
// This is the guard that must be GREEN before the triple mobile-push feed
// is collapsed onto the single router-authoritative path. It pins, for
// every critical event the unattended-night operator must not miss, that:
//
//   * the event classifies to the expected NotificationCategory (the ONE
//     shared classifier the router and the mobile-push service both use);
//   * driving it through the NotificationRouter produces EXACTLY ONE mobile
//     push on the PushNotificationService stream (via SystemPushTransport)
//     — never zero, never two;
//   * the same event also produces EXACTLY ONE in-app dispatch;
//   * the per-category routing toggle is honoured — disabling the category
//     suppresses both the push and the in-app dispatch;
//   * the master push `enabled` gate suppresses the mobile push.
//
// Why this lives here (core) and not only in the app-package
// critical_events_bridge_test: that test exercises the DASHBOARD-BRIDGE
// producer (bridge-typed events). This one exercises the ROUTER producer
// (core-typed events) — the path the plan makes authoritative. The two
// producers are the two halves of the triple feed; the collapse removes one
// of them, and whichever survives must keep THIS contract.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/backend/event_types.dart';
import 'package:skotiq_core/src/models/notification/notification_categories.dart';
import 'package:skotiq_core/src/services/notification/event_classifier.dart';
import 'package:skotiq_core/src/services/notification/notification_router.dart';
import 'package:skotiq_core/src/services/notification/transports/notification_transport.dart';
import 'package:skotiq_core/src/services/notification/transports/system_push_transport.dart';
import 'package:skotiq_core/src/services/push_notification_service.dart';

/// Records every send so we can count in-app dispatches per event.
class _RecordingTransport extends NotificationTransport {
  @override
  final NotificationTransportKind kind;
  final List<NotificationCategory> sentCategories = [];

  _RecordingTransport(this.kind);

  @override
  String get name => kind.label;

  @override
  bool get isConfigured => true;

  @override
  Future<NotificationResult> send({
    required NotificationCategory category,
    required String title,
    required String body,
  }) async {
    sentCategories.add(category);
    return NotificationResult.ok();
  }
}

SkotiqEvent _evt(
  EventCategory cat,
  String type,
  EventSeverity sev, [
  Map<String, dynamic> data = const {},
]) => SkotiqEvent(
  timestamp: DateTime.now().millisecondsSinceEpoch,
  severity: sev,
  category: cat,
  eventType: type,
  data: data,
);

/// The eight critical canary events, each as a core-typed [SkotiqEvent]
/// paired with the [NotificationCategory] it must classify to.
final _criticalCases =
    <String, ({SkotiqEvent event, NotificationCategory category})>{
      'sequenceFailed': (
        event: _evt(EventCategory.sequencer, 'Error', EventSeverity.error, {
          'message': 'boom',
        }),
        category: NotificationCategory.sequenceFailed,
      ),
      'weatherUnsafe': (
        event: _evt(
          EventCategory.safety,
          'WeatherUnsafe',
          EventSeverity.error,
          {'reason': 'clouds'},
        ),
        category: NotificationCategory.weatherUnsafe,
      ),
      'guidingLost': (
        event: _evt(EventCategory.guiding, 'StarLost', EventSeverity.error),
        category: NotificationCategory.guidingLost,
      ),
      'exposureFailed': (
        event: _evt(
          EventCategory.imaging,
          'ExposureFailed',
          EventSeverity.error,
          {'error': 'camera timeout'},
        ),
        category: NotificationCategory.exposureFailed,
      ),
      'equipmentDisconnected': (
        event: _evt(
          EventCategory.equipment,
          'Disconnected',
          EventSeverity.error,
          {'device_type': 'Mount', 'device_id': 'm1'},
        ),
        category: NotificationCategory.equipmentDisconnected,
      ),
      'recoveryGaveUp': (
        event: _evt(
          EventCategory.sequencer,
          'RecoveryGaveUp',
          EventSeverity.critical,
        ),
        category: NotificationCategory.recoveryGaveUp,
      ),
      'diskSpaceLow': (
        event: _evt(EventCategory.system, 'DiskSpaceLow', EventSeverity.error),
        category: NotificationCategory.diskSpaceLow,
      ),
      'autofocusFailed': (
        event: _evt(
          EventCategory.sequencer,
          'NodeCompleted',
          EventSeverity.error,
          {'node_type': 'autofocus', 'success': false},
        ),
        category: NotificationCategory.autofocusFailed,
      ),
    };

/// A push config with EVERY per-event toggle enabled. The canary asserts that
/// each critical alert "fires exactly once, honoring its config toggle"; to
/// prove the fire path we enable the toggle (some default OFF, e.g.
/// equipmentDisconnected, so the operator opts in). The "honours the toggle"
/// direction is proved separately by the toggle-suppression test.
const _allTogglesOn = PushNotificationConfig(
  enabled: true,
  notifySequenceCompleted: true,
  notifySequenceFailed: true,
  notifyMeridianFlip: true,
  notifyWeatherUnsafe: true,
  notifyGuidingLost: true,
  notifyExposureFailed: true,
  notifyAutofocusFailed: true,
  notifyEquipmentDisconnected: true,
);

/// A routing matrix where every category routes to [transports]. Lets a test
/// prove that an arbitrary critical event reaches a specific transport set.
NotificationRoutingMatrix _matrixRoutingAllTo(
  List<NotificationTransportKind> transports,
) {
  final base = NotificationRoutingMatrix.defaults();
  var matrix = base;
  for (final c in NotificationCategory.values) {
    matrix = matrix.withRule(
      c,
      base.ruleFor(c).copyWith(transports: transports),
    );
  }
  return matrix;
}

void main() {
  group('exactly-once classifier contract', () {
    test('every critical canary event classifies to its critical category', () {
      for (final entry in _criticalCases.entries) {
        final classified = NotificationEventClassifier.classify(
          entry.value.event,
        );
        expect(
          classified,
          isNotNull,
          reason: '${entry.key} must classify to a category',
        );
        expect(
          classified!.category,
          entry.value.category,
          reason: '${entry.key} classified to the wrong category',
        );
        expect(
          classified.category.isCritical,
          isTrue,
          reason: '${entry.key} must be critical-by-default',
        );
      }
    });
  });

  group('exactly-once router dispatch (mobile push + in-app)', () {
    /// Build a router whose `systemPush` transport feeds a real
    /// PushNotificationService, plus a recording in-app transport. Returns
    /// the router, the push service, and the in-app recorder.
    ({
      NotificationRouter router,
      PushNotificationService push,
      _RecordingTransport inApp,
    })
    build({bool pushEnabled = true, NotificationRoutingMatrix? matrix}) {
      // Post-collapse: PushNotificationService is a pure broadcaster with no
      // event subscription of its own — the router's SystemPushTransport is
      // the ONLY producer. There is no start()/stop() and no eventStream; the
      // collapse means the router path is the single feed by construction.
      final push = PushNotificationService(
        config: _allTogglesOn.copyWith(enabled: pushEnabled),
      );
      final inApp = _RecordingTransport(NotificationTransportKind.inApp);
      final router = NotificationRouter(
        transports: [inApp, SystemPushTransport(push)],
        matrix: matrix ?? NotificationRoutingMatrix.defaults(),
      );
      return (router: router, push: push, inApp: inApp);
    }

    test(
      'each critical event fires EXACTLY ONE mobile push + ONE in-app',
      () async {
        for (final entry in _criticalCases.entries) {
          final rig = build();
          final pushes = <PushNotification>[];
          final sub = rig.push.notifications.listen(pushes.add);

          rig.router.attachEventStream(Stream.value(entry.value.event));
          // Drain the stream listen + the router's Future.microtask dispatch +
          // the broadcast controller emission.
          await Future<void>.delayed(const Duration(milliseconds: 5));

          expect(
            pushes,
            hasLength(1),
            reason: '${entry.key}: expected exactly one mobile push',
          );
          expect(
            pushes.first.priority,
            PushNotificationPriority.critical,
            reason: '${entry.key}: matrix-routed critical push',
          );
          expect(
            rig.inApp.sentCategories.where((c) => c == entry.value.category),
            hasLength(1),
            reason: '${entry.key}: expected exactly one in-app dispatch',
          );

          await sub.cancel();
          await rig.router.dispose();
          rig.push.dispose();
        }
      },
    );

    test(
      'disabling a category suppresses BOTH push and in-app (toggle)',
      () async {
        for (final entry in _criticalCases.entries) {
          final disabledMatrix = NotificationRoutingMatrix.defaults().withRule(
            entry.value.category,
            NotificationRoutingMatrix.defaults()
                .ruleFor(entry.value.category)
                .copyWith(enabled: false),
          );
          final rig = build(matrix: disabledMatrix);
          final pushes = <PushNotification>[];
          final sub = rig.push.notifications.listen(pushes.add);

          rig.router.attachEventStream(Stream.value(entry.value.event));
          await Future<void>.delayed(const Duration(milliseconds: 5));

          expect(
            pushes,
            isEmpty,
            reason: '${entry.key}: disabled category must not push',
          );
          expect(
            rig.inApp.sentCategories,
            isEmpty,
            reason: '${entry.key}: disabled category must not dispatch in-app',
          );

          await sub.cancel();
          await rig.router.dispose();
          rig.push.dispose();
        }
      },
    );

    test(
      'master push disabled suppresses the mobile push but keeps in-app',
      () async {
        final entry = _criticalCases['weatherUnsafe']!;
        final rig = build(pushEnabled: false);
        final pushes = <PushNotification>[];
        final sub = rig.push.notifications.listen(pushes.add);

        rig.router.attachEventStream(Stream.value(entry.event));
        await Future<void>.delayed(const Duration(milliseconds: 5));

        // The master push `enabled=false` gate swallows the enqueue inside the
        // service, so no phone push — but the in-app transport is independent
        // and still fires.
        expect(pushes, isEmpty);
        expect(
          rig.inApp.sentCategories.where((c) => c == entry.category),
          hasLength(1),
        );

        await sub.cancel();
        await rig.router.dispose();
        rig.push.dispose();
      },
    );
  });

  group('eager-mount + collapsed feed: exactly-once with a single producer', () {
    // After the collapse the router is eagerly mounted (attached to the
    // backend event stream at app start) and is the ONLY systemPush producer
    // — PushNotificationService no longer subscribes to anything. These tests
    // pin that, with NO sequence running (the router fires off the raw event
    // stream alone), each critical event still produces exactly one push, AND
    // that the configurable external transports fire at idle (the bug the
    // eager-mount fixes: external alerts were dead when no UI surface had
    // lazily built the router).

    test(
      'with the router EAGERLY MOUNTED and ONLY the broadcaster live, each '
      'critical event fires exactly one push and one external transport send',
      () async {
        for (final entry in _criticalCases.entries) {
          final push = PushNotificationService(config: _allTogglesOn);
          final inApp = _RecordingTransport(NotificationTransportKind.inApp);
          // A stand-in external transport (Discord/email/telegram/… all behave
          // identically from the router's perspective). Route every category to
          // it so we can prove external delivery fires at idle.
          final external = _RecordingTransport(
            NotificationTransportKind.discord,
          );
          final matrix = _matrixRoutingAllTo(const [
            NotificationTransportKind.inApp,
            NotificationTransportKind.systemPush,
            NotificationTransportKind.discord,
          ]);
          final router = NotificationRouter(
            transports: [inApp, SystemPushTransport(push), external],
            matrix: matrix,
          );
          final pushes = <PushNotification>[];
          final sub = push.notifications.listen(pushes.add);

          // Eager-mount: attach BEFORE any event, no sequence active.
          router.attachEventStream(Stream.value(entry.value.event));
          await Future<void>.delayed(const Duration(milliseconds: 5));

          expect(
            pushes,
            hasLength(1),
            reason: '${entry.key}: exactly one mobile push (single producer)',
          );
          expect(pushes.first.priority, PushNotificationPriority.critical);
          expect(
            external.sentCategories.where((c) => c == entry.value.category),
            hasLength(1),
            reason:
                '${entry.key}: external transport must fire at idle '
                '(no sequence running)',
          );

          await sub.cancel();
          await router.dispose();
          push.dispose();
        }
      },
    );

    test('a previously-DEAD external transport fires for an at-idle '
        'weather-unsafe with no sequence running', () async {
      // External transports fire even with no sequence running. A router that
      // exists only once a UI surface builds it leaves an idle weather-unsafe
      // abort never reaching Discord/email.
      final push = PushNotificationService(
        config: const PushNotificationConfig(),
      );
      final external = _RecordingTransport(NotificationTransportKind.telegram);
      final matrix = NotificationRoutingMatrix.defaults().withRule(
        NotificationCategory.weatherUnsafe,
        NotificationRoutingMatrix.defaults()
            .ruleFor(NotificationCategory.weatherUnsafe)
            .copyWith(
              transports: const [
                NotificationTransportKind.inApp,
                NotificationTransportKind.systemPush,
                NotificationTransportKind.telegram,
              ],
            ),
      );
      final router = NotificationRouter(
        transports: [
          _RecordingTransport(NotificationTransportKind.inApp),
          SystemPushTransport(push),
          external,
        ],
        matrix: matrix,
      );

      router.attachEventStream(
        Stream.value(_criticalCases['weatherUnsafe']!.event),
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(
        external.sentCategories,
        [NotificationCategory.weatherUnsafe],
        reason: 'idle weather-unsafe must reach the external transport',
      );

      await router.dispose();
      push.dispose();
    });

    test('the dashboard-bridge explicit push and the classifier push for the '
        'SAME alert collapse to exactly one (cross-stream dedup)', () async {
      // The router has two converging systemPush inputs: its own classifier
      // subscription (core stream) and routeBridgeCriticalPush (the dashboard
      // bridge's bridge-stream path). For an event BOTH recognise, the
      // content-signature dedup must yield exactly one phone push.
      final push = PushNotificationService(
        config: const PushNotificationConfig(),
      );
      final router = NotificationRouter(
        transports: [
          _RecordingTransport(NotificationTransportKind.inApp),
          SystemPushTransport(push),
        ],
        matrix: NotificationRoutingMatrix.defaults(),
      );
      final pushes = <PushNotification>[];
      final sub = push.notifications.listen(pushes.add);

      // The bridge fires its explicit push for the same weather-unsafe alert
      // the classifier path will also see. Use the SAME rendered copy the
      // weatherUnsafe template produces so the signatures collide.
      router.attachEventStream(
        Stream.value(_criticalCases['weatherUnsafe']!.event),
      );
      router.routeBridgeCriticalPush(
        title: 'Weather unsafe',
        body: 'Safety monitor reports unsafe conditions.',
        eventType: 'WeatherUnsafe',
        eventCategory: EventCategory.safety,
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(
        pushes,
        hasLength(1),
        reason: 'classifier + bridge paths must collapse to one push',
      );

      await sub.cancel();
      await router.dispose();
      push.dispose();
    });

    test('the dashboard-bridge push for an UNCLASSIFIED critical event (system '
        'error) still fires exactly once at critical priority', () async {
      // The bridge covers events the classifier does NOT push (generic system
      // errors). With no classifier push to dedup against, the bridge path
      // alone must page the operator exactly once.
      final push = PushNotificationService(
        config: const PushNotificationConfig(),
      );
      final router = NotificationRouter(
        transports: [
          _RecordingTransport(NotificationTransportKind.inApp),
          SystemPushTransport(push),
        ],
        matrix: NotificationRoutingMatrix.defaults(),
      );
      final pushes = <PushNotification>[];
      final sub = push.notifications.listen(pushes.add);

      // A generic system error: the classifier returns null for it (only
      // "disk" is mapped under system), so only the bridge path fires.
      router.attachEventStream(
        Stream.value(
          _evt(EventCategory.system, 'Error', EventSeverity.error, {
            'message': 'FITS save failed',
          }),
        ),
      );
      router.routeBridgeCriticalPush(
        title: 'Critical · System',
        body: 'FITS save failed',
        eventType: 'System error',
        eventCategory: EventCategory.system,
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(pushes, hasLength(1));
      expect(pushes.first.priority, PushNotificationPriority.critical);
      expect(pushes.first.title, 'Critical · System');

      await sub.cancel();
      await router.dispose();
      push.dispose();
    });
  });

  group('non-critical events do NOT escalate to mobile push by default', () {
    test('a frameCaptured event fires in-app only, never systemPush', () async {
      final push = PushNotificationService(
        config: const PushNotificationConfig(),
      );
      final inApp = _RecordingTransport(NotificationTransportKind.inApp);
      final router = NotificationRouter(
        transports: [inApp, SystemPushTransport(push)],
        matrix: NotificationRoutingMatrix.defaults(),
      );
      final pushes = <PushNotification>[];
      final sub = push.notifications.listen(pushes.add);

      router.attachEventStream(
        Stream.value(
          _evt(EventCategory.imaging, 'ExposureCompleted', EventSeverity.info, {
            'frame_number': 3,
            'duration_secs': 120,
          }),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(pushes, isEmpty);
      expect(inApp.sentCategories, [NotificationCategory.frameCaptured]);

      await sub.cancel();
      await router.dispose();
      push.dispose();
    });
  });
}
