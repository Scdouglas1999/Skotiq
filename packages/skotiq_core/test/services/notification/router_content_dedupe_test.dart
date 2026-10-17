// One operator Stop, one toast.
//
// The stop pipeline has THREE reclassifying producers that converge on the same
// `sequenceStopped` category (the sequencer `Error` carrying the "Sequence
// cancelled" notice, the `Stopped` lifecycle event that follows it, and the
// dashboard bridge re-entering with the same stop). Each reaches the router,
// which is the one place they all converge, so that is where the repetition is
// collapsed — for every transport, not just the phone push.
//
// Two producers of one refusal whose bodies differ ONLY by a trailing full stop
// must collapse too: an exact-string key would not fire on them.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _RecordingTransport extends NotificationTransport {
  _RecordingTransport(this.kind);

  @override
  final NotificationTransportKind kind;

  final List<({String title, String body})> sent = [];

  @override
  String get name => 'Recording ${kind.name}';

  @override
  bool get isConfigured => true;

  @override
  Future<NotificationResult> send({
    required NotificationCategory category,
    required String title,
    required String body,
  }) async {
    sent.add((title: title, body: body));
    return NotificationResult.ok();
  }
}

/// A matrix that routes every category to [kinds] with no rate limit and no
/// debounce, so the only thing under test is content de-duplication.
NotificationRoutingMatrix _matrixTo(List<NotificationTransportKind> kinds) {
  return NotificationRoutingMatrix(
    enabled: true,
    rules: {
      for (final category in NotificationCategory.values)
        category: NotificationRoutingRule(
          enabled: true,
          transports: kinds,
          minSeverity: EventSeverity.info,
          maxPerHour: 0,
          debounceSeconds: 0,
        ),
    },
  );
}

SkotiqEvent _sequencer(String eventType, {Map<String, dynamic>? data}) =>
    SkotiqEvent(
      timestamp: DateTime.now().millisecondsSinceEpoch,
      severity: EventSeverity.info,
      category: EventCategory.sequencer,
      eventType: eventType,
      data: data ?? const {},
    );

/// Lets the microtask-scheduled transport sends run.
Future<void> _settle() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'one Stop seen by three producers raises ONE in-app notification',
    () async {
      final inApp = _RecordingTransport(NotificationTransportKind.inApp);
      final router = NotificationRouter(
        transports: [inApp],
        matrix: _matrixTo(const [NotificationTransportKind.inApp]),
      );
      final events = StreamController<SkotiqEvent>();
      addTearDown(() async {
        await events.close();
        await router.dispose();
      });
      router.attachEventStream(events.stream);

      // Producer 1: the sequencer `Error` carrying the cancellation notice.
      events.add(
        _sequencer('Error', data: {'message': kSequenceCancelledNotice}),
      );
      // Producer 2: the `Stopped` lifecycle event that follows it.
      events.add(_sequencer('Stopped'));
      // Producer 3: the dashboard bridge re-entering with the same stop.
      events.add(
        _sequencer('Error', data: {'message': kSequenceCancelledNotice}),
      );

      await _settle();

      expect(inApp.sent, hasLength(1));
      expect(inApp.sent.single.title, 'Sequence stopped');
    },
  );

  test(
    'a one-character trailing-punctuation difference cannot defeat the collapse',
    () async {
      // The counter-input keyed at the router: the two producers of one refusal
      // differ ONLY by a trailing full stop.
      const refusal =
          'Built-in guider requires an active profile with a guide focal length';
      final inApp = _RecordingTransport(NotificationTransportKind.inApp);
      final router = NotificationRouter(
        transports: [inApp],
        matrix: _matrixTo(const [NotificationTransportKind.inApp]),
      );
      addTearDown(router.dispose);

      router.routeNotificationNode(title: 'Guider Error', body: refusal);
      router.routeNotificationNode(title: 'Guider Error', body: '$refusal.');
      router.routeNotificationNode(title: 'Guider Error', body: ' $refusal  ');

      await _settle();

      expect(inApp.sent, hasLength(1));
    },
  );

  test('genuinely different notifications are never collapsed', () async {
    final inApp = _RecordingTransport(NotificationTransportKind.inApp);
    final router = NotificationRouter(
      transports: [inApp],
      matrix: _matrixTo(const [NotificationTransportKind.inApp]),
    );
    addTearDown(router.dispose);

    router.routeNotificationNode(
      title: 'Mount Error',
      body: 'Mount disconnected.',
    );
    router.routeNotificationNode(
      title: 'Focuser Error',
      body: 'Focuser disconnected.',
    );

    await _settle();

    expect(inApp.sent, hasLength(2));
  });

  test('each transport dedupes independently', () async {
    // An external alert must not be swallowed because the UI already said it;
    // the collapse is per-transport, not global.
    final inApp = _RecordingTransport(NotificationTransportKind.inApp);
    final webhook = _RecordingTransport(
      NotificationTransportKind.webhookGeneric,
    );
    final router = NotificationRouter(
      transports: [inApp, webhook],
      matrix: _matrixTo(const [
        NotificationTransportKind.inApp,
        NotificationTransportKind.webhookGeneric,
      ]),
    );
    addTearDown(router.dispose);

    router.routeNotificationNode(title: 'T', body: 'B');
    router.routeNotificationNode(title: 'T', body: 'B');

    await _settle();

    expect(inApp.sent, hasLength(1));
    expect(webhook.sent, hasLength(1));
  });

  test(
    'the same alert minutes later is NOT swallowed by the earlier copy',
    () async {
      // The collapse window exists to absorb converging producers, not to
      // silence a genuine repeat. Proven by driving the router's clock.
      var now = DateTime(2026, 8, 14, 0, 13, 25);
      final inApp = _RecordingTransport(NotificationTransportKind.inApp);
      final router = NotificationRouter(
        transports: [inApp],
        matrix: _matrixTo(const [NotificationTransportKind.inApp]),
        clock: () => now,
      );
      addTearDown(router.dispose);

      router.routeNotificationNode(title: 'Guiding lost', body: 'Star lost.');
      now = now.add(const Duration(minutes: 5));
      router.routeNotificationNode(title: 'Guiding lost', body: 'Star lost.');

      await _settle();

      expect(inApp.sent, hasLength(2));
    },
  );
}
