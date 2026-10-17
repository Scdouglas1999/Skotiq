import 'dart:convert';

import '../backend/device_types.dart';

/// Steps of the equipment-onboarding wizard in display order.
///
/// Why an explicit enum instead of an index: the wizard skips optional
/// steps based on the user's selections (e.g. focuser/filter wheel). Using
/// an enum lets [OnboardingDraft] persist which logical step the user is
/// on, even if the rendered step order changes between sessions.
enum OnboardingStep {
  welcome,
  drivers,
  camera,
  mount,
  focuser,
  filterWheel,
  guider,
  opticalTrain,

  /// Camera acquisition defaults (gain/offset/binning/cooling). Optional —
  /// sensible defaults are pre-filled from the selected camera preset, so the
  /// user can accept them with a single tap and never has to hunt forum
  /// threads. Sits between the optical train and the capture directory.
  cameraDefaults,
  captureDir,

  /// Observing site (latitude / longitude / elevation). Optional — a user
  /// setting up indoors can skip it and be nudged from the next-steps screen —
  /// but skipping leaves every location-driven surface (Tonight, planner
  /// visibility, meridian-flip timing, weather radar) in its "location not set"
  /// state. Persists straight to app settings, not the onboarding draft, since
  /// the coordinates are global observer settings rather than per-profile.
  site,
  summary,

  /// Terminal "what's next" step shown after the profile is created. This is
  /// the true end of the wizard: leaving it (via [OnboardingNotifier.finishNextSteps])
  /// is what marks the tutorial complete and flips the bootstrap gate off.
  nextSteps,
}

extension OnboardingStepOrder on OnboardingStep {
  /// Sequential index used for the progress dots in the wizard footer.
  int get order => OnboardingStep.values.indexOf(this);

  /// Total number of steps (constant; used for the "Step N of 10" label).
  static int get total => OnboardingStep.values.length;

  /// True for steps the user is allowed to skip without affecting profile
  /// validity. The wizard still renders them, but the Skip button is only
  /// visible (and only commits a null device id) on these.
  bool get isOptional {
    switch (this) {
      case OnboardingStep.focuser:
      case OnboardingStep.filterWheel:
      case OnboardingStep.guider:
      // Camera defaults are optional: the preset pre-fills sensible
      // gain/offset/binning/cooling values, so the user can move on without
      // touching them.
      case OnboardingStep.cameraDefaults:
      // The observing site is optional at setup time — a location can be added
      // later from Settings — though skipping degrades the location-driven
      // surfaces until it is.
      case OnboardingStep.site:
        return true;
      case OnboardingStep.welcome:
      case OnboardingStep.drivers:
      case OnboardingStep.camera:
      case OnboardingStep.mount:
      case OnboardingStep.opticalTrain:
      case OnboardingStep.captureDir:
      case OnboardingStep.summary:
      // The terminal step is the end of the wizard, not a forward-skippable
      // step — there is nothing after it to skip to.
      case OnboardingStep.nextSteps:
        return false;
    }
  }
}

/// Draft state for the equipment-onboarding wizard.
///
/// Persisted as JSON in `tutorial_progress.category =
/// OnboardingDraft.persistenceCategory`, with the JSON blob stored in a
/// separate app_settings row so the existing tutorial_progress schema does
/// not need a new column. The wizard reads and writes through
/// [OnboardingNotifier], which serializes via [toJson] / [fromJson].
///
/// Why a plain class instead of freezed: the wizard only mutates state via
/// copyWith and we want this model importable from tests without invoking
/// build_runner. Equality and hashCode are defined manually so widget
/// tests can assert on state without identity reference checks.
class OnboardingDraft {
  /// Category key used to mark the wizard as completed in
  /// `tutorial_progress`. Distinct from the first-night tutorial category
  /// so the two flows do not collide.
  static const String persistenceCategory = 'equipmentOnboarding';

  /// app_settings key under which the JSON draft is stored. Wiped when the
  /// user completes or dismisses the wizard so a fresh run starts clean.
  static const String draftSettingsKey = 'equipment_onboarding_draft';

  /// Current step the user is on. Survives an app restart mid-wizard.
  final OnboardingStep currentStep;

