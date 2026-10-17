import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

/// Compatibility policy for Skotiq remote/headless API clients.
///
/// This is a thin adapter over [SkotiqServerCompatibility] in
/// skotiq_remote_protocol, which is the single source of truth for the
/// version-negotiation policy. Both halves of the mobile connect flow (the
/// pre-flight check in the discovery layer and the WebSocket-handshake gate in
/// [NetworkBackend]) therefore evaluate the *same* logic and constants and
/// cannot drift apart. Only the decision-making is delegated: the core-side
/// [SemanticVersion] / [RemoteApiCompatibilityResult] surface stays here.
class RemoteApiCompatibility {
  static const apiVersionHeader =
      SkotiqServerCompatibility.apiVersionHeader;
  // 2.4.0 is the floor for the hardened remote API. Earlier 2.x builds did
  // not expose the auth, pairing, and version-negotiation contracts required
  // by current desktop, mobile, and WebRTC clients. Sourced from
  // SkotiqServerCompatibility so the two policies cannot diverge.
  static final SemanticVersion minimumSupportedVersion = _toCore(
    SkotiqServerCompatibility.minimumSupportedVersion,
  );
  static final SemanticVersion serverApiVersion = _toCore(
    SkotiqServerCompatibility.serverApiVersion,
  );
  static final SemanticVersion clientApiVersion = _toCore(
    SkotiqServerCompatibility.clientApiVersion,
  );

  const RemoteApiCompatibility._();

  static RemoteApiCompatibilityResult check(String? serverVersion) =>
      _adapt(SkotiqServerCompatibility.check(serverVersion));

  static RemoteApiCompatibilityResult checkClient(String? clientVersion) =>
      _adapt(SkotiqServerCompatibility.checkClient(clientVersion));

  static SemanticVersion _toCore(ServerSemanticVersion v) =>
      SemanticVersion(v.major, v.minor, v.patch);

  static RemoteApiCompatibilityResult _adapt(ServerCompatibilityResult r) {
    return r.isCompatible
        ? RemoteApiCompatibilityResult.compatible(
            serverVersion: r.serverVersion ?? serverApiVersion.format(),
            clientVersion: r.clientVersion,
          )
        : RemoteApiCompatibilityResult.incompatible(
            code: r.code,
            message: r.message,
            serverVersion: r.serverVersion,
            clientVersion: r.clientVersion,
          );
  }
}

class RemoteApiCompatibilityResult {
  final bool isCompatible;
  final String code;
  final String message;
  final String? serverVersion;
  final String? clientVersion;

  const RemoteApiCompatibilityResult._({
    required this.isCompatible,
    required this.code,
    required this.message,
    required this.serverVersion,
    required this.clientVersion,
  });

  factory RemoteApiCompatibilityResult.compatible({
    required String serverVersion,
    String? clientVersion,
  }) {
    return RemoteApiCompatibilityResult._(
      isCompatible: true,
      code: 'compatible',
      message: 'Compatible with Skotiq server $serverVersion.',
      serverVersion: serverVersion,
      clientVersion: clientVersion,
    );
  }

  factory RemoteApiCompatibilityResult.incompatible({
    required String code,
    required String message,
    required String? serverVersion,
    String? clientVersion,
  }) {
    return RemoteApiCompatibilityResult._(
      isCompatible: false,
      code: code,
      message: message,
      serverVersion: serverVersion,
      clientVersion: clientVersion,
    );
  }
}

class SemanticVersion implements Comparable<SemanticVersion> {
  final int major;
  final int minor;
  final int patch;

  const SemanticVersion(this.major, this.minor, this.patch);

  static SemanticVersion? tryParse(String? value) {
    if (value == null) return null;
    final match = RegExp(
      r'^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?',
    ).firstMatch(value.trim());
    if (match == null) return null;

    return SemanticVersion(
      int.parse(match.group(1)!),
      int.tryParse(match.group(2) ?? '') ?? 0,
      int.tryParse(match.group(3) ?? '') ?? 0,
    );
  }

  String format() => '$major.$minor.$patch';

  @override
  int compareTo(SemanticVersion other) {
    final majorCompare = major.compareTo(other.major);
    if (majorCompare != 0) return majorCompare;
    final minorCompare = minor.compareTo(other.minor);
    if (minorCompare != 0) return minorCompare;
    return patch.compareTo(other.patch);
  }

  bool operator <(SemanticVersion other) => compareTo(other) < 0;
  bool operator >(SemanticVersion other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) {
    return other is SemanticVersion &&
        major == other.major &&
        minor == other.minor &&
        patch == other.patch;
  }

  @override
  int get hashCode => Object.hash(major, minor, patch);
}
