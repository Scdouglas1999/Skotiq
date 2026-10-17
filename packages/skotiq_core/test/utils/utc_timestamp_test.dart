import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/utils/utc_timestamp.dart';

/// Timestamps that cross the Rust/HTTP boundary are UTC instants. The native
/// bridge can emit them without a `Z`, and `DateTime.parse` reads that
/// offset-less form as *local* time — shifting the instant by the host's
/// timezone offset for every consumer. These assertions are host-TZ
/// independent: `DateTime` equality also compares [DateTime.isUtc], so a
/// local-flagged parse fails even when the host clock is UTC.
void main() {
  group('parseUtcTimestamp', () {
    test('reads an offset-less bridge timestamp as UTC', () {
      final parsed = parseUtcTimestamp('2026-07-28T17:33:34');
      expect(parsed.isUtc, isTrue);
      expect(parsed, DateTime.utc(2026, 7, 28, 17, 33, 34));
    });

    test('reads a fractional offset-less timestamp as UTC', () {
      expect(
        parseUtcTimestamp('2026-07-28T17:33:34.250'),
        DateTime.utc(2026, 7, 28, 17, 33, 34, 250),
      );
    });

    test('honours a trailing Z', () {
      expect(
        parseUtcTimestamp('2026-07-28T17:33:34Z'),
        DateTime.utc(2026, 7, 28, 17, 33, 34),
      );
    });

    test('honours a fixed positive offset', () {
      expect(
        parseUtcTimestamp('2026-07-29T02:33:34+09:00'),
        DateTime.utc(2026, 7, 28, 17, 33, 34),
      );
    });

    test('honours a fixed negative offset', () {
      expect(
        parseUtcTimestamp('2026-07-28T13:33:34-04:00'),
        DateTime.utc(2026, 7, 28, 17, 33, 34),
      );
    });

    test('honours an offset written without a colon', () {
      expect(
        parseUtcTimestamp('2026-07-29T02:33:34+0900'),
        DateTime.utc(2026, 7, 28, 17, 33, 34),
      );
    });

    test('accepts a space-separated date and time', () {
      expect(
        parseUtcTimestamp('2026-07-28 17:33:34'),
        DateTime.utc(2026, 7, 28, 17, 33, 34),
      );
    });

    test('throws on an unparseable value', () {
      expect(
        () => parseUtcTimestamp('not-a-timestamp'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('normalizeUtcTimestamp', () {
    test('stamps an explicit Z onto an offset-less bridge timestamp', () {
      expect(
        normalizeUtcTimestamp('2026-07-28T17:33:34'),
        '2026-07-28T17:33:34.000Z',
      );
    });

    test('rebases a fixed offset onto UTC', () {
      expect(
        normalizeUtcTimestamp('2026-07-29T02:33:34+09:00'),
        '2026-07-28T17:33:34.000Z',
      );
    });

    test('returns an unparseable value unchanged', () {
      expect(normalizeUtcTimestamp('garbage'), 'garbage');
    });

    test('returns an empty value unchanged', () {
      expect(normalizeUtcTimestamp(''), '');
    });
  });
}
