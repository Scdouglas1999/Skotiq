// `/api/sessions` wire rows had TWO hand-maintained decoders — one on
// `ImagingRecordsRepository`, one in `database_provider` — decoding the same
// endpoint into the same Drift row. Both coerced timestamps with
// `DateTime.tryParse`, which reads an offset-less ISO-8601 string as LOCAL
// time: a companion in a different timezone than the appliance rendered every
// session start/end shifted by the offset delta, silently. There is now one
// decoder, and it routes strings through the UTC-aware parser.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/imaging_records_repository.dart'
    show imagingSessionFromWireJson, wireTimestamp;

void main() {
  group('wireTimestamp', () {
    test('reads an offset-less ISO-8601 string as UTC, not local', () {
      final parsed = wireTimestamp('2026-08-10T22:15:30');
      expect(parsed.isUtc, isTrue);
      expect(
        parsed.millisecondsSinceEpoch,
        DateTime.utc(2026, 8, 10, 22, 15, 30).millisecondsSinceEpoch,
        reason:
            'DateTime.tryParse would have shifted this by the host offset; '
            'the appliance serialises UTC instants',
      );
    });

    test('preserves an explicit designator or offset', () {
      expect(
        wireTimestamp('2026-08-10T22:15:30Z').millisecondsSinceEpoch,
        DateTime.utc(2026, 8, 10, 22, 15, 30).millisecondsSinceEpoch,
      );
      expect(
        wireTimestamp('2026-08-10T18:15:30-04:00').millisecondsSinceEpoch,
        DateTime.utc(2026, 8, 10, 22, 15, 30).millisecondsSinceEpoch,
      );
    });

    test('epoch milliseconds and unparseable values are unchanged', () {
      expect(
        wireTimestamp(1754864130000).millisecondsSinceEpoch,
        1754864130000,
      );
      expect(wireTimestamp('not a timestamp').millisecondsSinceEpoch, 0);
      expect(wireTimestamp(null).millisecondsSinceEpoch, 0);
    });
  });

  group('imagingSessionFromWireJson', () {
    test('decodes the host row, defaulting the fields it may omit', () {
      final session = imagingSessionFromWireJson(const {
        'id': 7,
        'name': 'M42',
        'profileId': 2,
        'targetId': 3,
        'startTime': 1754864130000,
        'endTime': null,
        'successfulExposures': 12,
        'totalIntegrationSecs': 3600.0,
        'avgHfr': 2.4,
        'sequenceId': 9,
      });

      expect(session.id, 7);
      expect(session.name, 'M42');
      expect(session.profileId, 2);
      expect(session.targetId, 3);
      expect(session.startTime.millisecondsSinceEpoch, 1754864130000);
      expect(session.endTime, isNull);
      expect(session.successfulExposures, 12);
      expect(session.totalExposures, 0);
      expect(session.failedExposures, 0);
      expect(session.totalIntegrationSecs, 3600.0);
      expect(session.avgHfr, 2.4);
      expect(session.autofocusCount, 0);
      expect(session.status, 'completed');
      expect(session.sequenceId, 9);
    });

    test('carries the UTC guard into startTime and endTime', () {
      final session = imagingSessionFromWireJson(const {
        'id': 1,
        'startTime': '2026-08-10T22:00:00',
        'endTime': '2026-08-11T04:30:00',
      });

      expect(
        session.startTime.millisecondsSinceEpoch,
        DateTime.utc(2026, 8, 10, 22).millisecondsSinceEpoch,
      );
      expect(
        session.endTime!.millisecondsSinceEpoch,
        DateTime.utc(2026, 8, 11, 4, 30).millisecondsSinceEpoch,
      );
    });
  });
}
