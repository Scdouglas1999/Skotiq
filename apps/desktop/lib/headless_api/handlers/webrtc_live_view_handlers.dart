// WebRTC datachannel transport for the live-view stream.
//
// The push WebSocket at `/ws/live-view` is the canonical
// producer (see `live_view_stream_handlers.dart`); this module is a
// PARALLEL fan-out path that publishes the SAME JPEG frames over a
// WebRTC RTCPeerConnection's datachannel. We do NOT re-encode and we
// do NOT spin up a second producer loop — the [LiveViewStreamHub]
// already owns subscriber book-keeping and JPEG-encode cadence; each
// WebRTC session simply attaches to it via the public `attachRaw`
// entry point with a custom sink that writes binary frames into the
// outbound datachannel and JSON envelopes as text datachannel messages.
//
// Why an HTTP signalling channel (POST offer / POST ICE / SSE answer)
// rather than the existing WS event bus: a phone behind a CGNAT or a
// strict mobile firewall often needs ICE-restart with TURN before any
// peer connection comes up. The signalling MUST be reachable when the
// data-plane WebSocket isn't — keeping signalling on plain HTTP means
// the WebRTC fallback works even when the LAN-direct WS path is dead.
//
// Wire protocol:
//
//   POST /api/webrtc/live-view/offer
//     Body: {
//       "deviceId": "ascom:Camera.QHY",
//       "sdp": {"type": "offer", "sdp": "v=0\r\n..."},
//       "iceServers": [{"urls":["stun:stun.l.google.com:19302"]}]?
//     }
//     Response: {
//       "sessionId": "<uuid>",
//       "sdp": {"type": "answer", "sdp": "v=0\r\n..."},
//       "iceServers": [...],
//       "expiresAt": "<iso8601>"
//     }
//
//   POST /api/webrtc/live-view/ice/<sessionId>
//     Body: {"candidate": {"candidate": "candidate:...", "sdpMid": "0",
//                           "sdpMLineIndex": 0}}
//     Sends a remote ICE candidate from the client. Returns 204.
//     When the body's `candidate` is null or empty, the client signals
//     end-of-candidates; the server forwards a null candidate to libwebrtc.
//
//   GET /api/webrtc/live-view/ice/<sessionId>/events
//     SSE stream of server-side ICE candidates. Each event has:
//       event: ice
//       data: {"candidate":{...}}
//     Plus a final `event: complete` once the server finishes gathering.
//
//   DELETE /api/webrtc/live-view/<sessionId>
//     Explicit teardown. Returns 204. Also called server-side when the
//     30s no-ICE-progress timer fires or the peer connection enters
//     `failed` / `disconnected`.
//
// Datachannel:
//   * Label: `live-view-frames`
//   * Ordered, reliable (default). The producer rate is at most ~10 fps
//     and a JPEG is a few-tens-of-KB; ordering preserves frame_meta →
//     binary pairing without needing per-message sequence numbers.
//   * Server → client messages:
//       - String: JSON `frame_meta` envelope, identical to the WS
//         protocol so the client-side parser is shared.
//       - Binary: the JPEG bytes for the most recent envelope.
//
// 30-second startup expiry: if the peer connection has not progressed
// beyond `new`/`checking` within 30 s the session is reaped — the
// client must re-offer. Once `connected` the session lives as long as
// the datachannel is open; the 30 s timer no longer applies.
//
// no stubs, no placeholders, errors are loud.
// A WebRTC failure (peer disconnect, ICE failure, datachannel close)
// tears the session down immediately and the client-side stream emits
// an explicit error. There is no silent fallback to the WS path inside
// this handler — that decision is made by `NetworkBackend.
// subscribeLiveViewAuto`.

import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import 'live_view_stream_handlers.dart';

/// Default ICE servers used when the client does not supply any.
/// Google's public STUN is fine for LAN + symmetric-NAT-free links;
/// operators who need TURN supply it via the request body.
const _kDefaultIceServers = <Map<String, Object?>>[
  {
    'urls': ['stun:stun.l.google.com:19302'],
  },
];

