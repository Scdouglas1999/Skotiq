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

  var sentinels = 0;

  /// What [receiver] emits for [datagrams], fed through [injector].
  ///
  /// A valid sentinel frame follows them: the receiver handles datagrams in
  /// order, so once the sentinel arrives every earlier datagram has been
  /// accepted or dropped, with no fixed wait to outlast. Each sentinel has its
  /// own id, or the receiver's de-duplication would drop the second.
  Future<List<PushNotificationFrame>> emittedFor(
    LanPushNotificationReceiver receiver,
    StreamController<Uint8List> injector,
    List<Uint8List> datagrams,
  ) async {
    final received = <PushNotificationFrame>[];
    final sentinel = 'sentinel-${sentinels++}';
    final sentinelSeen = Completer<void>();
    final sub = receiver.incoming.listen((frame) {
      if (frame.id == sentinel) {
        sentinelSeen.complete();
      } else {
        received.add(frame);
      }
    });
    datagrams.forEach(injector.add);
    injector.add(encodePushFrame(buildFrame(id: sentinel), hmacKey: hmacKey));
    await sentinelSeen.future.timeout(const Duration(seconds: 10));
    await sub.cancel();
    return received;
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

      final wrongKey = derivePushHmacKey('00' * 32);
      final bytes = encodePushFrame(buildFrame(), hmacKey: wrongKey);

      expect(await emittedFor(receiver, injectorController, [bytes]), isEmpty);
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

    // The HMAC is computed with a key derived from the OTHER fingerprint;
    // both sender and receiver must agree on the key. Build a frame
    // signed with a key that does not match the receiver's expected key.
    final attackerFingerprint = 'ffff' * 16;
    final attackerKey = derivePushHmacKey(attackerFingerprint);
    final spoofedBytes = encodePushFrame(
      buildFrame(fp: attackerFingerprint),
      hmacKey: attackerKey,
    );

    expect(
      await emittedFor(receiver, injectorController, [spoofedBytes]),
      isEmpty,
    );
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

    // Pretend the WS delivered this frame first.
    receiver.recordSeenFrameId('frame-dedup');
    final bytes = encodePushFrame(
      buildFrame(id: 'frame-dedup'),
      hmacKey: hmacKey,
    );

    // Second injection of the same id (e.g. multicast + broadcast copies):
    // must also be deduped.
    expect(
      await emittedFor(receiver, injectorController, [bytes, bytes]),
      isEmpty,
    );

    // A different id from the same server, however, passes through.
    final freshBytes = encodePushFrame(
      buildFrame(id: 'frame-fresh'),
      hmacKey: hmacKey,
    );
    final fresh = await emittedFor(receiver, injectorController, [freshBytes]);
    expect(fresh, hasLength(1));
    expect(fresh.single.id, 'frame-fresh');
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

    expect(
      await emittedFor(receiver, injectorController, [
        Uint8List.fromList([1, 2, 3]),
      ]),
      isEmpty,
    );
  });
}
