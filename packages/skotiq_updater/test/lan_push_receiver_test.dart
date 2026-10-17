import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_updater/src/services/lan_push_receiver.dart';
import 'package:skotiq_updater/src/services/update_verifier.dart';

Future<UpdateVerifier> _verifierWithKey() async {
  // startServer refuses to run without a trusted key compiled in. Tests do
  // not get `--dart-define=SKOTIQ_UPDATE_PUBLIC_KEY`, so a freshly
  // generated key is injected explicitly. It never verifies a real manifest
  // in this test.
  final keyPair = await Ed25519().newKeyPair();
  final publicKey = await keyPair.extractPublicKey();
  final base64Key = base64Encode(Uint8List.fromList(publicKey.bytes));
  return UpdateVerifier(trustedPublicKeyBase64: base64Key);
}

void main() {
  test(
    'rejects concurrent connections while authentication is in progress',
    () async {
      final verifier = await _verifierWithKey();
      final receiver = LanPushReceiver(
        currentVersion: '2.0.0',
        currentBuildNumber: 1,
        pushSecret: 'secret',
        serverPort: 45691,
        verifier: verifier,
      );
      await receiver.startServer();
      addTearDown(receiver.stopServer);

      final firstClient = await Socket.connect(
        InternetAddress.loopbackIPv4,
        45691,
      );
      addTearDown(firstClient.close);

      // Let the server reserve the receive slot for the first connection.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final secondClient = await Socket.connect(
        InternetAddress.loopbackIPv4,
        45691,
      );
      addTearDown(secondClient.close);

      final response = await secondClient
          .map(utf8.decode)
          .join()
          .timeout(const Duration(seconds: 2));

      expect(response, contains('Already receiving update'));
      expect(receiver.versionInfo['isReceiving'], isTrue);
    },
  );

  test('releases receive slot after failed authentication', () async {
    final verifier = await _verifierWithKey();
    final receiver = LanPushReceiver(
      currentVersion: '2.0.0',
      currentBuildNumber: 1,
      pushSecret: 'secret',
      serverPort: 45692,
      verifier: verifier,
    );
    await receiver.startServer();
    addTearDown(receiver.stopServer);

    final client = await Socket.connect(InternetAddress.loopbackIPv4, 45692);
    client.add(_authFrame('wrong-secret'));
    await client.flush();

    final response = await client
        .map(utf8.decode)
        .join()
        .timeout(const Duration(seconds: 2));

    expect(response, contains('rejected'));
    expect(response, contains('invalid secret'));
    expect(receiver.versionInfo['isReceiving'], isFalse);
  });

  test(
    'preserves a manifest frame coalesced with authentication bytes',
    () async {
      final error = Completer<String>();
      final receiver = LanPushReceiver(
        currentVersion: '2.0.0',
        currentBuildNumber: 1,
        pushSecret: 'secret',
        serverPort: 0,
        verifier: await _verifierWithKey(),
      )..onError = error.complete;
      await receiver.startServer();
      addTearDown(receiver.stopServer);

      final client = await Socket.connect(
        InternetAddress.loopbackIPv4,
        receiver.listeningPort!,
      );
      final response = client.map(utf8.decode).join();

      // Send both phases in one write. TCP is allowed to deliver this as one
      // chunk, and the update phase must see the four bytes left after auth.
      final invalidManifestLength = ByteData(4)..setInt32(0, 0, Endian.big);
      client.add(
        Uint8List.fromList([
          ..._authFrame('secret'),
          ...invalidManifestLength.buffer.asUint8List(),
        ]),
      );
      await client.flush();

      expect(
        await error.future.timeout(const Duration(seconds: 2)),
        contains('Invalid update manifest length'),
      );
      expect(
        await response.timeout(const Duration(seconds: 2)),
        contains('"auth":"ok"'),
      );
      expect(receiver.versionInfo['isReceiving'], isFalse);
    },
  );
}

Uint8List _authFrame(String secret) {
  final payload = utf8.encode(jsonEncode({'secret': secret}));
  final length = ByteData(4)..setInt32(0, payload.length, Endian.big);
  return Uint8List.fromList([...length.buffer.asUint8List(), ...payload]);
}
