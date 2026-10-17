// Persistent MQTT 3.1.1 session for Home Assistant discovery.
//
// The notification MqttTransport is deliberately connect-publish-
// disconnect and PUBLISH-only; HA discovery needs the opposite: one
// long-lived session with
//   * a last-will (availability "offline") registered at CONNECT,
//   * retained PUBLISHes for discovery configs + states (QoS 0),
//   * SUBSCRIBE + incoming PUBLISH dispatch for command topics,
//   * PINGREQ keepalive so the broker doesn't drop us.
// Hand-rolled MQTT 3.1.1 subset, like `mqtt_transport.dart` (no external
// client package); will/subscribe support lives here because that transport's
// codec does not carry it.

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import '../../models/notification/transport_configs.dart';
import '../notification/transports/mqtt_transport.dart' show MqttSocketOpener;

Future<Socket> _defaultOpener(String host, int port, bool useTls) {
  if (useTls) return SecureSocket.connect(host, port);
  return Socket.connect(host, port);
}

/// Incoming application message from a subscribed topic.
typedef HaMqttMessageHandler = void Function(String topic, String payload);

class HaMqttSessionClient {
  final MqttTransportConfig broker;
  final String clientId;
  final String willTopic;
  final String willPayload;
  final HaMqttMessageHandler? onMessage;

  /// Fired once when the session drops (socket error/close). The owner
  /// is responsible for reconnecting.
  final void Function()? onDisconnected;

  final MqttSocketOpener _open;
  final Duration _connectTimeout;
  static const _keepAlive = Duration(seconds: 60);

  Socket? _socket;
  StreamSubscription<List<int>>? _subscription;
  final List<int> _buffer = [];
  Completer<_Packet>? _handshakeWaiter;
  Timer? _pingTimer;
  bool _connected = false;
  bool _closing = false;
  int _nextPacketId = 1;

  HaMqttSessionClient({
    required this.broker,
    required this.clientId,
    required this.willTopic,
    this.willPayload = 'offline',
    this.onMessage,
    this.onDisconnected,
    MqttSocketOpener? opener,
    Duration connectTimeout = const Duration(seconds: 10),
  }) : _open = opener ?? _defaultOpener,
       _connectTimeout = connectTimeout;

  bool get isConnected => _connected;

  Future<void> connect() async {
    if (_connected) return;
    _closing = false;
    final socket = await _open(
      broker.host,
      broker.port,
      broker.useTls,
    ).timeout(_connectTimeout);
    _socket = socket;
    _buffer.clear();
    _subscription = socket.listen(
      _onData,
      onError: (Object e) {
        _handleDrop(e);
      },
      onDone: () {
        _handleDrop(StateError('MQTT socket closed'));
      },
    );

    _handshakeWaiter = Completer<_Packet>();
    socket.add(_buildConnect());
    final connack = await _handshakeWaiter!.future.timeout(_connectTimeout);
    _handshakeWaiter = null;
    if (connack.type != 2) {
      throw Exception('Expected CONNACK, got packet type ${connack.type}');
    }
    if (connack.body.length < 2 || connack.body[1] != 0) {
      final rc = connack.body.length >= 2
          ? connack.body[1].toRadixString(16)
          : '??';
      throw Exception('MQTT broker rejected CONNECT (rc=0x$rc)');
    }
    _connected = true;
    _pingTimer = Timer.periodic(
      Duration(seconds: _keepAlive.inSeconds ~/ 2),
      (_) => _sendPing(),
    );
  }

  void publish(String topic, String payload, {bool retain = false}) {
    final socket = _socket;
    if (!_connected || socket == null) {
      throw StateError('MQTT session not connected');
    }
    // QoS 0 PUBLISH; retained for discovery configs + state topics so
    // HA restarts pick everything back up without a republish cycle.
    final variable = BytesBuilder()..add(_encodeString(topic));
    final headerByte = (3 << 4) | (retain ? 1 : 0);
    socket.add(
      _frame(
        headerByte,
        variable.toBytes(),
        Uint8List.fromList(utf8.encode(payload)),
      ),
    );
  }

  void subscribe(String topicFilter) {
    final socket = _socket;
    if (!_connected || socket == null) {
      throw StateError('MQTT session not connected');
    }
    final packetId = _nextPacketId++;
    if (_nextPacketId > 0xffff) _nextPacketId = 1;
    final variable = BytesBuilder()
      ..addByte((packetId >> 8) & 0xff)
      ..addByte(packetId & 0xff);
    final payload = BytesBuilder()
      ..add(_encodeString(topicFilter))
      ..addByte(0x00); // requested QoS 0
    // SUBSCRIBE fixed header is 0x82 (type 8, reserved bits 0010).
    socket.add(_frame(0x82, variable.toBytes(), payload.toBytes()));
    // SUBACK is consumed and dropped in _dispatch; QoS 0 commands don't
    // need confirmation bookkeeping.
  }

  /// Graceful shutdown: the caller should publish its "offline"
  /// availability first (the LWT only fires on ungraceful drops).
  Future<void> disconnect() async {
    _closing = true;
    _connected = false;
    _pingTimer?.cancel();
    _pingTimer = null;
    final socket = _socket;
    _socket = null;
    final sub = _subscription;
    _subscription = null;
    if (socket != null) {
      try {
        socket.add(Uint8List.fromList([0xe0, 0x00])); // DISCONNECT
        await socket.flush();
        await socket.close();
      } catch (_) {
        /* already gone */
      }
    }
    await sub?.cancel();
  }

  // Incoming data

