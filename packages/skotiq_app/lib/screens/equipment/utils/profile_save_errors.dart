import 'package:flutter/services.dart';

/// Map profile save/load failures to operator-facing text.
///
/// Raw `SqliteException` / stack traces belong in logs only — the snackbar
/// should say what to do next.
String profileSaveErrorMessage(Object error) {
  final raw = error.toString();

  if (error is StateError) {
    final msg = error.message.toLowerCase();
    if (msg.contains('not found') || msg.contains('no longer exists')) {
      return 'That profile was deleted or changed elsewhere. Close this dialog '
          'and open the profile list again.';
    }
  }

  if (_looksLikeSqliteError(raw)) {
    final msg = raw.toLowerCase();
    if (msg.contains('unique') || msg.contains('constraint')) {
      return 'A profile with that name already exists. Choose a different name.';
    }
    if (msg.contains('foreign key')) {
      return 'Could not save because a linked record is missing. Reload profiles '
          'and try again.';
    }
    return 'Could not save the profile (database error). Check disk space and '
        'try again.';
  }

  if (error is PlatformException) {
    return 'Could not save the profile (${error.message ?? error.code}).';
  }

  if (error is FormatException) {
    return 'Profile data is invalid. Check filter names and numeric fields.';
  }

  return 'Could not save the profile. Check the name and device fields, then try again.';
}

bool _looksLikeSqliteError(String raw) {
  final lower = raw.toLowerCase();
  return lower.contains('sqlite') ||
      lower.contains('sql logic error') ||
      lower.contains('constraint failed');
}
