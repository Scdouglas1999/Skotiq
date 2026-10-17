import 'dart:typed_data';

import 'package:skotiq_relay/skotiq_relay.dart';
import 'package:test/test.dart';

void main() {
  group('MuxFrame codec', () {
    test('round-trips every frame type', () {
      for (final type in MuxFrameType.values) {
        final payload = Uint8List.fromList(List.generate(257, (i) => i % 256));
        final frame = MuxFrame(42, type, payload);
        final decoded = MuxFrame.decodeExact(frame.encode());
        expect(decoded.streamId, 42);
        expect(decoded.type, type);
        expect(decoded.payload, payload);
      }
    });

    test('round-trips an empty payload', () {
      final decoded = MuxFrame.decodeExact(
        MuxFrame(7, MuxFrameType.finish).encode(),
      );
      expect(decoded.streamId, 7);
      expect(decoded.type, MuxFrameType.finish);
      expect(decoded.payload, isEmpty);
    });

    test('round-trips the max uint32 stream id', () {
      final decoded = MuxFrame.decodeExact(
        MuxFrame(0xFFFFFFFF, MuxFrameType.data).encode(),
      );
      expect(decoded.streamId, 0xFFFFFFFF);
    });

    test('rejects truncated buffers', () {
      expect(
        () => MuxFrame.decodeExact(Uint8List(4)),
        throwsA(isA<MuxProtocolException>()),
      );
    });

    test('rejects declared-length mismatch', () {
      final bytes = MuxFrame(1, MuxFrameType.data, Uint8List(10)).encode();
      expect(
        () => MuxFrame.decodeExact(
          Uint8List.sublistView(bytes, 0, bytes.length - 1),
        ),
        throwsA(isA<MuxProtocolException>()),
      );
    });

    test('rejects unknown frame types', () {
      final bytes = MuxFrame(1, MuxFrameType.data).encode();
      bytes[4] = 99;
      expect(
        () => MuxFrame.decodeExact(bytes),
        throwsA(isA<MuxProtocolException>()),
      );
    });

    test('rejects oversize declared payloads', () {
      final bytes = MuxFrame(1, MuxFrameType.data).encode();
      ByteData.view(bytes.buffer).setUint32(5, kMuxMaxPayloadLength + 1);
      expect(
        () => MuxFrame.decodeExact(bytes),
        throwsA(isA<MuxProtocolException>()),
      );
    });

    test('constructor rejects oversized payloads', () {
      expect(
        () =>
            MuxFrame(1, MuxFrameType.data, Uint8List(kMuxMaxPayloadLength + 1)),
        throwsA(isA<MuxProtocolException>()),
      );
    });
  });

  group('MuxFrameReader', () {
    test('reassembles frames from arbitrarily misaligned chunks', () {
      final frames = <MuxFrame>[
        MuxFrame(1, MuxFrameType.open),
        MuxFrame(
          1,
          MuxFrameType.data,
          Uint8List.fromList(List.generate(1000, (i) => i % 251)),
        ),
        MuxFrame(2, MuxFrameType.open),
        MuxFrame(1, MuxFrameType.finish),
        MuxFrame(2, MuxFrameType.reset, Uint8List.fromList('bye'.codeUnits)),
      ];
      final wire = BytesBuilder();
      for (final f in frames) {
        wire.add(f.encode());
      }
      final bytes = wire.toBytes();

      // Feed in awkward chunk sizes (1, 2, 3, 7, 64, rest...).
      for (final chunkSize in [1, 3, 7, 64, 1024, bytes.length]) {
        final seen = <MuxFrame>[];
        final reader = MuxFrameReader(seen.add);
        var offset = 0;
        while (offset < bytes.length) {
          final end = (offset + chunkSize > bytes.length)
              ? bytes.length
              : offset + chunkSize;
          reader.add(bytes.sublist(offset, end));
          offset = end;
        }
        expect(seen.length, frames.length, reason: 'chunkSize=$chunkSize');
        for (var i = 0; i < frames.length; i++) {
          expect(seen[i].streamId, frames[i].streamId);
          expect(seen[i].type, frames[i].type);
          expect(seen[i].payload, frames[i].payload);
        }
      }
    });
  });
}
