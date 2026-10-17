part of '../profile_service.dart';

/// Marker written into every profile export so the importer can tell a
/// Skotiq profile from any other JSON the operator happens to pick.
const String kProfileExportFormat = 'skotiq.equipment-profile';

/// Format version of what [ProfileExportData.toJson] writes. Bumped only when
/// a reader of an older build could misread the document; an export carrying a
/// higher number is refused with a message that says so rather than being
/// half-parsed.
const int kProfileExportVersion = 2;

/// A profile import that failed for a reason the operator can act on.
///
/// [message] is user-facing prose — it is what the settings screen shows — so
/// it never names a Dart type, a character offset, or a JSON key path.
/// Messages about the chosen document deliberately open with `That file` so a
/// caller that knows the file's name can substitute it.
class ProfileImportException implements Exception {
  const ProfileImportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Wraps a single profile document in the export envelope.
Map<String, dynamic> profileExportEnvelope(
  List<Map<String, dynamic>> profiles,
) {
  return {
    'format': kProfileExportFormat,
    'version': kProfileExportVersion,
    'exportDate': DateTime.now().toIso8601String(),
    'profiles': profiles,
  };
}

/// Reads the profile list out of an export document, rejecting anything that
/// is not one with prose the operator can act on.
///
/// Accepts three shapes: the current envelope, the pre-envelope
/// `{"version":2,"profiles":[...]}` batch export, and a bare single-profile
/// map — the last two are what every build up to 6.1.0 wrote, and those files
/// are on people's disks.
List<dynamic> profilesFromExportDocument(String json) {
  final Object? data;
  try {
    data = jsonDecode(json);
  } on FormatException {
    throw const ProfileImportException(
      'That file is not a Skotiq equipment profile — it is not JSON at '
      'all. Pick a .json file exported from Settings > Equipment Profiles.',
    );
  }

  if (data is List) return data;
  if (data is! Map) {
    throw const ProfileImportException(
      'That file is not a Skotiq equipment profile.',
    );
  }

  final format = data['format'];
  if (format is String && format != kProfileExportFormat) {
    throw ProfileImportException(
      'That file is a "$format" export, not a Skotiq equipment profile.',
    );
  }

  final version = data['version'];
  if (version is num && version > kProfileExportVersion) {
    throw ProfileImportException(
      'That profile was exported by a newer version of Skotiq '
      '(export format ${version.toInt()}; this build reads up to '
      '$kProfileExportVersion). Update Skotiq and import it again.',
    );
  }

  if (data.containsKey('profiles')) {
    final profiles = data['profiles'];
    if (profiles is! List) {
      throw const ProfileImportException(
        'That file looks like a Skotiq export but its profile list is '
        'damaged.',
      );
    }
    return profiles;
  }

  // A sequence export is the neighbouring `.json` in the same folder and the
  // import picker offers it, so name it rather than letting the bare-map path
  // below mistake its `name` field for a profile's.
  if (data.containsKey('nodes') && data.containsKey('rootNodeId')) {
    throw const ProfileImportException(
      'That file is a Skotiq sequence, not an equipment profile. Import '
      'it from the Sequencer instead.',
    );
  }

  // Legacy single-profile export: a bare field map with no envelope. Every
  // build that wrote one wrote it with ProfileExportData.toJson, which always
  // emits the optical, binning and cooling fields — so requiring one of them
  // alongside the name is what separates a real profile from any other
  // document that merely happens to carry a `name`.
  if (data.containsKey('name') &&
      data.keys.any(_legacyProfileFields.contains)) {
    return [data];
  }

  throw const ProfileImportException(
    'That file is not a Skotiq equipment profile — it contains no '
    'profile data.',
  );
}

/// Fields only an equipment-profile export carries, used to recognise the
/// pre-envelope bare-map export without accepting unrelated JSON.
const Set<String> _legacyProfileFields = {
  'focalLength',
  'aperture',
  'focalRatio',
  'defaultBinX',
  'defaultBinY',
  'defaultGain',
  'defaultOffset',
  'defaultCoolingTemp',
  'coolOnConnect',
  'defaultCenteringExposure',
  'cameraId',
  'mountId',
  'focuserId',
  'filterWheelId',
  'guiderId',
  'rotatorId',
  'filterNames',
  'filterFocusOffsets',
  'telescopeFocalLength',
  'telescopeAperture',
  'profileIcon',
  'profileColor',
};

/// Parses one entry, restating any field-level rejection in plain language.
ProfileExportData parseExportedProfile(Object? entry, {required int index}) {
  if (entry is! Map<String, dynamic>) {
    throw ProfileImportException(
      'Entry ${index + 1} in that file is not a profile.',
    );
  }
  String subject() {
    final name = entry['name'];
    return name is String && name.trim().isNotEmpty
        ? '"${name.trim()}"'
        : 'entry ${index + 1}';
  }

  try {
    return ProfileExportData.fromJson(entry);
  } on FormatException catch (e) {
    throw ProfileImportException(
      'Skotiq could not import ${subject()}: ${_sentence(e.message)}',
    );
  } catch (e) {
    // A hand-edited file can put anything in any field. The typed readers
    // above turn the ones we know about into prose; this keeps a stray cast
    // from reaching the operator as a Dart type error while still leaving the
    // real thing in the log.
    developer.log(
      'ProfileService: unexpected error importing profile entry $index: $e',
      name: 'ProfileService',
      level: 1000,
      error: e,
    );
    throw ProfileImportException(
      'Skotiq could not import ${subject()}: one of its fields is not '
      'the kind of value a profile stores there.',
    );
  }
}

/// Lower-cases the leading `Profile ` the field validators prefix, so the
/// message reads as the tail of a sentence.
String _sentence(String message) {
  final trimmed = message.trim();
  if (trimmed.isEmpty) return 'the profile data is not valid.';
  final body = trimmed.startsWith('Profile ')
      ? trimmed.substring('Profile '.length)
      : '${trimmed[0].toLowerCase()}${trimmed.substring(1)}';
  return body.endsWith('.') ? body : '$body.';
}

/// Data class for profile import/export
class ProfileExportData {
  final String name;
  final String? description;
  final String? cameraId;
  final String? mountId;
  final String? focuserId;
  final String? filterWheelId;
  final String? guiderId;
  final String? rotatorId;
  final String? domeId;
  final String? weatherId;
  final String? safetyMonitorId;
  final String? switchId;
  final String? coverCalibratorId;
  final String? cameraName;
  final String? mountName;
  final String? focuserName;
  final String? filterWheelName;
  final String? guiderName;
  final String? rotatorName;
  final String? safetyMonitorName;
  final String? switchName;
  final String? telescopeName;
  final double? telescopeFocalLength;
  final double? telescopeAperture;
  final double focalLength;
  final double aperture;
  final double? focalRatio;
  final int? defaultGain;
  final int? defaultOffset;
  final int defaultBinX;
  final int defaultBinY;
  final double? defaultCoolingTemp;
  final bool coolOnConnect;
  final double? defaultCenteringExposure;
  final List<String>? filterNames;
  final Map<String, int>? filterFocusOffsets;
  final String? meridianFlipOverrides;
  final String? profileIcon;
  final int? profileColor;

