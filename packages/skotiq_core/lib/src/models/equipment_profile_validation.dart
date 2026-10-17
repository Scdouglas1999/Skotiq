/// Pure, UI-agnostic validation + parsing for equipment-profile input.
///
/// Both profile editors (the equipment `ProfileEditorDialog` and the Settings ›
/// Equipment Profiles inline editor) and the headless `POST /api/profiles`
/// handler funnel raw user/wire input through this single contract, so a blank
/// or malformed value is rejected — or normalized — the same way everywhere
/// instead of each call site silently coercing bad input to `0`/`null` with its
/// own `tryParse`. Keeping the numeric contract in one pure library also stops
/// an editor's local-save and remote-save build paths from drifting apart.
library;

import 'dart:convert';

import '../services/optical_train_limits.dart';
import 'equipment_profile.dart';
import 'meridian_flip_settings.dart';

/// Field/range limits shared by every profile-edit surface.
class EquipmentProfileLimits {
  const EquipmentProfileLimits._();

  /// Matches the Drift `equipment_profiles.name` column, `text(min: 1,
  /// max: 100)` — validating here keeps a too-long name from reaching the DB
  /// as an opaque constraint failure.
  static const int nameMinLength = 1;
  static const int nameMaxLength = 100;

  /// Square/independent binning factors the editors offer in their dropdowns.
  static const int binningMin = 1;
  static const int binningMax = 4;

  /// Canonical plate-solve/centering exposure window (seconds). Mirrors the
  /// `0.001..86400` range already enforced by centering and headless
  /// sequencing (see `secondary_rig_provider`).
  static const double centeringExposureMinSeconds = 0.001;
  static const double centeringExposureMaxSeconds = 86400.0;
}

/// Outcome of parsing one profile field: either a normalized [value] or an
/// [error] message. `error == null` means success — and [value] (which may be
/// a legitimate `null` for an optional field left blank) is then authoritative.
class ProfileFieldResult<T> {
  final T? value;
  final String? error;

  const ProfileFieldResult.ok(this.value) : error = null;
  const ProfileFieldResult.fail(String this.error) : value = null;

  bool get isValid => error == null;
}

/// A single filter row as typed in an editor: the raw name and offset strings.
class ProfileFilterRowInput {
  final String name;
  final String offset;

  const ProfileFilterRowInput({required this.name, required this.offset});
}

/// Normalized filter configuration: ordered [names] and the non-zero focus
/// [offsets] keyed by name. A zero offset is the default, so it is omitted from
/// the map (an absent entry reads back as `0`), matching the long-standing
/// on-disk encoding.
class ProfileFilterConfig {
  final List<String> names;
  final Map<String, int> offsets;

  const ProfileFilterConfig(this.names, this.offsets);
}

/// Outcome of validating a full set of filter rows: either a normalized
/// [config] or one message per rejected row in [errors].
class ProfileFilterResult {
  final ProfileFilterConfig? config;
  final List<String> errors;

  const ProfileFilterResult.ok(ProfileFilterConfig this.config)
    : errors = const [];
  const ProfileFilterResult.fail(this.errors) : config = null;

  bool get isValid => config != null;
}

/// Pure parsers/validators for the equipment-profile fields. Every method is
/// static and side-effect free so it can run from a widget, a headless handler,
/// or a unit test identically.
class ProfileValidator {
  const ProfileValidator._();