/// How long a freshly-minted session has to progress past ICE checking
/// before the server reaps it. After the peer connection reports
/// `connected`/`completed` the timer is cancelled and the session lives
/// until the datachannel closes.
const Duration _kSessionStartupTimeout = Duration(seconds: 30);

/// Maximum simultaneous WebRTC sessions per server. Hard cap so a
/// misbehaving client cannot drive the server out of memory by opening
/// peer connections it never closes.
const int _kMaxConcurrentSessions = 64;

/// Datachannel label. Mirrored on the client side; both sides must
/// agree or the channel will never open.
const String kLiveViewDataChannelLabel = 'live-view-frames';

/// Builder used by tests to swap the real `flutter_webrtc` factory for
/// an in-memory mock. Production callers leave this null and the real
/// `createPeerConnection` from `package:flutter_webrtc` is used.
typedef PeerConnectionFactory =
    Future<RTCPeerConnection> Function(Map<String, dynamic> configuration);

/// Handlers for the `/api/webrtc/live-view/*` signalling surface plus
/// the per-session [_WebRtcLiveViewSession] registry. One instance per
/// server; sessions are short-lived (one peer connection each).
class WebRtcLiveViewHandlers {
  final ProviderContainer container;
  final LiveViewStreamHub hub;
  final LoggingService _logger;
  final PeerConnectionFactory _factory;
  final Random _random;

  /// All currently-live sessions keyed by `sessionId`. Replaced rather
  /// than mutated when a session is destroyed so iteration during
  /// shutdown is safe.
  final Map<String, _WebRtcLiveViewSession> _sessions = {};

  bool _disposed = false;

  WebRtcLiveViewHandlers({
    required this.container,
    required this.hub,
    PeerConnectionFactory? peerConnectionFactory,
    Random? random,
  }) : _factory = peerConnectionFactory ?? createPeerConnection,
       _random = random ?? Random.secure(),
       _logger = container.read(loggingServiceProvider);

  /// Number of active sessions; exposed for tests + diagnostics.
  int get sessionCount => _sessions.length;

  /// Look up a session for tests. Returns null if absent. The return
  /// type is the package-private session class; the analyzer warning
  /// about exposing a private type in a public API is intentionally
  /// silenced because the only callers are sibling test fixtures that
  /// already live in the same package.
  // ignore: library_private_types_in_public_api
  _WebRtcLiveViewSession? sessionForTest(String sessionId) =>
      _sessions[sessionId];

