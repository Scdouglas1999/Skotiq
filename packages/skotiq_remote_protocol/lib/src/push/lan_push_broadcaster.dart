// LAN UDP push broadcaster.
//
// Threat model
//
// PushNotificationService fires critical alerts (weather unsafe, sequence
// failed, guiding lost, mount runaway) over the headless WebSocket. A phone
// whose WS has dropped (Android battery firmware, iOS app suspended, Wi-Fi
// roam) never sees them. The goal is to make critical pushes
// reach backgrounded clients on the same LAN even when the WS is dropped.
//
// This module implements the **server side** of a small UDP fan-out
// protocol — broadcast on 255.255.255.255 plus multicast on the private
// 239.255.42.99 group on every active interface. The receiver lives at
// apps/mobile/lib/services/lan_push_notification_receiver.dart and feeds
// the result into MobileNotificationService so a foreground-service Android
// or a foreground iOS app surfaces the alert as an OS notification even
// when its WS is broken.
//
// **What attackers can do without HMAC:** any host on the same LAN can
// craft a packet that says "WEATHER UNSAFE — PARKING" and the phone would
// honour it, panicking the operator and possibly triggering a destructive
// counter-action through the user. This is a real attack on a coffee-shop
// or campground Wi-Fi where the imaging rig and a hostile device share an
// SSID.
//
// **Mitigation:** every datagram carries an HMAC-SHA256 over the JSON
// payload, keyed by `sha256("skotiq-push-v1:" + serverFingerprint)`.
// The server fingerprint is the SAME SHA-256 hex digest already used by
// /api/info and the pairing QR code (see ServerIdentity); the receiver
// already has it from the pairing flow. A LAN host that did not complete
// pairing does not have the fingerprint and cannot forge a valid HMAC.
//
// **What this does NOT defend against:**
//   - A LAN attacker who already paired (they have the fingerprint).
//   - Replay: an old "WEATHER UNSAFE" datagram replayed an hour later will
//     verify. The receiver mitigates this with the per-frame UUID + a
//     bounded LRU of seen IDs, and the surfaced notification reads
//     "delivered at <wall clock>" so a replayed frame from yesterday is
//     visually distinguishable.
//   - Confidentiality. Payloads are NOT encrypted — anyone on the LAN can
//     read "Sequence aborted: clouds detected." Push notifications already
//     leak this information through OS lock-screen banners; encrypting
//     the UDP path would just hide the leak from a packet capture, not
//     close it. If confidentiality matters, the operator should use a
//     wired/VPN LAN.
//
// Wire format (frame layout)
//
//   offset    bytes   field
//   --------  ------  ----------------------------------------------------
//   [0:4]     4       magic = "NSPP"  (Skotiq Push Protocol)
//   [4]       1       version = 0x01
//   [5]       1       severity: 0=info, 1=warning, 2=critical
//   [6:8]     2       payload length (u16 big-endian, max 65535)
//   [8:40]    32      HMAC-SHA256(hmacKey, payload bytes)
//   [40:..]   N       payload (JSON: title, body, id, timestamp, data,
//                     serverFingerprint)
//
// The HMAC key is `sha256("skotiq-push-v1:" + serverFingerprint)`.
// Both sides derive it identically, so no extra key exchange is required.
//
// Port assignments
//
//   45679  UDP — existing discovery (SkotiqDiscovery)
//   45680  TCP — existing OTA push receiver (skotiq_updater)
//   45681  UDP — THIS module (LAN push notification)
//
// 45681 was chosen because 45680 is already TCP-bound by the OTA receiver
// on every running desktop and we want to coexist on the same host.

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Default port for the LAN push notification protocol. Distinct from
/// `45679` (discovery) and `45680` (OTA push receiver).
const int kLanPushDefaultPort = 45681;

/// IPv4 broadcast address used as the simple-LAN fan-out target.
const String kLanPushBroadcastAddress = '255.255.255.255';

/// Private multicast group used for LAN push notifications. Falls inside
/// the 239.0.0.0/8 administratively-scoped block (RFC 2365) so it does
/// not leak across routed boundaries. Chosen to avoid collision with the
/// few well-known assignments on 239.255.x.x.
const String kLanPushMulticastAddress = '239.255.42.99';

