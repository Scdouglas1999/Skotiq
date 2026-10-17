// Appliance side of the relay tunnel.
//
// [RelayUplink] maintains ONE outbound WebSocket to a self-hosted relay
// (reconnecting with exponential backoff), registers with the relay key
// (minted by the relay on first contact and persisted locally), and proxies
// every inbound mux stream to the local headless HTTP server — including
// WebSocket upgrades, which are just bytes at this layer.
//
// Consumed by apps/desktop/lib/main_headless.dart via the
// skotiq_remote_protocol re-export.

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'mux/mux_session.dart';
import 'relay_credentials.dart';
import 'socket_bridge.dart';

enum RelayUplinkState {
  stopped,
  connecting,
  registering,
  connected,
  waitingToRetry,

  /// Terminal: the relay rejected our stored credentials. Retrying would
  /// loop forever; the operator must delete the credentials file (minting
  /// a fresh appliance id) or fix the relay's state file.
  authFailed,
}

class RelayUplinkStatus {
  final RelayUplinkState state;
  final String? applianceId;
  final String? lastError;

  const RelayUplinkStatus(this.state, {this.applianceId, this.lastError});

  @override
  String toString() =>
      'RelayUplinkStatus(${state.name}'
      '${applianceId != null ? ', id=$applianceId' : ''}'
      '${lastError != null ? ', error=$lastError' : ''})';
}

class RelayUplink {
  /// Relay base URL. Accepts ws(s):// or http(s)://; http(s) is mapped to
  /// the matching WebSocket scheme. A path prefix is preserved so the relay
  /// can live behind a reverse-proxy subpath.
  final Uri relayUrl;

  /// Local headless API endpoint streams are proxied to.
  final String localHost;
  final int localPort;

  final RelayCredentialsStore credentialsStore;
  final void Function(String message)? onLog;
  final void Function(RelayUplinkStatus status)? onStatus;
  final Duration initialBackoff;
  final Duration maxBackoff;

  /// Allow self-signed relay TLS certs. Off by default — only enable for
  /// relays you operate yourself.
  final bool allowBadTlsCertificate;

  bool _running = false;
  WebSocket? _ws;
  MuxSession? _session;
  String? _applianceId;
  RelayUplinkStatus _status = const RelayUplinkStatus(RelayUplinkState.stopped);
  Future<void>? _runLoop;

  RelayUplink({
    required Uri relayUrl,
    required this.localPort,
    required this.credentialsStore,
    this.localHost = '127.0.0.1',
    this.onLog,
    this.onStatus,
    this.initialBackoff = const Duration(seconds: 2),
    this.maxBackoff = const Duration(seconds: 60),
    this.allowBadTlsCertificate = false,
  }) : relayUrl = normalizeRelayUrl(relayUrl);

  RelayUplinkStatus get status => _status;
  String? get applianceId => _applianceId;

  /// Map http(s) onto ws(s) and strip trailing slashes so endpoint paths
  /// can be appended uniformly. Throws [ArgumentError] on anything else.
  static Uri normalizeRelayUrl(Uri url) {
    final scheme = switch (url.scheme) {
      'ws' || 'http' => 'ws',
      'wss' || 'https' => 'wss',
      _ => throw ArgumentError.value(
        url,
        'relayUrl',
        'scheme must be ws, wss, http, or https',
      ),
    };
    final path = url.path.replaceAll(RegExp(r'/+$'), '');
    return url.replace(scheme: scheme, path: path);
  }

  Uri _endpoint(String suffix) =>
      relayUrl.replace(path: '${relayUrl.path}$suffix');

  void start() {
    if (_running) return;
    _running = true;
    _runLoop = _run();
  }

  Future<void> stop() async {
    _running = false;
    _setStatus(const RelayUplinkStatus(RelayUplinkState.stopped));
    final ws = _ws;
    _ws = null;
    _session?.closeAll('uplink stopped');
    _session = null;
    if (ws != null) {
      try {
        await ws.close(WebSocketStatus.goingAway, 'uplink stopped');
      } catch (_) {}
    }
    await _runLoop;
    _runLoop = null;
  }