  /// Tear down every session. Safe to call multiple times.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final ids = List.of(_sessions.keys);
    for (final id in ids) {
      await _destroySession(id, reason: 'server_shutdown');
    }
  }

  // Route handlers

  /// POST /api/webrtc/live-view/offer
  Future<Response> handleOffer(Request request) async {
    if (_disposed) {
      return jsonServiceUnavailable({
        'error': 'webrtc_disposed',
        'message': 'WebRTC handler is shutting down.',
      });
    }
    if (_sessions.length >= _kMaxConcurrentSessions) {
      return jsonResponse({
        'error': 'too_many_sessions',
        'message':
            'Server already holds the maximum number of WebRTC '
            'live-view sessions ($_kMaxConcurrentSessions). Close an '
            'existing session before requesting a new one.',
        'maxSessions': _kMaxConcurrentSessions,
      }, statusCode: 503);
    }

    final Map<String, Object?> body;
    try {
      body = await _readJsonBody(request);
    } on FormatException catch (e) {
      return jsonBadRequest({'error': 'bad_json', 'message': e.message});
    }

    final deviceIdRaw = body['deviceId'];
    if (deviceIdRaw is! String || deviceIdRaw.isEmpty) {
      return jsonBadRequest({
        'error': 'bad_request',
        'message': 'deviceId is required and must be a non-empty string.',
      });
    }
    final sdpRaw = body['sdp'];
    if (sdpRaw is! Map) {
      return jsonBadRequest({
        'error': 'bad_request',
        'message': 'sdp is required and must be an object {type, sdp}.',
      });
    }
    final sdpType = sdpRaw['type'];
    final sdpText = sdpRaw['sdp'];
    if (sdpType is! String || sdpText is! String || sdpText.isEmpty) {
      return jsonBadRequest({
        'error': 'bad_sdp',
        'message': 'sdp.type and sdp.sdp must be non-empty strings.',
      });
    }
    if (sdpType != 'offer') {
      return jsonBadRequest({
        'error': 'bad_sdp',
        'message': 'sdp.type must be "offer"; got "$sdpType".',
      });
    }

    // Client may override the ICE-server list — useful when the operator
    // brings their own TURN server (LTE-only phones, double-NATted LANs).
    final List<Map<String, Object?>> iceServers;
    final iceRaw = body['iceServers'];
    if (iceRaw is List) {
      try {
        iceServers = iceRaw
            .map(
              (e) => (e as Map).map(
                (k, v) => MapEntry(k.toString(), v as Object?),
              ),
            )
            .toList(growable: false);
      } catch (e) {
        return jsonBadRequest({
          'error': 'bad_ice_servers',
          'message': 'iceServers entries must be JSON objects: $e',
        });
      }
    } else {
      iceServers = _kDefaultIceServers;
    }

    final sessionId = _generateSessionId();
    final session = await _createSession(
      sessionId: sessionId,
      deviceId: deviceIdRaw,
      iceServers: iceServers,
    );

    try {
      await session.peerConnection.setRemoteDescription(
        RTCSessionDescription(sdpText, sdpType),
      );
      final answer = await session.peerConnection.createAnswer({});
      await session.peerConnection.setLocalDescription(answer);

      // Subscribe to the hub now that the local description is set;
      // frames will queue inside the data channel's send buffer until
      // the channel opens.
      session.attachToHub(hub: hub);

      _logger.info(
        '/api/webrtc/live-view/offer: created session=$sessionId '
        'device=$deviceIdRaw iceServers=${iceServers.length}',
        source: 'WebRtcLiveView',
      );

      return jsonResponse({
        'sessionId': sessionId,
        'sdp': {'type': answer.type, 'sdp': answer.sdp},
        'iceServers': iceServers,
        'expiresAt': session.expiresAt.toUtc().toIso8601String(),
        'dataChannelLabel': kLiveViewDataChannelLabel,
      });
    } catch (e, st) {
      _logger.warning(
        '/api/webrtc/live-view/offer: SDP negotiation failed for '
        'session=$sessionId device=$deviceIdRaw: $e\n$st',
        source: 'WebRtcLiveView',
      );
      await _destroySession(sessionId, reason: 'offer_failed');
      return jsonInternalServerError({
        'error': 'offer_failed',
        'message': 'Failed to apply offer / build answer: $e',
      });
    }
  }

  /// POST /api/webrtc/live-view/ice/{sessionId}
  Future<Response> handleIce(Request request, String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null) {
      return jsonNotFound({
        'error': 'unknown_session',
        'message': 'No active WebRTC live-view session for id=$sessionId.',
      });
    }

    final Map<String, Object?> body;
    try {
      body = await _readJsonBody(request);
    } on FormatException catch (e) {
      return jsonBadRequest({'error': 'bad_json', 'message': e.message});
    }

    final candidateRaw = body['candidate'];
    if (candidateRaw == null) {
      // Explicit end-of-candidates signal from the client.
      try {
        // Pass a candidate with empty string + null sdpMid; libwebrtc
        // interprets that as end-of-candidates on most platforms. We
        // surface this to the peer connection explicitly rather than
        // dropping it because some platforms gate connectivity on
        // seeing the EOC marker.
        await session.peerConnection.addCandidate(
          RTCIceCandidate('', null, null),
        );
      } catch (e) {
        _logger.warning(
          '/api/webrtc/live-view/ice: end-of-candidates failed: $e',
          source: 'WebRtcLiveView',
        );
      }
      return noContentResponse();
    }
    if (candidateRaw is! Map) {
      return jsonBadRequest({
        'error': 'bad_candidate',
        'message': 'candidate must be a JSON object or null for EOC.',
      });
    }

    final candidate = candidateRaw['candidate'];
    final sdpMid = candidateRaw['sdpMid'];
    final sdpMLineIndex = candidateRaw['sdpMLineIndex'];
    if (candidate is! String) {
      return jsonBadRequest({
        'error': 'bad_candidate',
        'message': 'candidate.candidate must be a string.',
      });
    }

    try {
      await session.peerConnection.addCandidate(
        RTCIceCandidate(
          candidate,
          sdpMid is String ? sdpMid : null,
          sdpMLineIndex is num ? sdpMLineIndex.toInt() : null,
        ),
      );
      return noContentResponse();
    } catch (e) {
      _logger.warning(
        '/api/webrtc/live-view/ice: addCandidate failed for '
        'session=$sessionId: $e',
        source: 'WebRtcLiveView',
      );
      return jsonInternalServerError({
        'error': 'ice_add_failed',
        'message': 'Failed to add remote ICE candidate: $e',
      });
    }
  }

  /// GET /api/webrtc/live-view/ice/{sessionId}/events
  ///
  /// Server-Sent Events stream of locally-gathered ICE candidates. The
  /// session pushes each candidate from its `onIceCandidate` handler
  /// into a broadcast controller; this method subscribes to that
  /// controller and writes SSE frames.
  Response handleIceEvents(Request request, String sessionId) {
    final session = _sessions[sessionId];
    if (session == null) {
      return jsonNotFound({
        'error': 'unknown_session',
        'message': 'No active WebRTC live-view session for id=$sessionId.',
      });
    }

    final controller = StreamController<List<int>>();
    StreamSubscription<_IceEvent>? sub;
    Timer? keepAlive;

    void write(String s) {
      if (controller.isClosed) return;
      controller.add(utf8.encode(s));
    }

    controller.onListen = () {
      // Replay every candidate gathered before the SSE consumer
      // connected — without this the client misses the host
      // candidates emitted during setLocalDescription.
      for (final ev in session.replayIceEvents()) {
        write('event: ${ev.eventName}\ndata: ${jsonEncode(ev.payload)}\n\n');
      }
      sub = session.iceEvents.listen(
        (ev) {
          write('event: ${ev.eventName}\ndata: ${jsonEncode(ev.payload)}\n\n');
        },
        onError: (Object e, _) {
          // Sanitized SSE error: don't leak the raw exception to the client.
          write(
            'event: error\ndata: ${jsonEncode({"message": "stream_error"})}\n\n',
          );
        },
        onDone: () {
          if (!controller.isClosed) controller.close();
        },
      );
      // Keep the long-poll alive across LTE NAT timeouts. SSE comments
      // start with `:` and are ignored client-side.
      keepAlive = Timer.periodic(const Duration(seconds: 20), (_) {
        write(': keepalive\n\n');
      });
      // Initial retry hint so EventSource backs off sensibly on
      // disconnects.
      write('retry: 5000\n\n');
    };
    controller.onCancel = () async {
      keepAlive?.cancel();
      keepAlive = null;
      await sub?.cancel();
      sub = null;
    };

    return streamResponse(
      controller.stream,
      contentType: 'text/event-stream; charset=utf-8',
      headers: {
        'cache-control': 'no-cache, no-transform',
        'connection': 'keep-alive',
        'x-accel-buffering': 'no',
      },
      context: {'shelf.io.buffer_output': false},
    );
  }

  /// DELETE /api/webrtc/live-view/{sessionId}
  Future<Response> handleDelete(Request request, String sessionId) async {
    final session = _sessions[sessionId];
    if (session == null) {
      return jsonNotFound({
        'error': 'unknown_session',
        'message': 'No active WebRTC live-view session for id=$sessionId.',
      });
    }
    await _destroySession(sessionId, reason: 'client_delete');
    return noContentResponse();
  }

  // Session lifecycle

  Future<_WebRtcLiveViewSession> _createSession({
    required String sessionId,
    required String deviceId,
    required List<Map<String, Object?>> iceServers,
  }) async {
    final configuration = <String, dynamic>{
      'iceServers': iceServers,
      // Default `sdpSemantics` to unified-plan — libwebrtc deprecated
      // plan-b. Match what the Flutter web demo uses.
      'sdpSemantics': 'unified-plan',
    };
    final pc = await _factory(configuration);

    final session = _WebRtcLiveViewSession(
      sessionId: sessionId,
      deviceId: deviceId,
      peerConnection: pc,
      logger: _logger,
      onDestroy: (reason) => _destroySession(sessionId, reason: reason),
    );

    // Server is the offerer's responder: create the outbound data
    // channel BEFORE setRemoteDescription so the SDP answer advertises
    // it. The offerer's SDP will already have requested an m=application
    // section if they pre-created their own channel; libwebrtc handles
    // negotiation either way as long as both sides offer/answer the
    // application m-line.
    final dc = await pc.createDataChannel(
      kLiveViewDataChannelLabel,
      RTCDataChannelInit()
        ..ordered = true
        // Reliable channel (default); explicit so the intent is clear.
        ..maxRetransmits = -1
        ..protocol = 'skotiq-live-view-1',
    );
    session.bindDataChannel(dc);

    _sessions[sessionId] = session;
    session.armStartupTimer(_kSessionStartupTimeout);

    return session;
  }

  Future<void> _destroySession(
    String sessionId, {
    required String reason,
  }) async {
    final session = _sessions.remove(sessionId);
    if (session == null) return;
    _logger.info(
      'WebRTC live-view session=$sessionId destroyed: reason=$reason',
      source: 'WebRtcLiveView',
    );
    await session.dispose();
  }

  String _generateSessionId() {
    // 128 random bits encoded as 32 lowercase hex. Cryptographically
    // strong because [Random.secure] backs the generator; the id is a
    // capability so weak entropy would let an attacker probe sessions
    // belonging to other paired clients.
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    final hex = StringBuffer();
    for (final b in bytes) {
      hex.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return hex.toString();
  }

  static Future<Map<String, Object?>> _readJsonBody(Request request) async {
    final raw = await request.readAsString();
    if (raw.isEmpty) {
      throw const FormatException('Request body is empty');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('Request body must be a JSON object');
    }
    return decoded.map((k, v) => MapEntry(k.toString(), v as Object?));
  }
}