  ProfileExportData({
    required this.name,
    this.description,
    this.cameraId,
    this.mountId,
    this.focuserId,
    this.filterWheelId,
    this.guiderId,
    this.rotatorId,
    this.domeId,
    this.weatherId,
    this.safetyMonitorId,
    this.switchId,
    this.coverCalibratorId,
    this.cameraName,
    this.mountName,
    this.focuserName,
    this.filterWheelName,
    this.guiderName,
    this.rotatorName,
    this.safetyMonitorName,
    this.switchName,
    this.telescopeName,
    this.telescopeFocalLength,
    this.telescopeAperture,
    required this.focalLength,
    required this.aperture,
    this.focalRatio,
    this.defaultGain,
    this.defaultOffset,
    required this.defaultBinX,
    required this.defaultBinY,
    this.defaultCoolingTemp,
    this.coolOnConnect = false,
    this.defaultCenteringExposure,
    this.filterNames,
    this.filterFocusOffsets,
    this.meridianFlipOverrides,
    this.profileIcon,
    this.profileColor,
  });

  factory ProfileExportData.fromDatabase(EquipmentProfile profile) {
    List<String>? filterNames;
    Map<String, int>? filterOffsets;

    if (profile.filterNames != null) {
      try {
        filterNames = decodeStringListJson(
          profile.filterNames,
          context: 'equipment_profiles.filter_names for "${profile.name}"',
        );
      } catch (e) {
        // Malformed filter names JSON - skip
        developer.log(
          'ProfileService: Failed to parse filterNames: $e',
          name: 'ProfileService',
          level: 1000,
          error: e,
        );
      }
    }

    if (profile.filterFocusOffsets != null) {
      try {
        filterOffsets = decodeStringIntMapJson(
          profile.filterFocusOffsets,
          context:
              'equipment_profiles.filter_focus_offsets for "${profile.name}"',
        );
      } catch (e) {
        // Malformed filter offsets JSON - skip
        developer.log(
          'ProfileService: Failed to parse filterFocusOffsets: $e',
          name: 'ProfileService',
          level: 1000,
          error: e,
        );
      }
    }

    return ProfileExportData(
      name: profile.name,
      description: profile.description,
      cameraId: profile.cameraId,
      mountId: profile.mountId,
      focuserId: profile.focuserId,
      filterWheelId: profile.filterWheelId,
      guiderId: profile.guiderId,
      rotatorId: profile.rotatorId,
      domeId: profile.domeId,
      weatherId: profile.weatherId,
      safetyMonitorId: profile.safetyMonitorId,
      switchId: profile.switchId,
      coverCalibratorId: profile.coverCalibratorId,
      cameraName: profile.cameraName,
      mountName: profile.mountName,
      focuserName: profile.focuserName,
      filterWheelName: profile.filterWheelName,
      guiderName: profile.guiderName,
      rotatorName: profile.rotatorName,
      safetyMonitorName: profile.safetyMonitorName,
      switchName: profile.switchName,
      telescopeName: profile.telescopeName,
      telescopeFocalLength: profile.telescopeFocalLength,
      telescopeAperture: profile.telescopeAperture,
      focalLength: profile.focalLength,
      aperture: profile.aperture,
      focalRatio: profile.focalRatio,
      defaultGain: profile.defaultGain,
      defaultOffset: profile.defaultOffset,
      defaultBinX: profile.defaultBinX,
      defaultBinY: profile.defaultBinY,
      defaultCoolingTemp: profile.defaultCoolingTemp,
      coolOnConnect: profile.coolOnConnect,
      defaultCenteringExposure: profile.defaultCenteringExposure,
      filterNames: filterNames,
      filterFocusOffsets: filterOffsets,
      meridianFlipOverrides: profile.meridianFlipOverrides,
      profileIcon: profile.profileIcon,
      profileColor: profile.profileColor,
    );
  }