  /// Profile name: trimmed, required, and 1..100 characters (the Drift schema
  /// bound). Returns the trimmed name on success.
  static ProfileFieldResult<String> parseName(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return const ProfileFieldResult.fail('Profile name is required');
    }
    if (trimmed.length > EquipmentProfileLimits.nameMaxLength) {
      return const ProfileFieldResult.fail(
        'Profile name must be '
        '${EquipmentProfileLimits.nameMaxLength} characters or fewer',
      );
    }
    return ProfileFieldResult.ok(trimmed);
  }

  /// Typed focal length (mm) as entered in an editor. Blank means
  /// "unspecified" and maps to the model's `0` sentinel; any other value must
  /// be finite, strictly positive, and inside [OpticalTrainLimits].
  static ProfileFieldResult<double> parseFocalLength(String raw) => _parseOptic(
    raw,
    label: 'Focal length',
    min: OpticalTrainLimits.minFocalLengthMm,
    max: OpticalTrainLimits.maxFocalLengthMm,
  );

  /// Typed aperture (mm) as entered in an editor. Same contract as
  /// [parseFocalLength], bounded by [OpticalTrainLimits].
  static ProfileFieldResult<double> parseAperture(String raw) => _parseOptic(
    raw,
    label: 'Aperture',
    min: OpticalTrainLimits.minApertureMm,
    max: OpticalTrainLimits.maxApertureMm,
  );

  /// Optics (focal length / aperture). These are optional because `0` means
  /// "unspecified" in the model, so a blank field maps to `0`. A non-blank
  /// value must parse as a finite, strictly-positive number; malformed or
  /// `<= 0` input is rejected rather than silently collapsed to `0`.
  ///
  /// The plausibility bound is what stops a fat-fingered `999999999` mm from
  /// reaching the FITS `FOCALLEN` card and the plate-solve field-of-view
  /// estimate. Bounds are never passed in by a caller — each public wrapper
  /// hardwires the shared [OpticalTrainLimits] constant for its field, so no
  /// surface can drift to a looser range of its own.
  static ProfileFieldResult<double> _parseOptic(
    String raw, {
    required String label,
    required double min,
    required double max,
  }) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return const ProfileFieldResult.ok(0.0);
    final parsed = double.tryParse(trimmed);
    if (parsed == null || !parsed.isFinite || parsed <= 0) {
      return ProfileFieldResult.fail(
        '$label must be a positive number (leave blank if unknown)',
      );
    }
    if (parsed < min || parsed > max) {
      return ProfileFieldResult.fail(
        '$label must be between ${_trim(min)} and ${_trim(max)} mm',
      );
    }
    return ProfileFieldResult.ok(parsed);
  }

  /// Cross-field plausibility for a profile's optical train, delegated wholesale
  /// to [OpticalTrainLimits.validate] so the bounds AND the messages are the
  /// ones every other surface uses. Returns the first problem, or null.
  ///
  /// A profile may legitimately leave optics unspecified (`0` focal length
  /// and/or `0` aperture, `null` pixel size), which the shared validator has no
  /// concept of — it treats every field as required. Rather than re-implement
  /// its checks with a different notion of "optional", an unspecified field is
  /// filled with a stand-in that is guaranteed in-range:
  ///
  /// * a missing partner in the focal-length/aperture pair is derived by
  ///   clamping the supplied side into the partner's own range, which always
  ///   yields an f-ratio in `[1, 10]` — inside the shared f-ratio window, so
  ///   the substitution can never be the reason validation fails;
  /// * when both sides are missing, both take their range minimum (f/1);
  /// * a missing pixel size takes a real sensor pitch.
  ///
  /// The consequence is that only a value the caller actually supplied can
  /// produce an error, and the f-ratio sanity check runs exactly when both
  /// sides of the pair are known.
  static String? validateOpticalTrain({
    required double focalLengthMm,
    required double apertureMm,
    double? pixelSizeMicrons,
  }) {
    final hasFocal = focalLengthMm > 0;
    final hasAperture = apertureMm > 0;
    if (!hasFocal && !hasAperture && pixelSizeMicrons == null) return null;

    final double effectiveFocal;
    final double effectiveAperture;
    if (hasFocal && hasAperture) {
      effectiveFocal = focalLengthMm;
      effectiveAperture = apertureMm;
    } else if (hasFocal) {
      effectiveFocal = focalLengthMm;
      effectiveAperture = focalLengthMm.clamp(
        OpticalTrainLimits.minApertureMm,
        OpticalTrainLimits.maxApertureMm,
      );
    } else if (hasAperture) {
      effectiveFocal = apertureMm.clamp(
        OpticalTrainLimits.minFocalLengthMm,
        OpticalTrainLimits.maxFocalLengthMm,
      );
      effectiveAperture = apertureMm;
    } else {
      effectiveFocal = OpticalTrainLimits.minFocalLengthMm;
      effectiveAperture = OpticalTrainLimits.minApertureMm;
    }

    return OpticalTrainLimits.validate(
      focalLengthMm: effectiveFocal,
      apertureMm: effectiveAperture,
      pixelSizeMicrons: pixelSizeMicrons ?? _standInPixelSizeMicrons,
      reducerFactor: _standInReducerFactor,
    );
  }

  /// Pixel pitch of an IMX571 — a real sensor, used only as an in-range
  /// stand-in when a profile carries no pixel size.
  static const double _standInPixelSizeMicrons = 3.76;

  /// A profile row has no reducer field; `1.0` is "no reducer" and is inside
  /// the shared reducer range.
  static const double _standInReducerFactor = 1.0;

  /// Trim a trailing `.0` so a bound reads as `50000` rather than `50000.0`.
  static String _trim(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toString();

  /// Optional whole non-negative integer (camera gain / offset). Blank maps to
  /// `null`; a non-blank value must be a whole integer `>= 0`. No upper bound
  /// is invented here — no connected-camera capability is authoritative at
  /// edit time.
  static ProfileFieldResult<int?> parseOptionalWholeNonNegative(
    String raw, {
    required String label,
  }) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return const ProfileFieldResult.ok(null);
    final parsed = int.tryParse(trimmed);
    if (parsed == null || parsed < 0) {
      return ProfileFieldResult.fail(
        '$label must be a whole number of 0 or more',
      );
    }
    return ProfileFieldResult.ok(parsed);
  }

  /// Optional cooling target (°C). Blank maps to `null`; a non-blank value must
  /// be finite. No range clamp — cameras' safe cooling deltas vary widely and
  /// no canonical range exists, so only malformed/non-finite input is rejected.
  static ProfileFieldResult<double?> parseCoolingTarget(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return const ProfileFieldResult.ok(null);
    final parsed = double.tryParse(trimmed);
    if (parsed == null || !parsed.isFinite) {
      return const ProfileFieldResult.fail(
        'Cooling target must be a number in °C',
      );
    }
    return ProfileFieldResult.ok(parsed);
  }

  /// Optional default centering exposure (seconds). Blank maps to `null`; a
  /// non-blank value must be finite and within the canonical `0.001..86400 s`
  /// window enforced by centering/headless sequencing.
  static ProfileFieldResult<double?> parseCenteringExposure(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return const ProfileFieldResult.ok(null);
    final parsed = double.tryParse(trimmed);
    if (parsed == null ||
        !parsed.isFinite ||
        parsed < EquipmentProfileLimits.centeringExposureMinSeconds ||
        parsed > EquipmentProfileLimits.centeringExposureMaxSeconds) {
      return const ProfileFieldResult.fail(
        'Centering exposure must be between 0.001 and 86400 seconds',
      );
    }
    return ProfileFieldResult.ok(parsed);
  }

  /// Binning factor: must be one of the offered `1..4` values.
  static ProfileFieldResult<int> parseBinning(
    int value, {
    String label = 'Binning',
  }) {
    if (value < EquipmentProfileLimits.binningMin ||
        value > EquipmentProfileLimits.binningMax) {
      return ProfileFieldResult.fail('$label must be between 1 and 4');
    }
    return ProfileFieldResult.ok(value);
  }

  /// Validate and normalize a full set of filter rows.
  ///
  /// Rules:
  /// - A blank-name row is dropped only when its offset is also effectively
  ///   blank/default (empty or `0`). A blank name paired with a non-zero or
  ///   otherwise non-blank offset is rejected, so a legitimate offset is never
  ///   silently orphaned.
  /// - Names are de-duplicated case-insensitively, matching how filter
  ///   selection resolves a filter to a wheel slot (`filter_rules`).
  /// - Each non-blank offset must be a whole signed integer; negative focus
  ///   offsets are preserved. A malformed offset is rejected rather than
  ///   coerced to `0`.
  static ProfileFilterResult parseFilterRows(List<ProfileFilterRowInput> rows) {
    final names = <String>[];
    final offsets = <String, int>{};
    final seen = <String>{};
    final errors = <String>[];

    for (var i = 0; i < rows.length; i++) {
      final label = 'Filter ${i + 1}';
      final name = rows[i].name.trim();
      final rawOffset = rows[i].offset.trim();

      if (name.isEmpty) {
        // Omit a blank row only when its offset carries no information.
        final isDefaultOffset =
            rawOffset.isEmpty || int.tryParse(rawOffset) == 0;
        if (!isDefaultOffset) {
          errors.add('$label has a focus offset but no filter name');
        }
        continue;
      }

      if (!seen.add(name.toLowerCase())) {
        errors.add('Duplicate filter name "$name"');
        continue;
      }

      int offset;
      if (rawOffset.isEmpty) {
        offset = 0;
      } else {
        final parsed = int.tryParse(rawOffset);
        if (parsed == null) {
          errors.add('$label focus offset must be a whole number');
          continue;
        }
        offset = parsed;
      }

      names.add(name);
      if (offset != 0) offsets[name] = offset;
    }

    if (errors.isNotEmpty) return ProfileFilterResult.fail(errors);
    return ProfileFilterResult.ok(ProfileFilterConfig(names, offsets));
  }

  /// Defense-in-depth semantic validation for a wire [EquipmentProfile]
  /// arriving at `POST /api/profiles`. Returns a human message for the first
  /// violated invariant, or `null` when the profile is acceptable. Mirrors the
  /// editor-side rules so a remote caller cannot bypass the UI checks and poke
  /// malformed values straight into the DAO.
  static String? validateWireProfile(EquipmentProfile p) {
    final nameResult = parseName(p.name);
    if (!nameResult.isValid) return nameResult.error;

    // Optics: `0` is the model's "unspecified" sentinel, so allow it; reject
    // only negative or non-finite values (the string editors additionally
    // forbid a typed non-blank `<= 0`, but the wire form cannot distinguish
    // "typed 0" from "blank").
    for (final entry in <String, double>{
      'Focal length': p.focalLength,
      'Aperture': p.aperture,
      'Telescope focal length': p.telescopeFocalLength,
      'Telescope aperture': p.telescopeAperture,
    }.entries) {
      if (!entry.value.isFinite || entry.value < 0) {
        return '${entry.key} must be a non-negative number';
      }
    }

    final focalRatio = p.focalRatio;
    if (focalRatio != null && (!focalRatio.isFinite || focalRatio <= 0)) {
      return 'Focal ratio must be a positive finite number';
    }

    final pixelSize = p.pixelSize;
    if (pixelSize != null && (!pixelSize.isFinite || pixelSize <= 0)) {
      return 'Pixel size must be a positive finite number';
    }

    // Sign/finiteness alone let a remote caller persist a physically impossible
    // train (focal length 999999999 mm with aperture 0.0001 mm renders as
    // f/9999999990000), which then reaches the FITS `FOCALLEN` card and the
    // plate-solve field-of-view estimate. Bound it with the same shared
    // contract the editors use.
    final trainError = validateOpticalTrain(
      focalLengthMm: p.focalLength,
      apertureMm: p.aperture,
      pixelSizeMicrons: pixelSize,
    );
    if (trainError != null) return trainError;

    // The legacy `telescope*` pair is a live alias, not dead weight: the
    // equipment editor prefers `telescopeFocalLength` when repopulating the
    // form and writes both columns on save, so an unbounded value here comes
    // straight back as the profile's focal length.
    final telescopeError = validateOpticalTrain(
      focalLengthMm: p.telescopeFocalLength,
      apertureMm: p.telescopeAperture,
    );
    if (telescopeError != null) return 'Telescope: $telescopeError';

    // `focalRatio` is stored, not recomputed on read, so it needs the same
    // ceiling as the ratio implied by the pair above.
    if (focalRatio != null &&
        (focalRatio < OpticalTrainLimits.minFRatio ||
            focalRatio > OpticalTrainLimits.maxFRatio)) {
      return 'Focal ratio must be between f/${_trim(OpticalTrainLimits.minFRatio)} '
          'and f/${_trim(OpticalTrainLimits.maxFRatio)}';
    }

    if (p.defaultGain != null && p.defaultGain! < 0) {
      return 'Gain must be a whole number of 0 or more';
    }
    if (p.defaultOffset != null && p.defaultOffset! < 0) {
      return 'Offset must be a whole number of 0 or more';
    }

    final cooling = p.defaultCoolingTemp;
    if (cooling != null && !cooling.isFinite) {
      return 'Cooling target must be a finite number';
    }

    final centering = p.defaultCenteringExposure;
    if (centering != null &&
        (!centering.isFinite ||
            centering < EquipmentProfileLimits.centeringExposureMinSeconds ||
            centering > EquipmentProfileLimits.centeringExposureMaxSeconds)) {
      return 'Centering exposure must be between 0.001 and 86400 seconds';
    }

    final binXResult = parseBinning(p.defaultBinX, label: 'Binning X');
    if (!binXResult.isValid) return binXResult.error;
    final binYResult = parseBinning(p.defaultBinY, label: 'Binning Y');
    if (!binYResult.isValid) return binYResult.error;

    final filterError = _validateWireFilters(p.filterNames);
    if (filterError != null) return filterError;

    final offsetError = _validateWireFilterOffsets(
      p.filterFocusOffsets,
      p.filterNames,
    );
    if (offsetError != null) return offsetError;

    final meridianError = _validateMeridianFlipOverrides(
      p.meridianFlipOverrides,
    );
    if (meridianError != null) return meridianError;

    if (p.sortOrder < 0) return 'Sort order must be 0 or more';
    return null;
  }

  /// Validate the JSON-encoded `filterNames` array carried on the wire model:
  /// well-formed JSON, every entry a non-blank string, and no case-insensitive
  /// duplicates. `null`/empty means "no filters" and is accepted.
  static String? _validateWireFilters(String? filterNamesJson) {
    if (filterNamesJson == null || filterNamesJson.trim().isEmpty) return null;

    Object? decoded;
    try {
      decoded = jsonDecode(filterNamesJson);
    } on FormatException {
      return 'filterNames must be a JSON array of names';
    }
    if (decoded is! List) {
      return 'filterNames must be a JSON array of names';
    }

    final seen = <String>{};
    for (final entry in decoded) {
      if (entry is! String || entry.trim().isEmpty) {
        return 'Every filter name must be a non-empty string';
      }
      if (!seen.add(entry.trim().toLowerCase())) {
        return 'Duplicate filter name "${entry.trim()}"';
      }
    }
    return null;
  }

  /// Validate the JSON-encoded focus-offset map. Every key must name one of
  /// the configured filters and every value must be a whole signed integer;
  /// otherwise later profile decoding either drops the map or carries an
  /// offset that can never be applied.
  static String? _validateWireFilterOffsets(
    String? offsetsJson,
    String? filterNamesJson,
  ) {
    if (offsetsJson == null || offsetsJson.trim().isEmpty) return null;

    Object? decodedOffsets;
    try {
      decodedOffsets = jsonDecode(offsetsJson);
    } on FormatException {
      return 'filterFocusOffsets must be a JSON object of whole numbers';
    }
    if (decodedOffsets is! Map<String, dynamic>) {
      return 'filterFocusOffsets must be a JSON object of whole numbers';
    }

    final configured = <String>{};
    if (filterNamesJson != null && filterNamesJson.trim().isNotEmpty) {
      final decodedNames = jsonDecode(filterNamesJson) as List<dynamic>;
      configured.addAll(decodedNames.cast<String>().map((name) => name.trim()));
    }

    for (final entry in decodedOffsets.entries) {
      final name = entry.key.trim();
      if (name.isEmpty) return 'Filter focus-offset names must not be blank';
      if (entry.value is! int) {
        return 'Focus offset for "$name" must be a whole number';
      }
      if (!configured.contains(name)) {
        return 'Focus offset references unknown filter "$name"';
      }
    }
    return null;
  }

  /// Meridian-flip overrides are stored as a partial JSON object and merged
  /// with global defaults at runtime. Reject malformed types, non-finite
  /// numbers, and values outside the model's own validation contract before a
  /// corrupt override is persisted and silently ignored by the runtime.
  static String? _validateMeridianFlipOverrides(String? overridesJson) {
    if (overridesJson == null || overridesJson.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(overridesJson);
      if (decoded is! Map<String, dynamic>) {
        return 'meridianFlipOverrides must be a JSON object';
      }
      final settings = MeridianFlipSettings.fromJson(decoded);
      final scalars = <double>[
        settings.minutesPastMeridian,
        settings.minutesBeforeLimit,
        settings.hourAngleThreshold,
        settings.trackingLimitWaitMinutes,
        settings.settleTimeSeconds,
        ...settings.retryDelaysSeconds,
      ];
      if (scalars.any((value) => !value.isFinite)) {
        return 'Meridian flip override values must be finite';
      }
      final errors = settings.validate();
      if (errors.isNotEmpty) return errors.first;
    } on Object {
      return 'meridianFlipOverrides contains invalid values';
    }
    return null;
  }
}
