import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/phd2_status_poll.dart';

void main() {
  group('isPhd2GuidingHeartbeatEvent', () {
    test('Disconnected is not a heartbeat', () {
      expect(isPhd2GuidingHeartbeatEvent('Disconnected'), isFalse);
    });

    test('GuideStep is a heartbeat', () {
      expect(isPhd2GuidingHeartbeatEvent('GuideStep'), isTrue);
    });

    test('GuidingStopped is a heartbeat (connect handshake)', () {
      expect(isPhd2GuidingHeartbeatEvent('GuidingStopped'), isTrue);
    });
  });
}
