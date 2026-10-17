// Owner decisions of 2026-10-06: a failed autofocus and a streak of rejected
// frames are things to tell the operator about, not reasons to stop. The
// engine keeps imaging and says so with a decision row; these are the
// notifications the app raises from those rows, and the ones it must not
// raise.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/services/notification/event_classifier.dart';

final _t0 = DateTime(2026, 10, 6, 1, 30);

class _RecordingTransport extends NotificationTransport {
  @override
  final NotificationTransportKind kind = NotificationTransportKind.inApp;

  final List<({NotificationCategory category, String title, String body})>
  sent = [];

  @override
  String get name => 'Recording in-app';

  @override
  bool get isConfigured => true;

  @override
  Future<NotificationResult> send({
    required NotificationCategory category,
    required String title,
    required String body,
  }) async {
    sent.add((category: category, title: title, body: body));
    return NotificationResult.ok();
  }
}

SkotiqEvent _sequencer(
  String eventType, {
  Map<String, dynamic> data = const {},
  EventSeverity severity = EventSeverity.info,
}) => SkotiqEvent(
  timestamp: DateTime.now().millisecondsSinceEpoch,
  severity: severity,
  category: EventCategory.sequencer,
  eventType: eventType,
  data: data,
);

/// The row the engine writes when the third frame in a row is rejected
/// (`IMAGE_GRADING_REJECT_STREAK_SUMMARY` in the native grading module).
SkotiqEvent get _rejectStreak => _sequencer(
  'DecisionLogged',
  data: const {
    'category': 'system_event',
    'summary': 'Frames rejected in a row — the run continues',
    'details_json':
        '{"consecutive_rejects":3,"limit":3,"frame":7,"total":40,'
        '"reason":"eccentricity 0.83 exceeds threshold 0.80",'
        '"reject_path":"/captures/Reject/NGC7380_OIII_0007.fits",'
        '"accepted_total":4,"rejected_total":3}',
    'sequence_run_id': 21,
  },
);

/// One per-frame reject event, as every rejected frame produces.
SkotiqEvent _frameRejected(int consecutive) => _sequencer(
  'FrameRejected',
  severity: EventSeverity.warning,
  data: {
    'frame': consecutive,
    'total': 40,
    'reason': 'eccentricity 0.83 exceeds threshold 0.80',
    'consecutive_rejects': consecutive,
  },
);

void main() {
  test('a reject streak classifies as frames being rejected, at warning', () {
    final classified = NotificationEventClassifier.classify(_rejectStreak);
    expect(classified?.category, NotificationCategory.frameRejected);
    expect(classified?.severity, EventSeverity.warning);
    expect(classified?.context['frame.streak'], '3');
    expect(
      classified?.context['frame.reason'],
      'eccentricity 0.83 exceeds threshold 0.80',
    );
  });

  test('a single rejected frame raises no notification of its own', () {
    expect(NotificationEventClassifier.classify(_frameRejected(1)), isNull);
  });

  test('an autofocus node that carried on raises the continuing notice', () {
    final classified = NotificationEventClassifier.classify(
      _sequencer(
        'DecisionLogged',
        data: const {
          'category': 'system_event',
          'summary': 'Autofocus failed — continuing with last-good focus',
          'details_json': '{"source":"Autofocus","node_id":"af-1"}',
        },
      ),
    );
    expect(classified?.category, NotificationCategory.autofocusContinued);
  });

  test('the continuing notice in the warnings feed is not a failed run', () {
    final classified = NotificationEventClassifier.classify(
      _sequencer(
        'Error',
        severity: EventSeverity.warning,
        data: const {
          'message':
              'Autofocus did not converge (Insufficient stars detected). '
              'The focuser was returned to position 6620 and imaging '
              'continues on the last-good focus.',
        },
      ),
    );
    expect(classified, isNull);
  });

  test('a streak of ten rejected frames is one notification that says the '
      'run continues', () {
    fakeAsync((async) {
      final inApp = _RecordingTransport();
      final router = NotificationRouter(
        transports: [inApp],
        matrix: NotificationRoutingMatrix.defaults(),
        clock: () => _t0.add(async.elapsed),
      );
      for (var frame = 1; frame <= 10; frame++) {
        router.attachEventStream(Stream.value(_frameRejected(frame)));
        async.elapse(const Duration(milliseconds: 1));
        if (frame == 3) {
          router.attachEventStream(Stream.value(_rejectStreak));
          async.elapse(const Duration(milliseconds: 1));
        }
      }
      async.elapse(const Duration(seconds: 5));

      expect(inApp.sent, hasLength(1), reason: '${inApp.sent}');
      final notice = inApp.sent.single;
      expect(notice.category, NotificationCategory.frameRejected);
      expect(notice.title, 'Frames being rejected');
      expect(notice.body, contains('3 frames in a row'));
      expect(notice.body, contains('eccentricity 0.83 exceeds threshold 0.80'));
      expect(notice.body, contains('The run continues'));
      router.dispose();
      async.elapse(const Duration(seconds: 1));
    });
  });

  // A quality problem the run carried on through: a Center that could not
  // solve, guiding RMS over a StartGuiding limit, a dither that did not settle,
  // a post-flip check (`QUALITY_PROBLEM_CONTINUED_SUMMARY` in the native
  // executor). The operator is told, at warning, and told the run goes on.
  SkotiqEvent problemNoticed() => _sequencer(
    'DecisionLogged',
    data: const {
      'category': 'system_event',
      'summary': 'Problem noticed — the run continues',
      'details_json':
          '{"source":"Center","problem":"Failed to center within 5.0\\" '
          'after 5 attempts on M31. The mount stays where the last correction '
          'put it.","node_id":"center-1"}',
      'sequence_run_id': 21,
    },
  );

  test(
    'a quality problem the run carried on through classifies at warning',
    () {
      final classified = NotificationEventClassifier.classify(problemNoticed());
      expect(classified?.category, NotificationCategory.problemNoticed);
      expect(classified?.severity, EventSeverity.warning);
      expect(classified?.context['problem.source'], 'Center');
      expect(
        classified?.context['problem.message'],
        startsWith('Failed to center within 5.0" after 5 attempts on M31.'),
      );
    },
  );

  test('it is one notification that names the problem and says the run '
      'continues', () {
    fakeAsync((async) {
      final inApp = _RecordingTransport();
      final router = NotificationRouter(
        transports: [inApp],
        matrix: NotificationRoutingMatrix.defaults(),
        clock: () => _t0.add(async.elapsed),
      );
      router.attachEventStream(Stream.value(problemNoticed()));
      async.elapse(const Duration(seconds: 5));

      expect(inApp.sent, hasLength(1), reason: '${inApp.sent}');
      final notice = inApp.sent.single;
      expect(notice.category, NotificationCategory.problemNoticed);
      expect(notice.title, 'Problem noticed — the run continues');
      expect(notice.body, contains('Center: Failed to center'));
      router.dispose();
      async.elapse(const Duration(seconds: 1));
    });
  });
}
