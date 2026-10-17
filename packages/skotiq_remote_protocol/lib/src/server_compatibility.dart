/// Compatibility policy for discovered Skotiq remote/headless servers.
///
/// This is the single source of truth for the Skotiq version-negotiation
/// policy. skotiq_core's `RemoteApiCompatibility` is a thin adapter that
/// delegates here, so the two halves of the connect flow (mobile pre-flight and
/// the [NetworkBackend] WS-handshake gate) cannot drift. Changing the floor /
/// current API version or the wire header here changes it everywhere.
class SkotiqServerCompatibility {
  static const apiVersionHeader = 'x-skotiq-api-version';
  // 2.4.0 is the floor: prior releases lacked the auth/pairing surface and the
  // `x-skotiq-api-version` handshake this client now relies on. Older
  // servers will surface a clear `server_too_old` error instead of a confusing
  // partial connection.
  static const minimumSupportedVersion = ServerSemanticVersion(2, 4, 0);
  static const serverApiVersion = ServerSemanticVersion(2, 6, 0);
  static const clientApiVersion = serverApiVersion;

  const SkotiqServerCompatibility._();

  static ServerCompatibilityResult check(String? serverVersion) {
    final parsed = ServerSemanticVersion.tryParse(serverVersion);
    if (parsed == null) {
      return ServerCompatibilityResult.incompatible(
        code: 'server_version_unknown',
        message:
            'The Skotiq server did not report a valid API version. Update the server before connecting.',
        serverVersion: serverVersion,
      );
    }

    if (parsed < minimumSupportedVersion) {
      return ServerCompatibilityResult.incompatible(
        code: 'server_too_old',
        message:
            'This Skotiq server is too old for this client. Server: ${parsed.format()}, required: ${minimumSupportedVersion.format()} or newer.',
        serverVersion: parsed.format(),
      );
    }

    if (parsed.major > clientApiVersion.major) {
      return ServerCompatibilityResult.incompatible(
        code: 'server_too_new',
        message:
            'This Skotiq server is newer than this client supports. Server: ${parsed.format()}, client API: ${clientApiVersion.format()}. Update this client before connecting.',
        serverVersion: parsed.format(),
      );
    }

    return ServerCompatibilityResult.compatible(serverVersion: parsed.format());
  }

  static ServerCompatibilityResult checkClient(String? clientVersion) {
    final parsed = ServerSemanticVersion.tryParse(clientVersion);
    if (parsed == null) {
      return ServerCompatibilityResult.incompatible(
        code: 'client_version_unknown',
        message:
            'The Skotiq client did not send a valid API version. Update the client before connecting.',
        serverVersion: serverApiVersion.format(),
        clientVersion: clientVersion,
      );
    }

    if (parsed < minimumSupportedVersion) {
      return ServerCompatibilityResult.incompatible(
        code: 'client_too_old',
        message:
            'This Skotiq client is too old for this server. Client: ${parsed.format()}, required: ${minimumSupportedVersion.format()} or newer.',
        serverVersion: serverApiVersion.format(),
        clientVersion: parsed.format(),
      );
    }

    if (parsed.major > serverApiVersion.major) {
      return ServerCompatibilityResult.incompatible(
        code: 'server_too_old',
        message:
            'This Skotiq server is too old for this client. Server API: ${serverApiVersion.format()}, client API: ${parsed.format()}. Update the server before connecting.',
        serverVersion: serverApiVersion.format(),
        clientVersion: parsed.format(),
      );
    }

    return ServerCompatibilityResult.compatible(
      serverVersion: serverApiVersion.format(),
      clientVersion: parsed.format(),
    );
  }
}

class ServerCompatibilityResult {
  final bool isCompatible;
  final String code;
  final String message;
  final String? serverVersion;
  final String? clientVersion;

  const ServerCompatibilityResult._({
    required this.isCompatible,
    required this.code,
    required this.message,
    required this.serverVersion,
    required this.clientVersion,
  });

  factory ServerCompatibilityResult.compatible({
    required String serverVersion,
    String? clientVersion,
  }) {
    return ServerCompatibilityResult._(
      isCompatible: true,
      code: 'compatible',
      message: 'Compatible with Skotiq server $serverVersion.',
      serverVersion: serverVersion,
      clientVersion: clientVersion,
    );
  }

  factory ServerCompatibilityResult.incompatible({
    required String code,
    required String message,
    required String? serverVersion,
    String? clientVersion,
  }) {
    return ServerCompatibilityResult._(
      isCompatible: false,
      code: code,
      message: message,
      serverVersion: serverVersion,
      clientVersion: clientVersion,
    );
  }
}

class ServerSemanticVersion implements Comparable<ServerSemanticVersion> {
  final int major;
  final int minor;
  final int patch;

  const ServerSemanticVersion(this.major, this.minor, this.patch);

  static ServerSemanticVersion? tryParse(String? value) {
    if (value == null) return null;
    final match = RegExp(
      r'^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?',
    ).firstMatch(value.trim());
    if (match == null) return null;

    return ServerSemanticVersion(
      int.parse(match.group(1)!),
      int.tryParse(match.group(2) ?? '') ?? 0,
      int.tryParse(match.group(3) ?? '') ?? 0,
    );
  }

  String format() => '$major.$minor.$patch';

  @override
  int compareTo(ServerSemanticVersion other) {
    final majorCompare = major.compareTo(other.major);
    if (majorCompare != 0) return majorCompare;
    final minorCompare = minor.compareTo(other.minor);
    if (minorCompare != 0) return minorCompare;
    return patch.compareTo(other.patch);
  }

  bool operator <(ServerSemanticVersion other) => compareTo(other) < 0;

  @override
  bool operator ==(Object other) {
    return other is ServerSemanticVersion &&
        major == other.major &&
        minor == other.minor &&
        patch == other.patch;
  }

  @override
  int get hashCode => Object.hash(major, minor, patch);
}