/// Magic bytes that identify a Skotiq push notification datagram so
/// stray UDP traffic on the LAN is ignored before HMAC verification runs.
const String kLanPushMagic = 'NSPP';

/// Protocol version. Bump on a wire-format change.
const int kLanPushProtocolVersion = 0x01;

/// Severity code for `info`-class notifications.
const int kLanPushSeverityInfo = 0;

/// Severity code for `warning`-class notifications.
const int kLanPushSeverityWarning = 1;

/// Severity code for `critical`-class notifications.
const int kLanPushSeverityCritical = 2;

/// Maximum total datagram size (header + payload). Conservative to stay
/// well inside the smallest practical MTU minus IP+UDP overhead — we
/// don't want fragmentation on a LAN push.
const int kLanPushMaxDatagramBytes = 1400;

/// Maximum payload bytes (u16 length field).
const int kLanPushMaxPayloadBytes = 65535;

/// Header overhead: magic(4) + version(1) + severity(1) + len(2) + hmac(32) = 40.
const int kLanPushHeaderBytes = 40;

/// One push notification frame ready to be encoded onto the wire or
/// reconstructed from a decoded payload.
///
/// Why a dedicated type rather than the existing `PushNotification` model
/// from `push_notification_service.dart`: that model lives in
/// `skotiq_core` and has GUI-specific fields; the wire frame is the
/// minimum subset needed for the receiver to surface a notification.
/// Mapping happens at the broadcaster boundary.
class PushNotificationFrame {
  /// UUID v4. Stable across the WebSocket-delivered copy and the UDP
  /// fan-out copy so the mobile client can deduplicate exactly instead of
  /// approximately by (eventType + timeWindow).
  final String id;

  /// Severity label. One of `info`, `warning`, `critical`.
  final String severity;

  /// Short title surfaced as the notification's primary line.
  final String title;

  /// Longer body text.
  final String body;

  /// Free-form data payload. Keep this small — the whole frame must fit in
  /// [kLanPushMaxDatagramBytes].
  final Map<String, Object?> data;

  /// Wall-clock the alert was emitted.
  final DateTime timestamp;

  /// SHA-256 fingerprint of the server that emitted this frame. Receivers
  /// MUST cross-check this against the fingerprint they have for the
  /// paired server before surfacing the notification — otherwise a host
  /// that completed pairing with server A could deliver a forged alert
  /// "from" server B.
  final String serverFingerprint;

  const PushNotificationFrame({
    required this.id,
    required this.severity,
    required this.title,
    required this.body,
    required this.data,
    required this.timestamp,
    required this.serverFingerprint,
  });

  /// Severity code as written into the wire byte. An unknown label collapses to
  /// `info` rather than dropping the frame: the receiver must still be able to
  /// decode and display the message, and an unrecognised severity is not a
  /// security failure.
  int get severityCode {
    switch (severity) {
      case 'critical':
        return kLanPushSeverityCritical;
      case 'warning':
        return kLanPushSeverityWarning;
      default:
        return kLanPushSeverityInfo;
    }
  }

  Map<String, Object?> toPayloadJson() => <String, Object?>{
    'id': id,
    'severity': severity,
    'title': title,
    'body': body,
    'data': data,
    'timestamp': timestamp.toUtc().millisecondsSinceEpoch,
    'serverFingerprint': serverFingerprint,
  };

  /// Reconstruct a frame from a decoded JSON payload. Throws
  /// [FormatException] on missing fields — the caller (decode) catches
  /// these and rejects the datagram.
  factory PushNotificationFrame.fromPayloadJson(Map<String, dynamic> json) {
    final id = json['id'];
    final severity = json['severity'];
    final title = json['title'];
    final body = json['body'];
    final timestamp = json['timestamp'];
    final fingerprint = json['serverFingerprint'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('push frame: missing id');
    }
    if (severity is! String || severity.isEmpty) {
      throw const FormatException('push frame: missing severity');
    }
    if (title is! String) {
      throw const FormatException('push frame: missing title');
    }
    if (body is! String) {
      throw const FormatException('push frame: missing body');
    }
    if (timestamp is! int) {
      throw const FormatException('push frame: missing/invalid timestamp');
    }
    if (fingerprint is! String || fingerprint.isEmpty) {
      throw const FormatException('push frame: missing serverFingerprint');
    }
    final rawData = json['data'];
    final data = rawData is Map<String, dynamic>
        ? Map<String, Object?>.from(rawData)
        : const <String, Object?>{};
    return PushNotificationFrame(
      id: id,
      severity: severity,
      title: title,
      body: body,
      data: data,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        timestamp,
        isUtc: true,
      ).toLocal(),
      serverFingerprint: fingerprint,
    );
  }
}

