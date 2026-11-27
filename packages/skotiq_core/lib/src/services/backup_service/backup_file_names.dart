/// The file extensions backups and cloud-sync bundles are written under and
/// read from. The `ns` names are the pre-rename ones: files made before the
/// rename stay listed and restorable.
abstract final class BackupFileNames {
  /// A backup file Skotiq writes.
  static const String extension = 'skbackup';

  /// A backup file written before the rename.
  static const String legacyExtension = 'nsbackup';

  /// A backup in plain JSON.
  static const String jsonExtension = 'json';

  /// Every extension a backup may be opened from, written name first.
  static const List<String> readableExtensions = [
    extension,
    legacyExtension,
    jsonExtension,
  ];

  /// Every extension a backup may be saved under.
  static const List<String> writableExtensions = [extension, jsonExtension];

  /// A cloud-sync bundle and its pre-rename name.
  static const String bundleExtension = 'skbak';
  static const String legacyBundleExtension = 'nsbak';

  /// Whether [name] ends in a readable backup extension. Case-sensitive: a
  /// caller that accepts any case lowercases [name] first.
  static bool isReadableBackup(String name) =>
      readableExtensions.any((ext) => name.endsWith('.$ext'));

  /// Whether [name] ends in either bundle extension.
  static bool isBundle(String name) =>
      name.endsWith('.$bundleExtension') ||
      name.endsWith('.$legacyBundleExtension');
}
