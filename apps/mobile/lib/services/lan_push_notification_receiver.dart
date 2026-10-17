// LAN UDP push notification receiver (mobile side).
//
// Pairs with `packages/skotiq_remote_protocol/lib/src/push/
// lan_push_broadcaster.dart` on the desktop. The broadcaster fans out
// every critical alert (weather unsafe, sequence failed, guiding lost,
// mount runaway) over UDP — both broadcast (255.255.255.255) and
// multicast (239.255.42.99) — so a phone whose WebSocket has dropped
// still wakes the OS notification system.
//
// Why a different file name from the OTA `LanPushReceiver`: the OTA
// receiver in `skotiq_updater` is a TCP server on port 45680 that
// accepts authenticated update packages. We're a UDP listener on a
// different port (45681) with a different wire format. Keeping the
// names distinct prevents anyone from confusing the two during a
// future refactor.
//
// Lifecycle:
//   - Construct with the paired server's fingerprint. The receiver
//     derives the HMAC key from the fingerprint (matches the desktop
//     side identically) and rejects any frame whose HMAC doesn't
//     verify.
//   - Call [start] when the mobile pairs (saved-server fingerprint
//     available). The receiver binds a UDP socket and joins the
//     multicast group on every interface.
//   - Listen on [incoming] to be notified of decoded frames. The
//     existing `MobileNotificationService.notifyPush` is the natural
//     consumer.
//   - Call [stop] on unpair / signout. The receiver releases the
//     socket and stops emitting.
//   - On iOS, the OS kills the socket when the app is suspended; the
//     receiver re-binds on `start()` so the next app-foreground call
//     rebuilds it.

import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

/// UDP push notification receiver. Verifies HMAC + fingerprint match,
/// surfaces decoded frames on [incoming], and deduplicates against any
/// frame already delivered via the WebSocket using the frame's `id`.
class LanPushNotificationReceiver {
  /// UDP port to listen on. Must match the broadcaster — defaults to
  /// [kLanPushDefaultPort] (45681).
  final int port;

  /// SHA-256 server fingerprint that paired phones learned during
  /// enrollment. Frames whose `serverFingerprint` field doesn't match
  /// this are dropped — that's the same identity binding the HMAC key
  /// derivation depends on.
  final String serverFingerprint;

  /// Sink used by tests to inject UDP datagrams without going through a
  /// real socket. Production binds a real `RawDatagramSocket`.
  final LanPushTestInjector? injector;

  /// Optional logger sink so production wiring routes through
  /// LoggingService; tests inject a recorder.
  final void Function(
    LanPushLogLevel level,
    String message, {
    Map<String, Object?>? fields,
  })?
  logger;

  /// Capacity of the dedup ring. We keep the last N frame IDs to
  /// suppress duplicates between the WS-delivered copy and the UDP
  /// copy. 256 covers a few hours of bursty critical alerts at a
  /// reasonable memory cost (~16 KB).
  static const int _dedupCapacity = 256;

  late final List<int> _hmacKey = derivePushHmacKey(serverFingerprint);

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _socketSubscription;
  StreamSubscription<Uint8List>? _injectorSubscription;

  final StreamController<PushNotificationFrame> _frameController =
      StreamController<PushNotificationFrame>.broadcast();

  // Insertion-ordered LRU of recently seen frame IDs. Add to tail on
  // arrival; trim the head past the capacity bound. O(1) lookup via
  // contains() because LinkedHashSet keeps both insertion order and
  // hash-set membership.
  final LinkedHashSet<String> _seenIds = LinkedHashSet<String>();

  bool _started = false;
  bool _active = false;

  LanPushNotificationReceiver({
    required this.serverFingerprint,
    this.port = kLanPushDefaultPort,
    this.injector,
    this.logger,
  });

  /// Stream of decoded, HMAC-verified, deduplicated frames.
  Stream<PushNotificationFrame> get incoming => _frameController.stream;

  /// True between a successful [start] and a [stop].
  bool get isActive => _active;

  /// True once [start] has been called. Used to make start/stop
  /// idempotent.
  bool get isStarted => _started;

  /// Record a frame ID that arrived over the WebSocket so the next
  /// UDP-delivered copy of the same frame is dropped. Callers wire
  /// this from their WS handler — typically the dedupe needs to span
  /// both directions (a UDP frame may arrive before WS, or vice
  /// versa).
  void recordSeenFrameId(String id) {
    if (id.isEmpty) return;
    if (_seenIds.contains(id)) {
      // Move to MRU by remove+add — keeps recently-seen IDs from
      // being evicted under burst arrival.
      _seenIds.remove(id);
    }
    _seenIds.add(id);
    _trimDedup();
  }

  void _trimDedup() {
    while (_seenIds.length > _dedupCapacity) {
      _seenIds.remove(_seenIds.first);
    }
  }

