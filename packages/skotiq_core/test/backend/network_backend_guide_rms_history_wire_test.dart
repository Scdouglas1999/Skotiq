import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';

Map<String, dynamic> _row(Object? sessionId) => {
  'id': 7,
  'sessionId': sessionId,
  'mountId': 'ascom:ASCOM.PegasusAstroNYX101.Telescope',
  'targetId': 25,
  'totalRmsArcsec': 1.643,
  'sampleCount': 4,
  'exposureSeconds': 60.0,
  'recordedAt': '2026-11-03T18:32:57.000',
};

void main() {
  group('RemoteGuideRmsHistoryEntry', () {
    test('reads the text session id that 8.2.0 hosts send', () {
      final page = RemotePage.fromJson({
        'items': [_row('113')],
        'total': 1,
      }, RemoteGuideRmsHistoryEntry.fromJson);

      expect(page.items.single.sessionId, 113);
      expect(page.items.single.totalRmsArcsec, 1.643);
    });

    test('reads a numeric session id', () {
      expect(RemoteGuideRmsHistoryEntry.fromJson(_row(113)).sessionId, 113);
    });

    test('a non-numeric or missing session id is null, not an error', () {
      expect(
        RemoteGuideRmsHistoryEntry.fromJson(_row('session-1')).sessionId,
        isNull,
      );
      expect(RemoteGuideRmsHistoryEntry.fromJson(_row(null)).sessionId, isNull);
    });

    test('a malformed row names the real cause', () {
      final row = _row(113)..['id'] = 'seven';
      expect(
        () => RemotePage.fromJson({
          'items': [row],
          'total': 1,
        }, RemoteGuideRmsHistoryEntry.fromJson),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            allOf(contains('row 0 is malformed'), isNot(contains('keys'))),
          ),
        ),
      );
    });
  });
}