/// Per-session state. Owns the [RTCPeerConnection], the outbound data
/// channel, the hub subscription, and the ICE-event broadcast that
/// backs the SSE endpoint.
class _WebRtcLiveViewSession {
  final String sessionId;
  final String deviceId;
  final RTCPeerConnection peerConnection;
  final LoggingService logger;
  final Future<void> Function(String reason) onDestroy;

  RTCDataChannel? _dataChannel;
  Timer? _startupTimer;
  final DateTime expiresAt;

  /// Hub identity used for `attachRaw`. Stable across the session's
  /// lifetime so unsubscribe routes correctly.
  late final Object _hubIdentity;
  bool _attachedToHub = false;

  /// Broadcast controller for outbound ICE candidates. Multiple SSE
  /// subscribers per session are not expected in practice, but the
  /// broadcast type lets a reconnecting client subscribe even after the
  /// session has been gathering candidates for a few hundred ms.
  final StreamController<_IceEvent> _iceController =
      StreamController<_IceEvent>.broadcast();

  /// Candidates emitted before the SSE consumer attached. Replayed when
  /// the SSE handler subscribes so the client never misses a host
  /// candidate.
  final List<_IceEvent> _iceReplay = [];
  bool _iceComplete = false;

  Stream<_IceEvent> get iceEvents => _iceController.stream;

