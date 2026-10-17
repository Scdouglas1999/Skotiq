// Push-based live-view streaming over WebSocket.
//
// The legacy `GET /api/camera/live-view/frame` endpoint forces the phone
// to poll at ~2 Hz, which (a) burns LTE bandwidth even when the camera
// has nothing new to emit, (b) adds a full HTTP round-trip per frame,
// and (c) gives every poll its own JPEG-encode pass. This handler
// flips that model: the server only encodes frames while at least one
// client is subscribed, and pushes each frame out as a binary WS message
// preceded by a small JSON envelope describing the frame.
//
// Wire protocol (text JSON unless noted):
//
//   Client → Server:
//     1. `{"type": "subscribe", "deviceId": "ascom:Camera.QHY",
//          "maxDim": 1024, "maxFps": 2, "jpegQuality": 70,
//          "region": {"x": 0, "y": 0, "w": 4000, "h": 4000}?}`
//        Begins (or replaces) this client's subscription. `maxDim` is
//        the longest-edge target after downscaling; the server preserves
//        aspect ratio. `maxFps` clamps the encode cadence (we never run
//        faster than the most demanding subscriber asks for). `region`
//        is in MASTER (pre-downscale) coordinates so a phone can zoom
//        without first downloading the full frame; omit for full sensor.
//        `jpegQuality` defaults to 70 — a sweet spot for cellular at
//        1024 px.
//
//     2. `{"type": "unsubscribe"}`
//        Stops streaming. The socket itself stays open so the same
//        client can resubscribe with different parameters without a
//        new upgrade.
//
//     3. `{"type": "ping"}` → server replies with
//        `{"type": "pong", "timestamp": "<iso8601>"}`. Useful on cell
//        gateways with aggressive idle timeouts.
//
//   Server → Client:
//     a. `{"type": "ready", "deviceId": "...", "maxDim": 1024,
//          "maxFps": 2, ...}` — emitted once per successful subscribe.
//     b. `{"type": "frame_meta", "deviceId": "...", "width": 1024,
//          "height": 768, "frameNumber": N,
//          "serverTimestamp": "<iso8601>"}` followed immediately by a
//        single binary WS message carrying the JPEG bytes. Paired
//        delivery means the receiver doesn't have to base64-decode or
//        guess which subscription a binary frame belongs to.
//     c. `{"type": "error", "code": "...", "message": "..."}` for
//        non-fatal errors (e.g. camera disconnected). The socket stays
//        open; the client may resubscribe.
//     d. `{"type": "stopped", "reason": "..."}` on the server-initiated
//        teardown. The socket then closes.
//
// Why binary frames rather than base64-in-JSON: a 1024 px JPEG at q=70
// is ~80 KB. JSON-wrapping it adds ~33% overhead AND forces a
// string<->bytes conversion every frame. Binary WS frames go straight
// into `Image.memory` on the client.
//
// Throttle / no-subscriber behaviour: the [LiveViewStreamHub] is the
// single source of truth for whether ANY subscriber is currently
// connected. While the subscriber set is empty, no encode work is done
// and no calls into the camera backend's preview API are made. The
// moment the first subscriber arrives, the producer loop starts; the
// moment the last subscriber leaves, the loop is cancelled.
//
// Multi-subscriber strategy: a single master frame is fetched from the
// backend at the cadence of the MOST demanding active subscriber (the
// max of all `maxFps` values). For each subscriber whose target
// (maxDim, region, jpegQuality) tuple is unique, we run one encode pass
// against the master frame. Subscribers with identical tuples share the
// encoded bytes, so two phones asking for `(1024, fullFrame, 70)` only
// pay one JPEG-encode cost. We chose per-subscriber encoding (rather
// than encoding once at the most-demanding tuple and downscaling the
// JPEG client-side) because (a) re-decoding a JPEG on the phone to
// downscale would waste CPU we just saved on the wire, and (b) the
// server's `image` package can resize the master bitmap directly which
// is one decode + N resizes, not N decodes.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Routing/diagnostic owner for the `/ws/live-view` endpoint. Stateless
/// on its own — all per-subscriber state lives inside the [LiveViewStreamHub]
/// instance that is created once per server lifetime.
class LiveViewStreamHandlers {
  final ProviderContainer container;
  final LiveViewStreamHub hub;

