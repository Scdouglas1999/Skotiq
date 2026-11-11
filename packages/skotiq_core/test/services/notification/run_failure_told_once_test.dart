// One failed run, one notice, with the reason.
//
// A run whose capture folder turned read-only reported its fault three times
// (the exposure's own error, the instruction failure restating it with the
// step's name, and the terminal `SequenceFailed`), and the operator got a
// toast for each, none of which said why the run had ended.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

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

  test('a failed run is told once, with the first fault as the reason', () async {
    events
      ..add(_sequencer('Started', severity: EventSeverity.info))
      ..add(_sequencer('Error', data: {'message': _fault}))
      ..add(_sequencer('Error', data: {'message': 'Exposure: $_fault'}))
      ..add(_sequencer('SequenceFailed', data: {'error': _fault}));
    await _settle();

    expect(failures(), hasLength(1));
    expect(failures().single.title, 'Sequence failed');
    expect(failures().single.body, endsWith('. $_fault.'));
  });

  test('a run that failed on a refusal is told by its terminal event', () async {
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
  });

  test('a failure without a reason says where the reason is', () async {
    events
      ..add(_sequencer('Started', severity: EventSeverity.info))
      ..add(_sequencer('SequenceFailed', data: {'error': 'Sequence failed'}));
    await _settle();

    expect(failures().single.body, endsWith('. The log has the reason.'));
  });

  test('the next run, and a failure after a run ended, are told again', () async {
    events
      ..add(_sequencer('Started', severity: EventSeverity.info))
      ..add(_sequencer('Error', data: {'message': _fault}))
      ..add(_sequencer('SequenceFailed', data: {'error': _fault}))
      ..add(_sequencer('Error', data: {'message': 'Flat panel did not open'}))
      ..add(_sequencer('Started', severity: EventSeverity.info))
      ..add(_sequencer('Error', data: {'message': 'Slew refused'}));
    await _settle();

    expect(failures().map((m) => m.body.split('. ').last), [
      '$_fault.',
      'Flat panel did not open.',
      'Slew refused.',
    ]);
  });
}
