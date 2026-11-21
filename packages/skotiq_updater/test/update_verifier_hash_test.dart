import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_updater/src/services/update_verifier.dart';

void main() {
  test('hashFile matches the SHA-256 of the file bytes', () async {
    final dir = await Directory.systemTemp.createTemp('skotiq_hash_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    // NIST SHA-256 vector for the three bytes "abc".
    final abc = File('${dir.path}/abc');
    await abc.writeAsString('abc');
    final verifier = UpdateVerifier();
    expect(
      await verifier.hashFile(abc),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );

    // Larger than one SHA-256 block so a streaming digest has to update
    // more than once. The expected value is computed here, not by hashFile.
    final payload = Uint8List(100 * 1024);
    for (var i = 0; i < payload.length; i++) {
      payload[i] = i & 0xff;
    }
    final big = File('${dir.path}/big.bin');
    await big.writeAsBytes(payload);
    expect(await verifier.hashFile(big), sha256.convert(payload).toString());
  });
}