  LiveViewStreamHandlers({required this.container, required this.hub});

  /// WebSocket upgrade callback wired by the server router. Each accepted
  /// socket is registered with the hub; the hub owns the rest of the
  /// lifecycle.
  void handleSocket(WebSocketChannel socket) {
    hub.attach(socket);
  }
}

/// Per-subscriber stream configuration. Captures the most recent
/// `subscribe` message; mutated in place if the client resubscribes on
/// the same socket.
class _LiveViewSubscription {
  String deviceId;
  int maxDim;
  double maxFps;
  int jpegQuality;
  LiveViewRegion? region;

  /// Monotonically increasing frame counter scoped to this subscription.
  /// Resets on resubscribe. Used by the client to detect drops.
  int frameNumber = 0;

  /// Wall-clock time of the last frame we sent to THIS subscriber. The
  /// producer loop respects this so a 1-Hz subscriber on the same hub as
  /// a 4-Hz subscriber doesn't get spammed with 4 frames a second.
  DateTime lastSentAt = DateTime.fromMillisecondsSinceEpoch(0);

  _LiveViewSubscription({
    required this.deviceId,
    required this.maxDim,
    required this.maxFps,
    required this.jpegQuality,
    this.region,
  });

  Duration get period {
    if (maxFps <= 0) {
      return const Duration(seconds: 1);
    }
    final ms = (1000.0 / maxFps).round();
    return Duration(milliseconds: ms < 16 ? 16 : ms);
  }

  bool dueNow(DateTime now) {
    return now.difference(lastSentAt) >= period;
  }
}

/// Owner of the per-server live-view producer loop and the registry of
/// currently subscribed sockets. The hub is a long-lived object created
/// once at server start; it survives socket churn so we never lose the
/// "is anyone listening?" signal between client reconnects.
class LiveViewStreamHub {
  final ProviderContainer container;
  final LoggingService _logger;

  /// Floor for the producer-loop tick. Even if no subscriber asks for
  /// faster than 0.5 fps we still poll every 2 s so a newly-arrived
  /// subscriber gets its first frame within a couple of hundred ms of
  /// connecting.
  static const Duration _producerMinTick = Duration(milliseconds: 250);

  /// Hard cap on the encoded JPEG long edge. A phone display rarely
  /// needs more than 2k on the long edge; setting this prevents a
  /// pathological client from pinning the server CPU by asking for
  /// `maxDim: 99999`.
  static const int _maxAllowedMaxDim = 4096;

  /// Hard cap on encode cadence. Anything faster than 10 fps is wasted
  /// on a JPEG live-view; the camera previews update at single-digit
  /// Hz at best.
  static const double _maxAllowedFps = 10.0;

  /// Default JPEG quality when the client omits the field. 70 is the
  /// cellular-friendly sweet spot used elsewhere in the codebase.
  static const int _defaultJpegQuality = 70;

  /// Default `maxDim` when the client omits it. Matches the documented
  /// default of `/api/run-watch/frame-thumbnail` so phone clients can
  /// reuse the same render budget.
  static const int _defaultMaxDim = 1024;

  /// Default `maxFps` when the client omits it. 2 Hz mirrors the
  /// recommended polling cadence on the legacy pull endpoint.
  static const double _defaultMaxFps = 2.0;

  // Identity-keyed maps (Object) so the same hub can be driven by
  // [WebSocketChannel]s in production AND in-memory test channels.
  final Map<Object, _LiveViewSubscription?> _subs = {};
  final Map<Object, StreamSubscription<dynamic>> _inboundSubs = {};
  final Map<Object, _SinkAdapter> _sinkAdapters = {};
  Timer? _producerTimer;
  bool _producerRunning = false;
  bool _disposed = false;

