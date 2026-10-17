part of '../network_backend.dart';

/// Private helper that holds the libwebrtc-side state for a single
/// [NetworkBackend.subscribeLiveViewWebRtc] subscription.
///
/// Lifetime:
///   1. POST `/api/webrtc/live-view/offer` to obtain `{sessionId, sdp}`.
///   2. setRemoteDescription(answer); subscribe to the SSE candidate
///      stream and POST every locally-gathered candidate as a remote
///      candidate on `/api/webrtc/live-view/ice/{sessionId}`.
///   3. Wait for the `live-view-frames` data channel; demux text
///      (frame_meta envelope) and binary (JPEG) messages into
///      [LiveViewFrame] instances and hand them to `onFrame`.
///   4. On dispose: DELETE the session, close the RTCPeerConnection.
class _WebRtcLiveViewSubscription {
  final NetworkBackend backend;
  final String deviceId;
  final String sessionId;
  final RTCPeerConnection peerConnection;
  final void Function(LiveViewFrame) onFrame;
  final void Function(Object) onError;
  final void Function() onDone;
  final HttpClient _sseClient;

  RTCDataChannel? _channel;
  HttpClientResponse? _sseResponse;
  StreamSubscription<String>? _sseSub;
  Map<String, Object?>? _pendingMeta;
  bool _disposed = false;

  _WebRtcLiveViewSubscription._({
    required this.backend,
    required this.deviceId,
    required this.sessionId,
    required this.peerConnection,
    required this.onFrame,
    required this.onError,
    required this.onDone,
  }) : _sseClient = HttpClient();

  static Future<_WebRtcLiveViewSubscription> start({
    required NetworkBackend backend,
    required String deviceId,
    required List<Map<String, Object?>>? iceServers,
    required void Function(LiveViewFrame) onFrame,
    required void Function(Object) onError,
    required void Function() onDone,
  }) async {
    final pc = await createPeerConnection(<String, dynamic>{
      'iceServers':
          iceServers ??
          const [
            {
              'urls': ['stun:stun.l.google.com:19302'],
            },
          ],
      'sdpSemantics': 'unified-plan',
    });

    // The server is the answerer and creates the data channel. We open
    // a one-shot offer with no audio/video tracks; libwebrtc still
    // emits an SCTP m=application section for the inbound datachannel.
    final offer = await pc.createOffer({
      'offerToReceiveAudio': 0,
      'offerToReceiveVideo': 0,
    });
    await pc.setLocalDescription(offer);

    // POST the offer to the server.
    final offerUri = backend._apiUri('webrtc/live-view/offer');
    final headers = backend._addAuthHeaders(
      {},
      endpoint: 'webrtc/live-view/offer',
    );
    headers[HttpHeaders.contentTypeHeader] = 'application/json';
    final body = <String, Object?>{
      'deviceId': deviceId,
      'sdp': {'type': offer.type, 'sdp': offer.sdp},
      if (iceServers != null) 'iceServers': iceServers,
    };
    final response = await backend._http.post(
      offerUri,
      headers: headers,
      body: jsonEncode(body),
    );
    if (response.statusCode != 200) {
      await pc.close();
      throw backend._parseErrorResponse(
        response.statusCode,
        response.body,
        'POST',
        'webrtc/live-view/offer',
      );
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      await pc.close();
      throw const FormatException(
        '/api/webrtc/live-view/offer: response was not a JSON object',
      );
    }
    final sessionId = decoded['sessionId'];
    final answerSdp = decoded['sdp'];
    if (sessionId is! String || sessionId.isEmpty) {
      await pc.close();
      throw const FormatException(
        '/api/webrtc/live-view/offer: response missing sessionId',
      );
    }
    if (answerSdp is! Map ||
        answerSdp['type'] is! String ||
        answerSdp['sdp'] is! String) {
      await pc.close();
      throw const FormatException(
        '/api/webrtc/live-view/offer: response missing sdp.{type,sdp}',
      );
    }

    final sub = _WebRtcLiveViewSubscription._(
      backend: backend,
      deviceId: deviceId,
      sessionId: sessionId,
      peerConnection: pc,
      onFrame: onFrame,
      onError: onError,
      onDone: onDone,
    );

    // Hook ICE + data channel BEFORE setRemoteDescription so we don't
    // miss any candidates the answerer is about to flush.
    pc.onIceCandidate = sub._onLocalIceCandidate;
    pc.onDataChannel = sub._bindChannel;
    pc.onConnectionState = sub._onConnectionState;

    await pc.setRemoteDescription(
      RTCSessionDescription(
        answerSdp['sdp'] as String,
        answerSdp['type'] as String,
      ),
    );

    // Subscribe to the server-side SSE candidate stream. This must run
    // concurrently with our local candidate POSTing, so we fire and
    // forget — the SSE consumer self-cancels on dispose.
    unawaited(sub._consumeServerIce());

    return sub;
  }

