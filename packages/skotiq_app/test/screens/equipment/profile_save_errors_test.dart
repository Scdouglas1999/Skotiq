import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/utils/profile_save_errors.dart';

void main() {
  group('profileSaveErrorMessage', () {
    test('maps unique constraint to actionable text', () {
      final message = profileSaveErrorMessage(
        Exception(
            'SqliteException(2067): UNIQUE constraint failed: equipment_profiles.name'),
      );
      expect(message, contains('name already exists'));
      expect(message, isNot(contains('SqliteException')));
    });

    test('maps missing profile StateError', () {
      final message = profileSaveErrorMessage(
        StateError('Profile not found'),
      );
      expect(message, contains('deleted or changed'));
    });

    test('generic fallback hides raw exception type', () {
      final message = profileSaveErrorMessage(Exception('internal boom'));
      expect(message, contains('Could not save'));
      expect(message, isNot(contains('internal boom')));
    });
  });
}