/// Derive the HMAC key from a server fingerprint. Both sides call this
/// with the same fingerprint string and arrive at the same key, so the
/// HMAC over the payload binds the datagram to the paired server.
///
/// Why a fixed `skotiq-push-v1:` prefix: domain-separates this key
/// from any other use of the fingerprint (e.g., as a TLS pin) so an
/// attacker who somehow learns the HMAC key cannot reuse it for a
/// different protocol surface.
List<int> derivePushHmacKey(String serverFingerprint) {
  final input = utf8.encode('skotiq-push-v1:$serverFingerprint');
  return sha256.convert(input).bytes;
}

/// Encode a [PushNotificationFrame] into the framed wire format. The
/// returned bytes are ready to hand to `socket.send(...)`.
///
/// Throws [ArgumentError] when the payload would exceed
/// [kLanPushMaxPayloadBytes] or the total datagram would exceed
/// [kLanPushMaxDatagramBytes]. Callers are expected to keep `data`
/// small; the broadcaster doesn't chunk.
Uint8List encodePushFrame(
  PushNotificationFrame frame, {
  required List<int> hmacKey,
}) {
  final payloadBytes = utf8.encode(jsonEncode(frame.toPayloadJson()));
  if (payloadBytes.length > kLanPushMaxPayloadBytes) {
    throw ArgumentError(
      'Push payload too large: ${payloadBytes.length} > '
      '$kLanPushMaxPayloadBytes bytes. Reduce `data` map size.',
    );
  }
  final totalBytes = kLanPushHeaderBytes + payloadBytes.length;
  if (totalBytes > kLanPushMaxDatagramBytes) {
    throw ArgumentError(
      'Push datagram too large: $totalBytes > '
      '$kLanPushMaxDatagramBytes bytes. Reduce `data` map size.',
    );
  }

  final hmacBytes = Hmac(sha256, hmacKey).convert(payloadBytes).bytes;
  if (hmacBytes.length != 32) {
    // HMAC-SHA256 is always 32 bytes; this would be a crypto package bug.
    throw StateError(
      'HMAC-SHA256 returned ${hmacBytes.length} bytes (expected 32)',
    );
  }

  final out = Uint8List(totalBytes);
  final magic = utf8.encode(kLanPushMagic);
  out.setRange(0, 4, magic);
  out[4] = kLanPushProtocolVersion;
  out[5] = frame.severityCode;
  final lenView = ByteData.view(out.buffer);
  lenView.setUint16(6, payloadBytes.length, Endian.big);
  out.setRange(8, 40, hmacBytes);
  out.setRange(40, totalBytes, payloadBytes);
  return out;
}

/// Outcome of a [decodePushFrame] attempt. Tests need to distinguish the
/// failure modes (truncated header, bad HMAC, malformed payload) without
/// matching on exception messages.
enum LanPushDecodeFailure {
  truncatedHeader,
  badMagic,
  unsupportedVersion,
  payloadLengthMismatch,
  hmacMismatch,
  malformedPayload,
}

/// Result of decoding a wire datagram. Either holds a verified frame or
/// the categorised failure reason. Callers MUST check `frame != null`
/// before trusting any field — a frame with a non-null `failure` is
/// always null.
class LanPushDecodeResult {
  final PushNotificationFrame? frame;
  final LanPushDecodeFailure? failure;

  const LanPushDecodeResult.ok(this.frame) : failure = null;
  const LanPushDecodeResult.failed(this.failure) : frame = null;

  bool get isOk => frame != null;
}

