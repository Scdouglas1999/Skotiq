// An operator's Stop is not a failure. Mapping the `Stopped` and `Error`
// sequencer events to one `sequenceFailed` category raises "Sequence failed"
// banners and a critical-priority phone push for an action the operator just
// took on purpose.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/backend/event_types.dart';
import 'package:skotiq_core/src/models/notification/notification_categories.dart';
import 'package:skotiq_core/src/models/sequence/run_stop_classification.dart';
import 'package:skotiq_core/src/services/notification/event_classifier.dart';

SkotiqEvent _sequencer(String eventType) => SkotiqEvent(
  timestamp: DateTime.now().millisecondsSinceEpoch,
  severity: EventSeverity.info,
  category: EventCategory.sequencer,
  eventType: eventType,
  data: const {},
);

void main() {
  test('an operator Stop classifies as stopped, not failed', () {
    final classified = NotificationEventClassifier.classify(
      _sequencer('Stopped'),
    );
    expect(classified?.category, NotificationCategory.sequenceStopped);
  });

  test('a stopped sequence is neither critical nor an error', () {
    expect(NotificationCategory.sequenceStopped.isCritical, isFalse);
    expect(
      NotificationCategory.sequenceStopped.defaultSeverity,
      EventSeverity.info,
    );
  });

  test('a failed run classifies as failed and critical, by its end', () {
    final classified = NotificationEventClassifier.classify(
      _sequencerWithData('SequenceFailed', const {'error': 'Slew refused'}),
    );
    expect(classified?.category, NotificationCategory.sequenceFailed);
    expect(NotificationCategory.sequenceFailed.isCritical, isTrue);
  });

  // A failing step's Error is not the run's failure: the run may be saved by
  // recovery, and when it is not, `SequenceFailed` says so with this reason.
  test('a failing step raises no failure notice of its own', () {
    expect(
      NotificationEventClassifier.classify(
        _sequencerWithData('Error', const {
          'message': 'Exposure: FITS save failed',
          'kind': 'step_failed',
        }),
      ),
      isNull,
    );
  });

  // A stop reaches this classifier first as the run's cancellation `Error`,
  // before `Stopped`. Read as a failing step it raised a red "Sequence failed"
  // toast for a run the operator stopped on purpose.
  test('a cancellation arriving as an Error classifies as stopped', () {
    final classified = NotificationEventClassifier.classify(
      _sequencerWithData('Error', const {
        'message': 'Sequence cancelled',
        'kind': 'cancelled',
      }),
    );
    expect(classified?.category, NotificationCategory.sequenceStopped);
  });

  test('a stop row names its author without reading its words', () {
    final decision = NotificationEventClassifier.stopDecisionOf(
      _sequencerWithData('DecisionLogged', const {
        'category': 'system_event',
        'summary': 'Reworded',
        'details_json': '{}',
        'stop': {'by': 'autopilot'},
      }),
    );
    expect(decision?.author, SequenceStopAuthor.autopilot);
  });

  test('a fault whose text contains "cancelled" is not read as a stop', () {
    expect(
      NotificationEventClassifier.classify(
        _sequencerWithData('Error', const {
          'kind': 'step_failed',
          'message': 'Temperature compensation cancelled',
        }),
      ),
      isNull,
    );
    final ended = NotificationEventClassifier.classify(
      _sequencerWithData('SequenceFailed', const {
        'error': 'Temperature compensation cancelled',
      }),
    );
    expect(ended?.category, NotificationCategory.sequenceFailed);
  });
}

SkotiqEvent _sequencerWithData(String eventType, Map<String, dynamic> data) =>
    SkotiqEvent(
      timestamp: DateTime.now().millisecondsSinceEpoch,
      severity: EventSeverity.error,
      category: EventCategory.sequencer,
      eventType: eventType,
      data: data,
    );
