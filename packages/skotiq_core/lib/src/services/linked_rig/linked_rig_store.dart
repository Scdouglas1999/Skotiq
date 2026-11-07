import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;

import '../../utils/skotiq_data_directory.dart';
import '../notification/secrets_store.dart' show SecureKeyValueStore;

/// The imaging computer this desktop links to, as remembered between launches.
///
/// The token is NOT in here: it lives in the platform keyring
/// ([LinkedRigStore.readToken]). This record is the rest of what the pairing
/// established, so the launch can decide the role and the UI can name the host.
class LinkedRig {
  const LinkedRig({
    required this.host,
    required this.port,
    required this.name,
    required this.tokenScope,
    required this.pairedAt,
    this.scheme = 'http',
    this.fingerprint,
    this.version,
    this.platform,
    this.hostMode,
    this.active = true,
  });

  final String host;
  final int port;
  final String scheme;

  /// What the list called the host: its computer name when it reported one.
  final String name;

  /// The host's identity as `/api/info` reported it when this desktop paired.
  /// A launch refuses to send the token to an address that now answers with a
  /// different fingerprint.
  final String? fingerprint;

  final String? version;
  final String? platform;
  final String? hostMode;

  /// What the host granted: `control` from the one-tap LAN pairing, `admin`
  /// from a pairing code with full access.
  final String tokenScope;

  final DateTime pairedAt;

  /// True: launch as this rig's linked client. False: the operator chose "Use
  /// this computer instead"; the pairing is kept so linking again is one tap.
  final bool active;

  String get address => '$host:$port';

  /// True when the host lets this desktop change its settings.
  bool get hasFullAccess => tokenScope == 'admin';

  LinkedRig copyWith({bool? active, String? host, int? port}) => LinkedRig(
    host: host ?? this.host,
    port: port ?? this.port,
    scheme: scheme,
    name: name,
    fingerprint: fingerprint,
    version: version,
    platform: platform,
    hostMode: hostMode,
    tokenScope: tokenScope,
    pairedAt: pairedAt,
    active: active ?? this.active,
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'host': host,
    'port': port,
    'scheme': scheme,
    'name': name,
    if (fingerprint != null) 'fingerprint': fingerprint,
    if (version != null) 'hostVersion': version,
    if (platform != null) 'platform': platform,
    if (hostMode != null) 'hostMode': hostMode,
    'tokenScope': tokenScope,
    'pairedAt': pairedAt.toUtc().toIso8601String(),
    'active': active,
  };

