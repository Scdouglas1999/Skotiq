import 'dart:async';
import 'dart:typed_data';

/// One subscription shared by authentication and update transfer. TCP can
/// coalesce both protocol frames into one chunk, so leftover bytes must remain
/// available when the authentication phase hands off to the manifest phase.
class LanPushFrameReader {
  final StreamIterator<Uint8List> _chunks;
  final Duration _idleTimeout;
  List<int> _buffer = const [];
  var _cancelled = false;

  LanPushFrameReader(Stream<Uint8List> stream, {required Duration idleTimeout})
    : _chunks = StreamIterator<Uint8List>(stream),
      _idleTimeout = idleTimeout;

  /// The length and payload share one deadline until the peer authenticates.
  Future<Uint8List?> readAuthFrame(Duration timeout) async {
    final deadline = Timer(timeout, () => unawaited(cancel()));
    try {
      final header = await readExactly(4, idleTimeout: timeout);
      if (header == null) return null;
      final length = ByteData.sublistView(header).getInt32(0, Endian.big);
      if (length <= 0 || length > 4096) {
        throw const FormatException('Invalid authentication frame length');
      }
      return await readExactly(length, idleTimeout: timeout);
    } finally {
      deadline.cancel();
    }
  }

  Future<Uint8List?> readExactly(int length, {Duration? idleTimeout}) async {
    final limit = idleTimeout ?? _idleTimeout;
    while (_buffer.length < length) {
      if (!await _moveNext(limit)) return null;
      _buffer = [..._buffer, ..._chunks.current];
    }
    final result = Uint8List.fromList(_buffer.sublist(0, length));
    _buffer = _buffer.sublist(length);
    return result;
  }

  Future<Uint8List?> readAtMost(int maxLength, {Duration? idleTimeout}) async {
    if (_buffer.isEmpty) {
      if (!await _moveNext(idleTimeout ?? _idleTimeout)) return null;
      _buffer = _chunks.current;
    }
    final length = _buffer.length < maxLength ? _buffer.length : maxLength;
    final result = Uint8List.fromList(_buffer.sublist(0, length));
    _buffer = _buffer.sublist(length);
    return result;
  }

  /// Await the next TCP chunk, or abort the subscription if nothing arrives.
  ///
  /// Cancelling the iterator completes the pending [StreamIterator.moveNext],
  /// so the read that the receiver is awaiting is the one that fails.
  /// The transfer then cannot continue into extract or `ready.json`.
  Future<bool> _moveNext(Duration limit) async {
    if (_cancelled) {
      throw TimeoutException(
        'LAN push stalled: no data for ${limit.inSeconds}s',
      );
    }
    var timedOut = false;
    final timer = Timer(limit, () {
      timedOut = true;
      unawaited(cancel());
    });
    try {
      final moved = await _chunks.moveNext();
      if (timedOut || _cancelled) {
        throw TimeoutException(
          'LAN push stalled: no data for ${limit.inSeconds}s',
        );
      }
      return moved;
    } catch (e) {
      if (timedOut || _cancelled || e is TimeoutException) {
        throw TimeoutException(
          'LAN push stalled: no data for ${limit.inSeconds}s',
        );
      }
      rethrow;
    } finally {
      timer.cancel();
    }
  }

  Future<void> cancel() {
    if (_cancelled) return Future<void>.value();
    _cancelled = true;
    return _chunks.cancel();
  }
}
