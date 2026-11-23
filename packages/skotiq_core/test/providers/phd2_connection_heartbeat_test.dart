import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/backend.dart';

void main() {
  group('isPhd2GuidingHeartbeatEvent', () {
    test('Disconnected is not a heartbeat', () {
      expect(
        isPhd2GuidingHeartbeatEvent(const GuidingEvent.disconnected()),
        isFalse,
      );
    });

    test('a guide step is a heartbeat', () {
      expect(
        isPhd2GuidingHeartbeatEvent(
          const GuidingEvent.correction(ra: 0, dec: 0, raRaw: 0, decRaw: 0),
        ),
        isTrue,
      );
    });

    test('GuidingStopped is a heartbeat (connect handshake)', () {
      expect(
        isPhd2GuidingHeartbeatEvent(const GuidingEvent.guidingStopped()),
        isTrue,
      );
    });
  });
}