  /// Test seam: injected JPEG producer. When non-null, [_fetchMasterFrame]
  /// will call this instead of the live backend. Lets unit tests drive
  /// the hub deterministically without spinning up a Rust FFI camera.
  Future<Uint8List> Function(String deviceId)? testFrameProducer;

  LiveViewStreamHub({required this.container})
    : _logger = container.read(loggingServiceProvider);

  /// Number of currently-subscribed sockets that have an active
  /// subscription (i.e. have sent at least one `subscribe` message and
  /// not subsequently unsubscribed). Exposed for tests + diagnostics.
  int get activeSubscriberCount => _subs.values.where((s) => s != null).length;

  /// Number of attached sockets (subscribed or not).
  int get attachedSocketCount => _subs.length;

  /// Attach a fresh WebSocket. The hub takes over its message loop and
  /// teardown. Safe to call from the WS upgrade callback.
  void attach(WebSocketChannel socket) {
    attachRaw(
      socket: socket,
      stream: socket.stream,
      sinkAdd: socket.sink.add,
      sinkClose: () => socket.sink.close(),
    );
  }

  /// Lower-level entry point used by tests that drive the hub with an
  /// in-memory channel pair rather than a real WS upgrade. We avoid
  /// pulling in `shelf_web_socket` test plumbing this way.
  ///
  /// [socket] is the identity used to key the per-subscriber state; it
  /// does not have to be a real [WebSocketChannel] as long as the same
  /// value is used for every outgoing write. [stream] is the incoming
  /// frame stream from the client; [sinkAdd] writes outgoing frames to
  /// the client; [sinkClose] tears the underlying transport down.
  void attachRaw({
    required Object socket,
    required Stream<dynamic> stream,
    required void Function(dynamic) sinkAdd,
    required Future<void> Function() sinkClose,
  }) {
    if (_disposed) {
      // Hub is shutting down; refuse new attachments cleanly rather
      // than registering a socket that will never see a frame.
      unawaited(sinkClose());
      return;
    }
    final adapter = _SinkAdapter(sinkAdd, sinkClose);
    _subs[socket] = null;
    _sinkAdapters[socket] = adapter;
    final inbound = stream.listen(
      (raw) => _onMessage(socket, raw),
      onDone: () => _detach(socket, reason: 'client_closed'),
      onError: (Object e, _) {
        _logger.warning(
          '/ws/live-view socket error: $e',
          source: 'LiveViewStreamHub',
        );
        _detach(socket, reason: 'socket_error');
      },
    );
    _inboundSubs[socket] = inbound;
    _logger.info(
      '/ws/live-view client attached (sockets=${_subs.length})',
      source: 'LiveViewStreamHub',
    );
  }

