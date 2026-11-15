// A cloudy stretch, replayed as the guider reports it: one guiding-lost
// notice once the star has stayed lost, nothing while the guider hunts, one
// recovered notice once it guides again, through the host's router with its
// default rules.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';

import 'recording_router.dart';

/// The guider's events of one stretch, two seconds a frame.
class _Night {
  final events = <SkotiqEvent>[];
  var _at = DateTime.utc(2026, 11, 15, 3).millisecondsSinceEpoch;

  void _add(bridge.GuidingEvent event, EventSeverity severity) {
    final (type, data) = bridge.encodeEventPayload(
      bridge.EventPayload.guiding(event),
    );
    events.add(
      SkotiqEvent(
        timestamp: _at,
        severity: severity,
        category: EventCategory.guiding,
        eventType: type,
        data: Map<String, dynamic>.from(data),
      ),
    );
    _at += 2000;
  }

  void guide(Duration span) {
    for (var t = Duration.zero; t < span; t += const Duration(seconds: 2)) {
      _add(
        const bridge.GuidingEvent.correction(
          ra: 0.2,
          dec: -0.1,
          raRaw: 0.2,
          decRaw: -0.1,
        ),
        EventSeverity.info,
      );
    }
  }

  /// Clouds: the star is lost every frame, and every ten seconds the guider
  /// picks a star and guides one frame on it before losing it again.
  void clouds(Duration span) {
    for (var t = Duration.zero; t < span; t += const Duration(seconds: 2)) {
      if (t.inSeconds % 10 == 8) {
        _add(
          const bridge.GuidingEvent.starSelected(x: 512, y: 384),
          EventSeverity.info,
        );
        guide(const Duration(seconds: 2));
      } else {
        _add(const bridge.GuidingEvent.lostStar(), EventSeverity.warning);
      }
    }
  }
}

Future<List<NotificationCategory>> _replay(List<SkotiqEvent> events) async {
  final transport = RecordingTransport(NotificationTransportKind.inApp);
  final router = NotificationRouter(
    transports: [transport],
    matrix: NotificationRoutingMatrix.defaults(),
  );
  router.attachEventStream(Stream.fromIterable(events));
  await Future<void>.delayed(const Duration(milliseconds: 20));
  await router.dispose();
  return transport.sent.map((m) => m.category).toList();
}

void main() {
  test(
    'a cloudy stretch is one lost notice and one recovered notice',
    () async {
      final night = _Night()
        ..guide(const Duration(minutes: 2))
        ..clouds(const Duration(minutes: 6))
        ..guide(const Duration(minutes: 2));

      expect(await _replay(night.events), [
        NotificationCategory.guidingLost,
        NotificationCategory.guidingRecovered,
      ]);
    },
  );

  test('a second cloud bank after a recovery is a second episode', () {
    final night = _Night()
      ..guide(const Duration(minutes: 1))
      ..clouds(const Duration(minutes: 3))
      ..guide(const Duration(minutes: 1))
      ..clouds(const Duration(minutes: 3))
      ..guide(const Duration(minutes: 1));

    // Followed by the episodes alone: the router folds two identical notices
    // inside seconds of wall clock, and a replay runs in milliseconds.
    final episodes = GuideStarEpisodes();
    expect(night.events.map(episodes.observe).nonNulls.map((n) => n.category), [
      NotificationCategory.guidingLost,
      NotificationCategory.guidingRecovered,
      NotificationCategory.guidingLost,
      NotificationCategory.guidingRecovered,
    ]);
  });

  test('a star lost for a few frames raises nothing', () async {
    final night = _Night()
      ..guide(const Duration(minutes: 1))
      ..clouds(const Duration(seconds: 8))
      ..guide(const Duration(minutes: 1));

    expect(await _replay(night.events), isEmpty);
  });

  test('guiding stopped on purpose ends an episode without a notice', () {
    final episodes = GuideStarEpisodes();
    final night = _Night()
      ..clouds(const Duration(minutes: 1))
      .._add(const bridge.GuidingEvent.guidingStopped(), EventSeverity.info)
      ..guide(const Duration(minutes: 2));
    final told = [
      for (final event in night.events) episodes.observe(event)?.category,
    ].nonNulls.toList();

    expect(told, [NotificationCategory.guidingLost]);
  });

  test('the lost notice says the run carries on', () {
    final episodes = GuideStarEpisodes();
    final night = _Night()..clouds(const Duration(minutes: 1));
    final lost = night.events.map(episodes.observe).nonNulls.single;
    final body = renderNotificationTemplate(
      NotificationPresentation.of(lost.category).body,
      NotificationContext(lost.context),
    );

    expect(body, contains('the run carries on'));
  });
}