  /// Drivers the user opted to use for discovery. Multi-select.
  final Set<DriverType> selectedDrivers;

  /// Device ids picked at each step, keyed by the device-type slug. We use
  /// the slug rather than [DeviceType] so that the JSON form is stable
  /// across enum reorderings.
  final String? cameraId;
  final String? cameraName;
  final String? mountId;
  final String? mountName;
  final String? focuserId;
  final String? focuserName;
  final String? filterWheelId;
  final String? filterWheelName;
  final String? guiderId;
  final String? guiderName;

  /// Optical-train inputs. Pixel size is microns, focal length and
  /// aperture are millimeters, reducer is a multiplier (1.0 = no reducer).
  final double? pixelSizeMicrons;
  final double? focalLengthMm;
  final double? apertureMm;
  final double reducerFactor;

  /// Filter names captured per slot when a filter wheel is configured.
  /// Empty list when no filter wheel is selected.
  final List<String> filterNames;

  /// Capture directory the user picked. Validated writable before being
  /// committed to settings on the summary step.
  final String? captureDirectory;

  /// Profile name on the summary step. Defaulted to "My First Rig" the
  /// first time the summary renders, but the user can override it.
  final String? profileName;

  /// Id of the telescope hardware preset the user picked at the optical-train
  /// step, when prefilled from the built-in catalog. `null` when the user
  /// typed optics manually. Persisting the id (not just the derived numbers)
  /// lets the wizard re-highlight the chosen preset on resume.
  final String? telescopePresetId;

  /// Display name of the chosen telescope preset (`brand model`). Threaded
  /// into the created profile's `telescopeName` so the rig shows a real OTA
  /// name rather than just focal length / aperture numbers.
  final String? telescopeName;

  /// Id of the camera-defaults preset applied at the camera-defaults step.
  /// `null` when the user did not pick a preset (defaults stay manual/empty).
  final String? cameraPresetId;

  /// Acquisition defaults captured at the camera-defaults step. All nullable
  /// so an unset value (e.g. a DSLR with no regulated cooling) stays null
  /// rather than collapsing to a misleading 0.
  final int? defaultGain;
  final int? defaultOffset;
  final int? defaultBinX;
  final int? defaultBinY;
  final double? defaultCoolingTempC;

  /// Whether the created profile should drive the cooler down to
  /// [defaultCoolingTempC] as soon as the camera connects.
  ///
  /// Opt-in, and asked as its own question in the wizard: a set-point on its
  /// own is only a preference, and a rig set up at noon must not pin the TEC at
  /// full power for the rest of the afternoon.
  final bool coolOnConnect;

  const OnboardingDraft({
    this.currentStep = OnboardingStep.welcome,
    this.selectedDrivers = const {},
    this.cameraId,
    this.cameraName,
    this.mountId,
    this.mountName,
    this.focuserId,
    this.focuserName,
    this.filterWheelId,
    this.filterWheelName,
    this.guiderId,
    this.guiderName,
    this.pixelSizeMicrons,
    this.focalLengthMm,
    this.apertureMm,
    this.reducerFactor = 1.0,
    this.filterNames = const [],
    this.captureDirectory,
    this.profileName,
    this.telescopePresetId,
    this.telescopeName,
    this.cameraPresetId,
    this.defaultGain,
    this.defaultOffset,
    this.defaultBinX,
    this.defaultBinY,
    this.defaultCoolingTempC,
    this.coolOnConnect = false,
  });

