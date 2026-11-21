import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:skotiq_updater/src/models/update_manifest.dart';
import 'package:skotiq_updater/src/services/lan_push_receiver.dart';
import 'package:skotiq_updater/src/services/update_verifier.dart';

void main() {
  test('a stalled sender aborts and frees the receive slot', () async {
    final dataDir = await Directory.systemTemp.createTemp('lan_stall_');
    addTearDown(() async {
      if (await dataDir.exists()) await dataDir.delete(recursive: true);
    });
    final received = Completer<void>();
    final error = Completer<String>();
    final receiver =
        LanPushReceiver(
            currentVersion: '1.0.0',
            currentBuildNumber: 1,
            dataDirectory: () async => dataDir,
            pushSecret: 'secret',
            serverPort: 0,
            verifier: await _verifierWithKey(),
            idleTimeout: const Duration(milliseconds: 200),
            currentPlatform: 'linux',
            currentArch: 'x64',
          )
          ..onUpdateReceived = (_, _) {
            if (!received.isCompleted) received.complete();
          }
          ..onError = (message) {
            if (!error.isCompleted) error.complete(message);
          };
    await receiver.startServer();
    addTearDown(receiver.stopServer);

    final client = await Socket.connect(
      InternetAddress.loopbackIPv4,
      receiver.listeningPort!,
    );
    addTearDown(client.close);
    client.add(_authFrame('secret'));
    await client.flush();

    final message = await error.future.timeout(const Duration(seconds: 2));
    expect(message, contains('stalled'));
    expect(received.isCompleted, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(received.isCompleted, isFalse);
    expect(receiver.versionInfo['isReceiving'], isFalse);
    expect(
      File(
        path.join(dataDir.path, 'updates', 'staging', 'ready.json'),
      ).existsSync(),
      isFalse,
    );
    expect(
      File(
        path.join(dataDir.path, 'updates', 'staging', 'update.zip'),
      ).existsSync(),
      isFalse,
    );

    final second = await Socket.connect(
      InternetAddress.loopbackIPv4,
      receiver.listeningPort!,
    );
    addTearDown(second.close);
    second.add(_authFrame('secret'));
    await second.flush();
    final response = await second
        .map(utf8.decode)
        .join()
        .timeout(const Duration(seconds: 2));
    expect(response, isNot(contains('Already receiving')));
    expect(response, contains('"auth":"ok"'));
  });

  test('a slow sender that keeps delivering bytes completes', () async {
    final dataDir = await Directory.systemTemp.createTemp('lan_slow_');
    addTearDown(() async {
      if (await dataDir.exists()) await dataDir.delete(recursive: true);
    });
    final key = await _keyPair();
    final staged = Completer<String>();
    final failure = Completer<String>();
    var receivedBytes = 0;
    final receiver =
        LanPushReceiver(
            currentVersion: '1.0.0',
            currentBuildNumber: 1,
            dataDirectory: () async => dataDir,
            pushSecret: 'secret',
            serverPort: 0,
            verifier: key.verifier,
            idleTimeout: const Duration(milliseconds: 200),
            currentPlatform: 'linux',
            currentArch: 'x64',
          )
          ..onProgress = (received, _, _, _) {
            receivedBytes = received;
          }
          ..onUpdateReceived = (manifest, _) {
            if (!staged.isCompleted) staged.complete(manifest.version);
          }
          ..onError = (message) {
            if (!failure.isCompleted) failure.complete(message);
          };
    await receiver.startServer();
    addTearDown(receiver.stopServer);

    final package = _zipOf({'payload.txt': utf8.encode('slow-push')});
    final manifest = await _signedManifest(
      keyPair: key.pair,
      algorithm: key.algorithm,
      packageBytes: package,
      fileName: 'payload.txt',
      fileBytes: utf8.encode('slow-push'),
    );

    final client = await Socket.connect(
      InternetAddress.loopbackIPv4,
      receiver.listeningPort!,
    );
    addTearDown(client.close);
    final incoming = StringBuffer();
    final authenticated = Completer<void>();
    client.listen((chunk) {
      incoming.write(utf8.decode(chunk));
      if (incoming.toString().contains('"auth":"ok"') &&
          !authenticated.isCompleted) {
        authenticated.complete();
      }
    });
    client.add(_authFrame('secret'));
    await client.flush();
    await authenticated.future.timeout(const Duration(seconds: 2));

    final manifestBytes = utf8.encode(jsonEncode(manifest.toJson()));
    client.add(_lengthPrefixed(manifestBytes));
    await client.flush();
    client.add([package[0]]);
    await client.flush();
    await _until(() => receivedBytes >= 1);

    // Two gaps, each shorter than the idle budget, together longer than it.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    client.add([package[1]]);
    await client.flush();
    await _until(() => receivedBytes >= 2);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    client.add(package.sublist(2));
    await client.flush();

    final version = await Future.any<String>([
      staged.future,
      failure.future.then((message) => throw Exception(message)),
    ]).timeout(const Duration(seconds: 5));
    expect(version, '1.1.0');
    expect(
      File(
        path.join(dataDir.path, 'updates', 'staging', 'ready.json'),
      ).existsSync(),
      isTrue,
    );
  });
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for push progress');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Uint8List _authFrame(String secret) {
  return _lengthPrefixed(utf8.encode(jsonEncode({'secret': secret})));
}

Uint8List _lengthPrefixed(List<int> payload) {
  final length = ByteData(4)..setUint32(0, payload.length, Endian.big);
  return Uint8List.fromList([...length.buffer.asUint8List(), ...payload]);
}

Uint8List _zipOf(Map<String, List<int>> entries) {
  final archive = Archive();
  entries.forEach((name, bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

class _Key {
  _Key(this.algorithm, this.pair, this.verifier);
  final Ed25519 algorithm;
  final SimpleKeyPair pair;
  final UpdateVerifier verifier;
}

Future<_Key> _keyPair() async {
  final algorithm = Ed25519();
  final pair = await algorithm.newKeyPair();
  final publicKey = await pair.extractPublicKey();
  return _Key(
    algorithm,
    pair,
    UpdateVerifier(
      trustedPublicKeyBase64: base64Encode(Uint8List.fromList(publicKey.bytes)),
    ),
  );
}

Future<UpdateVerifier> _verifierWithKey() async => (await _keyPair()).verifier;

Future<UpdateManifest> _signedManifest({
  required SimpleKeyPair keyPair,
  required Ed25519 algorithm,
  required Uint8List packageBytes,
  required String fileName,
  required List<int> fileBytes,
}) async {
  final unsigned = UpdateManifest(
    version: '1.1.0',
    buildNumber: 2,
    releaseDate: DateTime.utc(2026, 1, 1),
    platform: 'linux',
    arch: 'x64',
    files: {
      fileName: UpdateFileInfo(
        path: fileName,
        size: fileBytes.length,
        sha256: crypto.sha256.convert(fileBytes).toString(),
      ),
    },
    totalSize: fileBytes.length,
    compressedSize: packageBytes.length,
    packageSha256: crypto.sha256.convert(packageBytes).toString(),
    downloadUrl: 'lan://push',
  );
  final signature = await algorithm.sign(
    utf8.encode(UpdateVerifier.canonicalManifestPayload(unsigned)),
    keyPair: keyPair,
  );
  return unsigned.copyWith(signature: base64Encode(signature.bytes));
}