  Future<void> start() async {
    if (_started) return;
    _started = true;

    final inj = injector;
    if (inj != null) {
      _injectorSubscription = inj.datagrams.listen(_processDatagram);
      _active = true;
      _log(
        LanPushLogLevel.info,
        'LAN push receiver started (injector); port=$port',
      );
      return;
    }

    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
        reuseAddress: true,
        reusePort: false,
      );
      // multicast on every interface that supports it. Loopback is
      // includeded so the desktop+phone-on-same-host integration test
      // case works.
      try {
        final interfaces = await NetworkInterface.list(
          includeLoopback: true,
          type: InternetAddressType.IPv4,
        );
        for (final interface in interfaces) {
          try {
            socket.joinMulticast(
              InternetAddress(kLanPushMulticastAddress),
              interface,
            );
          } catch (e) {
            // Some virtual interfaces refuse multicast joins. The
            // broadcast (255.255.255.255) fan-out still reaches us on
            // those, so log and continue.
            _log(
              LanPushLogLevel.warning,
              'LAN push receiver: multicast join failed on interface',
              fields: {'interface': interface.name, 'error': '$e'},
            );
          }
        }
      } catch (e) {
        _log(
          LanPushLogLevel.warning,
          'LAN push receiver: failed to enumerate interfaces for '
          'multicast join — continuing with broadcast-only',
          fields: {'error': '$e'},
        );
      }

      _socketSubscription = socket.listen(
        _onSocketEvent,
        onError: (e, st) {
          _log(
            LanPushLogLevel.warning,
            'LAN push receiver: socket error',
            fields: {'error': '$e', 'stack': '$st'},
          );
        },
      );
      _socket = socket;
      _active = true;
      _log(
        LanPushLogLevel.info,
        'LAN push receiver started',
        fields: {'port': port},
      );
    } catch (e, st) {
      _log(
        LanPushLogLevel.warning,
        'LAN push receiver bind failed — backgrounded phones will not '
        'wake on critical alerts when their WebSocket is dropped',
        fields: {'port': port, 'error': '$e', 'stack': '$st'},
      );
      _started = false;
      _active = false;
    }
  }

  void _onSocketEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final socket = _socket;
    if (socket == null) return;
    final datagram = socket.receive();
    if (datagram == null) return;
    _processDatagram(datagram.data);
  }

  /// Decode + verify a datagram payload. Public for tests so they can
  /// inject bytes directly without going through a socket.
  void _processDatagram(Uint8List bytes) {
    final result = decodePushFrame(bytes, hmacKey: _hmacKey);
    if (!result.isOk) {
      // Categorise the failure for the log. Bad HMAC is the
      // security-relevant signal (someone on the LAN tried to forge an
      // alert without the right fingerprint); the others are usually
      // benign noise (random UDP traffic, a future protocol version).
      switch (result.failure) {
        case LanPushDecodeFailure.hmacMismatch:
          _log(
            LanPushLogLevel.warning,
            'LAN push receiver: HMAC verification FAILED — dropping '
            'datagram (possible forge attempt or fingerprint drift)',
          );
          break;
        case LanPushDecodeFailure.badMagic:
        case LanPushDecodeFailure.truncatedHeader:
          // Routine LAN noise — most UDP traffic on 45681 will not be
          // ours. Log at debug to keep production logs clean.
          break;
        case LanPushDecodeFailure.unsupportedVersion:
          _log(
            LanPushLogLevel.warning,
            'LAN push receiver: unsupported protocol version — drop',
          );
          break;
        case LanPushDecodeFailure.payloadLengthMismatch:
        case LanPushDecodeFailure.malformedPayload:
          _log(
            LanPushLogLevel.warning,
            'LAN push receiver: malformed payload — drop',
          );
          break;
        case null:
          // Defensive — decodePushFrame guarantees failure non-null when isOk is false.
          break;
      }
      return;
    }
    final frame = result.frame!;
    if (frame.serverFingerprint != serverFingerprint) {
      // The HMAC verified, which means the sender knew the fingerprint —
      // but the frame claims a *different* fingerprint than the one we
      // paired with. That's a misconfiguration or a deliberate spoof.
      // Either way, refuse to surface it.
      _log(
        LanPushLogLevel.warning,
        'LAN push receiver: fingerprint mismatch — frame claims '
        '"${frame.serverFingerprint}" but we paired with '
        '"$serverFingerprint"; dropping',
      );
      return;
    }
    if (_seenIds.contains(frame.id)) {
      // Dedup hit — already delivered via WebSocket or another
      // datagram.
      return;
    }
    _seenIds.add(frame.id);
    _trimDedup();
    if (!_frameController.isClosed) {
      _frameController.add(frame);
    }
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    _active = false;
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    await _injectorSubscription?.cancel();
    _injectorSubscription = null;
    try {
      _socket?.close();
    } catch (_) {
      // socket.close() is documented as best-effort idempotent.
    }
    _socket = null;
  }

  /// Tear down the controller. Call after [stop] when the receiver is
  /// no longer needed (sign-out path).
  Future<void> dispose() async {
    await stop();
    if (!_frameController.isClosed) {
      await _frameController.close();
    }
  }

  void _log(
    LanPushLogLevel level,
    String message, {
    Map<String, Object?>? fields,
  }) {
    final l = logger;
    if (l != null) {
      l(level, message, fields: fields);
      return;
    }
    final lvl = switch (level) {
      LanPushLogLevel.info => 800,
      LanPushLogLevel.warning => 900,
      LanPushLogLevel.error => 1000,
    };
    developer.log(
      message + (fields == null ? '' : ' fields=$fields'),
      name: 'LanPushNotificationReceiver',
      level: lvl,
    );
  }
}

/// Test-only injection point — production wiring binds a real
/// `RawDatagramSocket`. Tests construct a `_TestInjector` that pushes
/// pre-encoded datagrams into the receiver without touching the
/// network stack.
class LanPushTestInjector {
  final Stream<Uint8List> datagrams;
  LanPushTestInjector(this.datagrams);
}
