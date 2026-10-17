import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('zero polar-alignment max age persists as the disabled state', () async {
    final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    addTearDown(() async {
      container.dispose();
      await database.close();
    });

    await container.read(appSettingsProvider.future);
    await container
        .read(appSettingsProvider.notifier)
        .setPolarAlignmentMaxAgeDays(0);

    expect(
      container.read(appSettingsProvider).value!.polarAlignmentMaxAgeDays,
      0,
    );
    final row = await database
        .customSelect(
          'SELECT value FROM app_settings WHERE key = ?',
          variables: const [Variable<String>('polar_alignment_max_age_days')],
        )
        .getSingle();
    expect(row.data['value'], '0');

    container.invalidate(appSettingsProvider);
    final reloaded = await container.read(appSettingsProvider.future);
    expect(reloaded.polarAlignmentMaxAgeDays, 0);
  });
}