  Future<void> _run() async {
    var backoff = initialBackoff;
    final jitter = Random();
    while (_running) {
      try {
        _setStatus(
          RelayUplinkStatus(
            RelayUplinkState.connecting,
            applianceId: _applianceId,
          ),
        );
        await _connectOnce();
        // Clean session end (relay restarted, network blip): reset backoff
        // because we did get fully connected.
        backoff = initialBackoff;
      } on _RelayAuthFailure catch (e) {
        _log(
          'relay refused stored credentials: ${e.message}. '
          'Delete the relay credentials file to mint a new appliance id, '
          'or restore the relay state file.',
        );
        _setStatus(
          RelayUplinkStatus(
            RelayUplinkState.authFailed,
            applianceId: _applianceId,
            lastError: e.message,
          ),
        );
        return; // terminal — retrying cannot succeed
      } catch (e) {
        if (!_running) break;
        _log('relay uplink attempt failed: $e');
        _setStatus(
          RelayUplinkStatus(
            RelayUplinkState.waitingToRetry,
            applianceId: _applianceId,
            lastError: '$e',
          ),
        );
        final delayMs =
            backoff.inMilliseconds +
            jitter.nextInt(1 + backoff.inMilliseconds ~/ 4);
        await Future<void>.delayed(Duration(milliseconds: delayMs));
        final doubled = backoff * 2;
        backoff = doubled > maxBackoff ? maxBackoff : doubled;
        continue;
      }
      if (_running) {
        // Connected session ended without an exception — reconnect promptly.
        _setStatus(
          RelayUplinkStatus(
            RelayUplinkState.waitingToRetry,
            applianceId: _applianceId,
            lastError: 'relay connection closed',
          ),
        );
        await Future<void>.delayed(initialBackoff);
      }
    }
  }

  Future<void> _connectOnce() async {
    final uri = _endpoint('/uplink');
    HttpClient? client;
    if (allowBadTlsCertificate) {
      client = HttpClient()
        ..badCertificateCallback = (cert, host, port) => true;
    }
    final ws = await WebSocket.connect(
      uri.toString(),
      customClient: client,
    ).timeout(const Duration(seconds: 20));
    ws.pingInterval = const Duration(seconds: 20);
    _ws = ws;

    final registered = Completer<Map<String, dynamic>>();
    final session = MuxSession(
      send: ws.add,
      onStream: _acceptStream,
      onControl: (message) {
        final op = message['op'];
        if (op == 'registered') {
          if (!registered.isCompleted) registered.complete(message);
        } else if (op == 'error') {
          final code = message['code'];
          final text = '${message['message'] ?? code}';
          final error = code == 'auth_failed'
              ? _RelayAuthFailure(text)
              : Exception('relay error [$code]: $text');
          if (!registered.isCompleted) {
            registered.completeError(error);
          } else {
            _log('relay reported error after registration: [$code] $text');
          }
        }
      },
    );
    _session = session;

    final wsDone = Completer<void>();
    ws.listen(
      (message) {
        try {
          session.handleMessage(
            message is Uint8List
                ? message
                : Uint8List.fromList(message as List<int>),
          );
        } catch (e) {
          _log('protocol error from relay: $e');
          ws.close(WebSocketStatus.protocolError, 'bad frame');
        }
      },
      onError: (Object e) {
        if (!wsDone.isCompleted) wsDone.completeError(e);
      },
      onDone: () {
        if (!wsDone.isCompleted) wsDone.complete();
      },
      cancelOnError: true,
    );

    try {
      _setStatus(
        RelayUplinkStatus(
          RelayUplinkState.registering,
          applianceId: _applianceId,
        ),
      );
      final stored = await credentialsStore.load();
      session.sendControl({
        'op': 'register',
        if (stored != null) 'applianceId': stored.applianceId,
        if (stored != null) 'secret': stored.secret,
      });

      final reply = await registered.future.timeout(
        const Duration(seconds: 15),
      );
      final id = reply['applianceId'];
      if (id is! String || id.isEmpty) {
        throw Exception('relay registration reply lacked an applianceId');
      }
      _applianceId = id;
      final mintedSecret = reply['secret'];
      if (mintedSecret is String && mintedSecret.isNotEmpty) {
        await credentialsStore.save(
          RelayCredentials(applianceId: id, secret: mintedSecret),
        );
        _log('registered NEW appliance id with relay: $id');
      }
      _setStatus(
        RelayUplinkStatus(RelayUplinkState.connected, applianceId: id),
      );
      _log('relay uplink connected ($uri, appliance id $id)');

      await wsDone.future;
    } finally {
      session.closeAll('relay connection closed');
      if (identical(_session, session)) _session = null;
      if (identical(_ws, ws)) _ws = null;
      try {
        await ws.close();
      } catch (_) {}
      client?.close(force: true);
    }
  }

  /// New logical stream from a phone: dial the local headless server and
  /// pump bytes until either side is done.
  void _acceptStream(MuxStream stream) {
    Socket.connect(localHost, localPort, timeout: const Duration(seconds: 10))
        .then((socket) => bridgeSocketToMuxStream(socket, stream))
        .catchError((Object e) {
          _log('failed to reach local server $localHost:$localPort: $e');
          stream.reset('local server unreachable');
        });
  }

  void _setStatus(RelayUplinkStatus status) {
    _status = status;
    onStatus?.call(status);
  }

  void _log(String message) => onLog?.call(message);
}

class _RelayAuthFailure implements Exception {
  final String message;
  _RelayAuthFailure(this.message);

  @override
  String toString() => message;
}
