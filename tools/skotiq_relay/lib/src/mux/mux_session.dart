// Skotiq relay mux protocol — session/stream layer.
//
// A [MuxSession] turns one reliable, ordered, message-oriented transport
// (in practice: a WebSocket carrying one [MuxFrame] per binary message)
// into many independent logical byte streams with TCP-like half-close
// semantics. Both tunnel endpoints use it:
//
//   * the appliance ([RelayUplink]) is the ACCEPTOR — every `open` frame
//     becomes a fresh TCP connection to the local headless HTTP server;
//   * the phone ([RelayTunnelClient]) is the INITIATOR — every TCP accept
//     on its loopback listener becomes an `open` frame.
//
// The relay in the middle does NOT run a MuxSession; it forwards raw frames
// with stream-id rewriting only.
//
// Flow control (honest v1 limitation): there is no per-stream window. The
// session relies on the transport's own backpressure (TCP under the
// WebSocket) plus bounded frame size. A single bulk stream can therefore
// add latency to its siblings on the same uplink. Acceptable for the
// JSON/JPEG-sized traffic the headless API carries; revisit with
// credit-based windowing if FITS downloads over relay become a use case.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'frame.dart';

/// Surfaced on [MuxStream.incoming] when the peer aborts the stream.
class MuxStreamResetException implements Exception {
  final String reason;
  const MuxStreamResetException(this.reason);

  @override
  String toString() => 'MuxStreamResetException: $reason';
}

/// One logical byte stream inside a [MuxSession].
class MuxStream {
  final int id;
  final MuxSession _session;

  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  final Completer<void> _done = Completer<void>();

  bool _localFinished = false;
  bool _remoteFinished = false;
  bool _reset = false;

  MuxStream._(this.id, this._session);

  /// Bytes from the peer. Single-subscription. Closes after the peer's
  /// `finish`; errors with [MuxStreamResetException] on a peer `reset`.
  Stream<Uint8List> get incoming => _incoming.stream;

  /// Completes when the stream is fully closed in both directions (or
  /// reset). Never completes with an error.
  Future<void> get done => _done.future;

  bool get isReset => _reset;

  /// Send payload bytes to the peer. Oversized writes are chunked to the
  /// protocol's frame cap.
  void add(List<int> bytes) {
    if (_localFinished || _reset) {
      throw StateError('MuxStream $id: add() after finish()/reset');
    }
    var offset = 0;
    while (offset < bytes.length) {
      final end = (offset + kMuxMaxPayloadLength <= bytes.length)
          ? offset + kMuxMaxPayloadLength
          : bytes.length;
      final chunk = bytes is Uint8List
          ? Uint8List.sublistView(bytes, offset, end)
          : Uint8List.fromList(bytes.sublist(offset, end));
      _session._sendFrame(MuxFrame(id, MuxFrameType.data, chunk));
      offset = end;
    }
  }

  /// Half-close: no more local writes; the peer may keep sending.
  void finish() {
    if (_localFinished || _reset) return;
    _localFinished = true;
    _session._sendFrame(MuxFrame(id, MuxFrameType.finish));
    _maybeComplete();
  }

  /// Abort both directions.
  void reset([String reason = '']) {
    if (_reset) return;
    _reset = true;
    _session._sendFrame(
      MuxFrame(id, MuxFrameType.reset, Uint8List.fromList(utf8.encode(reason))),
    );
    _closeIncoming(error: null);
    _maybeComplete(force: true);
    _session._forget(id);
  }

  // -- driven by the session --------------------------------------------

  void _handleData(Uint8List payload) {
    if (_incoming.isClosed) return;
    _incoming.add(payload);
  }

  void _handleFinish() {
    if (_remoteFinished || _reset) return;
    _remoteFinished = true;
    _closeIncoming(error: null);
    _maybeComplete();
  }

  void _handleReset(String reason) {
    if (_reset) return;
    _reset = true;
    _closeIncoming(
      error: MuxStreamResetException(reason.isEmpty ? 'reset by peer' : reason),
    );
    _maybeComplete(force: true);
    _session._forget(id);
  }

  /// Transport died underneath us — tear down locally without sending.
  void _abortLocal(String reason) {
    if (_reset) return;
    _reset = true;
    _closeIncoming(error: MuxStreamResetException(reason));
    _maybeComplete(force: true);
  }

  void _closeIncoming({required Object? error}) {
    if (_incoming.isClosed) return;
    if (error != null) {
      _incoming.addError(error);
    }
    _incoming.close();
  }

