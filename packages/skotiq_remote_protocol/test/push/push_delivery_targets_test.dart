import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

void main() {
  group('PushDeliveryTargets', () {
    test(
      'a recording mock cannot deliver, however many devices registered',
      () {
        const targets = PushDeliveryTargets(
          registeredDeviceCount: 3,
          fcmTokenCount: 3,
          apnsTokenCount: 0,
          channel: PushDeliveryChannel.mock,
        );

        expect(targets.canDeliver, isFalse);
        expect(targets.cloudDeliveryConfigured, isFalse);
        expect(targets.blockedReason, contains('local mock'));
      },
    );

    test('cloud channel with a registered device delivers', () {
      const targets = PushDeliveryTargets(
        registeredDeviceCount: 1,
        fcmTokenCount: 1,
        apnsTokenCount: 0,
        channel: PushDeliveryChannel.cloud,
      );

      expect(targets.canDeliver, isTrue);
      expect(targets.blockedReason, isNull);
    });

    test('the two-state constructor maps onto cloud/none', () {
      const configured = PushDeliveryTargets(
        registeredDeviceCount: 1,
        fcmTokenCount: 1,
        apnsTokenCount: 0,
        cloudDeliveryConfigured: true,
      );
      const unconfigured = PushDeliveryTargets(
        registeredDeviceCount: 1,
        fcmTokenCount: 1,
        apnsTokenCount: 0,
        cloudDeliveryConfigured: false,
      );

      expect(configured.channel, PushDeliveryChannel.cloud);
      expect(unconfigured.channel, PushDeliveryChannel.none);
    });

    test('the channel round-trips over the wire', () {
      const targets = PushDeliveryTargets(
        registeredDeviceCount: 2,
        fcmTokenCount: 1,
        apnsTokenCount: 1,
        channel: PushDeliveryChannel.mock,
      );

      final json = targets.toJson();
      expect(json['deliveryChannel'], 'mock');
      expect(json['cloudDeliveryConfigured'], isFalse);
      expect(json['canDeliver'], isFalse);
      expect(PushDeliveryTargets.fromJson(json), targets);
    });

    test('a payload without deliveryChannel collapses to cloud/none', () {
      final fromCloud = PushDeliveryTargets.fromJson({
        'registeredDeviceCount': 1,
        'fcmTokenCount': 1,
        'apnsTokenCount': 0,
        'cloudDeliveryConfigured': true,
      });
      final fromNothing = PushDeliveryTargets.fromJson({
        'registeredDeviceCount': 0,
        'fcmTokenCount': 0,
        'apnsTokenCount': 0,
      });

      expect(fromCloud.channel, PushDeliveryChannel.cloud);
      expect(fromNothing.channel, PushDeliveryChannel.none);
    });
  });
}
