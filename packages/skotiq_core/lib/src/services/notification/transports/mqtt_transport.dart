// MQTT 3.1.1 PUBLISH-only transport.
//
// Hand-rolled because nothing here subscribes: one short JSON message per
// notification, then disconnect. A full mqtt_client package would add several
// hundred KB of dependencies for behaviour this transport does not use. The
// frame format implemented is the small subset of MQTT 3.1.1 §3.1 CONNECT /
// §3.3 PUBLISH / §3.14 DISCONNECT:
//
//     CONNECT  -> server CONNACK (success = 0x00)
//     PUBLISH  (QoS 0 fire-and-forget — no PUBACK round trip)
//     PUBLISH  (QoS 1 -> server PUBACK; we wait for it)
//     DISCONNECT
//
// QoS 2 is intentionally not implemented; a user choice of 2 downgrades to 1
// (logged) because the multi-message PUBREC/PUBREL/PUBCOMP handshake adds
// latency this transport does not need.

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import '../../../models/notification/notification_categories.dart';
import '../../../models/notification/transport_configs.dart';
import 'notification_transport.dart';

/// Strategy hook so tests can substitute a fake socket.
typedef MqttSocketOpener =
    Future<Socket> Function(String host, int port, bool useTls);

Future<Socket> _defaultMqttOpener(String host, int port, bool useTls) {
  if (useTls) return SecureSocket.connect(host, port);
  return Socket.connect(host, port);
}

class MqttTransport extends NotificationTransport {
  MqttTransportConfig _config;
  final Duration _timeout;
  final MqttSocketOpener _open;

  MqttTransport({
    required MqttTransportConfig config,
    Duration timeout = const Duration(seconds: 10),
    MqttSocketOpener? opener,
  }) : _config = config,
       _timeout = timeout,
       _open = opener ?? _defaultMqttOpener;

  @override
  NotificationTransportKind get kind => NotificationTransportKind.mqtt;

  @override
  String get name => 'MQTT';

  @override
  bool get isConfigured => _config.isConfigured;

  void updateConfig(MqttTransportConfig config) {
    _config = config;
  }

  MqttTransportConfig get config => _config;

  @override
  Future<NotificationResult> send({
    required NotificationCategory category,
    required String title,
    required String body,
  }) async {
    if (!isConfigured) {
      return NotificationResult.fail('MQTT not configured');
    }
    try {
      return await _runSession(category, title, body).timeout(_timeout);
    } on TimeoutException {
      return NotificationResult.fail(
        'MQTT session timed out after ${_timeout.inSeconds}s',
      );
    } catch (e) {
      developer.log(
        '[Notifications/MQTT] Send failed: $e',
        name: 'MqttTransport',
        level: 1000,
        error: e,
      );
      return NotificationResult.fail(e.toString());
    }
  }

  Future<NotificationResult> _runSession(
    NotificationCategory category,
    String title,
    String body,
  ) async {
    final socket = await _open(_config.host, _config.port, _config.useTls);
    final session = _MqttSession(socket);
    try {
      socket.add(_buildConnectPacket(_config));
      final connack = await session.readPacket();
      if (connack.type != _MqttPacketType.connack) {
        throw Exception('Expected CONNACK, got ${connack.type}');
      }
      // CONNACK: byte 1 = session-present flags, byte 2 = return code.
      // 0x00 = accepted; non-zero rejects.
      if (connack.payload.length != 2 ||
          (connack.payload[0] & 0xfe) != 0 ||
          connack.payload[1] != 0) {
        final rc = connack.payload.length >= 2
            ? connack.payload[1].toRadixString(16)
            : '??';
        throw Exception('MQTT broker returned invalid CONNACK (rc=0x$rc)');
      }

      final qos = (_config.qos < 0 || _config.qos > 2) ? 0 : _config.qos;
      final effectiveQos = qos == 2 ? 1 : qos;
      if (qos == 2) {
        developer.log(
          '[Notifications/MQTT] QoS 2 downgraded to QoS 1 (PUBREC/PUBREL not implemented).',
          name: 'MqttTransport',
          level: 800,
        );
      }

      final payload = jsonEncode({
        'source': 'skotiq',
        'category': category.storageKey,
        'categoryLabel': category.label,
        'title': title,
        'body': body,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      });

      const packetId = 1;
      socket.add(
        _buildPublishPacket(
          topic: _config.topic,
          payload: utf8.encode(payload),
          qos: effectiveQos,
          retain: _config.retain,
          packetId: packetId,
        ),
      );

      if (effectiveQos == 1) {
        final puback = await session.readPacket();
        if (puback.type != _MqttPacketType.puback) {
          throw Exception('Expected PUBACK, got ${puback.type}');
        }
        if (puback.payload.length != 2 ||
            puback.payload[0] != 0 ||
            puback.payload[1] != packetId) {
          throw Exception('MQTT broker returned PUBACK for the wrong packet');
        }
      }

      socket.add(_buildDisconnectPacket());
      await socket.flush();
      await socket.close();
      return NotificationResult.ok();
    } catch (e) {
      try {
        await socket.close();
      } catch (_) {
        /* already closed */
      }
      rethrow;
    } finally {
      session.dispose();
    }
  }
}

// Frame builders + reader

enum _MqttPacketType { connack, puback, unknown }

class _MqttPacket {
  final _MqttPacketType type;
  final Uint8List payload;
  _MqttPacket(this.type, this.payload);
}