  /// Shut the hub down. Cancels the producer loop and closes every
  /// attached socket. Safe to call multiple times.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _producerTimer?.cancel();
    _producerTimer = null;
    for (final entry in List.of(_inboundSubs.entries)) {
      await entry.value.cancel();
    }
    _inboundSubs.clear();
    for (final socket in List.of(_subs.keys)) {
      try {
        _writeJson(socket, {'type': 'stopped', 'reason': 'server_shutdown'});
      } on Object catch (e) {
        // Why: socket may already be dead; we're tearing down the stream, so
        // a failed final write has nothing left to surface.
        _logger.debug(
          'Live-view teardown: final stopped-notice write failed: $e',
          source: 'LiveViewStream',
        );
      }
      final adapter = _sinkAdapters[socket];
      if (adapter != null) {
        unawaited(adapter.close());
      }
    }
    _subs.clear();
    _sinkAdapters.clear();
  }

  void _detach(Object socket, {required String reason}) {
    final sub = _subs.remove(socket);
    _inboundSubs.remove(socket)?.cancel();
    _sinkAdapters.remove(socket);
    if (sub != null) {
      _logger.info(
        '/ws/live-view subscription closed for ${sub.deviceId}: $reason '
        '(remaining=$activeSubscriberCount)',
        source: 'LiveViewStreamHub',
      );
    }
    _maybeStopProducer();
  }

  void _onMessage(Object socket, Object? raw) {
    if (raw is! String) {
      // Binary frames from the client are not part of the protocol. Logged at
      // warning rather than dropped silently, so protocol drift is visible
      // instead of showing up as a client that mysteriously receives nothing.
      _logger.warning(
        '/ws/live-view: received non-text frame (${raw.runtimeType}); ignoring',
        source: 'LiveViewStreamHub',
      );
      return;
    }
    final Map<String, Object?> data;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('expected JSON object');
      }
      data = decoded.map((k, v) => MapEntry(k.toString(), v as Object?));
    } catch (e) {
      _writeJson(socket, {
        'type': 'error',
        'code': 'bad_message',
        'message': 'Could not parse message as JSON object: $e',
      });
      return;
    }

    final type = data['type'];
    if (type == 'subscribe') {
      _handleSubscribe(socket, data);
    } else if (type == 'unsubscribe') {
      _handleUnsubscribe(socket);
    } else if (type == 'ping') {
      _writeJson(socket, {
        'type': 'pong',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      });
    } else {
      _writeJson(socket, {
        'type': 'error',
        'code': 'unknown_type',
        'message': 'Unknown message type: $type',
      });
    }
  }

  void _handleSubscribe(Object socket, Map<String, Object?> data) {
    final deviceIdRaw = data['deviceId'];
    if (deviceIdRaw is! String || deviceIdRaw.isEmpty) {
      _writeJson(socket, {
        'type': 'error',
        'code': 'bad_subscribe',
        'message': 'subscribe requires non-empty string `deviceId`',
      });
      return;
    }
    final maxDim = _clampInt(
      raw: data['maxDim'],
      defaultValue: _defaultMaxDim,
      min: 16,
      max: _maxAllowedMaxDim,
    );
    final maxFps = _clampDouble(
      raw: data['maxFps'],
      defaultValue: _defaultMaxFps,
      min: 0.1,
      max: _maxAllowedFps,
    );
    final jpegQuality = _clampInt(
      raw: data['jpegQuality'],
      defaultValue: _defaultJpegQuality,
      min: 1,
      max: 100,
    );
    LiveViewRegion? region;
    final regionRaw = data['region'];
    if (regionRaw is Map) {
      try {
        region = LiveViewRegion.fromJson(
          regionRaw.map((k, v) => MapEntry(k.toString(), v as Object?)),
        );
      } on FormatException catch (e) {
        _writeJson(socket, {
          'type': 'error',
          'code': 'bad_region',
          'message': e.message,
        });
        return;
      }
    }

    _subs[socket] = _LiveViewSubscription(
      deviceId: deviceIdRaw,
      maxDim: maxDim,
      maxFps: maxFps,
      jpegQuality: jpegQuality,
      region: region,
    );
    _writeJson(socket, {
      'type': 'ready',
      'deviceId': deviceIdRaw,
      'maxDim': maxDim,
      'maxFps': maxFps,
      'jpegQuality': jpegQuality,
      if (region != null) 'region': region.toJson(),
    });
    _logger.info(
      '/ws/live-view subscribed: device=$deviceIdRaw maxDim=$maxDim '
      'maxFps=$maxFps quality=$jpegQuality region=${region?.toJson()}',
      source: 'LiveViewStreamHub',
    );
    _ensureProducerRunning();
  }

  void _handleUnsubscribe(Object socket) {
    if (_subs[socket] == null) {
      // Idempotent: an unsubscribe from a socket that never subscribed is
      // a no-op rather than an error.
      _writeJson(socket, {'type': 'stopped', 'reason': 'unsubscribed'});
      return;
    }
    _subs[socket] = null;
    _writeJson(socket, {'type': 'stopped', 'reason': 'unsubscribed'});
    _maybeStopProducer();
  }

  void _ensureProducerRunning() {
    if (_producerTimer != null) return;
    // Producer cadence: tick at the fastest active subscriber's period,
    // floored to [_producerMinTick]. Re-evaluated on every tick to handle
    // dynamic subscribe/unsubscribe.
    _producerTimer = Timer.periodic(_producerMinTick, (_) {
      if (_producerRunning) return; // re-entrancy guard
      _producerRunning = true;
      unawaited(
        _producerTick().whenComplete(() {
          _producerRunning = false;
        }),
      );
    });
    _logger.info('/ws/live-view producer started', source: 'LiveViewStreamHub');
  }

  void _maybeStopProducer() {
    if (activeSubscriberCount == 0 && _producerTimer != null) {
      _producerTimer?.cancel();
      _producerTimer = null;
      _logger.info(
        '/ws/live-view producer idled — no active subscribers',
        source: 'LiveViewStreamHub',
      );
    }
  }

  /// One producer tick. For every (deviceId, master frame) we fetch the
  /// frame ONCE then run per-subscriber resize/encode passes. Subscribers
  /// whose cadence hasn't elapsed since their last frame are skipped.
  Future<void> _producerTick() async {
    if (_disposed) return;
    final now = DateTime.now();

    // Group active subscriptions by deviceId so we fetch the master frame
    // at most once per device per tick.
    final byDevice = <String, List<MapEntry<Object, _LiveViewSubscription>>>{};
    for (final entry in _subs.entries) {
      final sub = entry.value;
      if (sub == null) continue;
      if (!sub.dueNow(now)) continue;
      byDevice
          .putIfAbsent(sub.deviceId, () => [])
          .add(MapEntry(entry.key, sub));
    }
    if (byDevice.isEmpty) return;

    for (final deviceEntry in byDevice.entries) {
      final deviceId = deviceEntry.key;
      final subscribers = deviceEntry.value;

      final Uint8List masterJpeg;
      try {
        masterJpeg = await _fetchMasterFrame(deviceId);
      } catch (e) {
        // Surface the error to every subscriber on this device and
        // proceed — the hub stays up.
        for (final s in subscribers) {
          _writeJson(s.key, {
            'type': 'error',
            'code': 'capture_failed',
            'deviceId': deviceId,
            // Sanitized: the machine-readable `code` conveys the failure; the
            // raw exception is not leaked to live-view subscribers.
            'message': 'Capture failed on the device.',
          });
        }
        continue;
      }
      if (masterJpeg.isEmpty) {
        for (final s in subscribers) {
          _writeJson(s.key, {
            'type': 'error',
            'code': 'live_view_unavailable',
            'deviceId': deviceId,
            'message': 'Camera returned an empty live-view frame.',
          });
        }
        continue;
      }

      // Decode once; reuse the bitmap across subscriber encodes. We swallow
      // a decode failure rather than crashing the loop — the next tick will
      // try again.
      final img.Image? master = img.decodeJpg(masterJpeg);
      if (master == null) {
        _logger.warning(
          '/ws/live-view: master JPEG from $deviceId failed to decode '
          '(${masterJpeg.length} bytes)',
          source: 'LiveViewStreamHub',
        );
        for (final s in subscribers) {
          _writeJson(s.key, {
            'type': 'error',
            'code': 'decode_failed',
            'deviceId': deviceId,
            'message':
                'Server failed to decode the master live-view frame for resize.',
          });
        }
        continue;
      }

      // Cache encoded bytes by (maxDim, region, quality) so duplicate
      // subscribers share the encode cost.
      final cache = <String, Uint8List>{};
      final cacheDims = <String, ({int width, int height})>{};
      for (final s in subscribers) {
        final sub = s.value;
        final cacheKey = _encodeCacheKey(sub);
        Uint8List encoded;
        int outW;
        int outH;
        final cached = cache[cacheKey];
        if (cached != null) {
          encoded = cached;
          final dims = cacheDims[cacheKey]!;
          outW = dims.width;
          outH = dims.height;
        } else {
          final result = _encodeFor(master, sub);
          encoded = result.bytes;
          outW = result.width;
          outH = result.height;
          cache[cacheKey] = encoded;
          cacheDims[cacheKey] = (width: outW, height: outH);
        }

        sub.frameNumber += 1;
        sub.lastSentAt = now;
        _writeJson(s.key, {
          'type': 'frame_meta',
          'deviceId': deviceId,
          'width': outW,
          'height': outH,
          'frameNumber': sub.frameNumber,
          'serverTimestamp': now.toUtc().toIso8601String(),
        });
        _writeBytes(s.key, encoded);
      }
    }
  }

  String _encodeCacheKey(_LiveViewSubscription sub) {
    final r = sub.region;
    final rk = r == null ? '-' : '${r.x},${r.y},${r.width},${r.height}';
    return '${sub.maxDim}|$rk|${sub.jpegQuality}';
  }

  ({Uint8List bytes, int width, int height}) _encodeFor(
    img.Image master,
    _LiveViewSubscription sub,
  ) {
    var bitmap = master;
    final region = sub.region;
    if (region != null) {
      // Clamp the region to the master bounds so a stale region from a
      // smaller-than-expected master doesn't throw inside copyCrop.
      final x = region.x.clamp(0, master.width - 1).toInt();
      final y = region.y.clamp(0, master.height - 1).toInt();
      final w = region.width.clamp(1, master.width - x).toInt();
      final h = region.height.clamp(1, master.height - y).toInt();
      bitmap = img.copyCrop(master, x: x, y: y, width: w, height: h);
    }

    final longEdge = bitmap.width >= bitmap.height
        ? bitmap.width
        : bitmap.height;
    if (sub.maxDim > 0 && longEdge > sub.maxDim) {
      final scale = sub.maxDim / longEdge;
      final newW = (bitmap.width * scale).round().clamp(1, sub.maxDim).toInt();
      final newH = (bitmap.height * scale).round().clamp(1, sub.maxDim).toInt();
      bitmap = img.copyResize(bitmap, width: newW, height: newH);
    }
    final jpeg = Uint8List.fromList(
      img.encodeJpg(bitmap, quality: sub.jpegQuality.clamp(1, 100)),
    );
    return (bytes: jpeg, width: bitmap.width, height: bitmap.height);
  }

  /// Fetch a master live-view JPEG from the backend (or the test seam).
  /// We deliberately do NOT wrap this in a try/catch — the caller in
  /// [_producerTick] surfaces failures to the affected subscribers.
  Future<Uint8List> _fetchMasterFrame(String deviceId) async {
    final injected = testFrameProducer;
    if (injected != null) {
      return injected(deviceId);
    }
    final backend = container.read(deviceBackendProvider);
    return backend.cameraLiveViewFrame(deviceId);
  }

  void _writeJson(Object socket, Map<String, Object?> data) {
    final adapter = _sinkAdapters[socket];
    if (adapter == null) return;
    try {
      adapter.add(jsonEncode(data));
    } catch (e) {
      _logger.warning(
        '/ws/live-view JSON write failed: $e',
        source: 'LiveViewStreamHub',
      );
    }
  }

  void _writeBytes(Object socket, Uint8List bytes) {
    final adapter = _sinkAdapters[socket];
    if (adapter == null) return;
    try {
      adapter.add(bytes);
    } catch (e) {
      _logger.warning(
        '/ws/live-view binary write failed: $e',
        source: 'LiveViewStreamHub',
      );
    }
  }

  static int _clampInt({
    required Object? raw,
    required int defaultValue,
    required int min,
    required int max,
  }) {
    if (raw is num) {
      final v = raw.toInt();
      if (v < min) return min;
      if (v > max) return max;
      return v;
    }
    return defaultValue;
  }

  static double _clampDouble({
    required Object? raw,
    required double defaultValue,
    required double min,
    required double max,
  }) {
    if (raw is num) {
      final v = raw.toDouble();
      if (v < min) return min;
      if (v > max) return max;
      return v;
    }
    return defaultValue;
  }
}

/// Tiny indirection over the underlying sink so the hub can write to a
/// real [WebSocketChannel] in production and an in-memory channel pair in
/// tests without conditionally referencing `socket.sink`.
class _SinkAdapter {
  final void Function(dynamic) _add;
  final Future<void> Function() _close;
  _SinkAdapter(this._add, this._close);

  void add(dynamic value) => _add(value);
  Future<void> close() => _close();
}
