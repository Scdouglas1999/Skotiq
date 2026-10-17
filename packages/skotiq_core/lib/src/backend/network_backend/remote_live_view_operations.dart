part of '../network_backend.dart';

mixin _NetworkBackendRemoteLiveViewOperations on _NetworkBackendTransport {
  // Live-view stream: client surface for the push-based
  // live-view WebSocket at `/ws/live-view`. Server protocol is documented
  // alongside the handler in
  // `apps/desktop/lib/headless_api/handlers/live_view_stream_handlers.dart`.
  //
  // The returned stream emits one [LiveViewFrame] per server push. The
  // socket is opened lazily on the first subscriber and torn down (with
  // a polite `unsubscribe` message + sink.close) when the subscription
  // is cancelled. Re-subscribing returns a NEW stream backed by a new
  // socket; we do not share a single socket across subscriptions because
  // each viewer may want different `maxDim`/`maxFps`/`region`.
  Stream<LiveViewFrame> subscribeLiveView({
    required String deviceId,
    int maxDim = 1024,
    double maxFps = 2.0,
    int jpegQuality = 70,
    LiveViewRegion? region,
  }) {
    if (deviceId.isEmpty) {
      // Eagerly reject so the UI sees a synchronous failure rather than
      // an empty stream.
      return Stream<LiveViewFrame>.error(
        ArgumentError.value(deviceId, 'deviceId', 'must not be empty'),
      );
    }
    final controller = StreamController<LiveViewFrame>();
    WebSocketChannel? channel;
    StreamSubscription<dynamic>? wsSub;
    Map<String, Object?>? pendingMeta;
    var closed = false;

    Future<void> openSocket() async {
      final query = <String, String>{};
      if (authToken != null && authToken!.isNotEmpty) {
        // Prefer the one-shot WS ticket so the bearer token stays out of the
        // WebSocket URL; fall back to ?token= for older servers.
        final wsTicket = await _mintWsTicket();
        if (wsTicket != null) {
          query['ticket'] = wsTicket;
        } else {
          query['token'] = authToken!;
        }
      }
      final uri = _wsUri('/ws/live-view', query);
      try {
        channel = IOWebSocketChannel.connect(uri);
        // IOWebSocketChannel reports a failed connection on BOTH the stream
        // (handled by the onError below, which routes to the controller) and
        // on sink.done. Absorb the sink.done error so a connection failure —
        // e.g. ECONNREFUSED, which fails immediately on Linux instead of
        // hanging as it tends to on Windows — doesn't escape as an unhandled
        // async error and tear down the zone.
        unawaited(channel!.sink.done.catchError((Object _) {}));
        // Wait for the socket to actually open before subscribing. `ready`
        // throws on connection failure (e.g. ECONNREFUSED), so the error is
        // caught by the try/catch below and surfaced via the controller
        // instead of escaping as an unhandled async error — and it avoids
        // sending `subscribe` into a socket that never connected.
        await channel!.ready;
        // Send the initial subscribe immediately. The server replies
        // with `{type: ready, ...}` then starts pushing frames.
        channel!.sink.add(
          jsonEncode({
            'type': 'subscribe',
            'deviceId': deviceId,
            'maxDim': maxDim,
            'maxFps': maxFps,
            'jpegQuality': jpegQuality,
            if (region != null) 'region': region.toJson(),
          }),
        );
        wsSub = channel!.stream.listen(
          (raw) {
            if (closed || controller.isClosed) return;
            if (raw is String) {
              try {
                final decoded = jsonDecode(raw);
                if (decoded is! Map) return;
                final type = decoded['type'];
                if (type == 'frame_meta') {
                  pendingMeta = decoded.map(
                    (k, v) => MapEntry(k.toString(), v as Object?),
                  );
                } else if (type == 'error') {
                  // Surface non-fatal server-reported errors as stream
                  // errors but don't close the stream — the server will
                  // try again on the next tick.
                  controller.addError(
                    dart_error.SkotiqError(
                      category: dart_error.BackendErrorCategory.system,
                      message:
                          (decoded['message'] as String?) ??
                          'live-view error: ${decoded['code']}',
                    ),
                  );
                } else if (type == 'stopped') {
                  // Server closed the stream voluntarily. Close from our
                  // side so the consumer's await for() exits cleanly.
                  if (!controller.isClosed) controller.close();
                }
                // ready/pong: nothing to surface to the consumer.
              } catch (e) {
                developer.log(
                  '[NetworkBackend] /ws/live-view JSON decode failed: $e',
                  name: 'NetworkBackend',
                  level: 900,
                );
              }
            } else if (raw is List<int>) {
              final meta = pendingMeta;
              pendingMeta = null;
              if (meta == null) {
                // Stray binary frame with no preceding meta — log + drop.
                developer.log(
                  '[NetworkBackend] /ws/live-view: received binary frame '
                  'with no preceding meta envelope; dropping',
                  name: 'NetworkBackend',
                  level: 900,
                );
                return;
              }
              try {
                final frame = LiveViewFrame.fromMetadata(
                  meta,
                  raw is Uint8List ? raw : Uint8List.fromList(raw),
                );
                controller.add(frame);
              } on FormatException catch (e) {
                controller.addError(e);
              }
            }
          },
          onError: (Object e, _) {
            if (closed || controller.isClosed) return;
            controller.addError(e);
            controller.close();
          },
          onDone: () {
            if (closed || controller.isClosed) return;
            controller.close();
          },
        );
      } catch (e) {
        if (!controller.isClosed) {
          controller.addError(e);
          await controller.close();
        }
      }
    }

    controller.onListen = () => unawaited(openSocket());
    controller.onCancel = () async {
      closed = true;
      try {
        channel?.sink.add(jsonEncode({'type': 'unsubscribe'}));
      } catch (_) {
        // sink may already be closed; ignore
      }
      await wsSub?.cancel();
      wsSub = null;
      try {
        await channel?.sink.close();
      } catch (_) {
        // ignore — already closing
      }
      channel = null;
    };
    return controller.stream;
  }

  // WebRTC live-view: parallel transport that publishes the
  // SAME server-side JPEG frames over an RTCDataChannel. The server-
  // side fan-out lives in
  // `apps/desktop/lib/headless_api/handlers/webrtc_live_view_handlers.dart`.
  //
  // The signalling channel is plain HTTP (POST offer / POST ICE / GET
  // SSE answer-ICE / DELETE), so even when the dashboard's main WS is
  // down the SDP exchange can complete. The data plane is a single
  // RTCDataChannel labelled `live-view-frames` carrying:
  //   * String messages: JSON frame_meta envelopes (identical wire
  //     format to the WS path).
  //   * Binary messages: the JPEG bytes paired with the most recent
  //     envelope.
  //
  // The returned stream emits one [LiveViewFrame] per server push. On
  // cancellation we DELETE the session and close the RTCPeerConnection;
  // on ICE/connection failure we emit an error and tear down — no
  // silent fallback. Callers wanting graceful degradation should use
  // [subscribeLiveViewAuto].
  Stream<LiveViewFrame> subscribeLiveViewWebRtc({
    required String deviceId,
    List<Map<String, Object?>>? iceServers,
  }) {
    if (deviceId.isEmpty) {
      return Stream<LiveViewFrame>.error(
        ArgumentError.value(deviceId, 'deviceId', 'must not be empty'),
      );
    }
    final controller = StreamController<LiveViewFrame>();
    _WebRtcLiveViewSubscription? sub;
    var closed = false;

    Future<void> open() async {
      try {
        sub = await _WebRtcLiveViewSubscription.start(
          backend: this as NetworkBackend,
          deviceId: deviceId,
          iceServers: iceServers,
          onFrame: (frame) {
            if (closed || controller.isClosed) return;
            controller.add(frame);
          },
          onError: (Object e) {
            if (closed || controller.isClosed) return;
            controller.addError(e);
            controller.close();
          },
          onDone: () {
            if (closed || controller.isClosed) return;
            controller.close();
          },
        );
      } catch (e) {
        if (!controller.isClosed) {
          controller.addError(e);
          await controller.close();
        }
      }
    }

    controller.onListen = () => unawaited(open());
    controller.onCancel = () async {
      closed = true;
      await sub?.dispose();
      sub = null;
    };
    return controller.stream;
  }

  /// Caller-friendly auto-select. Tries [subscribeLiveViewWebRtc]
  /// first; if it errors out before the first frame arrives within
  /// [webRtcFirstFrameTimeout] (default 10 s), the WebRTC stream is
  /// torn down and we fall through to [subscribeLiveView] (the legacy
  /// WS path). Once a WebRTC frame has been delivered, this method never
  /// silently downgrades — a subsequent failure surfaces as a stream
  /// error so the UI can tell the difference between "server doesn't
  /// support WebRTC" and "session crashed mid-stream".
  ///
  /// [onFallback] (optional) receives a single-line note when the auto
  /// path falls back. The note is also written to `dart:developer.log`
  /// at level 800 so it shows up in flutter logs without requiring the
  /// caller to plumb a logger.
  Stream<LiveViewFrame> subscribeLiveViewAuto({
    required String deviceId,
    int maxDim = 1024,
    double maxFps = 2.0,
    int jpegQuality = 70,
    LiveViewRegion? region,
    List<Map<String, Object?>>? iceServers,
    Duration webRtcFirstFrameTimeout = const Duration(seconds: 10),
    void Function(String message)? onFallback,
  }) {
    if (deviceId.isEmpty) {
      return Stream<LiveViewFrame>.error(
        ArgumentError.value(deviceId, 'deviceId', 'must not be empty'),
      );
    }
    final controller = StreamController<LiveViewFrame>();
    StreamSubscription<LiveViewFrame>? webRtcSub;
    StreamSubscription<LiveViewFrame>? wsSub;
    Timer? firstFrameTimer;
    var receivedFirstFrame = false;
    var fellBack = false;
    var closed = false;

    void logFallback(String reason) {
      final msg =
          '[NetworkBackend] live-view: falling back from WebRTC to '
          'WS — $reason';
      developer.log(msg, name: 'NetworkBackend', level: 800);
      if (onFallback != null) onFallback(msg);
    }

    void switchToWs() {
      if (fellBack || closed) return;
      fellBack = true;
      firstFrameTimer?.cancel();
      firstFrameTimer = null;
      unawaited(webRtcSub?.cancel());
      webRtcSub = null;
      wsSub =
          subscribeLiveView(
            deviceId: deviceId,
            maxDim: maxDim,
            maxFps: maxFps,
            jpegQuality: jpegQuality,
            region: region,
          ).listen(
            (frame) {
              if (closed || controller.isClosed) return;
              controller.add(frame);
            },
            onError: (Object e) {
              if (closed || controller.isClosed) return;
              controller.addError(e);
              controller.close();
            },
            onDone: () {
              if (closed || controller.isClosed) return;
              controller.close();
            },
          );
    }

    void startWebRtc() {
      webRtcSub =
          subscribeLiveViewWebRtc(
            deviceId: deviceId,
            iceServers: iceServers,
          ).listen(
            (frame) {
              if (closed || controller.isClosed) return;
              if (!receivedFirstFrame) {
                receivedFirstFrame = true;
                firstFrameTimer?.cancel();
                firstFrameTimer = null;
              }
              controller.add(frame);
            },
            onError: (Object e) {
              if (closed || controller.isClosed) return;
              if (receivedFirstFrame) {
                // Mid-stream failure: surface the error rather than
                // silently swap transports — the WS path would not recover
                // from a peer-side crash any faster than the caller can
                // re-subscribe.
                controller.addError(e);
                controller.close();
                return;
              }
              logFallback('WebRTC error before first frame: $e');
              switchToWs();
            },
            onDone: () {
              if (closed || controller.isClosed) return;
              if (receivedFirstFrame) {
                controller.close();
              } else {
                logFallback('WebRTC stream ended before first frame');
                switchToWs();
              }
            },
          );
      firstFrameTimer = Timer(webRtcFirstFrameTimeout, () {
        if (receivedFirstFrame || fellBack || closed) return;
        logFallback(
          'WebRTC did not deliver first frame within '
          '${webRtcFirstFrameTimeout.inSeconds}s',
        );
        switchToWs();
      });
    }

    controller.onListen = startWebRtc;
    controller.onCancel = () async {
      closed = true;
      firstFrameTimer?.cancel();
      firstFrameTimer = null;
      await webRtcSub?.cancel();
      webRtcSub = null;
      await wsSub?.cancel();
      wsSub = null;
    };
    return controller.stream;
  }
}