/// Verify HMAC and decode a wire-format datagram. Returns a failure
/// result rather than throwing so the calling receive loop can log-and-
/// continue without a try/catch (kept hot-path branch-free).
LanPushDecodeResult decodePushFrame(
  Uint8List bytes, {
  required List<int> hmacKey,
}) {
  if (bytes.length < kLanPushHeaderBytes) {
    return const LanPushDecodeResult.failed(
      LanPushDecodeFailure.truncatedHeader,
    );
  }
  final magic = utf8.decode(bytes.sublist(0, 4), allowMalformed: true);
  if (magic != kLanPushMagic) {
    return const LanPushDecodeResult.failed(LanPushDecodeFailure.badMagic);
  }
  final version = bytes[4];
  if (version != kLanPushProtocolVersion) {
    return const LanPushDecodeResult.failed(
      LanPushDecodeFailure.unsupportedVersion,
    );
  }
  final view = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);
  final payloadLen = view.getUint16(6, Endian.big);
  if (bytes.length != kLanPushHeaderBytes + payloadLen) {
    return const LanPushDecodeResult.failed(
      LanPushDecodeFailure.payloadLengthMismatch,
    );
  }
  final receivedHmac = bytes.sublist(8, 40);
  final payloadBytes = bytes.sublist(40);
  final expectedHmac = Hmac(sha256, hmacKey).convert(payloadBytes).bytes;
  if (!_constantTimeEquals(receivedHmac, expectedHmac)) {
    return const LanPushDecodeResult.failed(LanPushDecodeFailure.hmacMismatch);
  }
  try {
    final decoded = jsonDecode(utf8.decode(payloadBytes));
    if (decoded is! Map<String, dynamic>) {
      return const LanPushDecodeResult.failed(
        LanPushDecodeFailure.malformedPayload,
      );
    }
    final frame = PushNotificationFrame.fromPayloadJson(decoded);
    return LanPushDecodeResult.ok(frame);
  } on FormatException {
    return const LanPushDecodeResult.failed(
      LanPushDecodeFailure.malformedPayload,
    );
  }
}

/// Constant-time byte comparison so HMAC verification does not leak
/// timing information about how many bytes matched.
bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Severity floor that controls which frames the broadcaster forwards.
/// Defaults to [LanPushSeverityFilter.critical] so the UDP fan-out
/// carries only the events that need to wake a sleeping client. Set to
/// [LanPushSeverityFilter.warning] to also forward `warning`-class
/// pushes; `LanPushSeverityFilter.info` is intended for tests.
enum LanPushSeverityFilter { info, warning, critical }

extension _SeverityFilterMatch on LanPushSeverityFilter {
  bool admits(int severityCode) {
    switch (this) {
      case LanPushSeverityFilter.info:
        return true;
      case LanPushSeverityFilter.warning:
        return severityCode >= kLanPushSeverityWarning;
      case LanPushSeverityFilter.critical:
        return severityCode >= kLanPushSeverityCritical;
    }
  }
}

/// Sink used by [LanPushBroadcaster] to send datagrams. Production binds
/// real `RawDatagramSocket`s; tests inject a recording sink so they can
/// assert the encoded bytes without going through the network stack.
abstract class LanPushDatagramSink {
  /// Send [bytes] to [address] on [port]. Implementations should not
  /// throw on transient errors (e.g. interface flap) — log and continue.
  void send(List<int> bytes, InternetAddress address, int port);

  /// Close any underlying socket handles. Idempotent.
  Future<void> close();
}

/// LAN UDP broadcaster for critical push notifications.
///
/// Lifecycle:
///   1. Construct with the server's fingerprint and the per-interface
///      port (default 45681).
///   2. Call [start] once — binds a UDP socket per active interface and
///      joins the multicast group on each.
///   3. Call [sendCriticalPush] for every critical-severity push that
///      should reach off-WS clients. The broadcaster filters by
///      [severityFilter] (default: critical only).
///   4. Call [stop] on shutdown.
///
/// Failure modes are surfaced via a logger rather than rethrown:
/// failing to bind one interface (e.g. transient sleep/wake) should
/// not bring the server down. Total failure (no interface bound) is
/// still represented — the broadcaster is marked inactive and every
/// subsequent [sendCriticalPush] logs a warning.
class LanPushBroadcaster {
  /// UDP port the broadcaster targets.
  final int port;

  /// SHA-256 server fingerprint. Used both to derive the HMAC key and to
  /// stamp each outgoing frame's `serverFingerprint` field.
  final String serverFingerprint;

