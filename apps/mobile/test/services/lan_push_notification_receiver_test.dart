import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_mobile/services/lan_push_notification_receiver.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

void main() {
  final fingerprint = 'abcd' * 16; // 64 hex chars
  final hmacKey = derivePushHmacKey(fingerprint);

  PushNotificationFrame buildFrame({
    String id = 'frame-1',
    String severity = 'critical',
    String? fp,
  }) {
    return PushNotificationFrame(
      id: id,
      severity: severity,
      title: 'Sequence Aborted',
      body: 'Cloud cover exceeded threshold; imaging halted.',
      data: const {'eventType': 'WeatherUnsafe'},
      timestamp: DateTime.utc(2026, 5, 24, 1, 30, 0),
      serverFingerprint: fp ?? fingerprint,
    );
  }

  test('receiver decodes a valid frame and emits it on incoming', () async {
    final injectorController = StreamController<Uint8List>();
    final receiver = LanPushNotificationReceiver(
      serverFingerprint: fingerprint,
      injector: LanPushTestInjector(injectorController.stream),
    );
    addTearDown(() async {
      await receiver.dispose();
      await injectorController.close();
    });

    await receiver.start();
    final framesFuture = receiver.incoming.take(1).toList();

    final bytes = encodePushFrame(buildFrame(), hmacKey: hmacKey);
    injectorController.add(bytes);

    final frames = await framesFuture.timeout(const Duration(seconds: 2));
    expect(frames, hasLength(1));
    expect(frames.first.id, 'frame-1');
    expect(frames.first.severity, 'critical');
    expect(frames.first.title, 'Sequence Aborted');
  });

  test(
    'receiver drops a frame whose HMAC was computed with a different key',
    () async {
      final injectorController = StreamController<Uint8List>();
      final receiver = LanPushNotificationReceiver(
        serverFingerprint: fingerprint,
        injector: LanPushTestInjector(injectorController.stream),
      );
      addTearDown(() async {
        await receiver.dispose();
        await injectorController.close();
      });

      await receiver.start();
      final received = <PushNotificationFrame>[];
      final sub = receiver.incoming.listen(received.add);

      final wrongKey = derivePushHmacKey('00' * 32);
      final bytes = encodePushFrame(buildFrame(), hmacKey: wrongKey);
      injectorController.add(bytes);

      // Give the listener a chance to run.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(received, isEmpty);
      await sub.cancel();
    },
  );

  test('receiver drops a frame claiming the wrong fingerprint', () async {
    final injectorController = StreamController<Uint8List>();
    final receiver = LanPushNotificationReceiver(
      serverFingerprint: fingerprint,
      injector: LanPushTestInjector(injectorController.stream),
    );
    addTearDown(() async {
      await receiver.dispose();
      await injectorController.close();
    });

    await receiver.start();
    final received = <PushNotificationFrame>[];
    final sub = receiver.incoming.listen(received.add);

    // The HMAC is computed with a key derived from the OTHER fingerprint;
    // both sender and receiver must agree on the key. Build a frame
    // signed with a key that does not match the receiver's expected key.
    final attackerFingerprint = 'ffff' * 16;
    final attackerKey = derivePushHmacKey(attackerFingerprint);
    final spoofedBytes = encodePushFrame(
      buildFrame(fp: attackerFingerprint),
      hmacKey: attackerKey,
    );
    injectorController.add(spoofedBytes);

    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(received, isEmpty);
    await sub.cancel();
  });

  test('receiver deduplicates against an id seen via the WebSocket', () async {
    final injectorController = StreamController<Uint8List>();
    final receiver = LanPushNotificationReceiver(
      serverFingerprint: fingerprint,
      injector: LanPushTestInjector(injectorController.stream),
    );
    addTearDown(() async {
      await receiver.dispose();
      await injectorController.close();
    });

    await receiver.start();
    final received = <PushNotificationFrame>[];
    final sub = receiver.incoming.listen(received.add);

    // Pretend the WS delivered this frame first.
    receiver.recordSeenFrameId('frame-dedup');
    final bytes = encodePushFrame(
      buildFrame(id: 'frame-dedup'),
      hmacKey: hmacKey,
    );
    injectorController.add(bytes);

    // Second injection of the same id (e.g. multicast + broadcast copies):
    // must also be deduped.
    injectorController.add(bytes);

    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(received, isEmpty);

    // A different id from the same server, however, passes through.
    final freshBytes = encodePushFrame(
      buildFrame(id: 'frame-fresh'),
      hmacKey: hmacKey,
    );
    injectorController.add(freshBytes);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(received, hasLength(1));
    expect(received.single.id, 'frame-fresh');

    await sub.cancel();
  });

  test('receiver drops a truncated datagram silently', () async {
    final injectorController = StreamController<Uint8List>();
    final receiver = LanPushNotificationReceiver(
      serverFingerprint: fingerprint,
      injector: LanPushTestInjector(injectorController.stream),
    );
    addTearDown(() async {
      await receiver.dispose();
      await injectorController.close();
    });

    await receiver.start();
    final received = <PushNotificationFrame>[];
    final sub = receiver.incoming.listen(received.add);

    injectorController.add(Uint8List.fromList([1, 2, 3]));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(received, isEmpty);
    await sub.cancel();
  });
}