class _MqttSession {
  final Socket _socket;
  late StreamSubscription<List<int>> _subscription;
  final List<int> _buffer = [];
  final List<Completer<_MqttPacket>> _waiters = [];
  final List<_MqttPacket> _pendingPackets = [];
  Object? _streamError;

  _MqttSession(this._socket) {
    _subscription = _socket.listen(_onData, onError: _onError, onDone: _onDone);
  }

  void _onData(List<int> bytes) {
    try {
      _buffer.addAll(bytes);
      while (true) {
        if (_buffer.isEmpty) return;
        // Variable-length remaining-length field.
        var multiplier = 1;
        var value = 0;
        var i = 1;
        while (true) {
          if (i >= _buffer.length) return; // need more bytes
          final b = _buffer[i];
          value += (b & 0x7f) * multiplier;
          multiplier *= 128;
          i++;
          if ((b & 0x80) == 0) break;
          if (multiplier > 128 * 128 * 128) {
            throw const FormatException('MQTT remaining length malformed');
          }
        }
        final totalLen = i + value;
        if (_buffer.length < totalLen) return; // wait for more bytes
        final firstByte = _buffer[0];
        final type = (firstByte >> 4) & 0x0f;
        final payload = Uint8List.fromList(_buffer.sublist(i, totalLen));
        _buffer.removeRange(0, totalLen);
        final packet = _MqttPacket(_decodeType(type), payload);
        if (_waiters.isNotEmpty) {
          _waiters.removeAt(0).complete(packet);
        } else {
          // Brokers can respond between socket.add() and readPacket(). Keep
          // that response instead of dropping it and timing out a healthy
          // connection.
          _pendingPackets.add(packet);
        }
      }
    } catch (error) {
      _onError(error);
    }
  }

  _MqttPacketType _decodeType(int t) {
    if (t == 2) return _MqttPacketType.connack;
    if (t == 4) return _MqttPacketType.puback;
    return _MqttPacketType.unknown;
  }

  void _onError(Object e) {
    _streamError = e;
    for (final w in _waiters) {
      w.completeError(e);
    }
    _waiters.clear();
  }

  void _onDone() {
    final err =
        _streamError ?? StateError('MQTT socket closed before reply arrived');
    for (final w in _waiters) {
      w.completeError(err);
    }
    _waiters.clear();
  }

  Future<_MqttPacket> readPacket() {
    if (_pendingPackets.isNotEmpty) {
      return Future.value(_pendingPackets.removeAt(0));
    }
    if (_streamError != null) {
      return Future.error(_streamError!);
    }
    final completer = Completer<_MqttPacket>();
    _waiters.add(completer);
    return completer.future;
  }

  void dispose() {
    _subscription.cancel();
  }
}

Uint8List _buildConnectPacket(MqttTransportConfig cfg) {
  final variable = BytesBuilder();
  // Protocol name "MQTT" (MQTT 3.1.1)
  variable.add(_encodeString('MQTT'));
  variable.addByte(0x04); // protocol level (4 = 3.1.1)

  // Connect flags
  var flags = 0x02; // clean session
  if (cfg.username != null && cfg.username!.isNotEmpty) flags |= 0x80;
  if (cfg.password != null && cfg.password!.isNotEmpty) flags |= 0x40;
  variable.addByte(flags);

  // Keep alive: 60 s. We disconnect immediately so the broker timer is
  // mostly cosmetic.
  variable.addByte(0x00);
  variable.addByte(0x3c);

  // Payload: client id, optional username, optional password
  final payload = BytesBuilder();
  payload.add(
    _encodeString(cfg.clientId.isEmpty ? 'skotiq' : cfg.clientId),
  );
  if (cfg.username != null && cfg.username!.isNotEmpty) {
    payload.add(_encodeString(cfg.username!));
  }
  if (cfg.password != null && cfg.password!.isNotEmpty) {
    payload.add(_encodeString(cfg.password!));
  }

  return _buildFixedHeader(0x10, variable.toBytes(), payload.toBytes());
}

Uint8List _buildPublishPacket({
  required String topic,
  required List<int> payload,
  required int qos,
  required bool retain,
  required int packetId,
}) {
  final variable = BytesBuilder();
  variable.add(_encodeString(topic));
  if (qos > 0) {
    variable.addByte((packetId >> 8) & 0xff);
    variable.addByte(packetId & 0xff);
  }
  // Fixed header byte 1: type (3) << 4 | dup (0) | qos << 1 | retain
  final headerByte = (3 << 4) | ((qos & 0x03) << 1) | (retain ? 1 : 0);
  return _buildFixedHeader(
    headerByte,
    variable.toBytes(),
    Uint8List.fromList(payload),
  );
}

Uint8List _buildDisconnectPacket() {
  final out = BytesBuilder();
  out.addByte(0xe0);
  out.addByte(0x00);
  return out.toBytes();
}

Uint8List _buildFixedHeader(
  int firstByte,
  Uint8List variableHeader,
  Uint8List payload,
) {
  final out = BytesBuilder();
  out.addByte(firstByte);
  final remaining = variableHeader.length + payload.length;
  out.add(_encodeRemainingLength(remaining));
  out.add(variableHeader);
  out.add(payload);
  return out.toBytes();
}

Uint8List _encodeString(String s) {
  final bytes = utf8.encode(s);
  if (bytes.length > 0xffff) {
    throw Exception('MQTT string too long (${bytes.length})');
  }
  final out = BytesBuilder();
  out.addByte((bytes.length >> 8) & 0xff);
  out.addByte(bytes.length & 0xff);
  out.add(bytes);
  return out.toBytes();
}

Uint8List _encodeRemainingLength(int length) {
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