  /// Severity floor. Frames at or above this severity get broadcast.
  final LanPushSeverityFilter severityFilter;

  /// Custom sink for tests. When null, real `RawDatagramSocket`s are
  /// bound on every active interface during [start].
  final LanPushDatagramSink? overrideSink;

  /// Logger sink. Production wires this to `LoggingService` via a
  /// closure; tests inject a recording closure.
  final void Function(
    LanPushLogLevel level,
    String message, {
    Map<String, Object?>? fields,
  })?
  logger;

  late final List<int> _hmacKey = derivePushHmacKey(serverFingerprint);

  // One sink per bound interface. Each sink hides the socket detail so
  // tests can swap them out wholesale.
  final List<LanPushDatagramSink> _sinks = [];

  // Real socket handles — kept separately so close() can call them
  // directly. Empty when [overrideSink] is supplied.
  final List<RawDatagramSocket> _sockets = [];

  bool _started = false;
  bool _active = false;

  LanPushBroadcaster({
    required this.serverFingerprint,
    this.port = kLanPushDefaultPort,
    this.severityFilter = LanPushSeverityFilter.critical,
    this.overrideSink,
    this.logger,
  });

  /// True between a successful [start] and a [stop]. Stays false if
  /// no interface bound during start, so callers can detect a total
  /// fan-out failure via this flag instead of by guessing from logs.
  bool get isActive => _active;

  /// True after [start] has been called at least once. Used to make the
  /// method idempotent.
  bool get isStarted => _started;

  /// Number of currently-active sinks (interfaces). Tests use this to
  /// assert the bind succeeded.
  int get activeSinkCount => _sinks.length;

  Future<void> start() async {
    if (_started) return;
    _started = true;

    final overrideSinkLocal = overrideSink;
    if (overrideSinkLocal != null) {
      _sinks.add(overrideSinkLocal);
      _active = true;
      _log(
        LanPushLogLevel.info,
        'LAN push broadcaster started (override sink)',
        fields: {'port': port},
      );
      return;
    }

    final interfaces = await _listInterfaces();
    if (interfaces.isEmpty) {
      _log(
        LanPushLogLevel.warning,
        'LAN push broadcaster: no IPv4 interfaces available; '
        'broadcaster will not fan out to LAN',
        fields: {'port': port},
      );
      return;
    }

    final multicastTarget = InternetAddress(kLanPushMulticastAddress);
    for (final interface in interfaces) {
      final ipv4 = interface.addresses
          .where((a) => a.type == InternetAddressType.IPv4)
          .toList();
      if (ipv4.isEmpty) continue;
      try {
        final socket = await RawDatagramSocket.bind(
          ipv4.first,
          0,
          reuseAddress: true,
        );
        socket.broadcastEnabled = true;
        try {
          socket.joinMulticast(multicastTarget, interface);
        } catch (e) {
          // Joining a multicast group can fail on interfaces that don't
          // support multicast (some virtual adapters). The unicast
          // broadcast path still works on the same socket, so log and
          // keep the socket open.
          _log(
            LanPushLogLevel.warning,
            'LAN push broadcaster: multicast join failed; continuing '
            'with broadcast-only fan-out on this interface',
            fields: {'interface': interface.name, 'error': '$e'},
          );
        }
        _sockets.add(socket);
        _sinks.add(_RawSocketSink(socket));
      } catch (e) {
        _log(
          LanPushLogLevel.warning,
          'LAN push broadcaster: bind failed on interface',
          fields: {
            'interface': interface.name,
            'address': ipv4.first.address,
            'error': '$e',
          },
        );
      }
    }

    _active = _sinks.isNotEmpty;
    if (_active) {
      _log(
        LanPushLogLevel.info,
        'LAN push broadcaster started',
        fields: {'port': port, 'interfaces': _sinks.length},
      );
    } else {
      _log(
        LanPushLogLevel.warning,
        'LAN push broadcaster: no interfaces bound; will not fan out',
        fields: {'port': port},
      );
    }
  }

  Future<List<NetworkInterface>> _listInterfaces() async {
    try {
      return await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
    } catch (e) {
      _log(
        LanPushLogLevel.warning,
        'LAN push broadcaster: failed to enumerate interfaces',
        fields: {'error': '$e'},
      );
      return const <NetworkInterface>[];
    }
  }