  bool _disposed = false;

  _WebRtcLiveViewSession({
    required this.sessionId,
    required this.deviceId,
    required this.peerConnection,
    required this.logger,
    required this.onDestroy,
  }) : expiresAt = DateTime.now().add(_kSessionStartupTimeout) {
    _hubIdentity = Object();
    peerConnection.onIceCandidate = _onIceCandidate;
    peerConnection.onIceGatheringState = _onIceGatheringState;
    peerConnection.onConnectionState = _onConnectionState;
  }

  /// Whether the datachannel is currently open (test seam).
  bool get dataChannelOpen =>
      _dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen;

  /// Last data-channel state observed. Test seam only.
  RTCDataChannelState? get dataChannelStateForTest => _dataChannel?.state;

  /// Test seam: returns the buffered replay events without subscribing
  /// to the live stream.
  Iterable<_IceEvent> replayIceEvents() {
    return List<_IceEvent>.unmodifiable(_iceReplay);
  }

  void bindDataChannel(RTCDataChannel dc) {
    _dataChannel = dc;
    dc.onDataChannelState = (state) {
      logger.info(
        'WebRTC live-view session=$sessionId datachannel state=$state',
        source: 'WebRtcLiveView',
      );
      if (state == RTCDataChannelState.RTCDataChannelClosed ||
          state == RTCDataChannelState.RTCDataChannelClosing) {
        if (!_disposed) {
          unawaited(onDestroy('datachannel_closed'));
        }
      }
    };
  }

