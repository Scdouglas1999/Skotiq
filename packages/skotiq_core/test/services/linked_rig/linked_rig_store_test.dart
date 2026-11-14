// The remembered rig survives a restart, keeps its token out of the record,
// and falls back to an owner-only file only when the keyring is unusable.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/services.dart';

class _BrokenKeyring implements SecureKeyValueStore {
  @override
  Future<String?> read({required String key}) async =>
      throw Exception('no Secret Service');
  @override
  Future<void> write({required String key, required String value}) async =>
      throw Exception('no Secret Service');
  @override
  Future<void> delete({required String key}) async =>
      throw Exception('no Secret Service');
}

LinkedRig _rig({bool active = true, String scope = 'control'}) => LinkedRig(
  host: '192.168.1.32',
  port: 8099,
  name: 'DESKTOP-MMAJGAK',
  fingerprint: 'dc2f261109b13423',
  platform: 'windows',
  version: '8.2.1',
  tokenScope: scope,
  pairedAt: DateTime.utc(2026, 11, 7),
  active: active,
);

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('linked_rig_store');
  });
  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  LinkedRigStore storeWith(SecureKeyValueStore keyring) =>
      LinkedRigStore(dataDirectory: () async => dir, secureStore: keyring);

  test('round-trips the rig and keeps the token in the keyring', () async {
    final keyring = InMemorySecureKeyValueStore();
    final store = storeWith(keyring);
    final where = await store.save(_rig(), token: 'secret-token');

    expect(where, LinkedRigTokenStorage.keyring);
    final loaded = await storeWith(keyring).load();
    expect(loaded!.name, 'DESKTOP-MMAJGAK');
    expect(loaded.address, '192.168.1.32:8099');
    expect(loaded.fingerprint, 'dc2f261109b13423');
    expect(loaded.active, isTrue);
    expect(loaded.hasFullAccess, isFalse);
    expect(await store.readToken(), 'secret-token');

    final record = await File('${dir.path}/linked_rig.json').readAsString();
    expect(record, isNot(contains('secret-token')));
    expect(File('${dir.path}/linked_rig_token').existsSync(), isFalse);
  });

  test('two data directories never share a token', () async {
    final keyring = InMemorySecureKeyValueStore();
    final other = await Directory.systemTemp.createTemp('linked_rig_other');
    addTearDown(() => other.delete(recursive: true));
    await storeWith(keyring).save(_rig(), token: 'first');
    final second = LinkedRigStore(
      dataDirectory: () async => other,
      secureStore: keyring,
    );
    expect(await second.readToken(), isNull);
  });

  test('without a keyring the token goes to an owner-only file', () async {
    final store = storeWith(_BrokenKeyring());
    final where = await store.save(_rig(), token: 'fallback-token');

    expect(where, LinkedRigTokenStorage.ownerOnlyFile);
    expect(await store.readToken(), 'fallback-token');
    if (!Platform.isWindows) {
      final mode = (await File('${dir.path}/linked_rig_token').stat()).mode;
      expect(mode & 0x3F, 0, reason: 'no group or other permissions');
    }
  });

  test('"use this computer instead" keeps the pairing inactive', () async {
    final keyring = InMemorySecureKeyValueStore();
    final store = storeWith(keyring);
    await store.save(_rig(), token: 't');
    await store.setActive(false);
    final loaded = await store.load();
    expect(loaded!.active, isFalse);
    expect(await store.readToken(), 't');
  });

  test('forget removes the record and the token', () async {
    final keyring = InMemorySecureKeyValueStore();
    final store = storeWith(keyring);
    await store.save(_rig(), token: 't');
    await store.forget();
    expect(await store.load(), isNull);
    expect(await store.readToken(), isNull);
    expect(keyring.values, isEmpty);
  });

  test('a damaged record launches this computer as its own host', () async {
    await File('${dir.path}/linked_rig.json').writeAsString('{"host": ');
    expect(await storeWith(InMemorySecureKeyValueStore()).load(), isNull);
    await File(
      '${dir.path}/linked_rig.json',
    ).writeAsString('{"host": "x", "port": 0}');
    expect(await storeWith(InMemorySecureKeyValueStore()).load(), isNull);
  });

  test('the device id is stable across pairings', () async {
    final store = storeWith(InMemorySecureKeyValueStore());
    final first = await store.deviceId();
    expect(first, startsWith('desktop:'));
    expect(await storeWith(InMemorySecureKeyValueStore()).deviceId(), first);
  });

  test('normalizes a typed pairing code', () {
    expect(normalizePairingCode(' orbit nebula 4821 '), 'ORBIT-NEBULA-4821');
    expect(normalizePairingCode('Orbit--Nebula-4821'), 'ORBIT-NEBULA-4821');
  });
}
