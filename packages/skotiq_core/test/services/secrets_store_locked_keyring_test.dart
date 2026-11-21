import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/notification/secrets_store.dart';

class _FlakySecureStore implements SecureKeyValueStore {
  var locked = true;
  final values = <String, String>{};

  @override
  Future<String?> read({required String key}) async {
    if (locked) throw StateError('keyring locked');
    return values[key];
  }

  @override
  Future<void> write({required String key, required String value}) async {
    if (locked) throw StateError('keyring locked');
    values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    if (locked) throw StateError('keyring locked');
    values.remove(key);
  }
}

void main() {
  test('a locked keyring is not cached as an empty secret', () async {
    final backing = _FlakySecureStore();
    final secrets = SecretsStore(backing);

    await expectLater(
      secrets.read(SecretField.emailPassword),
      throwsStateError,
    );
    backing.locked = false;
    expect(await secrets.read(SecretField.emailPassword), '');
  });
}
