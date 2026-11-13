import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:skotiq_core/services.dart';

/// What the phone's own network link is: Wi-Fi, mobile data, both or none.
class NetworkServiceState {
  final List<ConnectivityResult> connectivityResults;
  final String? statusMessage;

  const NetworkServiceState({
    required this.connectivityResults,
    this.statusMessage,
  });

  bool get hasWifi => connectivityResults.contains(ConnectivityResult.wifi);
  bool get hasMobile => connectivityResults.contains(ConnectivityResult.mobile);
  bool get hasConnection =>
      connectivityResults.isNotEmpty &&
      !connectivityResults.every((r) => r == ConnectivityResult.none);
}

/// Reports the phone's network link. Which rig the phone is linked to, and
/// whether that link is alive, are the connect flow's and the backend's
/// WebSocket heartbeat's (see `rig_connection.dart`).
class NetworkService {
  static final NetworkService _instance = NetworkService._internal();
  factory NetworkService() => _instance;
  NetworkService._internal();

  final Connectivity _connectivity = Connectivity();
  StreamSubscription<ConnectivityResult>? _connectivitySubscription;

  final _stateController = StreamController<NetworkServiceState>.broadcast();
  NetworkServiceState _state = const NetworkServiceState(
    connectivityResults: [],
  );

  Stream<NetworkServiceState> get stateStream => _stateController.stream;
  NetworkServiceState get currentState => _state;

  bool _isInitialized = false;

  Future<void> initialize() async {
    if (_isInitialized) return;
    // connectivity_plus 5 reports one link at a time.
    _update([await _connectivity.checkConnectivity()]);
    _connectivitySubscription = _connectivity.onConnectivityChanged.listen(
      (result) {
        Log.info('Connectivity changed: $result', source: 'NetworkService');
        _update([result]);
      },
      onError: (Object error) {
        // Connectivity changes are missed until the OS emits again.
        Log.warning(
          'Connectivity stream error: $error',
          source: 'NetworkService',
        );
      },
    );
    _isInitialized = true;
  }

  Future<void> dispose() async {
    await _connectivitySubscription?.cancel();
    _connectivitySubscription = null;
    await _stateController.close();
    _isInitialized = false;
  }

  void _update(List<ConnectivityResult> results) {
    _state = NetworkServiceState(
      connectivityResults: results,
      statusMessage: _connectivityMessage(results),
    );
    if (!_stateController.isClosed) _stateController.add(_state);
  }

  String _connectivityMessage(List<ConnectivityResult> results) {
    if (results.isEmpty || results.every((r) => r == ConnectivityResult.none)) {
      return 'No network connection';
    }
    if (results.contains(ConnectivityResult.wifi)) return 'Connected via WiFi';
    if (results.contains(ConnectivityResult.mobile)) {
      return 'Connected via mobile data';
    }
    if (results.contains(ConnectivityResult.ethernet)) {
      return 'Connected via Ethernet';
    }
    return 'Network available';
  }

  bool get hasWifi => _state.hasWifi;

  bool get hasConnection => _state.hasConnection;
}