  factory ProfileExportData.fromModel(EquipmentProfileModel profile) {
    return ProfileExportData(
      name: profile.name,
      description: profile.description,
      cameraId: profile.cameraId,
      mountId: profile.mountId,
      focuserId: profile.focuserId,
      filterWheelId: profile.filterWheelId,
      guiderId: profile.guiderId,
      rotatorId: profile.rotatorId,
      domeId: profile.domeId,
      weatherId: profile.weatherId,
      safetyMonitorId: profile.safetyMonitorId,
      switchId: profile.switchId,
      coverCalibratorId: profile.coverCalibratorId,
      cameraName: profile.cameraName,
      mountName: profile.mountName,
      focuserName: profile.focuserName,
      filterWheelName: profile.filterWheelName,
      guiderName: profile.guiderName,
      rotatorName: profile.rotatorName,
      safetyMonitorName: profile.safetyMonitorName,
      switchName: profile.switchName,
      telescopeName: profile.telescopeName,
      telescopeFocalLength: profile.telescopeFocalLength,
      telescopeAperture: profile.telescopeAperture,
      focalLength: profile.focalLength,
      aperture: profile.aperture,
      focalRatio: profile.focalRatio,
      defaultGain: profile.defaultGain,
      defaultOffset: profile.defaultOffset,
      defaultBinX: profile.defaultBinX,
      defaultBinY: profile.defaultBinY,
      defaultCoolingTemp: profile.defaultCoolingTemp,
      coolOnConnect: profile.coolOnConnect,
      defaultCenteringExposure: profile.defaultCenteringExposure,
      filterNames: profile.filterNames.isNotEmpty ? profile.filterNames : null,
      filterFocusOffsets: profile.filterFocusOffsets.isNotEmpty
          ? profile.filterFocusOffsets
          : null,
      meridianFlipOverrides: profile.meridianFlipOverrides,
      profileIcon: profile.profileIcon,
      profileColor: profile.profileColor,
    );
  }

