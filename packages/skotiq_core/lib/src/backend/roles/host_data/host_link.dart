import '../../network_backend.dart' show BackendConnectionState;

/// The connection from this client to its imaging host.
abstract interface class HostLink {
  String get serverHost;

  int get serverPort;

  BackendConnectionState get connectionState;

  Stream<BackendConnectionState> get connectionStateStream;

  /// True once the host refused this client's token. Requests are pointless
  /// until the user pairs again.
  bool get isAuthTokenRejected;
}