  void _maybeComplete({bool force = false}) {
    if (_done.isCompleted) return;
    if (force || (_localFinished && _remoteFinished)) {
      _done.complete();
      if (_localFinished && _remoteFinished) {
        _session._forget(id);
      }
    }
  }
}

/// Multiplexes logical [MuxStream]s over a single message transport.
class MuxSession {
  /// Sends one encoded frame over the transport (e.g. `webSocket.add`).
  /// Exceptions are swallowed after the session is closed.
  final void Function(Uint8List frameBytes) _send;

  /// Called for every peer-initiated stream (acceptor role). When null,
  /// peer-initiated streams are refused with a `reset`.
  final void Function(MuxStream stream)? onStream;

  /// Called for every stream-0 control message (already JSON-decoded).
  final void Function(Map<String, dynamic> message)? onControl;

  final Map<int, MuxStream> _streams = {};
  int _nextStreamId = 1;
  bool _closed = false;

  MuxSession({
    required void Function(Uint8List frameBytes) send,
    this.onStream,
    this.onControl,
  }) : _send = send;

  /// Streams currently known to this session (open in at least one
  /// direction).
  int get activeStreamCount => _streams.length;

  bool get isClosed => _closed;

  /// Initiator role: open a new logical stream toward the peer.
  MuxStream openStream() {
    if (_closed) {
      throw StateError('MuxSession is closed');
    }
    final id = _nextStreamId++;
    final stream = MuxStream._(id, this);
    _streams[id] = stream;
    _sendFrame(MuxFrame(id, MuxFrameType.open));
    return stream;
  }

  /// Send a stream-0 JSON control message.
  void sendControl(Map<String, dynamic> message) {
    _sendFrame(
      MuxFrame(
        kMuxControlStreamId,
        MuxFrameType.control,
        Uint8List.fromList(utf8.encode(jsonEncode(message))),
      ),
    );
  }

  /// Feed one inbound transport message (exactly one frame).
  ///
  /// Throws [MuxProtocolException] on malformed input — the caller must
  /// treat that as fatal for the whole transport.
  void handleMessage(Uint8List bytes) {
    final frame = MuxFrame.decodeExact(bytes);
    switch (frame.type) {
      case MuxFrameType.control:
        if (frame.streamId != kMuxControlStreamId) {
          throw const MuxProtocolException('control frame on non-zero stream');
        }
        final decoded = jsonDecode(utf8.decode(frame.payload));
        if (decoded is! Map<String, dynamic>) {
          throw const MuxProtocolException('control payload is not an object');
        }
        onControl?.call(decoded);
      case MuxFrameType.open:
        if (frame.streamId == kMuxControlStreamId) {
          throw const MuxProtocolException('open frame on control stream');
        }
        if (_streams.containsKey(frame.streamId)) {
          throw MuxProtocolException(
            'open for already-active stream ${frame.streamId}',
          );
        }
        final stream = MuxStream._(frame.streamId, this);
        if (onStream == null) {
          // Initiator-only endpoint refusing an unexpected inbound stream.
          stream._reset = true;
          _sendFrame(
            MuxFrame(
              frame.streamId,
              MuxFrameType.reset,
              Uint8List.fromList(utf8.encode('not accepting streams')),
            ),
          );
          return;
        }
        _streams[frame.streamId] = stream;
        onStream!(stream);
      case MuxFrameType.data:
        // Unknown stream: tolerated (frames legitimately race a reset we
        // already sent), everything else routed to the stream.
        _streams[frame.streamId]?._handleData(frame.payload);
      case MuxFrameType.finish:
        _streams[frame.streamId]?._handleFinish();
      case MuxFrameType.reset:
        _streams[frame.streamId]?._handleReset(utf8.decode(frame.payload));
    }
  }

  /// Tear everything down because the transport died (or is being closed
  /// deliberately). Streams complete with a reset error; nothing further
  /// is sent.
  void closeAll(String reason) {
    if (_closed) return;
    _closed = true;
    final streams = List<MuxStream>.of(_streams.values);
    _streams.clear();
    for (final s in streams) {
      s._abortLocal(reason);
    }
  }

  void _forget(int id) {
    _streams.remove(id);
  }

  void _sendFrame(MuxFrame frame) {
    if (_closed) return;
    try {
      _send(frame.encode());
    } catch (_) {
      // Transport already failed; the owner's done/onDone path will call
      // closeAll. Swallowing here keeps stream teardown re-entrant safe.
    }
  }
}
