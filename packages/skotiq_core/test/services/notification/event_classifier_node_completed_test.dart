// `NodeCompleted` classification: the verdict field is `status` (a string),
// not a `success` bool.
//
// The classifier read `event.data['success'] as bool? ?? true` — a key no
// producer emits — so a FAILED node classified as "Autofocus Completed": a
// reassuring push notification for an autofocus that did not work, sent to an
// operator who is asleep. The wire shape is `{node_id, status}` (see
// `SequencerEvent.nodeCompleted` / `ffi_backend/event_mapping.dart`).

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/backend/event_types.dart';
import 'package:skotiq_core/src/models/notification/notification_categories.dart';
import 'package:skotiq_core/src/services/notification/event_classifier.dart';

SkotiqEvent _nodeCompleted(Map<String, dynamic> data) => SkotiqEvent(
  timestamp: DateTime.now().millisecondsSinceEpoch,
  severity: EventSeverity.info,
  category: EventCategory.sequencer,
  eventType: 'NodeCompleted',
  data: data,
);

void main() {
  test('a failed autofocus node is NOT reported as completed', () {
    final classified = NotificationEventClassifier.classify(
      _nodeCompleted({
        'node_id': 'af-1',
        'node_type': 'AutofocusNode',
        'status': 'failed',
      }),
    );

    expect(classified, isNotNull);
    expect(classified!.category, NotificationCategory.autofocusFailed);
  });

  test('a successful autofocus node is reported as completed', () {
    final classified = NotificationEventClassifier.classify(
      _nodeCompleted({
        'node_id': 'af-1',
        'node_type': 'AutofocusNode',
        'status': 'success',
      }),
    );

    expect(classified!.category, NotificationCategory.autofocusCompleted);
  });

  test('a cancelled autofocus node is not reported as completed', () {
    final classified = NotificationEventClassifier.classify(
      _nodeCompleted({
        'node_id': 'af-1',
        'node_type': 'AutofocusNode',
        'status': 'cancelled',
      }),
    );

    expect(classified!.category, NotificationCategory.autofocusFailed);
  });

  test('a missing status is not treated as success', () {
    final classified = NotificationEventClassifier.classify(
      _nodeCompleted({'node_id': 'af-1', 'node_type': 'AutofocusNode'}),
    );

    expect(classified!.category, NotificationCategory.autofocusFailed);
  });

  test('a legacy success bool still maps to completed', () {
    final classified = NotificationEventClassifier.classify(
      _nodeCompleted({
        'node_id': 'af-1',
        'node_type': 'AutofocusNode',
        'success': true,
      }),
    );

    expect(classified!.category, NotificationCategory.autofocusCompleted);
  });

  test('a non-autofocus node raises nothing', () {
    expect(
      NotificationEventClassifier.classify(
        _nodeCompleted({
          'node_id': 'e-1',
          'node_type': 'ExposureNode',
          'status': 'failed',
        }),
      ),
      isNull,
    );
  });

  test('the real wire shape (no node_type) raises nothing, not a guess', () {
    expect(
      NotificationEventClassifier.classify(
        _nodeCompleted({'node_id': 'af-1', 'status': 'failed'}),
      ),
      isNull,
    );
  });
}
