// reverify RV-03: a refused warm-up toasted "Failed to warm up:
// run_owns_cooler: The running sequence controls the camera cooler…".
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/utils/user_facing_error.dart';

void main() {
  test('a host error code before the sentence is dropped', () {
    expect(
      userFacingError(Exception(
        'run_owns_cooler: The running sequence controls the camera cooler.',
      )),
      'The running sequence controls the camera cooler.',
    );
  });

  test('ordinary text that starts with a word and a colon is kept', () {
    expect(userFacingError(Exception('Camera: not connected')),
        'Camera: not connected');
  });

  test('a database failure keeps the reason and drops the statement', () {
    final error = Exception(
      'SqliteException(1544): while executing statement, attempt to write a '
      'readonly database, attempt to write a readonly database (code 1544)\n'
      '  Causing statement: INSERT INTO "app_settings" ("key", "value") '
      'VALUES (?, ?), parameters: start_minimized, true',
    );
    expect(
      userFacingError(error),
      'database error: attempt to write a readonly database',
    );
  });
}
