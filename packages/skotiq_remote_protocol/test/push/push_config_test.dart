// Phase D push config loader tests. Exercises the env-override / app-support
// resolution, the "missing secret file disables the channel" validation, and
// the "malformed or absent => disabled, never crash" contract.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('push_cfg_test_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('absent config file => PushConfig.disabled (no crash)', () async {
    final cfg = await PushConfig.load(
      appSupportDir: tmp.path,
      environment: const {},
    );
    expect(cfg.fcm.enabled, isFalse);
    expect(cfg.apns.enabled, isFalse);
    expect(cfg.mock, isFalse);
    expect(cfg.hasCloudChannel, isFalse);
  });

  test('malformed JSON => disabled (never throws)', () async {
    final dir = Directory(p.join(tmp.path, 'Skotiq'))
      ..createSync(recursive: true);
    File(p.join(dir.path, 'push_config.json')).writeAsStringSync('{ not json');

    final cfg = await PushConfig.load(
      appSupportDir: tmp.path,
      environment: const {},
    );
    expect(cfg.hasCloudChannel, isFalse);
  });

  test('SKOTIQ_PUSH_CONFIG overrides the app-support path', () async {
    final secret = File(p.join(tmp.path, 'sa.json'))..writeAsStringSync('{}');
    final override = File(p.join(tmp.path, 'custom.json'));
    override.writeAsStringSync('''
      { "fcm": { "enabled": true, "serviceAccountPath": "${secret.path}" } }
    ''');

    final cfg = await PushConfig.load(
      appSupportDir: '/nonexistent',
      environment: {'SKOTIQ_PUSH_CONFIG': override.path},
    );
    // The override file was read and the secret exists => fcm enabled.
    expect(cfg.fcm.enabled, isTrue);
    expect(cfg.fcm.serviceAccountPath, secret.path);
  });

  test(
    'enabled fcm but missing service-account file => channel disabled',
    () async {
      final dir = Directory(p.join(tmp.path, 'Skotiq'))
        ..createSync(recursive: true);
      File(p.join(dir.path, 'push_config.json')).writeAsStringSync('''
      { "fcm": { "enabled": true,
                 "serviceAccountPath": "/does/not/exist.json" } }
    ''');

      final cfg = await PushConfig.load(
        appSupportDir: tmp.path,
        environment: const {},
      );
      // Half-configured deployment still runs: bad channel silently disabled.
      expect(cfg.fcm.enabled, isFalse);
    },
  );

  test('apns requires all id fields + an existing .p8', () async {
    final p8 = File(p.join(tmp.path, 'AuthKey.p8'))..writeAsStringSync('key');
    final dir = Directory(p.join(tmp.path, 'Skotiq'))
      ..createSync(recursive: true);

    // Missing teamId => disabled.
    File(p.join(dir.path, 'push_config.json')).writeAsStringSync('''
      { "apns": { "enabled": true, "p8KeyPath": "${p8.path}",
                  "keyId": "K", "bundleId": "com.x" } }
    ''');
    var cfg = await PushConfig.load(
      appSupportDir: tmp.path,
      environment: const {},
    );
    expect(cfg.apns.enabled, isFalse);

    // Complete + existing .p8 => enabled.
    File(p.join(dir.path, 'push_config.json')).writeAsStringSync('''
      { "apns": { "enabled": true, "p8KeyPath": "${p8.path}",
                  "keyId": "K1", "teamId": "T1",
                  "bundleId": "com.x", "useSandbox": true } }
    ''');
    cfg = await PushConfig.load(appSupportDir: tmp.path, environment: const {});
    expect(cfg.apns.enabled, isTrue);
    expect(cfg.apns.useSandbox, isTrue);
    expect(cfg.apns.bundleId, 'com.x');
  });

  test('mock flag is preserved even with no cloud channel', () async {
    final dir = Directory(p.join(tmp.path, 'Skotiq'))
      ..createSync(recursive: true);
    File(
      p.join(dir.path, 'push_config.json'),
    ).writeAsStringSync('{ "mock": true }');

    final cfg = await PushConfig.load(
      appSupportDir: tmp.path,
      environment: const {},
    );
    expect(cfg.mock, isTrue);
    expect(cfg.hasCloudChannel, isFalse);
  });
}