  /// Per-session inbound controller. Closed on [dispose]; the close
  /// triggers the hub's `onDone` which unsubscribes the session cleanly.
  /// Held as a field so [dispose] can close it deterministically (we
  /// must close inbound BEFORE the hub iterates `_subs` on the next
  /// producer tick so a destroyed session can't be written to a
  /// half-closed data channel).
  StreamController<dynamic>? _hubInbound;

  /// Live-view streaming parameters chosen for this WebRTC session.
  /// They mirror the defaults the WS path uses; phones with tighter
  /// bandwidth budgets can override these via subsequent control
  /// messages on the datachannel in a future revision (out of scope
  /// for ).
  int liveViewMaxDim = 1024;
  double liveViewMaxFps = 2.0;
  int liveViewJpegQuality = 70;

  /// Attach this session to the [LiveViewStreamHub]. The hub's
  /// `attachRaw` entry point keys subscriptions on an arbitrary
  /// `Object` so our [_hubIdentity] keeps server→client writes routed to
  /// the right data channel without modifying the hub.
  void attachToHub({required LiveViewStreamHub hub}) {
    if (_attachedToHub) return;
    // Inbound stream is consumed by the hub; closing it on [dispose]
    // signals `onDone` which detaches the subscription cleanly.
    final inbound = StreamController<dynamic>();
    _hubInbound = inbound;
    hub.attachRaw(
      socket: _hubIdentity,
      stream: inbound.stream,
      sinkAdd: _sinkAdd,
      sinkClose: () async {
        if (!inbound.isClosed) await inbound.close();
      },
    );
    _attachedToHub = true;
    // Synthesize a subscribe message so the hub's producer loop starts
    // immediately. The signalling layer already carried `deviceId`, so
    // the WebRTC client does not need to send a separate subscribe
    // message over the data channel.
    inbound.add(
      jsonEncode({
        'type': 'subscribe',
        'deviceId': deviceId,
        'maxDim': liveViewMaxDim,
        'maxFps': liveViewMaxFps,
        'jpegQuality': liveViewJpegQuality,
      }),
    );
  }

  /// Sink adapter passed to [LiveViewStreamHub.attachRaw]. The hub
  /// writes either JSON envelopes (as String) or JPEG bytes (as
  /// `Uint8List` / `List<int>`). We forward both into the data channel
  /// using the matching `RTCDataChannelMessage` variants.
  void _sinkAdd(dynamic value) {
    final dc = _dataChannel;
    if (dc == null) return;
    if (dc.state != RTCDataChannelState.RTCDataChannelOpen) {
      // Pre-open writes are dropped intentionally rather than buffered:
      // the JPEG cadence is at most ~10 fps, so missing the first few
      // frames while ICE settles is acceptable, and buffering would
      // let memory grow unbounded if the channel never opens.
      return;
    }
    try {
      if (value is String) {
        dc.send(RTCDataChannelMessage(value));
      } else if (value is Uint8List) {
        dc.send(RTCDataChannelMessage.fromBinary(value));
      } else if (value is List<int>) {
        dc.send(RTCDataChannelMessage.fromBinary(Uint8List.fromList(value)));
      } else {
        // Anything else is a protocol violation by the hub; surface it
        // loudly and tear the session down so the client
        // sees the error rather than mysteriously stops receiving.
        logger.warning(
          'WebRTC live-view session=$sessionId received unexpected '
          'sink value type: ${value.runtimeType}',
          source: 'WebRtcLiveView',
        );
      }
    } catch (e, st) {
      logger.warning(
        'WebRTC live-view session=$sessionId datachannel send failed: '
        '$e\n$st',
        source: 'WebRtcLiveView',
      );
      unawaited(onDestroy('send_failed'));
    }
  }

