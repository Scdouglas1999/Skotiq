import 'dart:async';
import 'dart:typed_data';

import 'package:skotiq_relay/skotiq_relay.dart';
import 'package:test/test.dart';

/// Wire two sessions together through async in-memory queues, mimicking a
/// message transport (delivery is ordered but decoupled from the send call,
/// like a real WebSocket).
({MuxSession initiator, MuxSession acceptor}) connectedPair({
  void Function(MuxStream stream)? onStream,
  void Function(Map<String, dynamic>)? onAcceptorControl,
}) {
  late MuxSession a;
  late MuxSession b;
  final aToB = StreamController<Uint8List>();
  final bToA = StreamController<Uint8List>();
  a = MuxSession(send: aToB.add);
  b = MuxSession(
    send: bToA.add,
    onStream: onStream,
    onControl: onAcceptorControl,
  );
  aToB.stream.listen(b.handleMessage);
  bToA.stream.listen(a.handleMessage);
  return (initiator: a, acceptor: b);
}

Future<Uint8List> collect(Stream<Uint8List> stream) async {
  final builder = BytesBuilder(copy: true);
  await for (final chunk in stream) {
    builder.add(chunk);
  }
  return builder.toBytes();
}

void main() {
  test('single stream round trip with half-close in both directions', () async {
    final echoed = Completer<Uint8List>();
    final pair = connectedPair(
      onStream: (stream) async {
        // Acceptor echoes everything back, then half-closes.
        final received = await collect(stream.incoming);
        stream.add(received);
        stream.finish();
        echoed.complete(received);
      },
    );

    final stream = pair.initiator.openStream();
    stream.add([1, 2, 3]);
    stream.add([4, 5]);
    stream.finish();

    final reply = await collect(stream.incoming);
    expect(reply, [1, 2, 3, 4, 5]);
    expect(await echoed.future, [1, 2, 3, 4, 5]);
    await stream.done;
    // Both sides fully closed -> stream table empty.
    expect(pair.initiator.activeStreamCount, 0);
    expect(pair.acceptor.activeStreamCount, 0);
  });

  test('interleaved concurrent streams stay isolated and ordered', () async {
    final pair = connectedPair(
      onStream: (stream) async {
        final received = await collect(stream.incoming);
        stream.add(received);
        stream.finish();
      },
    );

    const streamCount = 10;
    final streams = List.generate(
      streamCount,
      (_) => pair.initiator.openStream(),
    );
    final payloads = List.generate(
      streamCount,
      (s) => Uint8List.fromList(
        List.generate(20_000 + s * 137, (i) => (i * (s + 1)) % 256),
      ),
    );

    // Interleave writes across all streams in small slices.
    const slice = 1024;
    var offset = 0;
    var anyRemaining = true;
    while (anyRemaining) {
      anyRemaining = false;
      for (var s = 0; s < streamCount; s++) {
        if (offset < payloads[s].length) {
          final end = (offset + slice > payloads[s].length)
              ? payloads[s].length
              : offset + slice;
          streams[s].add(payloads[s].sublist(offset, end));
          if (end < payloads[s].length) anyRemaining = true;
        }
      }
      offset += slice;
    }
    for (final s in streams) {
      s.finish();
    }

    final replies = await Future.wait(streams.map((s) => collect(s.incoming)));
    for (var s = 0; s < streamCount; s++) {
      expect(replies[s], payloads[s], reason: 'stream $s corrupted');
    }
  });

  test(
    'writes larger than the frame cap are chunked and reassembled in order',
    () async {
      // Backpressure-basics: a 5 MiB single add() must arrive intact and
      // ordered even though it crosses the 1 MiB frame cap.
      final pair = connectedPair(
        onStream: (stream) async {
          final received = await collect(stream.incoming);
          stream.add([received.length & 0xff]);
          stream.finish();
        },
      );

      final big = Uint8List.fromList(
        List.generate(5 * 1024 * 1024 + 17, (i) => (i * 31) % 256),
      );
      final receivedOnAcceptor = Completer<Uint8List>();
      final pair2 = connectedPair(
        onStream: (stream) async {
          receivedOnAcceptor.complete(await collect(stream.incoming));
        },
      );

      final stream = pair2.initiator.openStream();
      stream.add(big);
      stream.finish();
      expect(await receivedOnAcceptor.future, big);

      // Keep the analyzer honest about the unused first pair.
      expect(pair.initiator.isClosed, isFalse);
    },
  );

  test('half-close lets the peer keep sending after local finish', () async {
    final pair = connectedPair(
      onStream: (stream) async {
        // Wait for the initiator's finish FIRST, then respond.
        await collect(stream.incoming);
        stream.add([9, 9, 9]);
        stream.finish();
      },
    );

    final stream = pair.initiator.openStream();
    stream.finish(); // immediately half-close, no request body
    expect(await collect(stream.incoming), [9, 9, 9]);
    await stream.done;
  });

  test('add() after finish() throws', () async {
    final pair = connectedPair(onStream: (_) {});
    final stream = pair.initiator.openStream();
    stream.finish();
    expect(() => stream.add([1]), throwsStateError);
  });

  test('reset surfaces as MuxStreamResetException on the peer', () async {
    final peerError = Completer<Object>();
    final pair = connectedPair(
      onStream: (stream) {
        stream.incoming.listen(
          (_) {},
          onError: peerError.complete,
          onDone: () {},
        );
      },
    );

    final stream = pair.initiator.openStream();
    stream.add([1]);
    stream.reset('operator aborted');

    final error = await peerError.future;
    expect(error, isA<MuxStreamResetException>());
    expect('$error', contains('operator aborted'));
    await stream.done;
  });

  test('acceptor without onStream refuses inbound opens with reset', () async {
    final aToB = StreamController<Uint8List>();
    final bToA = StreamController<Uint8List>();
    final a = MuxSession(send: aToB.add);
    final b = MuxSession(send: bToA.add); // no onStream
    aToB.stream.listen(b.handleMessage);
    bToA.stream.listen(a.handleMessage);

    final stream = a.openStream();
    final error = Completer<Object>();
    stream.incoming.listen((_) {}, onError: error.complete, onDone: () {});
    expect(await error.future, isA<MuxStreamResetException>());
  });

  test('control messages round trip', () async {
    final received = Completer<Map<String, dynamic>>();
    final pair = connectedPair(onAcceptorControl: received.complete);
    pair.initiator.sendControl({'op': 'hello', 'n': 3});
    expect(await received.future, {'op': 'hello', 'n': 3});
  });

  test('closeAll aborts every open stream with an error', () async {
    final pair = connectedPair(onStream: (_) {});
    final s1 = pair.initiator.openStream();
    final s2 = pair.initiator.openStream();
    final errors = <Object>[];
    s1.incoming.listen((_) {}, onError: errors.add, onDone: () {});
    s2.incoming.listen((_) {}, onError: errors.add, onDone: () {});

    pair.initiator.closeAll('transport died');
    await Future.wait([s1.done, s2.done]);
    expect(errors, hasLength(2));
    expect(pair.initiator.isClosed, isTrue);
    expect(() => pair.initiator.openStream(), throwsStateError);
  });

  test('data for an unknown stream is ignored (races with reset)', () {
    final session = MuxSession(send: (_) {});
    final frame = MuxFrame(99, MuxFrameType.data, Uint8List.fromList([1]));
    expect(() => session.handleMessage(frame.encode()), returnsNormally);
  });

  test('malformed control payload is a protocol error', () {
    final session = MuxSession(send: (_) {});
    final frame = MuxFrame(
      0,
      MuxFrameType.control,
      Uint8List.fromList('[1,2,3]'.codeUnits),
    );
    expect(
      () => session.handleMessage(frame.encode()),
      throwsA(isA<MuxProtocolException>()),
    );
  });

  test('open on the control stream id is a protocol error', () {
    final session = MuxSession(send: (_) {}, onStream: (_) {});
    expect(
      () => session.handleMessage(MuxFrame(0, MuxFrameType.open).encode()),
      throwsA(isA<MuxProtocolException>()),
    );
  });
}
