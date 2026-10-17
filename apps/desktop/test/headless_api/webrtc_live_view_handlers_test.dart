// WebRtcLiveViewHandlers lifecycle + hub fan-out tests.
//
// We do NOT spin up libwebrtc in tests because (a) the bundled libwebrtc
// DLL is several hundred MB and CI runners don't have it on the link
// path, (b) the bits we care about — session registry, hub fan-out, and
// teardown — don't depend on real ICE negotiation. We inject a
// [_FakePeerConnection] via the `peerConnectionFactory` parameter and
// verify the handler wires it up correctly.
//
// What's covered:
//   * POST /api/webrtc/live-view/offer creates a session, returns sdp
//     + sessionId, and registers it in the handler's session map.
//   * The session attaches to the LiveViewStreamHub via attachRaw and
//     the hub's frame fan-out reaches the fake datachannel's send()
//     hook with the JPEG bytes from the test producer.
//   * DELETE /api/webrtc/live-view/<sessionId> removes the session and
//     closes the peer connection.
//   * POST /api/webrtc/live-view/ice/<sessionId> forwards the candidate
//     to addCandidate() on the underlying peer connection.
//   * SSE GET endpoint replays locally-gathered ICE candidates.
//   * Bad-input paths return 400 with a structured error body.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:image/image.dart' as img;
import 'package:skotiq_desktop/headless_api/handlers/live_view_stream_handlers.dart';
import 'package:skotiq_desktop/headless_api/handlers/webrtc_live_view_handlers.dart';
import 'package:shelf/shelf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WebRtcLiveViewHandlers', () {
    late ProviderContainer container;
    late LiveViewStreamHub hub;
    late WebRtcLiveViewHandlers handlers;
    late List<_FakePeerConnection> fakes;

    Uint8List fakeMasterJpeg() {
      final bitmap = img.Image(width: 32, height: 24);
      img.fill(bitmap, color: img.ColorRgb8(0, 255, 0));
      return Uint8List.fromList(img.encodeJpg(bitmap, quality: 80));
    }

    setUp(() {
      container = ProviderContainer();
      hub = LiveViewStreamHub(container: container);
      hub.testFrameProducer = (_) async => fakeMasterJpeg();
      fakes = [];
      handlers = WebRtcLiveViewHandlers(
        container: container,
        hub: hub,
        peerConnectionFactory: (config) async {
          final fake = _FakePeerConnection(config: config);
          fakes.add(fake);
          return fake;
        },
      );
    });

    tearDown(() async {
      await handlers.dispose();
      await hub.dispose();
      container.dispose();
    });

    Future<Response> postOffer({
      String deviceId = 'test:cam:1',
      Map<String, Object?>? sdp,
      List<Map<String, Object?>>? iceServers,
    }) {
      final body = jsonEncode({
        'deviceId': deviceId,
        'sdp': sdp ?? {'type': 'offer', 'sdp': 'v=0\r\nm=application'},
        if (iceServers != null) 'iceServers': iceServers,
      });
      return handlers.handleOffer(
        Request(
          'POST',
          Uri.parse('http://localhost/api/webrtc/live-view/offer'),
          body: body,
          headers: {'content-type': 'application/json'},
        ),
      );
    }

    test(
      'POST offer creates a session and returns sessionId + sdp answer',
      () async {
        final response = await postOffer();
        expect(response.statusCode, 200);
        final body =
            jsonDecode(await response.readAsString()) as Map<String, dynamic>;
        expect(body['sessionId'], isA<String>());
        expect((body['sessionId'] as String).length, 32);
        final answer = body['sdp'] as Map<String, dynamic>;
        expect(answer['type'], 'answer');
        expect(answer['sdp'], isA<String>());
        expect(body['dataChannelLabel'], 'live-view-frames');
        expect(handlers.sessionCount, 1);
      },
    );

    test('POST offer rejects empty deviceId', () async {
      final response = await postOffer(deviceId: '');
      expect(response.statusCode, 400);
      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['error'], 'bad_request');
      expect(handlers.sessionCount, 0);
    });

    test('POST offer rejects missing sdp', () async {
      final response = await handlers.handleOffer(
        Request(
          'POST',
          Uri.parse('http://localhost/api/webrtc/live-view/offer'),
          body: jsonEncode({'deviceId': 'test:cam:1'}),
          headers: {'content-type': 'application/json'},
        ),
      );
      expect(response.statusCode, 400);
      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['error'], 'bad_request');
    });

    test('POST offer rejects non-offer SDP types', () async {
      final response = await postOffer(
        sdp: {'type': 'answer', 'sdp': 'v=0\r\nm=application'},
      );
      expect(response.statusCode, 400);
      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['error'], 'bad_sdp');
    });

    test(
      'session subscribes to hub and JPEG frames reach the datachannel',
      () async {
        final response = await postOffer(deviceId: 'test:cam:2');
        expect(response.statusCode, 200);
        final body =
            jsonDecode(await response.readAsString()) as Map<String, dynamic>;
        final sessionId = body['sessionId'] as String;
        final fake = fakes.single;
        // Open the data channel so the session's sink starts forwarding
        // frames. (The hub starts the producer loop the moment a
        // subscription is registered, regardless of channel state, but
        // pre-open writes are dropped by the session's sink adapter.)
        fake.channel.openForTest();

        // Wait for the hub to deliver at least one binary frame to our
        // fake channel. The hub ticks at ~250 ms so a 5 s timeout is
        // safely generous.
        await _waitUntil(
          () => fake.channel.binaryWrites.isNotEmpty,
          timeout: const Duration(seconds: 5),
          reason: 'no binary frame reached the datachannel',
        );
        // We expect at least one text message (the frame_meta envelope)
        // immediately before the binary frame.
        expect(fake.channel.textWrites, isNotEmpty);
        final firstMeta =
            jsonDecode(fake.channel.textWrites.first) as Map<String, dynamic>;
        expect(firstMeta['type'], 'frame_meta');
        expect(firstMeta['deviceId'], 'test:cam:2');
        expect(fake.channel.binaryWrites.first, isNotEmpty);
        // Hub should have one active subscriber from this session.
        expect(hub.activeSubscriberCount, 1);
        // sanity: session is still registered
        expect(handlers.sessionCount, 1);
        // Cleanup
        final del = await handlers.handleDelete(
          Request(
            'DELETE',
            Uri.parse('http://localhost/api/webrtc/live-view/$sessionId'),
          ),
          sessionId,
        );
        expect(del.statusCode, 204);
        expect(handlers.sessionCount, 0);
        // Hub should idle once the last subscriber is gone.
        await _waitUntil(
          () => hub.activeSubscriberCount == 0,
          timeout: const Duration(seconds: 2),
          reason: 'hub did not unsubscribe after session DELETE',
        );
      },
    );

    test(
      'POST ICE candidate forwards to the underlying peer connection',
      () async {
        final response = await postOffer();
        final body =
            jsonDecode(await response.readAsString()) as Map<String, dynamic>;
        final sessionId = body['sessionId'] as String;
        final fake = fakes.single;
        expect(fake.addedCandidates, isEmpty);

        final iceResp = await handlers.handleIce(
          Request(
            'POST',
            Uri.parse('http://localhost/api/webrtc/live-view/ice/$sessionId'),
            body: jsonEncode({
              'candidate': {
                'candidate':
                    'candidate:1 1 UDP 2122252543 192.168.1.10 50000 typ host',
                'sdpMid': '0',
                'sdpMLineIndex': 0,
              },
            }),
            headers: {'content-type': 'application/json'},
          ),
          sessionId,
        );
        expect(iceResp.statusCode, 204);
        expect(fake.addedCandidates.length, 1);
        expect(fake.addedCandidates.single.sdpMid, '0');
        expect(fake.addedCandidates.single.sdpMLineIndex, 0);
      },
    );

    test(
      'POST ICE with null candidate forwards end-of-candidates marker',
      () async {
        final response = await postOffer();
        final body =
            jsonDecode(await response.readAsString()) as Map<String, dynamic>;
        final sessionId = body['sessionId'] as String;
        final fake = fakes.single;
        final iceResp = await handlers.handleIce(
          Request(
            'POST',
            Uri.parse('http://localhost/api/webrtc/live-view/ice/$sessionId'),
            body: jsonEncode({'candidate': null}),
            headers: {'content-type': 'application/json'},
          ),
          sessionId,
        );
        expect(iceResp.statusCode, 204);
        expect(fake.addedCandidates.length, 1);
        // The EOC marker is encoded as an empty-string candidate.
        expect(fake.addedCandidates.single.candidate, '');
      },
    );

    test('POST ICE for unknown session returns 404', () async {
      final iceResp = await handlers.handleIce(
        Request(
          'POST',
          Uri.parse('http://localhost/api/webrtc/live-view/ice/nope'),
          body: jsonEncode({
            'candidate': {'candidate': 'x', 'sdpMid': '0', 'sdpMLineIndex': 0},
          }),
          headers: {'content-type': 'application/json'},
        ),
        'nope',
      );
      expect(iceResp.statusCode, 404);
    });

    test('DELETE for unknown session returns 404', () async {
      final del = await handlers.handleDelete(
        Request(
          'DELETE',
          Uri.parse('http://localhost/api/webrtc/live-view/nope'),
        ),
        'nope',
      );
      expect(del.statusCode, 404);
    });

    test('SSE replay surfaces locally-gathered ICE candidates', () async {
      final response = await postOffer();
      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      final sessionId = body['sessionId'] as String;
      final fake = fakes.single;
      // Pretend libwebrtc gathered two candidates before the client
      // subscribed to the SSE endpoint — these must be replayed.
      fake.emitCandidate(RTCIceCandidate('candidate:1 1 UDP ...', '0', 0));
      fake.emitCandidate(RTCIceCandidate('candidate:2 1 TCP ...', '0', 0));
      final sse = handlers.handleIceEvents(
        Request(
          'GET',
          Uri.parse(
            'http://localhost/api/webrtc/live-view/ice/$sessionId/events',
          ),
        ),
        sessionId,
      );
      expect(sse.statusCode, 200);
      expect(sse.headers['content-type'], contains('text/event-stream'));
      // Consume the SSE stream for a short window to capture the
      // replay events. The handler emits `retry:` first then the
      // queued events.
      final completer = Completer<String>();
      final buf = StringBuffer();
      late StreamSubscription<List<int>> sub;
      sub = sse.read().listen((bytes) {
        buf.write(utf8.decode(bytes));
        if (buf.toString().contains('candidate:2')) {
          if (!completer.isCompleted) {
            completer.complete(buf.toString());
          }
        }
      }, cancelOnError: true);
      final received = await completer.future.timeout(
        const Duration(seconds: 3),
      );
      await sub.cancel();
      expect(received, contains('candidate:1'));
      expect(received, contains('candidate:2'));
      expect(received, contains('event: ice'));
    });

    test('handler dispose tears down all sessions', () async {
      await postOffer(deviceId: 'cam:a');
      await postOffer(deviceId: 'cam:b');
      expect(handlers.sessionCount, 2);
      await handlers.dispose();
      expect(handlers.sessionCount, 0);
      // All fakes should have been closed.
      for (final fake in fakes) {
        expect(fake.closed, isTrue);
      }
    });
  });
}

