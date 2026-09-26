import 'package:freezed_annotation/freezed_annotation.dart';

part 'update_manifest.freezed.dart';
part 'update_manifest.g.dart';

/// Information about a single file in the update package
@freezed
abstract class UpdateFileInfo with _$UpdateFileInfo {
  const factory UpdateFileInfo({
    required String path,
    required int size,
    required String sha256,
  }) = _UpdateFileInfo;

  factory UpdateFileInfo.fromJson(Map<String, dynamic> json) =>
      _$UpdateFileInfoFromJson(json);
}

/// Manifest for an update package
@freezed
abstract class UpdateManifest with _$UpdateManifest {
  const UpdateManifest._();

  const factory UpdateManifest({
    /// Version string (e.g., "2.1.0")
    required String version,

    /// Build number for ordering
    required int buildNumber,

    /// Release date
    required DateTime releaseDate,

    /// Target platform (windows, macos, linux)
    required String platform,

    /// Architecture (x64, arm64)
    required String arch,

    /// Minimum version required to update from
    String? minVersion,

    /// Map of file path to file info
    required Map<String, UpdateFileInfo> files,

    /// Total uncompressed size in bytes
    required int totalSize,

    /// Compressed package size in bytes
    required int compressedSize,

    /// SHA-256 hash of the downloaded package archive
    String? packageSha256,

    /// Download URL for the update package
    required String downloadUrl,

    /// Release notes (markdown)
    String? releaseNotes,

    /// Ed25519 signature for the canonical manifest payload
    String? signature,
  }) = _UpdateManifest;

  factory UpdateManifest.fromJson(Map<String, dynamic> json) =>
      _$UpdateManifestFromJson(json);

  /// Numeric release components of the version, with any prerelease tag
  /// and build metadata stripped. '2.1.0-beta.1' -> [2, 1, 0].
  List<int> get versionParts => _coreParts(version);

  /// Check if this version is newer than another
  bool isNewerThan(String otherVersion) =>
      _compareVersions(version, otherVersion) > 0;

  /// Check if this build supersedes [currentVersion]+[currentBuild].
  ///
  /// Newer when the semver is strictly newer, OR the semver is identical
  /// and this manifest's [buildNumber] is greater, so a rebuild of the same
  /// semver is offered while an identical version+build never is (that would
  /// loop a self-update). [isNewerThan] keeps a semver-only contract for
  /// callers that want pure string ordering.
  bool isNewerBuildThan(String currentVersion, int currentBuild) =>
      buildSupersedes(version, buildNumber, currentVersion, currentBuild);

  /// [isNewerBuildThan] for a build known only by its version and build
  /// number, such as a staged update whose manifest has not been read.
  static bool buildSupersedes(
    String version,
    int buildNumber,
    String currentVersion,
    int currentBuild,
  ) {
    final cmp = _compareVersions(version, currentVersion);
    if (cmp != 0) return cmp > 0;
    return buildNumber > currentBuild;
  }

  /// Check if upgrade from a version is allowed
  bool canUpgradeFrom(String fromVersion) {
    if (minVersion == null) return true;
    // At or above minVersion may upgrade; below it is gated out. Equal is
    // allowed (compare == 0). Shorter component lists are zero-padded so
    // '2.0' < '2.0.5'.
    return _compareVersions(fromVersion, minVersion!) >= 0;
  }

  /// Numeric core components (major.minor.patch...) of a semver string, with
  /// any prerelease tag and build metadata stripped. '2.1.0-beta.1' ->
  /// [2, 1, 0].
  static final RegExp _versionPattern = RegExp(
    r'^[0-9]+(?:\.[0-9]+)*(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
  );

  static List<int> _coreParts(String version) {
    if (!_versionPattern.hasMatch(version)) {
      throw FormatException('Invalid semantic version: "$version"');
    }
    return version
        .split('+')
        .first
        .split('-')
        .first
        .split('.')
        .map(int.parse)
        .toList();
  }

  /// Dot-separated prerelease identifiers of a semver string, or an empty
  /// list when there is no prerelease tag. '2.1.0-beta.1' -> ['beta', '1'].
  static List<String> _prereleaseParts(String version) {
    final withoutBuild = version.split('+').first;
    final dash = withoutBuild.indexOf('-');
    if (dash < 0) return const [];
    return withoutBuild.substring(dash + 1).split('.');
  }

  /// Compare two semver strings. Returns >0 if [a] is newer, <0 if older,
  /// 0 if equal. Numeric core components are compared first (shorter list
  /// zero-padded so '2.0' < '2.0.5'). When cores are equal, a release with
  /// no prerelease outranks one carrying a prerelease; two prereleases
  /// compare identifier by identifier (numerically when both are numbers,
  /// otherwise lexically), and a longer identifier set outranks a shorter
  /// one whose leading identifiers are equal.
  static int _compareVersions(String a, String b) {
    final coreCmp = _compareCore(_coreParts(a), _coreParts(b));
    if (coreCmp != 0) return coreCmp;

    final aPre = _prereleaseParts(a);
    final bPre = _prereleaseParts(b);
    if (aPre.isEmpty && bPre.isEmpty) return 0;
    if (aPre.isEmpty) return 1;
    if (bPre.isEmpty) return -1;

    for (var i = 0; i < aPre.length && i < bPre.length; i++) {
      final cmp = _comparePrereleaseIdentifier(aPre[i], bPre[i]);
      if (cmp != 0) return cmp;
    }
    return aPre.length.compareTo(bPre.length);
  }

  static int _compareCore(List<int> a, List<int> b) {
    final length = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < length; i++) {
      final ai = i < a.length ? a[i] : 0;
      final bi = i < b.length ? b[i] : 0;
      if (ai != bi) return ai > bi ? 1 : -1;
    }
    return 0;
  }

  static int _comparePrereleaseIdentifier(String a, String b) {
    final an = int.tryParse(a);
    final bn = int.tryParse(b);
    if (an != null && bn != null) return an.compareTo(bn);
    // Semver: numeric identifiers rank below alphanumeric ones.
    if (an != null) return -1;
    if (bn != null) return 1;
    return a.compareTo(b);
  }
}

/// Version info returned from update server
@freezed
abstract class VersionInfo with _$VersionInfo {
  const factory VersionInfo({
    /// Latest stable version
    required String latestVersion,

    /// Latest build number
    required int latestBuildNumber,

    /// Available channels
    required Map<String, ChannelInfo> channels,

    /// Minimum supported version (older versions must update)
    String? minSupportedVersion,

    /// Server version for compatibility checks
    String? serverVersion,
  }) = _VersionInfo;

  factory VersionInfo.fromJson(Map<String, dynamic> json) =>
      _$VersionInfoFromJson(json);
}

/// Channel information (stable, beta, etc.)
@freezed
abstract class ChannelInfo with _$ChannelInfo {
  const factory ChannelInfo({
    required String version,
    required String manifestUrl,
  }) = _ChannelInfo;

  factory ChannelInfo.fromJson(Map<String, dynamic> json) =>
      _$ChannelInfoFromJson(json);
}
