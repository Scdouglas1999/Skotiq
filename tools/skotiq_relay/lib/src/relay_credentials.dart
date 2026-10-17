// Appliance-side relay credentials: the (id, secret) pair minted by the
// relay at first registration. The secret authenticates the APPLIANCE to
// the RELAY only — end-to-end auth between phone and appliance remains the
// existing HMAC pairing token, which the relay never sees in plaintext
// (it only forwards opaque tunnel bytes).

import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// The identity an appliance presents to the relay.
class RelayCredentials {
  final String applianceId;
  final String secret;

  const RelayCredentials({required this.applianceId, required this.secret});

  Map<String, dynamic> toJson() => {
    'applianceId': applianceId,
    'secret': secret,
  };

  static RelayCredentials? fromJson(Map<String, dynamic> json) {
    final id = json['applianceId'];
    final secret = json['secret'];
    if (id is! String || id.isEmpty || secret is! String || secret.isEmpty) {
      return null;
    }
    return RelayCredentials(applianceId: id, secret: secret);
  }
}

/// Where the appliance persists its minted credentials between restarts.
abstract class RelayCredentialsStore {
  Future<RelayCredentials?> load();
  Future<void> save(RelayCredentials credentials);
}

/// JSON-file store, used by the headless daemon (file lives next to the
/// other appliance state under the app-support directory). World-readable
/// is acceptable: the secret only grants "pretend to be this appliance's
/// tunnel endpoint", and a phone still cannot authenticate against an
/// imposter without the HMAC pairing token. Permissions are tightened to
/// 600 on POSIX anyway.
class FileRelayCredentialsStore implements RelayCredentialsStore {
  final String path;

  const FileRelayCredentialsStore(this.path);

  @override
  Future<RelayCredentials?> load() async {
    final file = File(path);
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      return RelayCredentials.fromJson(decoded);
    } on FormatException {
      // Corrupt file: treat as unregistered; the relay will mint a new
      // identity (the old appliance id becomes unreachable, which is the
      // honest outcome of losing the secret).
      return null;
    }
  }

  @override
  Future<void> save(RelayCredentials credentials) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final tmp = File('$path.tmp');
    await tmp.writeAsString(jsonEncode(credentials.toJson()), flush: true);
    await tmp.rename(path);
    if (!Platform.isWindows) {
      try {
        await Process.run('chmod', ['600', path]);
      } catch (_) {
        // Best-effort tightening only.
      }
    }
  }
}

/// In-memory store for tests.
class MemoryRelayCredentialsStore implements RelayCredentialsStore {
  RelayCredentials? credentials;

  MemoryRelayCredentialsStore([this.credentials]);

  @override
  Future<RelayCredentials?> load() async => credentials;

  @override
  Future<void> save(RelayCredentials value) async => credentials = value;
}

const String _idAlphabet = 'abcdefghjkmnpqrstuvwxyz23456789';

/// Mint a human-relayable appliance id (e.g. `k7mp-q2vx-9rtn`): lowercase,
/// no ambiguous characters, 31^12 ≈ 7.9e17 combinations.
String mintApplianceId(Random random) {
  final sb = StringBuffer();
  for (var group = 0; group < 3; group++) {
    if (group > 0) sb.write('-');
    for (var i = 0; i < 4; i++) {
      sb.write(_idAlphabet[random.nextInt(_idAlphabet.length)]);
    }
  }
  return sb.toString();
}

/// Mint a 256-bit hex secret.
String mintSecret(Random random) {
  final sb = StringBuffer();
  for (var i = 0; i < 32; i++) {
    sb.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// `true` when [id] looks like a minted appliance id. Used for cheap input
/// validation on both the relay (path segment) and the phone (form field).
bool isValidApplianceId(String id) =>
    RegExp(r'^[a-z2-9]{4}-[a-z2-9]{4}-[a-z2-9]{4}$').hasMatch(id);
