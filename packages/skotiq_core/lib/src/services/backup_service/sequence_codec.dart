part of '../backup_service.dart';

extension _BackupSequenceCodec on BackupService {
  Map<String, dynamic> _sequenceToJson(Sequence sequence) {
    return SequenceFileService().sequenceToMap(sequence);
  }

  // Private import methods

  Future<int> _importSettings(
    Map<String, dynamic> settingsMap, {
    bool replace = false,
  }) async {
    final settingsDao = SettingsDao(database);
    int count = 0;

    for (final entry in settingsMap.entries) {
      // Never let a bundle move this install's backup folder. Current bundles
      // do not carry the key (`_exportSettings` strips it), but a hand-edited
      // or hand-written one could, and restoring it would repoint both where
      // backups are written and where "Maximum backups" deletes from.
      if (entry.key == BackupService.backupDirectorySettingKey) continue;
      await settingsDao.setSetting(entry.key, entry.value?.toString() ?? '');
      count++;
    }

    return count;
  }

  /// Merge the backup's equipment profiles into the live table.
  ///
  /// Backup row IDs are installation-local, so profiles are matched by name
  /// and new rows receive fresh IDs. A merge preserves the local active/default
  /// selections; an empty table may adopt one of each from the backup. Returns
  /// only the number of rows actually written.
  Future<int> _importProfiles(List<dynamic> profilesList) async {
    final existing = await database.select(database.equipmentProfiles).get();
    final unclaimedIdsByName = <String, List<int>>{};
    for (final row in existing) {
      unclaimedIdsByName.putIfAbsent(row.name, () => <int>[]).add(row.id);
    }

    // Which imported row may claim default / active. Only ever set when the
    // table started empty; otherwise the local selection stands untouched.
    int? defaultIndex;
    int? activeIndex;
    if (existing.isEmpty && profilesList.isNotEmpty) {
      for (var i = 0; i < profilesList.length; i++) {
        final raw = profilesList[i];
        if (raw is! Map) continue;
        if (defaultIndex == null && raw['isDefault'] == true) defaultIndex = i;
        if (activeIndex == null && raw['isActive'] == true) activeIndex = i;
      }
      // A pre-`isDefault` bundle carries only `isActive`; fall back to that,
      // then to the first profile, so a startup target always exists.
      defaultIndex ??= activeIndex ?? 0;
      activeIndex ??= defaultIndex;
    }

    int count = 0;

    for (var index = 0; index < profilesList.length; index++) {
      final profile = profilesList[index] as Map<String, dynamic>;
      final name = profile['name'] as String;
      final unclaimed = unclaimedIdsByName[name];
      final targetId = (unclaimed == null || unclaimed.isEmpty)
          ? null
          : unclaimed.removeAt(0);
      final isInsert = targetId == null;

      final companion = EquipmentProfilesCompanion.insert(
        name: name,
        description: Value(_stringOrNull(profile['description'])),
        isActive: isInsert ? Value(index == activeIndex) : const Value.absent(),
        isDefault: isInsert
            ? Value(index == defaultIndex)
            : const Value.absent(),
        cameraId: Value(_stringOrNull(profile['cameraId'])),
        mountId: Value(_stringOrNull(profile['mountId'])),
        focuserId: Value(_stringOrNull(profile['focuserId'])),
        filterWheelId: Value(_stringOrNull(profile['filterWheelId'])),
        guiderId: Value(_stringOrNull(profile['guiderId'])),
        rotatorId: Value(_stringOrNull(profile['rotatorId'])),
        domeId: Value(_stringOrNull(profile['domeId'])),
        weatherId: Value(_stringOrNull(profile['weatherId'])),
        safetyMonitorId: Value(_stringOrNull(profile['safetyMonitorId'])),
        switchId: Value(_stringOrNull(profile['switchId'])),
        coverCalibratorId: Value(_stringOrNull(profile['coverCalibratorId'])),
        focalLength: Value(_doubleOrDefault(profile['focalLength'], 0.0)),
        aperture: Value(_doubleOrDefault(profile['aperture'], 0.0)),
        focalRatio: Value(_doubleOrNull(profile['focalRatio'])),
        defaultGain: Value(_intOrNull(profile['defaultGain'])),
        defaultOffset: Value(_intOrNull(profile['defaultOffset'])),
        defaultBinX: Value(_intOrDefault(profile['defaultBinX'], 1)),
        defaultBinY: Value(_intOrDefault(profile['defaultBinY'], 1)),
        defaultCoolingTemp: Value(_doubleOrNull(profile['defaultCoolingTemp'])),
        coolOnConnect: Value(profile['coolOnConnect'] as bool? ?? false),
        defaultCenteringExposure: Value(
          _doubleOrNull(profile['defaultCenteringExposure']),
        ),
        filterNames: Value(_stringOrNull(profile['filterNames'])),
        filterFocusOffsets: Value(_stringOrNull(profile['filterFocusOffsets'])),
        meridianFlipOverrides: Value(
          _stringOrNull(profile['meridianFlipOverrides']),
        ),
        cameraName: Value(_stringOrNull(profile['cameraName'])),
        mountName: Value(_stringOrNull(profile['mountName'])),
        focuserName: Value(_stringOrNull(profile['focuserName'])),
        filterWheelName: Value(_stringOrNull(profile['filterWheelName'])),
        guiderName: Value(_stringOrNull(profile['guiderName'])),
        rotatorName: Value(_stringOrNull(profile['rotatorName'])),
        safetyMonitorName: Value(_stringOrNull(profile['safetyMonitorName'])),
        switchName: Value(_stringOrNull(profile['switchName'])),
        telescopeName: Value(_stringOrNull(profile['telescopeName'])),
        telescopeFocalLength: Value(
          _doubleOrNull(profile['telescopeFocalLength']),
        ),
        telescopeAperture: Value(_doubleOrNull(profile['telescopeAperture'])),
        profileIcon: Value(_stringOrNull(profile['profileIcon'])),
        profileColor: Value(_intOrNull(profile['profileColor'])),
        sortOrder: Value(_intOrDefault(profile['sortOrder'], 0)),
        createdAt: _dateTimeValue(profile['createdAt']),
        updatedAt: _dateTimeValue(profile['updatedAt']),
      );

      if (isInsert) {
        await database.into(database.equipmentProfiles).insert(companion);
        count++;
      } else {
        final written = await (database.update(
          database.equipmentProfiles,
        )..where((tbl) => tbl.id.equals(targetId))).write(companion);
        if (written > 0) count++;
      }
    }

    return count;
  }

  Future<int> _importTargets(
    List<dynamic> targetsList, {
    bool replace = false,
  }) async {
    int count = 0;

    for (final targetJson in targetsList) {
      final target = targetJson as Map<String, dynamic>;

      // Count what SQLite actually wrote. `insert` returns 0 when an
      // insertOrIgnore conflicted and nothing landed, and the restore screen
      // reports this sum to the user as "Restored N items" — so an attempted
      // row counted as a written one is the app stating something untrue.
      final inserted = await database
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
            mode: replace ? InsertMode.replace : InsertMode.insertOrIgnore,
          );
      if (inserted != 0) count++;
    }

    return count;
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
