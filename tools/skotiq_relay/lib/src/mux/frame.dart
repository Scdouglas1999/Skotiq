// Skotiq relay mux protocol — frame layer.
//
// One appliance keeps ONE outbound WebSocket to the relay; everything the
// phone does (REST calls, the event WebSocket, JPEG live view) is carried as
// independent logical streams multiplexed over that socket. The framing is a
// deliberately tiny length-prefixed binary format:
//
//   offset  size  field
//   ------  ----  -----------------------------------------------------
//   0       4     streamId   (uint32, big-endian; 0 = session control)
//   4       1     type       (see [MuxFrameType])
//   5       4     length     (uint32, big-endian; payload byte count)
//   9       n     payload
//
// Over WebSocket each binary message carries EXACTLY one frame (the length
// field is validated against the message size — a mismatch is a protocol
// error, not a streaming boundary). [MuxFrameReader] additionally supports
// parsing frames out of an arbitrary byte stream so the codec is reusable
// over raw TCP and easy to fuzz in tests.

import 'dart:typed_data';

/// Frame types. Kept as plain ints on the wire; unknown types are a protocol
/// error (fail loudly — a version mismatch must not be silently ignored).
enum MuxFrameType {
  /// Session-level JSON control message. Only valid on streamId 0.
  /// Used for registration/auth between appliance↔relay and the
  /// connected/error handshake between client↔relay. Control frames are
  /// hop-local: the relay never forwards them between the two legs.
  control(0),

  /// Open a new logical stream (sent by the stream initiator — always the
  /// phone side in v1). Payload is reserved (empty today).
  open(1),

  /// Stream payload bytes.
  data(2),

  /// Half-close: the sender will emit no more data on this stream, but can
  /// still receive. Mirrors TCP FIN so HTTP request/response and WebSocket
  /// close handshakes proxy faithfully.
  finish(3),

  /// Abort the stream in both directions. Optional UTF-8 reason payload.
  reset(4);

  const MuxFrameType(this.wireValue);
  final int wireValue;

  static MuxFrameType fromWire(int value) {
    for (final t in MuxFrameType.values) {
      if (t.wireValue == value) return t;
    }
    throw MuxProtocolException('Unknown mux frame type: $value');
  }
}

/// Header size in bytes: 4 (streamId) + 1 (type) + 4 (length).
const int kMuxHeaderLength = 9;

/// Hard cap on a single frame's payload. Larger writes are chunked by the
/// session layer; a peer announcing a larger frame is a protocol error
/// (defends the relay against memory-exhaustion from one bad appliance).
const int kMuxMaxPayloadLength = 1 << 20; // 1 MiB

/// The reserved session-control stream id.
const int kMuxControlStreamId = 0;

/// Thrown on any wire-format violation. The connection carrying the bad
/// frame must be torn down — frame boundaries can no longer be trusted.
class MuxProtocolException implements Exception {
  final String message;
  const MuxProtocolException(this.message);

  @override
  String toString() => 'MuxProtocolException: $message';
}

/// A single decoded frame.
class MuxFrame {
  final int streamId;
  final MuxFrameType type;
  final Uint8List payload;

  MuxFrame(this.streamId, this.type, [Uint8List? payload])
    : payload = payload ?? Uint8List(0) {
    if (streamId < 0 || streamId > 0xFFFFFFFF) {
      throw MuxProtocolException('streamId out of uint32 range: $streamId');
    }
    if (this.payload.length > kMuxMaxPayloadLength) {
      throw MuxProtocolException(
        'payload ${this.payload.length} exceeds $kMuxMaxPayloadLength',
      );
    }
  }

  /// Serialise to header + payload.
  Uint8List encode() {
    final out = Uint8List(kMuxHeaderLength + payload.length);
    final view = ByteData.view(out.buffer);
    view.setUint32(0, streamId);
    out[4] = type.wireValue;
    view.setUint32(5, payload.length);
    out.setRange(kMuxHeaderLength, out.length, payload);
    return out;
  }

  /// Decode a buffer that must contain EXACTLY one frame (the WebSocket
  /// message case). Throws [MuxProtocolException] on any mismatch.
  static MuxFrame decodeExact(Uint8List bytes) {
    if (bytes.length < kMuxHeaderLength) {
      throw MuxProtocolException(
        'frame too short: ${bytes.length} < $kMuxHeaderLength',
      );
    }
    final view = ByteData.sublistView(bytes);
    final streamId = view.getUint32(0);
    final type = MuxFrameType.fromWire(bytes[4]);
    final length = view.getUint32(5);
    if (length > kMuxMaxPayloadLength) {
      throw MuxProtocolException(
        'declared payload $length exceeds $kMuxMaxPayloadLength',
      );
    }
    if (bytes.length != kMuxHeaderLength + length) {
      throw MuxProtocolException(
        'frame length mismatch: declared $length, got '
        '${bytes.length - kMuxHeaderLength} payload bytes',
      );
    }
    return MuxFrame(
      streamId,
      type,
      Uint8List.sublistView(bytes, kMuxHeaderLength),
    );
  }

  @override
  String toString() =>
      'MuxFrame(stream=$streamId, ${type.name}, ${payload.length}B)';
}

/// Incremental frame parser for byte-stream transports (and tests that feed
/// deliberately misaligned chunks). Call [add] with arbitrary chunks; every
/// completed frame is handed to [onFrame] in order.
class MuxFrameReader {
  final void Function(MuxFrame frame) onFrame;
  final BytesBuilder _buffer = BytesBuilder(copy: true);

  MuxFrameReader(this.onFrame);

  void add(List<int> chunk) {
    _buffer.add(chunk);
    while (true) {
      final bytes = _buffer.toBytes();
      if (bytes.length < kMuxHeaderLength) return;
      final view = ByteData.sublistView(bytes);
      final length = view.getUint32(5);
      if (length > kMuxMaxPayloadLength) {
        throw MuxProtocolException(
          'declared payload $length exceeds $kMuxMaxPayloadLength',
        );
      }
      final total = kMuxHeaderLength + length;
      if (bytes.length < total) return;
      onFrame(MuxFrame.decodeExact(Uint8List.sublistView(bytes, 0, total)));
      _buffer.clear();
      if (bytes.length > total) {
        _buffer.add(Uint8List.sublistView(bytes, total));
      }
    }
  }
}
