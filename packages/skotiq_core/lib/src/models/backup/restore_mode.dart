/// How a backup is restored.
enum RestoreMode {
  /// Add the records the backup has and this database does not.
  merge,

  /// Make this database the backup.
  replace;

  /// The name on the wire.
  String get wireName => name;

  static RestoreMode fromWire(Object? value) =>
      value == 'replace' ? RestoreMode.replace : RestoreMode.merge;

  /// What this mode does, said to the operator before they confirm.
  String get summary => switch (this) {
    RestoreMode.merge =>
      'Adds the targets, sequences, sessions, frames, masters, library '
          'entries and equipment profiles that are in the backup and not in '
          'this database. Nothing you have is changed or removed: your '
          'settings stay as they are, a record you already have keeps your '
          'version, and nothing is added inside it.',
    RestoreMode.replace =>
      'Makes this database the backup: its settings, profiles, sequences, '
          'targets, sessions and frames replace everything here, and what '
          'was recorded after the backup is no longer in the database. A '
          'safety backup of the database as it is now is written first, and '
          'the switch happens when Skotiq next starts. Image files on disk '
          'are not touched.',
  };
}