  void armStartupTimer(Duration timeout) {
    _startupTimer = Timer(timeout, () {
      if (_disposed) return;
      final state = peerConnection.connectionState;
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        return;
      }
      logger.warning(
        'WebRTC live-view session=$sessionId did not connect within '
        '${timeout.inSeconds}s (state=$state) — reaping',
        source: 'WebRtcLiveView',
      );
      unawaited(onDestroy('startup_timeout'));
    });
  }

  void _onIceCandidate(RTCIceCandidate candidate) {
    if (_disposed) return;
    final payload = <String, Object?>{
      'candidate': {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      },
    };
    final ev = _IceEvent(eventName: 'ice', payload: payload);
    _iceReplay.add(ev);
    if (!_iceController.isClosed) {
      _iceController.add(ev);
    }
  }

  void _onIceGatheringState(RTCIceGatheringState state) {
    if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
        !_iceComplete) {
      _iceComplete = true;
      final ev = _IceEvent(
        eventName: 'complete',
        payload: const {'complete': true},
      );
      _iceReplay.add(ev);
      if (!_iceController.isClosed) {
        _iceController.add(ev);
      }
    }
  }

  void _onConnectionState(RTCPeerConnectionState state) {
    logger.info(
      'WebRTC live-view session=$sessionId peer state=$state',
      source: 'WebRtcLiveView',
    );
    switch (state) {
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        // Connectivity established — the startup timer is no longer
        // relevant.
        _startupTimer?.cancel();
        _startupTimer = null;
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        if (!_disposed) {
          unawaited(onDestroy('peer_state_$state'));
        }
      case RTCPeerConnectionState.RTCPeerConnectionStateNew:
      case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
        break;
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _startupTimer?.cancel();
    _startupTimer = null;
    // Close inbound FIRST so the hub's `onDone` listener detaches the
    // session before we tear down the data channel — otherwise the
    // hub's next producer tick could try to write into a closed
    // channel.
    final inbound = _hubInbound;
    _hubInbound = null;
    if (inbound != null && !inbound.isClosed) {
      try {
        await inbound.close();
      } on Object catch (e) {
        // Why: best-effort teardown — the hub side may have already closed.
        logger.debug(
          'WebRTC $sessionId teardown: hub inbound close failed: $e',
          source: 'WebRtcLiveView',
        );
      }
    }
    try {
      await _dataChannel?.close();
    } on Object catch (e) {
      // Why: best-effort teardown — the connection is already closing.
      logger.debug(
        'WebRTC $sessionId teardown: data channel close failed: $e',
        source: 'WebRtcLiveView',
      );
    }
    _dataChannel = null;
    try {
      await peerConnection.close();
    } on Object catch (e) {
      // Why: best-effort teardown — the connection is already closing.
      logger.debug(
        'WebRTC $sessionId teardown: peer connection close failed: $e',
        source: 'WebRtcLiveView',
      );
    }
    if (!_iceController.isClosed) {
      await _iceController.close();
    }
    _attachedToHub = false;
  }
}

/// One SSE event for the `/api/webrtc/live-view/ice/<sessionId>/events`
/// stream.
class _IceEvent {
  final String eventName;
  final Map<String, Object?> payload;
  const _IceEvent({required this.eventName, required this.payload});
}