  OnboardingDraft copyWith({
    OnboardingStep? currentStep,
    Set<DriverType>? selectedDrivers,
    String? cameraId,
    String? cameraName,
    String? mountId,
    String? mountName,
    String? focuserId,
    String? focuserName,
    String? filterWheelId,
    String? filterWheelName,
    String? guiderId,
    String? guiderName,
    double? pixelSizeMicrons,
    double? focalLengthMm,
    double? apertureMm,
    double? reducerFactor,
    List<String>? filterNames,
    String? captureDirectory,
    String? profileName,
    String? telescopePresetId,
    String? telescopeName,
    String? cameraPresetId,
    int? defaultGain,
    int? defaultOffset,
    int? defaultBinX,
    int? defaultBinY,
    double? defaultCoolingTempC,
    bool? coolOnConnect,
    bool clearCamera = false,
    bool clearMount = false,
    bool clearFocuser = false,
    bool clearFilterWheel = false,
    bool clearGuider = false,
    bool clearFocalLength = false,
    bool clearAperture = false,
    bool clearPixelSize = false,
    bool clearCoolingTempC = false,
    // A plain null argument means "leave unchanged", which cannot express the
    // user emptying a field. Without these the camera-defaults step showed a
    // blank Gain box while the draft — and the profile created from it — still
    // carried the number the preset had put there.
    bool clearGain = false,
    bool clearOffset = false,
    bool clearBinX = false,
    bool clearBinY = false,
  }) {
    return OnboardingDraft(
      currentStep: currentStep ?? this.currentStep,
      selectedDrivers: selectedDrivers ?? this.selectedDrivers,
      cameraId: clearCamera ? null : (cameraId ?? this.cameraId),
      cameraName: clearCamera ? null : (cameraName ?? this.cameraName),
      mountId: clearMount ? null : (mountId ?? this.mountId),
      mountName: clearMount ? null : (mountName ?? this.mountName),
      focuserId: clearFocuser ? null : (focuserId ?? this.focuserId),
      focuserName: clearFocuser ? null : (focuserName ?? this.focuserName),
      filterWheelId: clearFilterWheel
          ? null
          : (filterWheelId ?? this.filterWheelId),
      filterWheelName: clearFilterWheel
          ? null
          : (filterWheelName ?? this.filterWheelName),
      guiderId: clearGuider ? null : (guiderId ?? this.guiderId),
      guiderName: clearGuider ? null : (guiderName ?? this.guiderName),
      pixelSizeMicrons: clearPixelSize
          ? null
          : (pixelSizeMicrons ?? this.pixelSizeMicrons),
      focalLengthMm: clearFocalLength
          ? null
          : (focalLengthMm ?? this.focalLengthMm),
      apertureMm: clearAperture ? null : (apertureMm ?? this.apertureMm),
      reducerFactor: reducerFactor ?? this.reducerFactor,
      filterNames: filterNames ?? this.filterNames,
      captureDirectory: captureDirectory ?? this.captureDirectory,
      profileName: profileName ?? this.profileName,
      telescopePresetId: telescopePresetId ?? this.telescopePresetId,
      telescopeName: telescopeName ?? this.telescopeName,
      cameraPresetId: cameraPresetId ?? this.cameraPresetId,
      defaultGain: clearGain ? null : (defaultGain ?? this.defaultGain),
      defaultOffset: clearOffset ? null : (defaultOffset ?? this.defaultOffset),
      defaultBinX: clearBinX ? null : (defaultBinX ?? this.defaultBinX),
      defaultBinY: clearBinY ? null : (defaultBinY ?? this.defaultBinY),
      defaultCoolingTempC: clearCoolingTempC
          ? null
          : (defaultCoolingTempC ?? this.defaultCoolingTempC),
      // Clearing the set-point clears the promise that goes with it.
      coolOnConnect: clearCoolingTempC
          ? false
          : (coolOnConnect ?? this.coolOnConnect),
    );
  }

  /// Whether [step] actually put something on record in this draft.
  ///
  /// Distinct from "the user walked past it": a tick in the wizard's step list
  /// is a claim about the rig being built and must be backed by a value, so a
  /// step the user reached and skipped does not tick.
  ///
  /// [siteConfigured] is supplied by the caller: the observing site is a
  /// global observer setting persisted to app settings, not to this draft.
  ///
  /// [OnboardingStep.welcome] and [OnboardingStep.nextSteps] carry no captured
  /// value — reading them IS the step — so passing them counts as done.
  bool producedValueFor(OnboardingStep step, {required bool siteConfigured}) {
    switch (step) {
      case OnboardingStep.welcome:
      case OnboardingStep.nextSteps:
        return true;
      case OnboardingStep.drivers:
        return selectedDrivers.isNotEmpty;
      case OnboardingStep.camera:
        return cameraId != null;
      case OnboardingStep.mount:
        return mountId != null;
      case OnboardingStep.focuser:
        return focuserId != null;
      case OnboardingStep.filterWheel:
        return filterWheelId != null;
      case OnboardingStep.guider:
        return guiderId != null;
      case OnboardingStep.opticalTrain:
        return focalLengthMm != null;
      case OnboardingStep.cameraDefaults:
        return defaultGain != null ||
            defaultOffset != null ||
            defaultBinX != null ||
            defaultBinY != null ||
            defaultCoolingTempC != null;
      case OnboardingStep.captureDir:
        return (captureDirectory ?? '').trim().isNotEmpty;
      case OnboardingStep.site:
        return siteConfigured;
      case OnboardingStep.summary:
        return (profileName ?? '').trim().isNotEmpty;
    }
  }

