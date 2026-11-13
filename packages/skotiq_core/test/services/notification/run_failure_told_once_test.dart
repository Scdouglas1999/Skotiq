// One failed run, one notice, with the reason; a problem the run carried on
// through is a warning, never a failure.
//
// A run whose capture folder turned read-only reported its fault three times
// (the exposure's own error, the instruction failure restating it with the
// step's name, and the terminal `SequenceFailed`), and the operator got a
// toast for each. And every mid-run error, a dome that could not confirm its
// shutter included, was told and pushed as "Sequence failed / Sequence
// aborted at 23:41" while the run went on imaging.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';

import 'recording_router.dart';

SkotiqEvent _sequencer(
  String eventType, {
  EventSeverity severity = EventSeverity.error,
  Map<String, dynamic> data = const {},
}) => SkotiqEvent(
  timestamp: DateTime.now().millisecondsSinceEpoch,
  severity: severity,
  category: EventCategory.sequencer,
  eventType: eventType,
  data: data,
);

Future<void> _settle() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// A sequencer `Error` of [kind], at the severity the host gives that kind.
SkotiqEvent _error(SequencerErrorKind kind, String message) => _sequencer(
  'Error',
  severity: kind.runContinues ? EventSeverity.warning : EventSeverity.error,
  data: {
    'message': message,
    kSequencerErrorKindKey: encodeSequencerErrorKind(kind),
  },
);

const _fault =
    'Could not create save directory `/data/M31`: Permission denied (os error 13)';

void main() {
  late NotificationRouter router;
  late RecordingTransport inApp;
  late StreamController<SkotiqEvent> events;

  List<NotificationMessage> failures() => [
    for (final message in inApp.sent)
      if (message.category == NotificationCategory.sequenceFailed) message,
  ];

  List<NotificationMessage> problems() => [
    for (final message in inApp.sent)
      if (message.category == NotificationCategory.problemNoticed) message,
  ];

  setUp(() {
    final recording = recordingRouter();
    router = recording.router;
    inApp = recording.transports[NotificationTransportKind.inApp]!;
    events = StreamController<SkotiqEvent>();
    router.attachEventStream(events.stream);
  });

  tearDown(() async {
    await events.close();
    await router.dispose();
  });

  test(
    'a failed run is told once, by its end, with the first fault as the reason',
    () async {
      events
        ..add(_sequencer('Started', severity: EventSeverity.info))
        ..add(_error(SequencerErrorKind.stepFailed, _fault))
        ..add(_error(SequencerErrorKind.stepFailed, 'Exposure: $_fault'))
        ..add(_sequencer('SequenceFailed', data: {'error': _fault}));
      await _settle();

      expect(failures(), hasLength(1));
      expect(failures().single.title, 'Sequence failed');
      expect(failures().single.body, endsWith('. $_fault.'));
      expect(problems(), isEmpty);
    },
  );

  test(
    'a run that failed on a refusal is told by its terminal event',
    () async {
      events
        ..add(_sequencer('Started', severity: EventSeverity.info))
        ..add(
          _sequencer(
            'SequenceFailed',
            data: {'error': 'run_refused: Mount is not connected'},
          ),
        );
      await _settle();

      expect(failures(), hasLength(1));
      expect(failures().single.body, endsWith('. Mount is not connected.'));
    },
  );

  test('a failure without a reason says where the reason is', () async {
    events
      ..add(_sequencer('Started', severity: EventSeverity.info))
      ..add(_sequencer('SequenceFailed', data: {'error': 'Sequence failed'}));
    await _settle();

    expect(failures().single.body, endsWith('. The log has the reason.'));
  });

  test('a problem the run carried on through is a warning that says the run '
      'continues, and never a failure', () async {
    events
      ..add(_sequencer('Started', severity: EventSeverity.info))
      ..add(
        _error(
          SequencerErrorKind.stepProblem,
          'Dome shutter status unavailable; cannot confirm open',
        ),
      )
      ..add(_sequencer('ExposureStarted', severity: EventSeverity.info));
    await _settle();

    expect(failures(), isEmpty);
    expect(problems(), hasLength(1));
    expect(problems().single.title, 'Problem noticed — the run continues');
    expect(
      problems().single.body,
      'Sequence: Dome shutter status unavailable; cannot confirm open',
    );
    expect(problems().single.severity, EventSeverity.warning);
  });

  test('a run that carried on past a step problem and failed hours later is '
      'told one warning and one failure', () async {
    events
      ..add(_sequencer('Started', severity: EventSeverity.info))
      ..add(_error(SequencerErrorKind.stepProblem, 'Dither did not settle'))
      ..add(_sequencer('ExposureStarted', severity: EventSeverity.info))
      ..add(_error(SequencerErrorKind.stepFailed, _fault))
      ..add(_sequencer('SequenceFailed', data: {'error': _fault}));
    await _settle();

    expect(problems().map((m) => m.body), ['Sequence: Dither did not settle']);
    expect(failures().map((m) => m.body.split('. ').last), ['$_fault.']);
  });

  test('a failed step that recovery saved raises no failure notice', () async {
    events
      ..add(_sequencer('Started', severity: EventSeverity.info))
      ..add(_error(SequencerErrorKind.stepFailed, 'Camera disconnected'))
      ..add(_sequencer('ExposureStarted', severity: EventSeverity.info))
      ..add(_sequencer('Completed', severity: EventSeverity.info));
    await _settle();

    expect(failures(), isEmpty);
  });

  test('a note, a pause reason and a hand-started operation raise no run '
      'notice', () async {
    events
      ..add(_sequencer('Started', severity: EventSeverity.info))
      ..add(_error(SequencerErrorKind.advisory, 'No plate solver configured'))
      ..add(_error(SequencerErrorKind.runHeld, 'Drift recenter failed'))
      ..add(_error(SequencerErrorKind.standalone, 'Autofocus frame not saved'));
    await _settle();

    expect(failures(), isEmpty);
    expect(problems(), isEmpty);
  });

  test('two runs that fail are each told', () async {
    events
      ..add(_sequencer('Started', severity: EventSeverity.info))
      ..add(_sequencer('SequenceFailed', data: {'error': _fault}))
      ..add(_sequencer('Started', severity: EventSeverity.info))
      ..add(_sequencer('SequenceFailed', data: {'error': 'Slew refused'}));
    await _settle();

    expect(failures().map((m) => m.body.split('. ').last), [
      '$_fault.',
      'Slew refused.',
    ]);
  });

  // A host from before the kind was on the wire: its errors carry none.
  test('an error without a kind is a failing step, and a warning without one '
      'a note', () async {
    events
      ..add(_sequencer('Started', severity: EventSeverity.info))
      ..add(_sequencer('Error', data: {'message': _fault}))
      ..add(
        _sequencer(
          'Error',
          severity: EventSeverity.warning,
          data: {'message': 'No plate solver configured'},
        ),
      )
      ..add(_sequencer('SequenceFailed', data: {'error': _fault}));
    await _settle();

    expect(failures(), hasLength(1));
    expect(problems(), isEmpty);
  });
}
