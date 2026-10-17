import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Result of a single NTP query.
class TimeSyncResult {
  /// Local clock offset relative to the NTP server, in seconds.
  ///
  /// Positive means the local clock is ahead of network time; negative
  /// means it lags. The pre-flight rule treats `|offset|` as the drift
  /// magnitude.
  final double offsetSeconds;

  /// Server we queried. Useful for diagnostics surfaces ("clock is 47 s
  /// ahead of pool.ntp.org").
  final String server;

  /// Round-trip time to the server. Surfaced for diagnostics so a user
  /// can sanity-check whether the offset is dominated by network latency
  /// (e.g. behind a slow VPN).
  final Duration roundTrip;

  const TimeSyncResult({
    required this.offsetSeconds,
    required this.server,
    required this.roundTrip,
  });

  double get absOffsetSeconds => offsetSeconds.abs();
}

/// Lightweight NTP client (RFC-5905 short-form) for the pre-flight
/// time-sync check. Sends a single UDP request to `pool.ntp.org` (or a
/// caller-supplied host) and computes the offset using the standard
/// `(t2 - t1 + t3 - t4) / 2` formula.
///
/// We deliberately do NOT pull in `package:ntp` — that dependency drags
/// in additional code we don't need, and the protocol is small enough
/// that a direct implementation here is easier to audit and to mock in
/// tests.
class TimeSyncService {
  /// Default NTP host. Public pool, anycast, low-latency for most
  /// observers.
  static const String defaultHost = 'pool.ntp.org';

  /// Difference between the NTP epoch (1900-01-01) and the Unix epoch
  /// (1970-01-01), in seconds. Used to convert NTP timestamps to Unix
  /// time. 70 years × 365.25 days × 86400 s ≈ 2208988800 s.
  static const int ntpEpochOffsetSecs = 2208988800;

  final Duration timeout;
  final String host;

  const TimeSyncService({
    this.host = defaultHost,
    this.timeout = const Duration(seconds: 3),
  });

  /// Query the NTP server and return the clock offset.
  ///
  /// Throws on I/O failure / DNS failure / timeout. Callers should
  /// catch and surface as a `info` issue ("could not contact NTP
  /// server").
  Future<TimeSyncResult> queryOffset() async {
    final addresses = await InternetAddress.lookup(host);
    if (addresses.isEmpty) {
      throw const SocketException(
        'No A/AAAA records returned for NTP host lookup',
      );
    }
    final address = addresses.first;

    final socket = await RawDatagramSocket.bind(
      address.type == InternetAddressType.IPv6
          ? InternetAddress.anyIPv6
          : InternetAddress.anyIPv4,
      0,
    );

    try {
      // Build a minimal NTPv4 client request: LI=0 (no warning), VN=4,
      // Mode=3 (client). All other fields zero.
      final packet = Uint8List(48);
      packet[0] = 0x1B; // 0b00_100_011

      final sendTime = DateTime.now();
      socket.send(packet, address, 123);

      // Wait for the response. Reusing the socket's stream is awkward,
      // so we poll with a deadline.
      final deadline = sendTime.add(timeout);
      Datagram? response;
      while (response == null && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        response = socket.receive();
      }

      if (response == null) {
        throw TimeoutException('NTP query to $host timed out', timeout);
      }

      final recvTime = DateTime.now();
      final data = response.data;
      if (data.length < 48) {
        throw FormatException('NTP response too short (${data.length} bytes)');
      }

      // Receive timestamp (server clock at request arrival) — bytes 32..39.
      final t2 = _readNtpTimestamp(data, 32);
      // Transmit timestamp (server clock at response send)  — bytes 40..47.
      final t3 = _readNtpTimestamp(data, 40);
      final t1 = sendTime.millisecondsSinceEpoch / 1000.0;
      final t4 = recvTime.millisecondsSinceEpoch / 1000.0;

      // Standard NTP offset formula. Average of forward and reverse
      // half-trip skew. Positive => local clock is ahead.
      final offset = ((t2 - t1) + (t3 - t4)) / 2.0;
      final roundTrip = Duration(microseconds: ((t4 - t1) * 1000000).round());

      return TimeSyncResult(
        // NTP convention: server-minus-local => positive offset means
        // server is ahead, i.e. local clock LAGS. Most callers expect
        // "how far is my clock ahead of network time?" — invert so a
        // positive value means "local clock is fast".
        offsetSeconds: -offset,
        server: host,
        roundTrip: roundTrip,
      );
    } finally {
      socket.close();
    }
  }

  /// Parse a 64-bit NTP timestamp at [start] into seconds since the
  /// Unix epoch.
  static double _readNtpTimestamp(List<int> data, int start) {
    final secs =
        (data[start] << 24) |
        (data[start + 1] << 16) |
        (data[start + 2] << 8) |
        data[start + 3];
    final frac =
        (data[start + 4] << 24) |
        (data[start + 5] << 16) |
        (data[start + 6] << 8) |
        data[start + 7];
    // Unsigned reinterpret of secs (Dart int is signed by default;
    // shifts above are safe for values < 2^31 but we coerce just in
    // case a future timestamp's high bit is set).
    final secsUnsigned = secs & 0xFFFFFFFF;
    return (secsUnsigned - ntpEpochOffsetSecs) + (frac / 0xFFFFFFFF);
  }
}

/// Test seam — production callers should use [TimeSyncService] directly,
/// tests can pass a fake that implements this interface.
abstract class TimeSyncProbe {
  Future<TimeSyncResult> queryOffset();
}

/// Adapter so [TimeSyncService] satisfies [TimeSyncProbe] without
/// declaring the interface on the service directly (the service can
/// still be used standalone).
class TimeSyncServiceProbe implements TimeSyncProbe {
  final TimeSyncService _service;
  const TimeSyncServiceProbe(this._service);

  @override
  Future<TimeSyncResult> queryOffset() => _service.queryOffset();
}