  /// Effective focal length after applying the reducer factor.
  /// Returns null if focal length is unset so callers don't have to guard.
  double? get effectiveFocalLengthMm {
    if (focalLengthMm == null) return null;
    return focalLengthMm! * reducerFactor;
  }

  /// Image scale in arcsec/pixel from pixel size + effective focal length.
  /// Formula: 206.265 * pixel_microns / focal_length_mm.
  /// Returns null when inputs are missing or focal length is zero so the
  /// UI can render "--" instead of a misleading "0.00".
  double? get imageScaleArcsecPerPixel {
    final fl = effectiveFocalLengthMm;
    if (fl == null || fl <= 0) return null;
    if (pixelSizeMicrons == null || pixelSizeMicrons! <= 0) return null;
    return 206.265 * pixelSizeMicrons! / fl;
  }

  Map<String, dynamic> toJson() => {
    'currentStep': currentStep.name,
    'selectedDrivers': selectedDrivers.map((d) => d.name).toList(),
    'cameraId': cameraId,
    'cameraName': cameraName,
    'mountId': mountId,
    'mountName': mountName,
    'focuserId': focuserId,
    'focuserName': focuserName,
    'filterWheelId': filterWheelId,
    'filterWheelName': filterWheelName,
    'guiderId': guiderId,
    'guiderName': guiderName,
    'pixelSizeMicrons': pixelSizeMicrons,
    'focalLengthMm': focalLengthMm,
    'apertureMm': apertureMm,
    'reducerFactor': reducerFactor,
    'filterNames': filterNames,
    'captureDirectory': captureDirectory,
    'profileName': profileName,
    'telescopePresetId': telescopePresetId,
    'telescopeName': telescopeName,
    'cameraPresetId': cameraPresetId,
    'defaultGain': defaultGain,
    'defaultOffset': defaultOffset,
    'defaultBinX': defaultBinX,
    'defaultBinY': defaultBinY,
    'defaultCoolingTempC': defaultCoolingTempC,
    'coolOnConnect': coolOnConnect,
  };

