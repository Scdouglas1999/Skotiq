part of '../database.dart';

extension _SkotiqDatabaseMigrationV62 on SkotiqDatabase {
  /// Version 62 — the brand violet becomes the default accent.
  ///
  /// The seeded accent was the old blue `#6EB3EC`, written into
  /// `app_settings` by `_defaultSettings` at install, so every profile
  /// carries that row whether the operator picked it or never opened
  /// Settings › Appearance. There is no "did the user choose" flag, so the
  /// row still equal to the old seed is rewritten to the new default
  /// `#A48CF2` — an operator who deliberately re-picked the old blue moves
  /// with it and can pick it again (it stays the second swatch). Every
  /// other stored value is a real choice and is left alone.
  ///
  /// Runs once, on the upgrade to 62. A swatch picked afterwards is kept:
  /// nothing here runs on a later open.
  Future<void> _upgradeSchemaV62(Migrator m, int from) async {
    if (from >= 62) return;
    await customUpdate(
      "UPDATE app_settings SET value = '$kDefaultAccentColorHex' "
      "WHERE key = 'accent_color' "
      "AND REPLACE(UPPER(value), '#', '') = '6EB3EC'",
      updates: {appSettings},
      updateKind: UpdateKind.update,
    );
  }
}
