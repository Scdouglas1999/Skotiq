/// Every field of an equipment profile, declared once.
///
/// To add a field: add one entry here, add its column to
/// `database/tables/equipment_profiles.dart` (with a schema migration), and
/// run `SKOTIQ_REGENERATE=1 flutter test test/models/equipment_profile_fields_test.dart`
/// in `packages/skotiq_core`. The entry gives the profile model
/// (`EquipmentProfileModel`), the REST body (`EquipmentProfile`), the stored
/// row mapping both ways, a save's row and the export file their field; the
/// generator writes those between the `BEGIN GENERATED` markers of the files
/// in `tool/generate_equipment_profile.dart`. A test fails when a declared
/// field has no column or a column is not declared.
///
/// The name is the model field, the Drift column getter (the SQL column is
/// its snake_case), the REST body key and the export key.
///
/// The id, the active, default and sort flags and the timestamps belong to
/// the stored row rather than to what the profile describes; each shape
/// carries them its own way, so they are not entries.
library;

/// What a field holds.
enum ProfileValueKind {
  text,
  real,
  whole,
  flag,

  /// A list of filter names: a list in the model and the export file, JSON
  /// text in the stored row and the REST body.
  filterNames,

  /// Filter name to focuser offset: a map in the model and the export file,
  /// JSON text in the stored row and the REST body.
  focusOffsets,
}

class ProfileField {
  const ProfileField(
    this.name,
    this.kind, {
    this.required = false,
    this.fallback,
    this.unsetWhenNotPositive = false,
    this.fallsBackTo,
    this.keptWhenBodyOmits = false,
    this.clearable = false,
  });

  final String name;
  final ProfileValueKind kind;

  /// Always set (only the name).
  final bool required;

  /// Dart source of the value the field holds when nothing set it. A field
  /// with one is never null; one without is nullable.
  final String? fallback;

  /// The stored column may hold 0 or less for "not set": the model reads that
  /// as null and the REST body carries 0.0 for null.
  final bool unsetWhenNotPositive;

  /// When the stored value is not positive the model reads this other
  /// field's value instead (older rows kept optics only there).
  final String? fallsBackTo;

  /// A REST body without the field keeps the host row's value instead of
  /// clearing it.
  final bool keptWhenBodyOmits;

  /// The model's `copyWith` takes a `clear<Name>` flag to set it to null.
  final bool clearable;
}

const List<ProfileField> kEquipmentProfileFields = [
  ProfileField('name', ProfileValueKind.text, required: true),
  ProfileField('description', ProfileValueKind.text),

  // The driver-specific id of the device in each slot.
  ProfileField('cameraId', ProfileValueKind.text),
  ProfileField('mountId', ProfileValueKind.text),
  ProfileField('focuserId', ProfileValueKind.text),
  ProfileField('filterWheelId', ProfileValueKind.text),
  ProfileField('guiderId', ProfileValueKind.text),

  // The camera the built-in guider takes its frames with; never the imaging
  // camera.
  ProfileField('guideCameraId', ProfileValueKind.text),

  // Guide scope focal length (mm); null for an off-axis guider, which shares
  // the telescope's focal length.
  ProfileField('guideFocalLength', ProfileValueKind.real),
  ProfileField('rotatorId', ProfileValueKind.text),
  ProfileField('domeId', ProfileValueKind.text),
  ProfileField('weatherId', ProfileValueKind.text),
  ProfileField('safetyMonitorId', ProfileValueKind.text),
  ProfileField('switchId', ProfileValueKind.text),
  ProfileField('coverCalibratorId', ProfileValueKind.text),

  // The imaging train as it images, after any reducer or barlow (mm).
  ProfileField(
    'focalLength',
    ProfileValueKind.real,
    fallback: '0.0',
    fallsBackTo: 'telescopeFocalLength',
  ),
  ProfileField(
    'aperture',
    ProfileValueKind.real,
    fallback: '0.0',
    fallsBackTo: 'telescopeAperture',
  ),
  ProfileField('focalRatio', ProfileValueKind.real),

  ProfileField('defaultGain', ProfileValueKind.whole),
  ProfileField('defaultOffset', ProfileValueKind.whole),

  // The camera read mode frames are taken in, by the name the camera lists;
  // null leaves the camera in the mode it is in.
  ProfileField('defaultReadoutMode', ProfileValueKind.text, clearable: true),
  ProfileField('defaultBinX', ProfileValueKind.whole, fallback: '1'),
  ProfileField('defaultBinY', ProfileValueKind.whole, fallback: '1'),
  ProfileField('defaultCoolingTemp', ProfileValueKind.real),
  ProfileField('coolOnConnect', ProfileValueKind.flag, fallback: 'false'),

  // Centering and plate-solve exposure (seconds).
  ProfileField('defaultCenteringExposure', ProfileValueKind.real),

  ProfileField('filterNames', ProfileValueKind.filterNames),
  ProfileField('filterFocusOffsets', ProfileValueKind.focusOffsets),

  // Meridian flip settings for this rig as JSON; null uses the global ones.
  ProfileField(
    'meridianFlipOverrides',
    ProfileValueKind.text,
    keptWhenBodyOmits: true,
  ),

  // The model names of the devices, auto-generated or typed.
  ProfileField('cameraName', ProfileValueKind.text),
  ProfileField('mountName', ProfileValueKind.text),
  ProfileField('focuserName', ProfileValueKind.text),
  ProfileField('filterWheelName', ProfileValueKind.text),
  ProfileField('guiderName', ProfileValueKind.text),
  ProfileField('guideCameraName', ProfileValueKind.text),
  ProfileField('rotatorName', ProfileValueKind.text),
  ProfileField('safetyMonitorName', ProfileValueKind.text),
  ProfileField('switchName', ProfileValueKind.text),

  // The telescope itself: its native optics, before a reducer or barlow.
  ProfileField('telescopeName', ProfileValueKind.text),
  ProfileField(
    'telescopeFocalLength',
    ProfileValueKind.real,
    unsetWhenNotPositive: true,
  ),
  ProfileField(
    'telescopeAperture',
    ProfileValueKind.real,
    unsetWhenNotPositive: true,
  ),

  ProfileField('profileIcon', ProfileValueKind.text),
  ProfileField('profileColor', ProfileValueKind.whole),
];
