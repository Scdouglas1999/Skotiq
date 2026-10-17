// LiveViewStreamHub tests.
//
// The hub runs the producer loop only while subscribers are attached. We
// drive it via the `attachRaw` test seam with an in-memory channel pair
// (so we can write client→server messages and observe server→client
// frames directly) and a deterministic test frame producer that returns
// a synthetic JPEG. That keeps the test off the camera FFI and lets the
// assertions focus on the streaming contract.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:skotiq_desktop/headless_api/handlers/live_view_stream_handlers.dart';

/// In-memory channel pair. The test sends client→server JSON messages via
/// [clientToServer] and observes server→client frames on [serverToClient].
class _ChannelPair {
  final StreamController<dynamic> clientToServer;
  final StreamController<dynamic> serverToClient;
  _ChannelPair()
    : clientToServer = StreamController<dynamic>.broadcast(),
      serverToClient = StreamController<dynamic>.broadcast();

  Future<void> dispose() async {
    await clientToServer.close();
    await serverToClient.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LiveViewStreamHub', () {
    late ProviderContainer container;
    late LiveViewStreamHub hub;
    final List<_ChannelPair> pairs = [];

    /// 64×48 solid-blue JPEG. Small enough that the encode passes are
    /// trivially fast; big enough that downscaling to 32 px on the long
    /// edge produces a sane image.
    Uint8List fakeMasterJpeg() {
      final bitmap = img.Image(width: 64, height: 48);
      img.fill(bitmap, color: img.ColorRgb8(0, 64, 255));
      return Uint8List.fromList(img.encodeJpg(bitmap, quality: 80));
    }

    _ChannelPair attachClient(Object key) {
      final pair = _ChannelPair();
      pairs.add(pair);
      hub.attachRaw(
        socket: key,
        stream: pair.clientToServer.stream,
        sinkAdd: pair.serverToClient.add,
        sinkClose: () async {
          await pair.serverToClient.close();
        },
      );
      return pair;
    }

    setUp(() {
      container = ProviderContainer();
      hub = LiveViewStreamHub(container: container);
      hub.testFrameProducer = (deviceId) async => fakeMasterJpeg();
    });

    tearDown(() async {
      await hub.dispose();
      for (final p in pairs) {
        await p.dispose();
      }
      pairs.clear();
      container.dispose();
    });

    test('does not start producer until first subscribe', () async {
      final socketKey = Object();
      attachClient(socketKey);

      // Give the hub a tick to register the socket; the producer should
      // still be idle because no subscribe message arrived.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(hub.attachedSocketCount, 1);
      expect(hub.activeSubscriberCount, 0);
    });

    test('subscribe yields >=1 frame', () async {
      final socketKey = Object();
      final pair = attachClient(socketKey);

      final received = <dynamic>[];
      final done = Completer<void>();
      pair.serverToClient.stream.listen((msg) {
        received.add(msg);
        // Wait for the meta + at least one binary frame before resolving.
        final binaryCount = received.whereType<List<int>>().length;
        if (binaryCount >= 1 && !done.isCompleted) done.complete();
      });

      pair.clientToServer.add(
        jsonEncode({
          'type': 'subscribe',
          'deviceId': 'test:cam:1',
          'maxDim': 32,
          'maxFps': 8.0,
          'jpegQuality': 60,
        }),
      );

      await done.future.timeout(const Duration(seconds: 5));
      expect(hub.activeSubscriberCount, 1);

      // Frame contract: text `ready` → text `frame_meta` → binary JPEG.
      final readyMsg = received.first as String;
      expect((jsonDecode(readyMsg) as Map)['type'], 'ready');
      // Find the first meta and the following binary.
      var metaIndex = -1;
      for (var i = 1; i < received.length; i++) {
        if (received[i] is String) {
          final decoded = jsonDecode(received[i] as String);
          if (decoded is Map && decoded['type'] == 'frame_meta') {
            metaIndex = i;
            break;
          }
        }
      }
      expect(metaIndex, greaterThan(0));
      final meta = jsonDecode(received[metaIndex] as String) as Map;
      expect(meta['deviceId'], 'test:cam:1');
      expect(meta['width'], lessThanOrEqualTo(32));
      expect(meta['height'], lessThanOrEqualTo(32));
      expect(meta['frameNumber'], 1);

      final binary = received[metaIndex + 1];
      expect(binary, isA<List<int>>());
      expect((binary as List<int>).length, greaterThan(0));
    });

    test(
      'unsubscribe stops the producer once last subscriber leaves',
      () async {
        final socketKey = Object();
        final pair = attachClient(socketKey);

        final ready = Completer<void>();
        late StreamSubscription clientSub;
        clientSub = pair.serverToClient.stream.listen((msg) {
          if (msg is String) {
            final m = jsonDecode(msg);
            if (m is Map && m['type'] == 'ready' && !ready.isCompleted) {
              ready.complete();
            }
          }
        });

        pair.clientToServer.add(
          jsonEncode({
            'type': 'subscribe',
            'deviceId': 'test:cam:1',
            'maxDim': 32,
            'maxFps': 8.0,
          }),
        );
        await ready.future.timeout(const Duration(seconds: 3));
        expect(hub.activeSubscriberCount, 1);

        pair.clientToServer.add(jsonEncode({'type': 'unsubscribe'}));
        // Give the hub a moment to process and stop the producer.
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(hub.activeSubscriberCount, 0);

        await clientSub.cancel();
      },
    );

    test('bad subscribe payload returns an error frame', () async {
      final socketKey = Object();
      final pair = attachClient(socketKey);

      final errorReceived = Completer<Map>();
      pair.serverToClient.stream.listen((msg) {
        if (msg is String) {
          final m = jsonDecode(msg);
          if (m is Map && m['type'] == 'error' && !errorReceived.isCompleted) {
            errorReceived.complete(m.map((k, v) => MapEntry(k.toString(), v)));
          }
        }
      });

      pair.clientToServer.add(
        jsonEncode({
          'type': 'subscribe',
          // missing deviceId
          'maxDim': 32,
        }),
      );

      final err = await errorReceived.future.timeout(
        const Duration(seconds: 2),
      );
      expect(err['code'], 'bad_subscribe');
      expect(hub.activeSubscriberCount, 0);
    });
  });
}