  /// Fan out [frame] to broadcast + multicast addresses on every bound
  /// interface. The frame's [PushNotificationFrame.serverFingerprint] is
  /// overwritten with the broadcaster's fingerprint so a caller passing a
  /// stale or wrong value still emits a verifiable frame.
  Future<void> sendCriticalPush(PushNotificationFrame frame) async {
    if (!_started) {
      _log(
        LanPushLogLevel.warning,
        'LAN push broadcaster: sendCriticalPush before start() — dropping',
        fields: {'id': frame.id},
      );
      return;
    }
    final stamped = PushNotificationFrame(
      id: frame.id,
      severity: frame.severity,
      title: frame.title,
      body: frame.body,
      data: frame.data,
      timestamp: frame.timestamp,
      serverFingerprint: serverFingerprint,
    );
    if (!severityFilter.admits(stamped.severityCode)) {
      return;
    }
    if (_sinks.isEmpty) {
      _log(
        LanPushLogLevel.warning,
        'LAN push broadcaster: no sinks; cannot forward push',
        fields: {'id': stamped.id, 'severity': stamped.severity},
      );
      return;
    }
    final Uint8List bytes;
    try {
      bytes = encodePushFrame(stamped, hmacKey: _hmacKey);
    } catch (e) {
      _log(
        LanPushLogLevel.warning,
        'LAN push broadcaster: encode failed — dropping frame',
        fields: {'id': stamped.id, 'error': '$e'},
      );
      return;
    }

    final broadcastAddr = InternetAddress(kLanPushBroadcastAddress);
    final multicastAddr = InternetAddress(kLanPushMulticastAddress);
    for (final sink in _sinks) {
      _safeSend(sink, bytes, broadcastAddr);
      _safeSend(sink, bytes, multicastAddr);
    }
  }

  /// Send through [sink], swallowing transport-layer failures so one bad
  /// interface doesn't abort the fan-out to the others. The default
  /// `_RawSocketSink` already catches `socket.send` errors internally;
  /// this is a belt-and-braces guard for custom sinks (tests, future
  /// overrides) so a sink that throws from its `send` doesn't take down
  /// the broadcaster.
  void _safeSend(
    LanPushDatagramSink sink,
    Uint8List bytes,
    InternetAddress address,
  ) {
    try {
      sink.send(bytes, address, port);
    } catch (e) {
      _log(
        LanPushLogLevel.warning,
        'LAN push broadcaster: sink send failed',
        fields: {'address': address.address, 'error': '$e'},
      );
    }
  }

  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    _active = false;
    for (final sink in _sinks) {
      try {
        await sink.close();
      } catch (e) {
        _log(
          LanPushLogLevel.warning,
          'LAN push broadcaster: error closing sink',
          fields: {'error': '$e'},
        );
      }
    }
    _sinks.clear();
    _sockets.clear();
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
      name: 'LanPushBroadcaster',
      level: lvl,
    );
  }
}

/// Logging levels surfaced by the broadcaster to its host logger. Kept
/// independent of any specific logger implementation so this file does
/// not pull `skotiq_core` (which depends on this package's siblings).
enum LanPushLogLevel { info, warning, error }

class _RawSocketSink implements LanPushDatagramSink {
  final RawDatagramSocket socket;

  _RawSocketSink(this.socket);

  @override
  void send(List<int> bytes, InternetAddress address, int port) {
    try {
      socket.send(bytes, address, port);
    } catch (e) {
      // Per-send transport errors (interface lost, no route to host) are
      // expected across sleep/wake. The host logger is not reachable here;
      // a socket that always fails surfaces as a missing notification on
      // the client. Nothing rethrows — losing one frame on one socket must
      // not abort the fan-out to the remaining sinks.
      developer.log(
        'LanPush datagram send failed: $e',
        name: 'LanPushBroadcaster',
        level: 900,
      );
    }
  }

  @override
  Future<void> close() async {
    try {
      socket.close();
    } catch (_) {
      // RawDatagramSocket.close() is documented as idempotent and never
      // throws on normal shutdown; if it does we cannot meaningfully
      // recover.
    }
  }
}
