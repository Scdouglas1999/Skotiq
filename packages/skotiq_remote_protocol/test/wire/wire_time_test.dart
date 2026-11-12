// Times cross the wire as UTC with a `Z`, and are read as the reader's local
// time. A host used to send its local wall-clock time with no offset, which a
// client in another time zone read as its own local time: a run the host
// started at 20:09 in New York showed as 20:09 in Tokyo, 14 hours off.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_remote_protocol/wire.dart';

void main() {
  // A local value, as every row the host reads from its database carries.
  final startedLocal = DateTime(2026, 11, 11, 20, 9, 15);

  test('a local time is written as the same instant in UTC with a Z', () {
    final wire = startedLocal.toWireTime();
    expect(wire, endsWith('Z'));
    expect(DateTime.parse(wire).isUtc, isTrue);
    expect(DateTime.parse(wire).isAtSameMomentAs(startedLocal), isTrue);
    expect(startedLocal.toUtc().toWireTime(), wire);
  });

  test('a wire time is read as local time, the same instant', () {
    final read = parseWireTime('2026-11-12T01:09:15.000Z');
    expect(read.isUtc, isFalse);
    expect(read.isAtSameMomentAs(DateTime.utc(2026, 11, 12, 1, 9, 15)), isTrue);
    expect(tryParseWireTime('2026-11-11T20:09:15.000-05:00'), read);
    expect(tryParseWireTime('not a time'), isNull);
  });

  test('a time without an offset, from an older host, still reads', () {
    final read = parseWireTime('2026-11-11T20:09:15.000');
    expect(read, startedLocal);
  });

  test('every row that carries a time sends it with a Z', () {
    final rows = <Map<String, dynamic>>[
      RemoteSequenceRun(
        id: 1,
        startedAt: startedLocal,
        endedAt: startedLocal.add(const Duration(hours: 1)),
        status: 'completed',
      ).toJson(),
      RemoteSequenceRunDetail(
        id: 1,
        startedAt: startedLocal,
        endedAt: startedLocal.add(const Duration(hours: 1)),
        status: 'completed',
        frameCount: 0,
      ).toJson(),
      RemoteReplayEvent(
        timestamp: startedLocal,
        timestampMs: startedLocal.millisecondsSinceEpoch,
        severity: 'info',
        message: 'Started',
      ).toJson(),
      RemoteReplayFrame(
        id: 1,
        fileName: 'a.fits',
        filePath: '/f/a.fits',
        capturedAt: startedLocal,
        capturedAtMs: startedLocal.millisecondsSinceEpoch,
        frameType: 'light',
        exposureDuration: 60,
        binX: 1,
        binY: 1,
        isAccepted: true,
      ).toJson(),
    ];
    for (final row in rows) {
      for (final key in ['startedAt', 'endedAt', 'timestamp', 'capturedAt']) {
        final value = row[key];
        if (value == null) continue;
        expect(value, endsWith('Z'), reason: '$key of $row');
        expect(
          DateTime.parse(value as String).difference(startedLocal).inHours,
          lessThanOrEqualTo(1),
        );
      }
    }
    expect(
      RemoteSequenceRun.fromJson(rows.first).startedAt,
      startedLocal,
      reason: 'read back as the local time it was',
    );
  });

  group('a replay frame', () {
    Map<String, dynamic> frame({required String capturedAt, required int ms}) =>
        {
          ...RemoteReplayFrame(
            id: 1,
            fileName: 'a.fits',
            filePath: '/f/a.fits',
            capturedAt: startedLocal,
            capturedAtMs: startedLocal.millisecondsSinceEpoch,
            frameType: 'light',
            exposureDuration: 60,
            binX: 1,
            binY: 1,
            isAccepted: true,
          ).toJson(),
          'capturedAt': capturedAt,
          'capturedAtMs': ms,
        };
    final instant = DateTime.utc(2026, 11, 12, 1, 9, 15);

    test('from an older host in another time zone is read by its epoch '
        'milliseconds', () {
      // The host's wall clock, nine hours from this instant wherever the
      // reader is: no reader's zone makes the string name it.
      final read = RemoteReplayFrame.fromJson(
        frame(
          capturedAt: '2026-11-12T10:09:15.000',
          ms: instant.millisecondsSinceEpoch,
        ),
      );
      expect(read.capturedAt.isAtSameMomentAs(instant), isTrue);
      expect(read.capturedAt.isUtc, isFalse);
    });

    test('whose wire time names another instant than its milliseconds is '
        'refused', () {
      expect(
        () => RemoteReplayFrame.fromJson(
          frame(
            capturedAt: '2026-11-12T10:09:15.000Z',
            ms: instant.millisecondsSinceEpoch,
          ),
        ),
        throwsFormatException,
      );
    });
  });
}