  void _onData(List<int> bytes) {
    _buffer.addAll(bytes);
    while (true) {
      if (_buffer.length < 2) return;
      var multiplier = 1;
      var value = 0;
      var i = 1;
      while (true) {
        if (i >= _buffer.length) return;
        final b = _buffer[i];
        value += (b & 0x7f) * multiplier;
        multiplier *= 128;
        i++;
        if ((b & 0x80) == 0) break;
        if (multiplier > 128 * 128 * 128) {
          _handleDrop(Exception('MQTT remaining length malformed'));
          return;
        }
      }
      final totalLen = i + value;
      if (_buffer.length < totalLen) return;
      final firstByte = _buffer[0];
      final body = Uint8List.fromList(_buffer.sublist(i, totalLen));
      _buffer.removeRange(0, totalLen);
      _dispatch(firstByte, body);
    }
  }

  void _dispatch(int firstByte, Uint8List body) {
    final type = (firstByte >> 4) & 0x0f;
    switch (type) {
      case 2: // CONNACK
        _handshakeWaiter?.complete(_Packet(type, body));
        break;
      case 3: // PUBLISH (incoming command)
        _handleIncomingPublish(firstByte, body);
        break;
      case 9: // SUBACK
      case 13: // PINGRESP
        break;
      default:
        // QoS 0 everywhere: nothing else is expected; ignore.
        break;
    }
  }

  void _handleIncomingPublish(int firstByte, Uint8List body) {
    if (body.length < 2) return;
    final topicLen = (body[0] << 8) | body[1];
    if (body.length < 2 + topicLen) return;
    final topic = utf8.decode(
      body.sublist(2, 2 + topicLen),
      allowMalformed: true,
    );
    var offset = 2 + topicLen;
    final qos = (firstByte >> 1) & 0x03;
    if (qos > 0) {
      // Skip the packet id; we subscribed at QoS 0 so brokers should
      // downgrade, but be tolerant of ones that don't.
      offset += 2;
    }
    if (offset > body.length) return;
    final payload = utf8.decode(body.sublist(offset), allowMalformed: true);
    try {
      onMessage?.call(topic, payload);
    } catch (e) {
      developer.log(
        '[HomeAssistant/MQTT] Command handler failed: $e',
        name: 'HaMqttSessionClient',
        level: 900,
        error: e,
      );
    }
  }

  void _sendPing() {
    final socket = _socket;
    if (!_connected || socket == null) return;
    try {
      socket.add(Uint8List.fromList([0xc0, 0x00])); // PINGREQ
    } catch (e) {
      _handleDrop(e);
    }
  }

  void _handleDrop(Object error) {
    if (_closing) return;
    final wasConnected = _connected;
    _connected = false;
    _pingTimer?.cancel();
    _pingTimer = null;
    _handshakeWaiter?.completeError(error);
    _handshakeWaiter = null;
    final socket = _socket;
    _socket = null;
    _subscription?.cancel();
    _subscription = null;
    if (socket != null) {
      try {
        socket.destroy();
      } catch (_) {
        /* best effort */
      }
    }
    if (wasConnected) {
      developer.log(
        '[HomeAssistant/MQTT] Session dropped: $error',
        name: 'HaMqttSessionClient',
        level: 900,
      );
      onDisconnected?.call();
    }
  }

  // Frame builders (MQTT 3.1.1)

  Uint8List _buildConnect() {
    final variable = BytesBuilder()
      ..add(_encodeString('MQTT'))
      ..addByte(0x04); // protocol level 4 = 3.1.1

    var flags = 0x02; // clean session
    flags |= 0x04; // will flag
    flags |= 0x20; // will retain (availability topic stays retained)
    if (broker.username != null && broker.username!.isNotEmpty) flags |= 0x80;
    if (broker.password != null && broker.password!.isNotEmpty) flags |= 0x40;
    variable.addByte(flags);
    variable.addByte((_keepAlive.inSeconds >> 8) & 0xff);
    variable.addByte(_keepAlive.inSeconds & 0xff);

    final payload = BytesBuilder()
      ..add(_encodeString(clientId.isEmpty ? 'skotiq_ha' : clientId))
      ..add(_encodeString(willTopic))
      ..add(_encodeString(willPayload));
    if (broker.username != null && broker.username!.isNotEmpty) {
      payload.add(_encodeString(broker.username!));
    }
    if (broker.password != null && broker.password!.isNotEmpty) {
      payload.add(_encodeString(broker.password!));
    }
    return _frame(0x10, variable.toBytes(), payload.toBytes());
  }

  static Uint8List _frame(
    int firstByte,
    Uint8List variableHeader,
    Uint8List payload,
  ) {
    final out = BytesBuilder()..addByte(firstByte);
    out.add(_encodeRemainingLength(variableHeader.length + payload.length));
    out.add(variableHeader);
    out.add(payload);
    return out.toBytes();
  }

  static Uint8List _encodeString(String s) {
    final bytes = utf8.encode(s);
    if (bytes.length > 0xffff) {
      throw Exception('MQTT string too long (${bytes.length})');
    }
    final out = BytesBuilder()
      ..addByte((bytes.length >> 8) & 0xff)
      ..addByte(bytes.length & 0xff)
      ..add(bytes);
    return out.toBytes();
  }

  static Uint8List _encodeRemainingLength(int length) {
    final out = BytesBuilder();
    var x = length;
    do {
      var encoded = x % 128;
      x ~/= 128;
      if (x > 0) encoded |= 0x80;
      out.addByte(encoded);
    } while (x > 0);
    return out.toBytes();
  }
}

class _Packet {
  final int type;
  final Uint8List body;
  _Packet(this.type, this.body);
}