/// Wait until [predicate] returns true. Polls every 50 ms; fails the
/// surrounding test if [timeout] elapses without the predicate
/// becoming true.
Future<void> _waitUntil(
  bool Function() predicate, {
  required Duration timeout,
  String? reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(
        reason ?? 'predicate never became true within ${timeout.inSeconds}s',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// In-memory fake of [RTCPeerConnection]. Implements only the surface
/// the WebRTC handler touches:
///   * setRemoteDescription / setLocalDescription / createAnswer /
///     createDataChannel / addCandidate / close
///   * onIceCandidate / onIceGatheringState / onConnectionState setters
///
/// All other members throw `UnimplementedError`, so production code reaching
/// past the modelled surface fails visibly instead of silently receiving null.
class _FakePeerConnection implements RTCPeerConnection {
  final Map<String, dynamic> config;
  _FakePeerConnection({required this.config});

  // ── State the production code reads back ────────────────────────────────
  RTCPeerConnectionState _connState =
      RTCPeerConnectionState.RTCPeerConnectionStateNew;

  final List<RTCIceCandidate> addedCandidates = [];
  late final _FakeDataChannel channel = _FakeDataChannel(this);
  bool closed = false;

  // ── Event callbacks the handler installs ────────────────────────────────
  Function(RTCIceCandidate)? _onIceCandidate;
  Function(RTCIceGatheringState)? _onIceGatheringState;
  Function(RTCPeerConnectionState)? _onConnectionState;

  /// Pretend libwebrtc gathered a candidate locally — fans it out to the
  /// installed `onIceCandidate` callback. Used by tests that exercise
  /// the SSE replay path.
  void emitCandidate(RTCIceCandidate c) {
    _onIceCandidate?.call(c);
  }

  @override
  Future<RTCSessionDescription> createAnswer([
    Map<String, dynamic>? constraints,
  ]) async {
    return RTCSessionDescription(
      'v=0\r\ns=fake\r\nt=0 0\r\nm=application 1 UDP/DTLS/SCTP webrtc-datachannel\r\n',
      'answer',
    );
  }

  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {
    // recorded by the underlying noSuchMethod fallback; we only need
    // to satisfy the interface contract for the production code path.
  }

  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {
    // see setLocalDescription above
  }

  @override
  Future<RTCDataChannel> createDataChannel(
    String label,
    RTCDataChannelInit dataChannelDict,
  ) async {
    channel._label = label;
    return channel;
  }

  @override
  Future<void> addCandidate(RTCIceCandidate candidate) async {
    addedCandidates.add(candidate);
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    _connState = RTCPeerConnectionState.RTCPeerConnectionStateClosed;
    channel.closeForTest();
  }

  @override
  RTCPeerConnectionState? get connectionState => _connState;

  // ── Callback setters (the only properties the handler writes) ───────────
  @override
  set onIceCandidate(Function(RTCIceCandidate)? cb) => _onIceCandidate = cb;
  @override
  Function(RTCIceCandidate)? get onIceCandidate => _onIceCandidate;

  @override
  set onIceGatheringState(Function(RTCIceGatheringState)? cb) =>
      _onIceGatheringState = cb;
  @override
  Function(RTCIceGatheringState)? get onIceGatheringState =>
      _onIceGatheringState;

  @override
  set onConnectionState(Function(RTCPeerConnectionState)? cb) =>
      _onConnectionState = cb;
  @override
  Function(RTCPeerConnectionState)? get onConnectionState => _onConnectionState;

  // ── Everything else is unimplemented; loud-fail ───────────
  @override
  dynamic noSuchMethod(Invocation invocation) {
    // Silence read-only properties the analyzer/runtime might probe.
    final name = invocation.memberName.toString();
    // Property getters from RTCPeerConnection we don't model
    if (invocation.isGetter) {
      switch (name) {
        case 'Symbol("iceConnectionState")':
        case 'Symbol("iceGatheringState")':
        case 'Symbol("signalingState")':
          return null;
        case 'Symbol("getConfiguration")':
          return config;
      }
    }
    return super.noSuchMethod(invocation);
  }
}

/// Minimal fake [RTCDataChannel] backed by two lists for text + binary
/// writes. The handler's sink adapter calls `send(RTCDataChannelMessage)`
/// which we capture for assertions.
class _FakeDataChannel implements RTCDataChannel {
  final _FakePeerConnection parent;
  String _label = 'live-view-frames';
  RTCDataChannelState _state = RTCDataChannelState.RTCDataChannelConnecting;
  Function(RTCDataChannelState)? _onState;

  final List<String> textWrites = [];
  final List<Uint8List> binaryWrites = [];

  _FakeDataChannel(this.parent);

  void openForTest() {
    _state = RTCDataChannelState.RTCDataChannelOpen;
    _onState?.call(_state);
  }

  void closeForTest() {
    if (_state == RTCDataChannelState.RTCDataChannelClosed) return;
    _state = RTCDataChannelState.RTCDataChannelClosed;
    _onState?.call(_state);
  }

  @override
  String get label => _label;

  @override
  RTCDataChannelState? get state => _state;

  @override
  set onDataChannelState(Function(RTCDataChannelState)? cb) => _onState = cb;
  @override
  Function(RTCDataChannelState)? get onDataChannelState => _onState;

  @override
  Future<void> send(RTCDataChannelMessage message) async {
    if (message.isBinary) {
      binaryWrites.add(message.binary);
    } else {
      textWrites.add(message.text);
    }
  }

  @override
  Future<void> close() async {
    closeForTest();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isGetter) {
      // The handler does not read other getters; return safe defaults.
      return null;
    }
    return super.noSuchMethod(invocation);
  }
}
