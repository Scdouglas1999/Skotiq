/// Pre-flight validation strictness mode. Tunes how aggressively the
/// pre-flight dialog should warn (or block) on questionable conditions:
///
///   * [lax]     — only obvious hardware errors block. Missing darks, stale
///                 polar alignment, mild time drift all surface as `info`.
///                 Suitable for "experienced user, knows what they're doing".
///   * [normal]  — default. Missing darks / stale alignment / cooler ambient
///                 issues become `warning`. Sequence can still start.
///   * [strict]  — production / unattended imaging. Missing darks and stale
///                 polar alignment become `error` (sequence won't start).
///                 Time-sync drift > 30 s is always an error regardless of
///                 strictness (it would falsify FITS timestamps).
enum PreflightStrictness { lax, normal, strict }

extension PreflightStrictnessLabel on PreflightStrictness {
  String get persistedName {
    switch (this) {
      case PreflightStrictness.lax:
        return 'lax';
      case PreflightStrictness.normal:
        return 'normal';
      case PreflightStrictness.strict:
        return 'strict';
    }
  }

  String get displayName {
    switch (this) {
      case PreflightStrictness.lax:
        return 'Lax';
      case PreflightStrictness.normal:
        return 'Normal';
      case PreflightStrictness.strict:
        return 'Strict';
    }
  }

  String get description {
    switch (this) {
      case PreflightStrictness.lax:
        return 'Soft warnings only. Missing darks and stale calibration surface as info.';
      case PreflightStrictness.normal:
        return 'Default. Missing darks and stale calibration are warnings; severe issues block.';
      case PreflightStrictness.strict:
        return 'Production / unattended. Missing darks and stale alignment block the start.';
    }
  }
}
