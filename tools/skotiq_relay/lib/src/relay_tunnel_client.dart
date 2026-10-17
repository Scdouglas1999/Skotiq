// Phone side of the relay tunnel.
//
// [RelayTunnelClient] connects to `<relay>/connect/<applianceId>` and then
// exposes the remote appliance's headless API as a LOCAL loopback TCP port:
// every connection accepted on 127.0.0.1:<localPort> becomes one mux stream
// through the relay, terminating at the appliance's local HTTP server.
//
// That design means the rest of the mobile app needs zero changes — the
// transport layer treats a relay connection as just another base URL
// (http://127.0.0.1:<localPort>), and everything (REST, the event
// WebSocket upgrade, pairing, HMAC tokens, even TLS if the appliance
// serves https) flows through unchanged, end-to-end.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'mux/mux_session.dart';
import 'relay_uplink.dart' show RelayUplink;
import 'socket_bridge.dart';

/// Structured failure from the relay's connect handshake (e.g.
/// `appliance_offline`, `bad_appliance_id`, `too_many_clients`).
class RelayTunnelException implements Exception {
  final String code;
  final String message;
  const RelayTunnelException(this.code, this.message);

  @override
  String toString() => 'RelayTunnelException($code): $message';
}

class RelayTunnelClient {
  final Uri relayUrl;
  final String applianceId;
  final WebSocket _ws;
  final ServerSocket _listener;
  final MuxSession _session;
  final void Function(String message)? _onLog;
  final Completer<void> _done = Completer<void>();
  bool _closed = false;

  RelayTunnelClient._(
    this.relayUrl,
    this.applianceId,
    this._ws,
    this._listener,
    this._session,
    this._onLog,
  );

  /// Loopback port carrying the tunnelled appliance API.
  int get localPort => _listener.port;

  /// Completes when the tunnel is torn down (relay/appliance went away or
  /// [close] was called). Never completes with an error.
  Future<void> get done => _done.future;

  bool get isClosed => _closed;

  /// Open a tunnel. Throws [RelayTunnelException] when the relay refuses
  /// (offline appliance, bad id, capacity), [TimeoutException]/[SocketException]
  /// when the relay itself is unreachable.
  static Future<RelayTunnelClient> connect({
    required Uri relayUrl,
    required String applianceId,
    Duration timeout = const Duration(seconds: 15),
    bool allowBadTlsCertificate = false,
    void Function(String message)? onLog,
  }) async {
    final normalized = RelayUplink.normalizeRelayUrl(relayUrl);
    final uri = normalized.replace(
      path: '${normalized.path}/connect/$applianceId',
    );

    HttpClient? client;
    if (allowBadTlsCertificate) {
      client = HttpClient()
        ..badCertificateCallback = (cert, host, port) => true;
    }
    final ws = await WebSocket.connect(
      uri.toString(),
      customClient: client,
    ).timeout(timeout);
    ws.pingInterval = const Duration(seconds: 20);

    final handshake = Completer<void>();
    RelayTunnelClient? tunnel;

    final session = MuxSession(
      send: ws.add,
      onControl: (message) {
        final op = message['op'];
        if (op == 'connected') {
          if (!handshake.isCompleted) handshake.complete();
        } else if (op == 'error') {
          final error = RelayTunnelException(
            '${message['code'] ?? 'error'}',
            '${message['message'] ?? 'relay refused the connection'}',
          );
          if (!handshake.isCompleted) {
            handshake.completeError(error);
          } else {
            // Post-handshake failure (appliance dropped offline): tear the
            // tunnel down; the app's connection monitor handles the rest.
            onLog?.call('relay tunnel error: $error');
            tunnel?.close();
          }
        }
      },
    );

    ws.listen(
      (message) {
        try {
          session.handleMessage(
            message is Uint8List
                ? message
                : Uint8List.fromList(message as List<int>),
          );
        } catch (e) {
          onLog?.call('relay tunnel protocol error: $e');
          ws.close(WebSocketStatus.protocolError, 'bad frame');
        }
      },
      onError: (Object e) {
        if (!handshake.isCompleted) handshake.completeError(e);
        tunnel?._teardown('relay connection error: $e');
      },
      onDone: () {
        if (!handshake.isCompleted) {
          handshake.completeError(
            const RelayTunnelException(
              'closed',
              'relay closed the connection during handshake',
            ),
          );
        }
        tunnel?._teardown('relay connection closed');
      },
      cancelOnError: false,
    );

    try {
      await handshake.future.timeout(timeout);
    } catch (_) {
      try {
        await ws.close();
      } catch (_) {}
      client?.close(force: true);
      rethrow;
    }

    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    tunnel = RelayTunnelClient._(
      normalized,
      applianceId,
      ws,
      listener,
      session,
      onLog,
    );
    listener.listen(
      tunnel._acceptLocalConnection,
      onError: (Object e) => onLog?.call('relay tunnel listener error: $e'),
      onDone: () => tunnel!._teardown('local listener closed'),
    );
    onLog?.call(
      'relay tunnel open: 127.0.0.1:${listener.port} -> $applianceId via '
      '$normalized',
    );
    return tunnel;
  }

  void _acceptLocalConnection(Socket socket) {
    if (_closed) {
      socket.destroy();
      return;
    }
    final stream = _session.openStream();
    bridgeSocketToMuxStream(socket, stream);
  }

  Future<void> close() async {
    _teardown('closed by caller');
    try {
      await _ws.close(WebSocketStatus.normalClosure, 'tunnel closed');
    } catch (_) {}
  }

  void _teardown(String reason) {
    if (_closed) return;
    _closed = true;
    _session.closeAll(reason);
    _listener.close();
    _onLog?.call('relay tunnel closed: $reason');
    if (!_done.isCompleted) _done.complete();
  }
}
