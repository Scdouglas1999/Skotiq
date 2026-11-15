part of '../backup_service.dart';

extension _BackupSequenceCodec on BackupService {
  /// The `equipmentProfiles` section of a backup older than 3.1, under the
  /// ids the backup gave them, so the rows that point at a profile still do.
  /// One profile is the default and one the active one.
  Future<void> _importProfiles(List<Map<String, dynamic>> profiles) async {
    var defaultIndex = profiles.indexWhere((p) => p['isDefault'] == true);
    var activeIndex = profiles.indexWhere((p) => p['isActive'] == true);
    // A bundle from before `isDefault` carries only `isActive`.
    if (defaultIndex < 0) defaultIndex = activeIndex < 0 ? 0 : activeIndex;
    if (activeIndex < 0) activeIndex = defaultIndex;

    for (var index = 0; index < profiles.length; index++) {
      final profile = profiles[index];
      final backupId = (profile['id'] as num?)?.toInt();
      await database
          .into(database.equipmentProfiles)
          .insert(
            EquipmentProfilesCompanion.insert(
              id: backupId == null ? const Value.absent() : Value(backupId),
              name: profile['name'] as String,
              description: Value(_stringOrNull(profile['description'])),
              isActive: Value(index == activeIndex),
              isDefault: Value(index == defaultIndex),
              cameraId: Value(_stringOrNull(profile['cameraId'])),
              mountId: Value(_stringOrNull(profile['mountId'])),
              focuserId: Value(_stringOrNull(profile['focuserId'])),
              filterWheelId: Value(_stringOrNull(profile['filterWheelId'])),
              guiderId: Value(_stringOrNull(profile['guiderId'])),
              guideCameraId: Value(_stringOrNull(profile['guideCameraId'])),
              rotatorId: Value(_stringOrNull(profile['rotatorId'])),
              domeId: Value(_stringOrNull(profile['domeId'])),
              weatherId: Value(_stringOrNull(profile['weatherId'])),
              safetyMonitorId: Value(_stringOrNull(profile['safetyMonitorId'])),
              switchId: Value(_stringOrNull(profile['switchId'])),
              coverCalibratorId: Value(
                _stringOrNull(profile['coverCalibratorId']),
              ),
              focalLength: Value(_doubleOrDefault(profile['focalLength'], 0.0)),
              aperture: Value(_doubleOrDefault(profile['aperture'], 0.0)),
              focalRatio: Value(_doubleOrNull(profile['focalRatio'])),
              defaultGain: Value(_intOrNull(profile['defaultGain'])),
              defaultOffset: Value(_intOrNull(profile['defaultOffset'])),
              defaultBinX: Value(_intOrDefault(profile['defaultBinX'], 1)),
              defaultBinY: Value(_intOrDefault(profile['defaultBinY'], 1)),
              defaultCoolingTemp: Value(
                _doubleOrNull(profile['defaultCoolingTemp']),
              ),
              coolOnConnect: Value(profile['coolOnConnect'] as bool? ?? false),
              defaultCenteringExposure: Value(
                _doubleOrNull(profile['defaultCenteringExposure']),
              ),
              filterNames: Value(_stringOrNull(profile['filterNames'])),
              filterFocusOffsets: Value(
                _stringOrNull(profile['filterFocusOffsets']),
              ),
              meridianFlipOverrides: Value(
                _stringOrNull(profile['meridianFlipOverrides']),
              ),
              cameraName: Value(_stringOrNull(profile['cameraName'])),
              mountName: Value(_stringOrNull(profile['mountName'])),
              focuserName: Value(_stringOrNull(profile['focuserName'])),
              filterWheelName: Value(_stringOrNull(profile['filterWheelName'])),
              guiderName: Value(_stringOrNull(profile['guiderName'])),
              guideCameraName: Value(_stringOrNull(profile['guideCameraName'])),
              rotatorName: Value(_stringOrNull(profile['rotatorName'])),
              safetyMonitorName: Value(
                _stringOrNull(profile['safetyMonitorName']),
              ),
              switchName: Value(_stringOrNull(profile['switchName'])),
              telescopeName: Value(_stringOrNull(profile['telescopeName'])),
              telescopeFocalLength: Value(
                _doubleOrNull(profile['telescopeFocalLength']),
              ),
              telescopeAperture: Value(
                _doubleOrNull(profile['telescopeAperture']),
              ),
              guideFocalLength: Value(
                _doubleOrNull(profile['guideFocalLength']),
              ),
              profileIcon: Value(_stringOrNull(profile['profileIcon'])),
              profileColor: Value(_intOrNull(profile['profileColor'])),
              sortOrder: Value(_intOrDefault(profile['sortOrder'], 0)),
              createdAt: _dateTimeValue(profile['createdAt']),
              updatedAt: _dateTimeValue(profile['updatedAt']),
            ),
          );
    }
  }

  /// The `targets` section of a 2.x backup.
  Future<void> _importTargets(List<Map<String, dynamic>> targets) async {
    for (final target in targets) {
      await database
          .into(database.targets)
          .insert(
            TargetsCompanion.insert(
              name: target['name'] as String,
              catalogId: Value(_stringOrNull(target['catalogId'])),
              ra: _doubleOrDefault(target['ra'], 0.0),
              dec: _doubleOrDefault(target['dec'], 0.0),
              constellation: Value(_stringOrNull(target['constellation'])),
              objectType: Value(_stringOrNull(target['objectType'])),
              magnitude: Value(_doubleOrNull(target['magnitude'])),
              sizeArcmin: Value(_doubleOrNull(target['sizeArcmin'])),
              notes: Value(_stringOrNull(target['notes'])),
              isFavorite: Value(target['isFavorite'] as bool? ?? false),
              priority: Value(_intOrDefault(target['priority'], 0)),
            ),
          );
    }
  }

  Sequence? _jsonToSequence(Map<String, dynamic> json) {
    try {
      // parseFromMap mutates the supplied map while stamping its schema
      // version. Restore validation should remain side-effect free, so decode
      // a shallow copy of the backup entry.
      return SequenceFileService().parseFromMap(Map<String, dynamic>.of(json));
    } catch (e) {
      _logger.debug('Failed to parse sequence: $e');
      return null;
    }
  }
}
