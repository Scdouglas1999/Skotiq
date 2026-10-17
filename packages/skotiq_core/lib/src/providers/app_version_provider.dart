import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The running application's semantic version + build number.
///
/// Single source of truth surfaced to all packages that need to label
/// payloads (backups, manifests, OTA updates, telemetry). Composed from
/// `version.yaml` and wired into the provider container at app startup
/// via `appVersionProvider.overrideWithValue(...)`.
class AppVersionInfo {
  final String version;
  final int buildNumber;

  const AppVersionInfo({required this.version, required this.buildNumber});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AppVersionInfo &&
          other.version == version &&
          other.buildNumber == buildNumber);

  @override
  int get hashCode => Object.hash(version, buildNumber);

  @override
  String toString() => '$version+$buildNumber';
}

/// Provider for the running application version.
///
/// Must be overridden at app startup. It throws rather than defaulting
/// because the OTA server compares against this string to decide whether to
/// advertise a newer build: a stand-in like `2.0.0` would offer "updates" to
/// the build already running, or refuse legitimate ones.
final appVersionProvider = Provider<AppVersionInfo>((ref) {
  throw UnsupportedError(
    'appVersionProvider must be overridden at app startup with the '
    'concrete version from version.yaml. See main.dart in apps/desktop '
    'or apps/mobile for the canonical override.',
  );
});

/// `Skotiq <version>` label for stamping exports and FITS headers
/// (AAVSO #SOFTWARE, SKHA_VER, science reports). Falls back to a plain
/// "Skotiq" when [appVersionProvider] has not been overridden (test
/// benches) so a label consumer never crashes a data export over version
/// metadata. Kept short — the FITS writeback needs it to fit a single
/// 80-char header card with room for a comment.
final appVersionLabelProvider = Provider<String>((ref) {
  try {
    final v = ref.read(appVersionProvider);
    return 'Skotiq ${v.version}';
  } catch (_) {
    return 'Skotiq';
  }
});
