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
}
