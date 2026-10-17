import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

/// Integration tests for the LAN push update functionality.
///
/// These tests verify:
/// 1. Discovery protocol (UDP broadcast/response)
/// 2. Push protocol (TCP manifest + package transfer)
/// 3. Error handling (busy receiver, connection refused, etc.)
///
/// Run with: dart test packages/skotiq_updater/test/lan_push_test.dart

const int testDiscoveryPort =
    45689; // Different from production to avoid conflicts
const int advertisedPushPort = 45690;
const String updatePushMessage = 'SKOTIQ_UPDATE_PUSH';
const String updateResponsePrefix = 'SKOTIQ_UPDATE_TARGET:';

Future<int> _unusedTcpPort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

void main() {
  group('LAN Push Discovery Protocol', () {
    test('should broadcast discovery message and receive response', () async {
      // Start a mock responder
      final responder = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        testDiscoveryPort,
        reuseAddress: true,
      );

      final receivedMessage = Completer<String>();

      responder.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = responder.receive();
          if (datagram != null) {
            final message = utf8.decode(datagram.data);
            receivedMessage.complete(message);

            // Send response
            if (message == updatePushMessage) {
              final response =
                  updateResponsePrefix +
                  jsonEncode({
                    'name': 'TestReceiver',
                    'version': '2.0.0',
                    'buildNumber': 42,
                    'pushPort': advertisedPushPort,
                    'isReceiving': false,
                  });
              responder.send(
                utf8.encode(response),
                datagram.address,
                datagram.port,
              );
            }
          }
        }
      });

      // Send discovery broadcast
      final sender = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      sender.send(
        utf8.encode(updatePushMessage),
        InternetAddress.loopbackIPv4,
        testDiscoveryPort,
      );

      // Wait for message to be received
      final message = await receivedMessage.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw TimeoutException('Discovery response timeout'),
      );

      expect(message, equals(updatePushMessage));

      sender.close();
      responder.close();
    });

    test('should handle busy receiver response', () async {
      final responder = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        testDiscoveryPort,
        reuseAddress: true,
      );

      responder.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = responder.receive();
          if (datagram != null) {
            final message = utf8.decode(datagram.data);
            if (message == updatePushMessage) {
              // Respond as busy
              final response =
                  updateResponsePrefix +
                  jsonEncode({
                    'name': 'BusyReceiver',
                    'version': '2.0.0',
                    'buildNumber': 42,
                    'pushPort': advertisedPushPort,
                    'isReceiving': true, // Busy flag
                  });
              responder.send(
                utf8.encode(response),
                datagram.address,
                datagram.port,
              );
            }
          }
        }
      });

      // Send discovery
      final sender = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      final responseReceived = Completer<Map<String, dynamic>>();

      sender.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = sender.receive();
          if (datagram != null) {
            final message = utf8.decode(datagram.data);
            if (message.startsWith(updateResponsePrefix)) {
              final json = jsonDecode(
                message.substring(updateResponsePrefix.length),
              );
              responseReceived.complete(json as Map<String, dynamic>);
            }
          }
        }
      });

      sender.send(
        utf8.encode(updatePushMessage),
        InternetAddress.loopbackIPv4,
        testDiscoveryPort,
      );

      final response = await responseReceived.future.timeout(
        const Duration(seconds: 2),
      );

      expect(response['isReceiving'], isTrue);

      sender.close();
      responder.close();
    });
  });

  group('LAN Push Transfer Protocol', () {
    test('should transfer manifest and package data', () async {
      // Start mock receiver
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final pushPort = server.port;
      final connectionReceived = Completer<void>();
      Map<String, dynamic>? receivedManifest;
      int receivedBytes = 0;

      server.listen((socket) async {
        final buffer = BytesBuilder();
        int? manifestLength;

        await for (final chunk in socket) {
          buffer.add(chunk);

          // Read manifest length
          if (manifestLength == null && buffer.length >= 4) {
            final bytes = buffer.takeBytes();
            manifestLength = ByteData.view(
              Uint8List.fromList(bytes.sublist(0, 4)).buffer,
            ).getInt32(0, Endian.big);
            buffer.add(bytes.sublist(4));
          }

          // Read manifest
          if (receivedManifest == null &&
              manifestLength != null &&
              buffer.length >= manifestLength) {
            final bytes = buffer.takeBytes();
            final manifestJson = utf8.decode(bytes.sublist(0, manifestLength));
            receivedManifest = jsonDecode(manifestJson) as Map<String, dynamic>;
            receivedBytes = bytes.length - manifestLength;
            buffer.add(bytes.sublist(manifestLength));
          }

          // Count package bytes
          if (receivedManifest != null) {
            receivedBytes += chunk.length;
          }
        }

        // Send success response
        socket.write(
          jsonEncode({'status': 'complete', 'receivedBytes': receivedBytes}),
        );
        await socket.close();
        connectionReceived.complete();
      });

      // Create test data
      final manifest = {
        'version': '2.1.0',
        'buildNumber': 100,
        'compressedSize': 1024,
        'files': {},
      };
      final manifestBytes = utf8.encode(jsonEncode(manifest));
      final packageData = List.generate(1024, (i) => i % 256);

      // Connect and send
      final client = await Socket.connect(
        InternetAddress.loopbackIPv4,
        pushPort,
      );

      // Send manifest length (4 bytes, big-endian)
      final lengthBytes = ByteData(4);
      lengthBytes.setInt32(0, manifestBytes.length, Endian.big);
      client.add(lengthBytes.buffer.asUint8List());

      // Send manifest
      client.add(manifestBytes);

      // Send package
      client.add(packageData);
      await client.flush();
      await client.close();

      // Wait for receiver to process
      await connectionReceived.future.timeout(const Duration(seconds: 5));

      expect(receivedManifest, isNotNull);
      expect(receivedManifest!['version'], equals('2.1.0'));
      expect(receivedBytes, greaterThanOrEqualTo(1024));

      await server.close();
    });

    test('should handle connection refused gracefully', () async {
      final unusedPort = await _unusedTcpPort();

      // Try to connect to a port with no listener
      expect(
        () async => await Socket.connect(
          InternetAddress.loopbackIPv4,
          unusedPort,
          timeout: const Duration(seconds: 1),
        ),
        throwsA(isA<SocketException>()),
      );
    });

    test(
      'should handle large package transfer',
      () async {
        final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final pushPort = server.port;
        final completer = Completer<int>();

        server.listen((socket) async {
          final buffer = BytesBuilder();
          int? manifestLength;
          Map<String, dynamic>? manifest;
          int receivedBytes = 0;

          await for (final chunk in socket) {
            buffer.add(chunk);

            if (manifestLength == null && buffer.length >= 4) {
              final bytes = buffer.takeBytes();
              manifestLength = ByteData.view(
                Uint8List.fromList(bytes.sublist(0, 4)).buffer,
              ).getInt32(0, Endian.big);
              buffer.add(bytes.sublist(4));
            }

            if (manifest == null &&
                manifestLength != null &&
                buffer.length >= manifestLength) {
              final bytes = buffer.takeBytes();
              final manifestJson = utf8.decode(
                bytes.sublist(0, manifestLength),
              );
              manifest = jsonDecode(manifestJson) as Map<String, dynamic>;
              receivedBytes = bytes.length - manifestLength;
              buffer.add(bytes.sublist(manifestLength));
            }

            if (manifest != null) {
              final bytes = buffer.takeBytes();
              receivedBytes += bytes.length;
            }
          }

          socket.write(jsonEncode({'status': 'complete'}));
          await socket.close();
          completer.complete(receivedBytes);
        });

        // Send 1MB of data
        const largeSize = 1024 * 1024; // 1MB
        final manifest = {
          'version': '2.1.0',
          'buildNumber': 100,
          'compressedSize': largeSize,
          'files': {},
        };
        final manifestBytes = utf8.encode(jsonEncode(manifest));
        final largeData = List.generate(largeSize, (i) => i % 256);

        final client = await Socket.connect(
          InternetAddress.loopbackIPv4,
          pushPort,
        );

        final lengthBytes = ByteData(4);
        lengthBytes.setInt32(0, manifestBytes.length, Endian.big);
        client.add(lengthBytes.buffer.asUint8List());
        client.add(manifestBytes);

        // Send in chunks
        const chunkSize = 64 * 1024; // 64KB chunks
        for (var i = 0; i < largeData.length; i += chunkSize) {
          final end = (i + chunkSize < largeData.length)
              ? i + chunkSize
              : largeData.length;
          client.add(largeData.sublist(i, end));
          await client.flush();
        }

        await client.close();

        final received = await completer.future.timeout(
          const Duration(seconds: 10),
        );
        expect(
          received,
          greaterThanOrEqualTo(largeSize * 0.99),
        ); // Allow 1% tolerance

        await server.close();
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });

  group('UpdateManifest', () {
    test('should serialize and deserialize correctly', () {
      final manifest = {
        'version': '2.1.0',
        'buildNumber': 42,
        'releaseDate': '2025-01-15T12:00:00Z',
        'platform': 'windows',
        'arch': 'x64',
        'files': {
          'skotiq.exe': {
            'path': 'skotiq.exe',
            'size': 1024,
            'sha256': 'abc123',
          },
        },
        'totalSize': 1024,
        'compressedSize': 512,
        'downloadUrl': 'https://example.com/update.zip',
        'releaseNotes': 'Test release',
      };

      final json = jsonEncode(manifest);
      final decoded = jsonDecode(json) as Map<String, dynamic>;

      expect(decoded['version'], equals('2.1.0'));
      expect(decoded['buildNumber'], equals(42));
      expect(decoded['files'], isA<Map>());
    });
  });
}