  factory ProfileExportData.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    if (name is! String || name.trim().isEmpty) {
      throw const FormatException('Profile name must be a non-empty string');
    }
    final data = ProfileExportData(
      name: name.trim(),
      description: _profileText(json['description'], 'description'),
      cameraId: _profileText(json['cameraId'], 'cameraId'),
      mountId: _profileText(json['mountId'], 'mountId'),
      focuserId: _profileText(json['focuserId'], 'focuserId'),
      filterWheelId: _profileText(json['filterWheelId'], 'filterWheelId'),
      guiderId: _profileText(json['guiderId'], 'guiderId'),
      rotatorId: _profileText(json['rotatorId'], 'rotatorId'),
      domeId: _profileText(json['domeId'], 'domeId'),
      weatherId: _profileText(json['weatherId'], 'weatherId'),
      safetyMonitorId: _profileText(json['safetyMonitorId'], 'safetyMonitorId'),
      switchId: _profileText(json['switchId'], 'switchId'),
      coverCalibratorId: _profileText(
        json['coverCalibratorId'],
        'coverCalibratorId',
      ),
      cameraName: _profileText(json['cameraName'], 'cameraName'),
      mountName: _profileText(json['mountName'], 'mountName'),
      focuserName: _profileText(json['focuserName'], 'focuserName'),
      filterWheelName: _profileText(json['filterWheelName'], 'filterWheelName'),
      guiderName: _profileText(json['guiderName'], 'guiderName'),
      rotatorName: _profileText(json['rotatorName'], 'rotatorName'),
      safetyMonitorName: _profileText(
        json['safetyMonitorName'],
        'safetyMonitorName',
      ),
      switchName: _profileText(json['switchName'], 'switchName'),
      telescopeName: _profileText(json['telescopeName'], 'telescopeName'),
      telescopeFocalLength: _profileDouble(
        json['telescopeFocalLength'],
        'telescopeFocalLength',
      ),
      telescopeAperture: _profileDouble(
        json['telescopeAperture'],
        'telescopeAperture',
      ),
      focalLength: _profileDouble(json['focalLength'], 'focalLength') ?? 0.0,
      aperture: _profileDouble(json['aperture'], 'aperture') ?? 0.0,
      focalRatio: _profileDouble(json['focalRatio'], 'focalRatio'),
      defaultGain: _profileInt(json['defaultGain'], 'defaultGain'),
      defaultOffset: _profileInt(json['defaultOffset'], 'defaultOffset'),
      defaultBinX: _profileInt(json['defaultBinX'], 'defaultBinX') ?? 1,
      defaultBinY: _profileInt(json['defaultBinY'], 'defaultBinY') ?? 1,
      defaultCoolingTemp: _profileDouble(
        json['defaultCoolingTemp'],
        'defaultCoolingTemp',
      ),
      coolOnConnect:
          _profileBool(json['coolOnConnect'], 'coolOnConnect') ?? false,
      defaultCenteringExposure: _profileDouble(
        json['defaultCenteringExposure'],
        'defaultCenteringExposure',
      ),
      filterNames: _profileStringList(json['filterNames'], 'filterNames'),
      filterFocusOffsets: _profileIntMap(
        json['filterFocusOffsets'],
        'filterFocusOffsets',
      ),
      meridianFlipOverrides: _profileText(
        json['meridianFlipOverrides'],
        'meridianFlipOverrides',
      ),
      profileIcon: _profileText(json['profileIcon'], 'profileIcon'),
      profileColor: _profileInt(json['profileColor'], 'profileColor'),
    );
    if (!data.focalLength.isFinite || data.focalLength < 0) {
      throw const FormatException('Profile focalLength must be non-negative');
    }
    if (!data.aperture.isFinite || data.aperture < 0) {
      throw const FormatException('Profile aperture must be non-negative');
    }
    // An export file is hand-editable and may have been produced by an older
    // build that had no plausibility bounds, so import is a real entry point
    // for an impossible optical train — not merely a round-trip of our own
    // data. Reject it with the same shared contract the editors and
    // `POST /api/profiles` use rather than letting it reach the FITS
    // `FOCALLEN` card and the plate-solve field-of-view estimate.
    final trainError = ProfileValidator.validateOpticalTrain(
      focalLengthMm: data.focalLength,
      apertureMm: data.aperture,
    );
    if (trainError != null) {
      throw FormatException('Profile optics rejected: $trainError');
    }
    final telescopeTrainError = ProfileValidator.validateOpticalTrain(
      focalLengthMm: data.telescopeFocalLength ?? 0,
      apertureMm: data.telescopeAperture ?? 0,
    );
    if (telescopeTrainError != null) {
      throw FormatException(
        'Profile telescope optics rejected: $telescopeTrainError',
      );
    }
    final importedFocalRatio = data.focalRatio;
    if (importedFocalRatio != null &&
        (!importedFocalRatio.isFinite ||
            importedFocalRatio < OpticalTrainLimits.minFRatio ||
            importedFocalRatio > OpticalTrainLimits.maxFRatio)) {
      throw const FormatException(
        'Profile focalRatio is outside the plausible range',
      );
    }
    if (data.defaultBinX < 1 || data.defaultBinY < 1) {
      throw const FormatException('Profile binning values must be at least 1');
    }
    final centeringExposure = data.defaultCenteringExposure;
    if (centeringExposure != null &&
        (!centeringExposure.isFinite || centeringExposure <= 0)) {
      throw const FormatException(
        'Profile centering exposure must be a positive finite value',
      );
    }
    final coolingTemp = data.defaultCoolingTemp;
    if (coolingTemp != null && !coolingTemp.isFinite) {
      throw const FormatException('Profile cooling temperature must be finite');
    }
    final overrides = data.meridianFlipOverrides;
    if (overrides != null && overrides.trim().isNotEmpty) {
      final Object? decoded;
      try {
        decoded = jsonDecode(overrides);
      } on FormatException {
        // Restated: the raw message is a character offset into a nested
        // string, which tells the operator nothing about the field.
        throw const FormatException(
          'Profile meridian flip overrides are damaged',
        );
      }
      if (decoded is! Map) {
        throw const FormatException(
          'Profile meridian flip overrides must be a JSON object',
        );
      }
    }
    return data;
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'description': description,
      'cameraId': cameraId,
      'mountId': mountId,
      'focuserId': focuserId,
      'filterWheelId': filterWheelId,
      'guiderId': guiderId,
      'rotatorId': rotatorId,
      'domeId': domeId,
      'weatherId': weatherId,
      'safetyMonitorId': safetyMonitorId,
      'switchId': switchId,
      'coverCalibratorId': coverCalibratorId,
      'cameraName': cameraName,
      'mountName': mountName,
      'focuserName': focuserName,
      'filterWheelName': filterWheelName,
      'guiderName': guiderName,
      'rotatorName': rotatorName,
      'safetyMonitorName': safetyMonitorName,
      'switchName': switchName,
      'telescopeName': telescopeName,
      'telescopeFocalLength': telescopeFocalLength,
      'telescopeAperture': telescopeAperture,
      'focalLength': focalLength,
      'aperture': aperture,
      'focalRatio': focalRatio,
      'defaultGain': defaultGain,
      'defaultOffset': defaultOffset,
      'defaultBinX': defaultBinX,
      'defaultBinY': defaultBinY,
      'defaultCoolingTemp': defaultCoolingTemp,
      'coolOnConnect': coolOnConnect,
      'defaultCenteringExposure': defaultCenteringExposure,
      'filterNames': filterNames,
      'filterFocusOffsets': filterFocusOffsets,
      'meridianFlipOverrides': meridianFlipOverrides,
      'profileIcon': profileIcon,
      'profileColor': profileColor,
    };
  }
}

