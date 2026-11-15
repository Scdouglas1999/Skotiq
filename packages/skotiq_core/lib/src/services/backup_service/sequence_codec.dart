part of '../backup_service.dart';

extension _BackupSequenceCodec on BackupService {
  /// The `equipmentProfiles` section of a backup older than 3.1, under the
  /// ids the backup gave them, so the rows that point at a profile still do.
  /// One profile is the default and one the active one.
  ///
  /// The columns are read off the table, not listed here: every column the
  /// section names is written, and a column it does not name (one the schema
  /// gained since) keeps its default.
  Future<void> _importProfiles(List<Map<String, dynamic>> profiles) async {
    var defaultIndex = profiles.indexWhere((p) => p['isDefault'] == true);
    var activeIndex = profiles.indexWhere((p) => p['isActive'] == true);
    // A bundle from before `isDefault` carries only `isActive`.
    if (defaultIndex < 0) defaultIndex = activeIndex < 0 ? 0 : activeIndex;
    if (activeIndex < 0) activeIndex = defaultIndex;

    final table = database.equipmentProfiles;
    for (var index = 0; index < profiles.length; index++) {
      final profile = {
        ...profiles[index],
        'isActive': index == activeIndex,
        'isDefault': index == defaultIndex,
      };
      await database
          .into(table)
          .insert(
            RawValuesInsertable({
              for (final column in table.$columns)
                if (profile[_jsonKey(column.name)] case final value?)
                  column.name: _jsonVariable(column, value),
            }),
          );
    }
    _noteCarried(table, profiles);
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
    _noteCarried(database.targets, targets);
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
