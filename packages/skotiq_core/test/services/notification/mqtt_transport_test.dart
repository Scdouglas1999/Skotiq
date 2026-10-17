import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/notification/notification_categories.dart';
import 'package:skotiq_core/src/models/notification/transport_configs.dart';
import 'package:skotiq_core/src/services/notification/transports/mqtt_transport.dart';

Future<({ServerSocket server, StreamSubscription<Socket> subscription})>
_brokerThatImmediatelySends(List<int> bytes) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final subscription = server.listen((socket) {
    // Deliberately respond as soon as TCP accepts. This can beat the client's
    // readPacket() call, so it pins the packet buffering that keeps a healthy
    // broker's CONNACK/PUBACK from being dropped.
    socket.add(bytes);
  });
  return (server: server, subscription: subscription);
}

Future<void> _closeBroker(
  ({ServerSocket server, StreamSubscription<Socket> subscription}) broker,
) async {
  await broker.subscription.cancel();
  await broker.server.close();
}

void main() {
  test('an immediate CONNACK is buffered instead of timing out', () async {
    final broker = await _brokerThatImmediatelySends(const [
      0x20,
      0x02,
      0x00,
      0x00,
    ]);
    addTearDown(() => _closeBroker(broker));
    final transport = MqttTransport(
      config: MqttTransportConfig(
        host: InternetAddress.loopbackIPv4.address,
        port: broker.server.port,
        topic: 'skotiq/test',
      ),
      timeout: const Duration(seconds: 1),
    );

    final result = await transport.send(
      category: NotificationCategory.custom,
      title: 'Test',
      body: 'Immediate broker response',
    );

    expect(result.success, isTrue);
  });

  test('QoS 1 rejects a PUBACK for a different packet id', () async {
    final broker = await _brokerThatImmediatelySends(const [
      0x20, 0x02, 0x00, 0x00, // accepted CONNACK
      0x40, 0x02, 0x00, 0x02, // wrong id; Skotiq publishes id 1
    ]);
    addTearDown(() => _closeBroker(broker));
    final transport = MqttTransport(
      config: MqttTransportConfig(
        host: InternetAddress.loopbackIPv4.address,
        port: broker.server.port,
        topic: 'skotiq/test',
        qos: 1,
      ),
      timeout: const Duration(seconds: 1),
    );

    final result = await transport.send(
      category: NotificationCategory.custom,
      title: 'Test',
      body: 'Wrong PUBACK',
    );

    expect(result.success, isFalse);
    expect(result.error, contains('wrong packet'));
  });

  test('malformed remaining-length bytes fail promptly', () async {
    final broker = await _brokerThatImmediatelySends(const [
      0x20,
      0xff,
      0xff,
      0xff,
      0xff,
    ]);
    addTearDown(() => _closeBroker(broker));
    final transport = MqttTransport(
      config: MqttTransportConfig(
        host: InternetAddress.loopbackIPv4.address,
        port: broker.server.port,
        topic: 'skotiq/test',
      ),
      timeout: const Duration(seconds: 1),
    );

    final result = await transport.send(
      category: NotificationCategory.custom,
      title: 'Test',
      body: 'Malformed broker response',
    );

    expect(result.success, isFalse);
    expect(result.error, contains('remaining length malformed'));
  });
}