/// Typed field readers. A hand-edited or foreign document can put any JSON
/// value in any key; a bare `as String?` turns that into a Dart `TypeError`,
/// which escapes [ProfileExportData.fromJson]'s `FormatException` contract and
/// reaches the operator as "type 'int' is not a subtype of type 'String?' in
/// type cast". These state the field instead.
String? _profileText(Object? raw, String field) {
  if (raw == null) return null;
  if (raw is! String) {
    throw FormatException('Profile $field must be text');
  }
  return raw;
}

double? _profileDouble(Object? raw, String field) {
  if (raw == null) return null;
  if (raw is! num) {
    throw FormatException('Profile $field must be a number');
  }
  return raw.toDouble();
}

int? _profileInt(Object? raw, String field) {
  if (raw == null) return null;
  if (raw is! num || !raw.isFinite) {
    throw FormatException('Profile $field must be a whole number');
  }
  return raw.toInt();
}

bool? _profileBool(Object? raw, String field) {
  if (raw == null) return null;
  if (raw is! bool) {
    throw FormatException('Profile $field must be true or false');
  }
  return raw;
}

List<String>? _profileStringList(Object? raw, String field) {
  if (raw == null) return null;
  if (raw is! List) {
    throw FormatException('Profile $field must be an array');
  }
  final result = <String>[];
  for (var i = 0; i < raw.length; i++) {
    final value = raw[i];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('Profile $field[$i] must be a non-empty string');
    }
    result.add(value.trim());
  }
  return result;
}

Map<String, int>? _profileIntMap(Object? raw, String field) {
  if (raw == null) return null;
  if (raw is! Map) {
    throw FormatException('Profile $field must be an object');
  }
  final result = <String, int>{};
  for (final entry in raw.entries) {
    final key = entry.key;
    final value = entry.value;
    if (key is! String ||
        key.trim().isEmpty ||
        value is! num ||
        !value.isFinite) {
      throw FormatException(
        'Profile $field entries require non-empty string keys and finite numbers',
      );
    }
    result[key.trim()] = value.toInt();
  }
  return result;
}