  void _bindChannel(RTCDataChannel channel) {
    if (channel.label != kLiveViewClientDataChannelLabel) {
      // Unexpected channel — log and ignore. The server only ever
      // opens `live-view-frames` for this session type.
      developer.log(
        '[NetworkBackend] webrtc: unexpected data channel label '
        '"${channel.label}" on session $sessionId',
        name: 'NetworkBackend',
        level: 900,
      );
      return;
    }
    _channel = channel;
    channel.onMessage = _onMessage;
    channel.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelClosed) {
        if (!_disposed) onDone();
      }
    };
  }

  void _onMessage(RTCDataChannelMessage message) {
    if (_disposed) return;
    if (message.isBinary) {
      final meta = _pendingMeta;
      _pendingMeta = null;
      if (meta == null) {
        developer.log(
          '[NetworkBackend] webrtc: binary frame with no preceding '
          'meta envelope on session $sessionId; dropping',
          name: 'NetworkBackend',
          level: 900,
        );
        return;
      }
      try {
        final frame = LiveViewFrame.fromMetadata(meta, message.binary);
        onFrame(frame);
      } on FormatException catch (e) {
        onError(e);
      }
      return;
    }
    // Text message: JSON envelope.
    final text = message.text;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return;
      final type = decoded['type'];
      if (type == 'frame_meta') {
        _pendingMeta = decoded.map(
          (k, v) => MapEntry(k.toString(), v as Object?),
        );
      } else if (type == 'error') {
        onError(
          dart_error.SkotiqError(
            category: dart_error.BackendErrorCategory.system,
            message:
                (decoded['message'] as String?) ??
                'live-view error: ${decoded['code']}',
          ),
        );
      } else if (type == 'stopped') {
        if (!_disposed) onDone();
      }
      // ready/pong: nothing to surface.
    } catch (e) {
      developer.log(
        '[NetworkBackend] webrtc: text frame decode failed on session '
        '$sessionId: $e',
        name: 'NetworkBackend',
        level: 900,
      );
    }
  }

  Future<void> _onLocalIceCandidate(RTCIceCandidate candidate) async {
    if (_disposed) return;
    final uri = backend._apiUri('webrtc/live-view/ice/$sessionId');
    final headers = backend._addAuthHeaders(
      {},
      endpoint: 'webrtc/live-view/ice',
    );
    headers[HttpHeaders.contentTypeHeader] = 'application/json';
    final body = jsonEncode({
      'candidate': {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      },
    });
    try {
      final response = await backend._http.post(
        uri,
        headers: headers,
        body: body,
      );
      if (response.statusCode >= 400) {
        developer.log(
          '[NetworkBackend] webrtc: POST ICE candidate failed '
          'status=${response.statusCode} body=${response.body}',
          name: 'NetworkBackend',
          level: 900,
        );
      }
    } catch (e) {
      developer.log(
        '[NetworkBackend] webrtc: POST ICE candidate threw: $e',
        name: 'NetworkBackend',
        level: 900,
      );
    }
  }

  Future<void> _consumeServerIce() async {
    if (_disposed) return;
    try {
      final uri = backend._apiUri('webrtc/live-view/ice/$sessionId/events');
      final request = await _sseClient.getUrl(uri);
      backend
          ._addAuthHeaders({}, endpoint: 'webrtc/live-view/ice/events')
          .forEach((k, v) => request.headers.add(k, v));
      request.headers.set('accept', 'text/event-stream');
      final response = await request.close();
      _sseResponse = response;
      if (response.statusCode != 200) {
        onError(
          dart_error.SkotiqError(
            category: dart_error.BackendErrorCategory.system,
            message:
                'WebRTC ICE SSE returned ${response.statusCode} for '
                'session $sessionId',
          ),
        );
        return;
      }
      // Decode UTF-8 + split into lines. SSE framing is line-oriented:
      // we buffer `data:` lines until a blank line marks end-of-event,
      // then dispatch by the most recent `event:` name.
      final lines = response
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      String? currentEvent;
      final dataBuf = StringBuffer();
      final completer = Completer<void>();
      _sseSub = lines.listen(
        (line) {
          if (_disposed) return;
          if (line.isEmpty) {
            if (dataBuf.isNotEmpty) {
              final dataStr = dataBuf.toString();
              dataBuf.clear();
              final event = currentEvent ?? 'message';
              currentEvent = null;
              unawaited(_handleSseEvent(event, dataStr));
            }
            return;
          }
          if (line.startsWith(':')) return; // keepalive comment
          if (line.startsWith('event: ')) {
            currentEvent = line.substring('event: '.length).trim();
          } else if (line.startsWith('data: ')) {
            if (dataBuf.isNotEmpty) dataBuf.write('\n');
            dataBuf.write(line.substring('data: '.length));
          }
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete();
        },
        onError: (Object e, _) {
          if (!_disposed) {
            developer.log(
              '[NetworkBackend] webrtc: ICE SSE stream error on session '
              '$sessionId: $e',
              name: 'NetworkBackend',
              level: 900,
            );
          }
          if (!completer.isCompleted) completer.complete();
        },
        cancelOnError: true,
      );
      await completer.future;
    } catch (e) {
      if (_disposed) return;
      developer.log(
        '[NetworkBackend] webrtc: ICE SSE failed for session '
        '$sessionId: $e',
        name: 'NetworkBackend',
        level: 900,
      );
    }
  }

  Future<void> _handleSseEvent(String event, String data) async {
    if (_disposed) return;
    if (event == 'ice') {
      try {
        final decoded = jsonDecode(data);
        if (decoded is! Map) return;
        final cand = decoded['candidate'];
        if (cand is! Map) return;
        final candStr = cand['candidate'];
        final sdpMid = cand['sdpMid'];
        final sdpMLineIndex = cand['sdpMLineIndex'];
        if (candStr is! String) return;
        await peerConnection.addCandidate(
          RTCIceCandidate(
            candStr,
            sdpMid is String ? sdpMid : null,
            sdpMLineIndex is num ? sdpMLineIndex.toInt() : null,
          ),
        );
      } catch (e) {
        developer.log(
          '[NetworkBackend] webrtc: failed to apply server ICE '
          'candidate on session $sessionId: $e',
          name: 'NetworkBackend',
          level: 900,
        );
      }
    } else if (event == 'complete') {
      // Server done gathering. Send EOC marker to our local PC.
      try {
        await peerConnection.addCandidate(RTCIceCandidate('', null, null));
      } catch (_) {
        // EOC marker is best-effort.
      }
    } else if (event == 'error') {
      try {
        final decoded = jsonDecode(data);
        final msg = decoded is Map ? decoded['message']?.toString() : null;
        onError(
          dart_error.SkotiqError(
            category: dart_error.BackendErrorCategory.system,
            message: msg ?? 'WebRTC ICE SSE error on session $sessionId',
          ),
        );
      } catch (_) {
        onError(
          dart_error.SkotiqError(
            category: dart_error.BackendErrorCategory.system,
            message: 'WebRTC ICE SSE error (unparseable) on session $sessionId',
          ),
        );
      }
    }
  }

  void _onConnectionState(RTCPeerConnectionState state) {
    if (_disposed) return;
    switch (state) {
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        onError(
          dart_error.SkotiqError(
            category: dart_error.BackendErrorCategory.system,
            message: 'WebRTC peer connection failed on session $sessionId',
          ),
        );
      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        if (!_disposed) onDone();
      case RTCPeerConnectionState.RTCPeerConnectionStateNew:
      case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        break;
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _sseSub?.cancel();
    _sseSub = null;
    try {
      unawaited(
        _sseResponse
                ?.detachSocket()
                .then((s) => s.destroy())
                .catchError((_) {}) ??
            Future<void>.value(),
      );
    } catch (_) {
      // ignore
    }
    _sseResponse = null;
    try {
      _sseClient.close(force: true);
    } catch (_) {
      // ignore
    }
    try {
      await _channel?.close();
    } catch (_) {
      // ignore
    }
    _channel = null;
    try {
      await peerConnection.close();
    } catch (_) {
      // ignore
    }
    // Best-effort DELETE so the server reaps the session immediately
    // rather than waiting for the 30 s startup timer.
    try {
      final uri = backend._apiUri('webrtc/live-view/$sessionId');
      final headers = backend._addAuthHeaders(
        {},
        endpoint: 'webrtc/live-view/delete',
      );
      await backend._http.delete(uri, headers: headers);
    } catch (_) {
      // Server might already be unreachable; the startup timer will
      // clean up server-side.
    }
  }
}

/// Datachannel label expected by the client when accepting the inbound
/// channel from the server. Must match the server-side constant in
/// `webrtc_live_view_handlers.dart` (`kLiveViewDataChannelLabel`); kept
/// here as a separate const so changing one without the other is a
/// visible diff in code review.
const String kLiveViewClientDataChannelLabel = 'live-view-frames';

/// Client-side mirror of the headless server's Job model. Tolerates
/// missing/extra fields so a server that gains additional metadata does
/// not break older clients.
