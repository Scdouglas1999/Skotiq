// A happening the run carries on through reaches the operator once.
//
// The engine records it twice, a decision row and a Warning, and both carry
// the same notice. The router raises the notification from the row; the error
// bridge leaves the Warning to Tonight's run-warnings list. Before the notice
// was on the wire both were recognized by their words, so rewording either
// side on the host brought the second toast back.
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/src/services/notification/event_classifier.dart';

class _MockFfiBackend extends Mock implements FfiBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

class _RecordingTransport extends NotificationTransport {
  @override
  final NotificationTransportKind kind = NotificationTransportKind.inApp;

  final List<NotificationMessage> sent = [];

  @override
  String get name => 'Recording in-app';

  @override
  bool get isConfigured => true;

  @override
  Future<NotificationResult> send(NotificationMessage message) async {
    sent.add(message);
    return NotificationResult.ok();
  }
}

SkotiqEvent _sequencer(
  String eventType,
  EventSeverity severity,
  Map<String, dynamic> data,
) => SkotiqEvent(
  timestamp: DateTime.now().millisecondsSinceEpoch,
  severity: severity,
  category: EventCategory.sequencer,
  eventType: eventType,
  data: data,
);

/// The row and the Warning a host writes for one happening, worded unlike any
/// other, so only the notice can tie them together.
(SkotiqEvent row, SkotiqEvent warning) _happening(
  SequencerNotice notice,
  String detailsJson,
) => (
  _encoded(
    EventSeverity.info,
    SequencerEvent.decisionLogged(
      timestampIso: '2026-11-13T03:00:00Z',
      category: 'system_event',
      summary: 'Reworded summary for ${notice.wireName}',
      detailsJson: detailsJson,
      sequenceRunId: 7,
      notice: notice,
    ),
  ),
  _encoded(
    EventSeverity.warning,
    SequencerEvent.error(
      message: 'Reworded warning line for ${notice.wireName}.',
      kind: SequencerErrorKind.advisory,
      notice: notice,
    ),
  ),
);

SkotiqEvent _encoded(EventSeverity severity, SequencerEvent event) {
  final (type, data) = encodeEventPayload(EventPayload.sequencer(event));
  return _sequencer(type, severity, Map<String, dynamic>.from(data));
}

void main() {
  final cases = [
    (
      'an autofocus that did not converge',
      const SequencerNotice.autofocusContinued(),
      '{"source":"Autofocus trigger \'Refocus\'","reason":"no V-curve minimum"}',
      NotificationCategory.autofocusContinued,
    ),
    (
      'a streak of rejected frames',
      const SequencerNotice.rejectStreak(
        consecutiveRejects: 3,
        reason: 'eccentricity 0.83 exceeds threshold 0.80',
      ),
      '{"consecutive_rejects":3,"limit":3,'
          '"reason":"eccentricity 0.83 exceeds threshold 0.80"}',
      NotificationCategory.frameRejected,
    ),
    (
      'a quality problem',
      const SequencerNotice.problemNoticed(
        source: 'Center',
        problem: 'Failed to center within 5.0 arcsec.',
      ),
      '{"source":"Center","problem":"Failed to center within 5.0 arcsec."}',
      NotificationCategory.problemNoticed,
    ),
  ];

  for (final (name, notice, details, category) in cases) {
    test('$name is one notification from its row', () {
      final (row, warning) = _happening(notice, details);
      fakeAsync((async) {
        final inApp = _RecordingTransport();
        final router = NotificationRouter(
          transports: [inApp],
          matrix: NotificationRoutingMatrix.defaults(),
          clock: () => DateTime(2026, 11, 12, 1).add(async.elapsed),
        );
        router.attachEventStream(Stream.fromIterable([warning, row]));
        async.elapse(const Duration(seconds: 5));

        expect(inApp.sent, hasLength(1), reason: '${inApp.sent}');
        expect(inApp.sent.single.category, category);
        router.dispose();
        async.elapse(const Duration(seconds: 1));
      });
    });

    test('$name is not toasted from its Warning', () async {
      final (row, warning) = _happening(notice, details);
      final backend = _MockFfiBackend();
      final controller = StreamController<SkotiqEvent>.broadcast();
      when(() => backend.eventStream).thenAnswer((_) => controller.stream);
      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(controller.close);
      container.read(errorNotificationBridgeProvider);

      controller
        ..add(row)
        ..add(warning);
      await pumpEventQueue();

      expect(container.read(uiNotificationProvider), isEmpty);
    });
  }

  test('a row without a notice raises nothing, whatever its summary', () {
    expect(
      NotificationEventClassifier.classify(
        _sequencer('DecisionLogged', EventSeverity.info, {
          'category': 'system_event',
          'summary': 'Sequence started',
          'details_json': '{}',
        }),
      ),
      isNull,
    );
  });
}
