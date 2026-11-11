import 'package:skotiq_core/skotiq_core.dart';

import '../../network_backend.dart' show BackendConnectionState;

/// The connection from this client to its imaging host.
abstract interface class HostLink {
  /// `http` or `https`.
  String get scheme;

  String get serverHost;

  int get serverPort;

  BackendConnectionState get connectionState;

  Stream<BackendConnectionState> get connectionStateStream;

  /// The token this client presents to the host, or null before pairing.
  String? get authToken;

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
}

extension HostLinkAddress on HostLink {
  /// `host:port`, as shown to the user and typed when linking.
  String get address => '$serverHost:$serverPort';
}
