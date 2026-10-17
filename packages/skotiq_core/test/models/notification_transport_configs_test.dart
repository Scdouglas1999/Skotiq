import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/notification/transport_configs.dart';

void main() {
  group('MqttTransportConfig QoS migration', () {
    test(
      'legacy QoS 2 is decoded as the QoS 1 behavior actually delivered',
      () {
        final config = MqttTransportConfig.fromJson(const {'qos': 2});

        expect(config.qos, 1);
        expect(config.toJson()['qos'], 1);
      },
    );

    test('invalid persisted QoS values surface corruption', () {
      expect(
        () => MqttTransportConfig.fromJson(const {'qos': -1}),
        throwsFormatException,
      );
      expect(
        () => MqttTransportConfig.fromJson(const {'qos': 99}),
        throwsFormatException,
      );
    });
  });

  group('strict persisted transport values', () {
    test('rejects fractional and out-of-range ports', () {
      expect(
        () => EmailTransportConfig.fromJson(const {'smtpPort': 587.5}),
        throwsFormatException,
      );
      expect(
        () => MqttTransportConfig.fromJson(const {'port': 70000}),
        throwsFormatException,
      );
    });

    test('rejects malformed URLs and lossy webhook headers', () {
      expect(
        () => WebhookTransportConfig.fromJson(const {'url': 'not a URL'}),
        throwsFormatException,
      );
      expect(
        () => WebhookTransportConfig.fromJson(const {
          'headers': {'X-Retry': 3},
        }),
        throwsFormatException,
      );
    });

    test('rejects out-of-range Pushover priority', () {
      expect(
        () => PushoverTransportConfig.fromJson(const {'priority': 3}),
        throwsFormatException,
      );
    });
  });
}