  /// Deserialize a draft. Returns the default draft on parse failure so a
  /// corrupted settings row never wedges the wizard — the user just starts
  /// over.
  factory OnboardingDraft.fromJson(Map<String, dynamic> json) {
    OnboardingStep parseStep(String? name) {
      for (final s in OnboardingStep.values) {
        if (s.name == name) return s;
      }
      return OnboardingStep.welcome;
    }

    Set<DriverType> parseDrivers(dynamic raw) {
      if (raw is! List) return const {};
      final result = <DriverType>{};
      for (final entry in raw) {
        if (entry is! String) continue;
        for (final d in DriverType.values) {
          if (d.name == entry) {
            result.add(d);
            break;
          }
        }
      }
      return result;
    }

    List<String> parseFilters(dynamic raw) {
      if (raw is! List) return const [];
      return raw.whereType<String>().toList();
    }

    return OnboardingDraft(
      currentStep: parseStep(json['currentStep'] as String?),
      selectedDrivers: parseDrivers(json['selectedDrivers']),
      cameraId: json['cameraId'] as String?,
      cameraName: json['cameraName'] as String?,
      mountId: json['mountId'] as String?,
      mountName: json['mountName'] as String?,
      focuserId: json['focuserId'] as String?,
      focuserName: json['focuserName'] as String?,
      filterWheelId: json['filterWheelId'] as String?,
      filterWheelName: json['filterWheelName'] as String?,
      guiderId: json['guiderId'] as String?,
      guiderName: json['guiderName'] as String?,
      pixelSizeMicrons: (json['pixelSizeMicrons'] as num?)?.toDouble(),
      focalLengthMm: (json['focalLengthMm'] as num?)?.toDouble(),
      apertureMm: (json['apertureMm'] as num?)?.toDouble(),
      reducerFactor: (json['reducerFactor'] as num?)?.toDouble() ?? 1.0,
      filterNames: parseFilters(json['filterNames']),
      captureDirectory: json['captureDirectory'] as String?,
      profileName: json['profileName'] as String?,
      telescopePresetId: json['telescopePresetId'] as String?,
      telescopeName: json['telescopeName'] as String?,
      cameraPresetId: json['cameraPresetId'] as String?,
      defaultGain: (json['defaultGain'] as num?)?.toInt(),
      defaultOffset: (json['defaultOffset'] as num?)?.toInt(),
      defaultBinX: (json['defaultBinX'] as num?)?.toInt(),
      defaultBinY: (json['defaultBinY'] as num?)?.toInt(),
      defaultCoolingTempC: (json['defaultCoolingTempC'] as num?)?.toDouble(),
      coolOnConnect: json['coolOnConnect'] as bool? ?? false,
    );
  }

  String toJsonString() => jsonEncode(toJson());

  /// Parses a JSON-encoded draft; returns a fresh draft if the string is
  /// null, empty, or not valid JSON. Errors are swallowed here on purpose:
  /// the draft is purely an optimization, never a source of truth.
  static OnboardingDraft fromJsonStringOrEmpty(String? raw) {
    if (raw == null || raw.isEmpty) return const OnboardingDraft();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return const OnboardingDraft();
      return OnboardingDraft.fromJson(decoded);
    } catch (_) {
      return const OnboardingDraft();
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is OnboardingDraft &&
        other.currentStep == currentStep &&
        _setEquals(other.selectedDrivers, selectedDrivers) &&
        other.cameraId == cameraId &&
        other.cameraName == cameraName &&
        other.mountId == mountId &&
        other.mountName == mountName &&
        other.focuserId == focuserId &&
        other.focuserName == focuserName &&
        other.filterWheelId == filterWheelId &&
        other.filterWheelName == filterWheelName &&
        other.guiderId == guiderId &&
        other.guiderName == guiderName &&
        other.pixelSizeMicrons == pixelSizeMicrons &&
        other.focalLengthMm == focalLengthMm &&
        other.apertureMm == apertureMm &&
        other.reducerFactor == reducerFactor &&
        _listEquals(other.filterNames, filterNames) &&
        other.captureDirectory == captureDirectory &&
        other.profileName == profileName &&
        other.telescopePresetId == telescopePresetId &&
        other.telescopeName == telescopeName &&
        other.cameraPresetId == cameraPresetId &&
        other.defaultGain == defaultGain &&
        other.defaultOffset == defaultOffset &&
        other.defaultBinX == defaultBinX &&
        other.defaultBinY == defaultBinY &&
        other.defaultCoolingTempC == defaultCoolingTempC &&
        other.coolOnConnect == coolOnConnect;
  }

  @override
  int get hashCode => Object.hash(
    currentStep,
    Object.hashAllUnordered(selectedDrivers),
    cameraId,
    mountId,
    focuserId,
    filterWheelId,
    guiderId,
    pixelSizeMicrons,
    focalLengthMm,
    apertureMm,
    reducerFactor,
    Object.hashAll(filterNames),
    captureDirectory,
    profileName,
    // Group the camera-defaults + telescope-preset fields into a single
    // nested hash to stay under Object.hash's 20-argument limit.
    Object.hash(
      telescopePresetId,
      telescopeName,
      cameraPresetId,
      defaultGain,
      defaultOffset,
      defaultBinX,
      defaultBinY,
      defaultCoolingTempC,
      coolOnConnect,
    ),
  );
}

bool _setEquals<T>(Set<T> a, Set<T> b) {
  if (a.length != b.length) return false;
  return a.containsAll(b);
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
