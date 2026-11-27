import 'package:skotiq_remote_protocol/wire_models.dart';

import '../../../models/backend/backend_connection_state.dart';

/// The wait before a dropped link's reconnect attempt number [attempt]
/// (0-based): doubling from 1 s to 16 s, then 30 s for as long as it takes.
Duration hostLinkReconnectDelay(int attempt) =>
    _hostLinkReconnectRamp[attempt.clamp(0, _hostLinkReconnectRamp.length - 1)];

/// How long a dropped link is given before the client gives up on it: every
/// attempt of the ramp, then one full wait at its longest, so the first
/// steady attempt has had its time to answer.
final Duration hostLinkRetryWindow = _hostLinkReconnectRamp.fold(
  _hostLinkReconnectRamp.last,
  (total, wait) => total + wait,
);

const _hostLinkReconnectRamp = <Duration>[
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
  Duration(seconds: 16),
  Duration(seconds: 30),
];

/// The connection from this client to its imaging host.
abstract interface class HostLink {
  /// `http` or `https`.
  String get scheme;

  String get serverHost;

  int get serverPort;

  /// The certificate fingerprint this client pinned for the host, if any.
  String? get pinnedFingerprint;

  BackendConnectionState get connectionState;

  Stream<BackendConnectionState> get connectionStateStream;

  /// The token this client presents to the host, or null before pairing.
  String? get authToken;

  /// Whether the host said, when this client connected, that every client
  /// has to present a pairing credential. Null before the first connection
  /// and for a host that does not say.
  bool? get hostRequiresPairing;

  /// True once the host refused this client's token. Requests are pointless
  /// until the user pairs again.
  bool get isAuthTokenRejected;

  /// True when the host is reached over a Tailscale address rather than the
  /// local network.
  bool get isRemoteHost;

  Duration? get lastLatency;

  Stream<Duration> get latencyStream;

  Future<void> reconnectNow();

  Duration? get unansweredPingAge;

  void pauseWebSocketHeartbeatForAppLifecycle();

  void resumeWebSocketHeartbeatForAppLifecycle();

  /// Waits for a job the host queued (a catalog download, an autofocus run, a
  /// plate solve) to reach a terminal state.
  Future<RemoteJob> awaitJobCompletion(
    String jobId, {
    Duration timeout,
    Duration pollInterval,
  });
}

extension HostLinkAddress on HostLink {
  /// `host:port`, as shown to the user and typed when linking.
  String get address => '$serverHost:$serverPort';
}
