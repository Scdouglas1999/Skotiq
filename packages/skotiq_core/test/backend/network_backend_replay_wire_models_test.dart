import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../fakes/fakes.dart';

Map<String, Object?> _event({int timestampMs = 1700000000000}) => {
  'timestamp': DateTime.fromMillisecondsSinceEpoch(
    timestampMs,
    isUtc: true,
  ).toIso8601String(),
  'timestampMs': timestampMs,
  'severity': 'info',
  'source': 'Sequencer',
  'message': 'Captured frame',
  'fields': <String, Object?>{'node': 'Exposure'},
};

Map<String, Object?> _frame({num id = 3, int capturedAtMs = 1700000000000}) => {
  'id': id,
  'fileName': 'frame.fits',
  'filePath': '/data/frame.fits',
  'capturedAt': DateTime.fromMillisecondsSinceEpoch(
    capturedAtMs,
    isUtc: true,
  ).toIso8601String(),
  'capturedAtMs': capturedAtMs,
  'frameType': 'light',
  'exposureDuration': 60.0,
  'filter': 'L',
  'gain': 100,
  'offset': 20,
  'binX': 1,
  'binY': 1,
  'sensorTemp': -10.0,
  'hfr': 2.3,
  'starCount': 50,
  'background': 500.0,
  'noise': 4.0,
  'qualityScore': 0.9,
  'guidingRmsRa': 0.4,
  'guidingRmsDec': 0.5,
  'guidingRmsTotal': 0.64,
  'mountRa': 12.3,
  'mountDec': -22.0,
  'mountAltitude': 45.0,
  'mountAzimuth': 180.0,
  'focuserPosition': 25000,
  'isAccepted': true,
  'rejectionReason': null,
  'sessionId': 4,
  'targetId': 5,
};

void main() {
  group('Replay wire model contracts', () {
    test('accepts complete current event and frame payloads', () {
      final event = RemoteReplayEvent.fromJson(_event());
      final frame = RemoteReplayFrame.fromJson(_frame());

      expect(event.message, 'Captured frame');
      expect(event.fields, {'node': 'Exposure'});
      expect(frame.id, 3);
      expect(frame.hfr, 2.3);
      expect(frame.isAccepted, isTrue);
    });

    test('generic pages reject missing totals and silently droppable rows', () {
      expect(
        () => RemotePage<RemoteReplayFrame>.fromJson({
          'items': [_frame()],
        }, RemoteReplayFrame.fromJson),
        throwsFormatException,
      );
      expect(
        () => RemotePage<RemoteReplayFrame>.fromJson({
          'items': [false],
          'total': 1,
        }, RemoteReplayFrame.fromJson),
        throwsFormatException,
      );
      expect(
        () => RemotePage<RemoteReplayFrame>.fromJson({
          'items': [_frame()],
          'total': 0,
        }, RemoteReplayFrame.fromJson),
        throwsFormatException,
      );
    });

    test(
      'events reject clock defaults, malformed fields, and false completeness',
      () {
        final missingTimestamp = _event()..remove('timestamp');
        final wrongTimestamp = _event()..['timestampMs'] = 1700000000001;
        final badFields = _event()..['fields'] = 'not-an-object';

        for (final row in [missingTimestamp, wrongTimestamp, badFields]) {
          expect(
            () => RemoteReplayEvent.fromJson(row.cast<String, dynamic>()),
            throwsFormatException,
          );
        }
        expect(
          () => RemoteReplayEventsPage.fromJson({
            'items': [_event()],
            'total': 1,
            'is_partial': true,
            'source': 'logging_service_ring_buffer',
          }),
          throwsFormatException,
        );
        expect(
          () => RemoteReplayEventsPage.fromJson({
            'items': [false],
            'total': 1,
            'is_partial': false,
            'source': 'logging_service_ring_buffer',
          }),
          throwsFormatException,
        );
      },
    );

    test(
      'frames reject fractional ids, missing acceptance, and invalid domains',
      () {
        final fractional = _frame(id: 3.5);
        final missingAccepted = _frame()..remove('isAccepted');
        final negativeHfr = _frame()..['hfr'] = -1;
        final mismatchedClock = _frame()..['capturedAtMs'] = 1700000000001;

        for (final row in [
          fractional,
          missingAccepted,
          negativeHfr,
          mismatchedClock,
        ]) {
          expect(
            () => RemoteReplayFrame.fromJson(row.cast<String, dynamic>()),
            throwsFormatException,
          );
        }
      },
    );

    test('run detail endpoint rejects a mismatched response id', () async {
      final fake = FakeNetworkClient()
        ..setResponse(
          '/api/sequence-runs/4',
          body: jsonEncode({
            'run': {
              'id': 5,
              'sequenceId': null,
              'sequenceName': 'Run',
              'startedAt': '2026-01-01T00:00:00.000Z',
              'endedAt': '2026-01-01T01:00:00.000Z',
              'status': 'completed',
              'statsJson': null,
              'frameCount': 1,
              'targetName': 'M31',
            },
          }),
        );
      final backend = NetworkBackend(
        serverHost: 'example.invalid',
        httpClient: fake,
        autoConnectWebSocket: false,
      );
      addTearDown(backend.dispose);

      await expectLater(backend.fetchSequenceRunById(4), throwsFormatException);
    });
  });
}