  /// Null for anything that is not a complete record, so a damaged file
  /// launches this computer as its own host rather than a half-linked client.
  static LinkedRig? fromJson(Object? json) {
    if (json is! Map) return null;
    final host = json['host'];
    final port = json['port'];
    if (host is! String || host.trim().isEmpty) return null;
    if (port is! int || port <= 0 || port > 65535) return null;
    final scheme = json['scheme'] == 'https' ? 'https' : 'http';
    String? text(String key) {
      final value = json[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    return LinkedRig(
      host: host.trim(),
      port: port,
      scheme: scheme,
      name: text('name') ?? host,
      fingerprint: text('fingerprint'),
      version: text('hostVersion'),
      platform: text('platform'),
      hostMode: text('hostMode'),
      tokenScope: text('tokenScope') ?? 'control',
      pairedAt:
          DateTime.tryParse(text('pairedAt') ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      active: json['active'] != false,
    );
  }
}

/// Where the remembered rig and its token are kept.
///
/// * `linked_rig.json` in the Skotiq data directory: the [LinkedRig] record.
/// * The token: the platform keyring through `flutter_secure_storage`
///   (Credential Manager, Keychain, libsecret). The key carries a hash of the
///   data directory, so two installs on one machine (or a test instance with
///   its own `SKOTIQ_DATA_DIR`) never read each other's token.
/// * A Linux desktop with no Secret Service running (a bare window manager, a
///   kiosk) cannot use the keyring. The token then goes to an owner-only
///   (0600) file beside the record, the same protection the host's own
///   `remote_access_token.txt` has, and the record says so.
class LinkedRigStore {
  LinkedRigStore({
    Future<Directory> Function()? dataDirectory,
    SecureKeyValueStore? secureStore,
  }) : _dataDirectory = dataDirectory ?? resolveSkotiqDataDirectory,
       _secure = secureStore ?? const _PlatformKeyring();

  final Future<Directory> Function() _dataDirectory;
  final SecureKeyValueStore _secure;

  static const _recordFile = 'linked_rig.json';
  static const _tokenFile = 'linked_rig_token';
  static const _deviceIdFile = 'link_device_id';

  Future<File> _file(String name) async =>
      File(p.join((await _dataDirectory()).path, name));

  Future<String> _keyringKey() async {
    final dir = (await _dataDirectory()).absolute.path;
    final digest = sha256.convert(utf8.encode(dir)).toString().substring(0, 16);
    return 'skotiq.linked_rig.v1.$digest';
  }

  /// The remembered rig, or null when there is none (or the file is damaged).
  Future<LinkedRig?> load() async {
    try {
      final file = await _file(_recordFile);
      if (!await file.exists()) return null;
      return LinkedRig.fromJson(jsonDecode(await file.readAsString()));
    } catch (e) {
      developer.log('linked rig record unreadable: $e', name: 'LinkedRigStore');
      return null;
    }
  }

  /// The token for the remembered rig, or null when none is stored.
  Future<String?> readToken() async {
    try {
      final value = await _secure.read(key: await _keyringKey());
      if (value != null && value.isNotEmpty) return value;
    } catch (e) {
      developer.log('keyring read failed: $e', name: 'LinkedRigStore');
    }
    final file = await _file(_tokenFile);
    if (await file.exists()) {
      final value = (await file.readAsString()).trim();
      if (value.isNotEmpty) return value;
    }
    return null;
  }

  /// Remember [rig] with [token]. Returns where the token went.
  Future<LinkedRigTokenStorage> save(
    LinkedRig rig, {
    required String token,
  }) async {
    final storage = await _writeToken(token);
    await _writeRecord(rig);
    return storage;
  }

  Future<LinkedRigTokenStorage> _writeToken(String token) async {
    final tokenFile = await _file(_tokenFile);
    try {
      await _secure.write(key: await _keyringKey(), value: token);
      if (await tokenFile.exists()) await tokenFile.delete();
      return LinkedRigTokenStorage.keyring;
    } catch (e) {
      developer.log(
        'keyring unavailable ($e); keeping the token in an owner-only file',
        name: 'LinkedRigStore',
        level: 900,
      );
      await _writeOwnerOnly(tokenFile, token);
      return LinkedRigTokenStorage.ownerOnlyFile;
    }
  }

  Future<void> _writeRecord(LinkedRig rig) async {
    final file = await _file(_recordFile);
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(rig.toJson()),
      flush: true,
    );
    await temp.rename(file.path);
  }

  /// Keep the pairing but stop (or start) launching as its client.
  Future<void> setActive(bool active) async {
    final rig = await load();
    if (rig == null || rig.active == active) return;
    await _writeRecord(rig.copyWith(active: active));
  }

  /// Drop the rig and its token entirely.
  Future<void> forget() async {
    try {
      await _secure.delete(key: await _keyringKey());
    } catch (e) {
      developer.log('keyring delete failed: $e', name: 'LinkedRigStore');
    }
    for (final name in [_recordFile, _tokenFile]) {
      final file = await _file(name);
      if (await file.exists()) await file.delete();
    }
  }

  /// A stable id for this install, sent as `deviceId` when pairing so the host
  /// lists one entry per desktop however many times it re-pairs.
  Future<String> deviceId() async {
    final file = await _file(_deviceIdFile);
    try {
      if (await file.exists()) {
        final existing = (await file.readAsString()).trim();
        if (existing.isNotEmpty) return existing;
      }
    } catch (_) {}
    final rng = Random.secure();
    final hex = List.generate(
      16,
      (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final id = 'desktop:$hex';
    await file.parent.create(recursive: true);
    await file.writeAsString(id, flush: true);
    return id;
  }

  static Future<void> _writeOwnerOnly(File file, String contents) async {
    await file.parent.create(recursive: true);
    if (!await file.exists()) await file.create();
    if (!Platform.isWindows) {
      try {
        await Process.run('chmod', ['600', file.path]);
      } catch (_) {}
    }
    await file.writeAsString(contents, flush: true);
  }
}

enum LinkedRigTokenStorage { keyring, ownerOnlyFile }

class _PlatformKeyring implements SecureKeyValueStore {
  const _PlatformKeyring();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  @override
  Future<String?> read({required String key}) => _storage.read(key: key);

  @override
  Future<void> write({required String key, required String value}) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete({required String key}) => _storage.delete(key: key);
}
