part of '../backup_service.dart';

extension _BackupSections on BackupService {
  /// Write the sections of a backup other than `tables` into this (staged,
  /// otherwise empty) database: the settings, and what a backup older than
  /// 3.1 holds under keys of its own.
  ///
  /// Every section is checked before the first write: `settings` is an
  /// object, `equipmentProfiles` and `targets` are lists of objects with a
  /// name, every entry of `sequences` decodes to its last node.
  Future<void> _applySections(Map<String, dynamic> backup) async {
    Map<String, dynamic>? settings;
    if (backup.containsKey('settings')) {
      final raw = backup['settings'];
      if (raw is! Map<String, dynamic>) {
        throw const BackupArchiveException(
          'Invalid backup file: "settings" is not an object',
        );
      }
      settings = raw;
    }
    final profiles = backup.containsKey('equipmentProfiles')
        ? _namedRows(backup['equipmentProfiles'], 'equipmentProfiles')
        : null;
    final targets = backup.containsKey('targets')
        ? _namedRows(backup['targets'], 'targets')
        : null;
    List<Sequence>? sequences;
    if (backup.containsKey('sequences')) {
      final raw = backup['sequences'];
      if (raw is! List) {
        throw const BackupArchiveException(
          'Invalid backup file: "sequences" is not a list',
        );
      }
      sequences = [];
      for (var i = 0; i < raw.length; i++) {
        final entry = raw[i];
        if (entry is! Map<String, dynamic>) {
          throw BackupArchiveException(
            'Invalid backup file: sequences[$i] is not an object',
          );
        }
        final sequence = _jsonToSequence(entry);
        if (sequence == null) {
          throw BackupArchiveException(
            'Invalid backup file: sequences[$i] failed to decode '
            '(name: ${entry['name'] ?? '<unknown>'})',
          );
        }
        sequences.add(sequence);
      }
    }
    for (final key in _legacyTableImporters.keys) {
      if (backup.containsKey(key) && backup[key] is! List) {
        throw BackupArchiveException(
          'Invalid backup file: "$key" is not a list',
        );
      }
    }

    await database.transaction(() async {
      if (settings != null) await _importSettings(settings);
      if (profiles != null) await _importProfiles(profiles);
      final repository = LocalSequenceRepository(database.sequencesDao);
      for (final sequence in sequences ?? const <Sequence>[]) {
        await repository.saveSequence(sequence);
      }
      if (targets != null) await _importTargets(targets);
      for (final MapEntry(:key, value: importer)
          in _legacyTableImporters.entries) {
        if (backup[key] case final List rows) {
          try {
            await importer(rows);
          } on FormatException catch (e) {
            throw BackupArchiveException(
              'Invalid backup file: "$key": ${e.message}',
            );
          }
        }
      }
    });
  }

  List<Map<String, dynamic>> _namedRows(Object? raw, String section) {
    if (raw is! List) {
      throw BackupArchiveException(
        'Invalid backup file: "$section" is not a list',
      );
    }
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < raw.length; i++) {
      final entry = raw[i];
      if (entry is! Map<String, dynamic>) {
        throw BackupArchiveException(
          'Invalid backup file: $section[$i] is not an object',
        );
      }
      final name = entry['name'];
      if (name is! String || name.isEmpty) {
        throw BackupArchiveException(
          'Invalid backup file: $section[$i] is missing a non-empty "name"',
        );
      }
      out.add(entry);
    }
    return out;
  }
}
