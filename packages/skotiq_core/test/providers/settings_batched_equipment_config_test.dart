// Batched mount/focuser equipment-config persistence.
//
// The mount and focuser "Configuration" dialogs on the connected-device card
// used to issue two/three sequential AppSettingsNotifier writes and swallow
// malformed numeric input via `parse(...) ?? old`, so a mid-write failure (or
// a bad value) could persist a partial/inconsistent change while still
// reporting success. `setMeridianFlipConfig` / `setFocuserCompensationConfig`
// replace those with a single batched `_saveSettings` transaction, patching
// in-memory state only after the write resolves.
//
// These tests assert the two invariants the dialogs depend on:
//   1. Success writes ALL keys in ONE batched DAO call and updates state.
//   2. A failed write leaves state byte-for-byte unchanged and is retryable
//      (the next call succeeds), never leaving a half-applied config.

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/database/daos/settings_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';

class _MockSettingsDao extends Mock implements SettingsDao {}

Future<String?> _storedValue(SkotiqDatabase db, String key) async {
  final rows = await db
      .customSelect(
        'SELECT value FROM app_settings WHERE key = ?',
        variables: [Variable<String>(key)],
      )
      .get();
  if (rows.isEmpty) return null;
  return rows.single.data['value'] as String?;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('batched config writes through the real DAO (local backend)', () {
    late ProviderContainer container;
    late SkotiqDatabase database;

    setUp(() {
      database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(database)],
      );
    });

    tearDown(() async {
      container.dispose();
      await database.close();
    });

    test(
      'setMeridianFlipConfig persists both keys and updates state',
      () async {
        await container.read(appSettingsProvider.future);

        await container
            .read(appSettingsProvider.notifier)
            .setMeridianFlipConfig(enableFlip: false, minutes: 30);

        // Both keys landed in the store.
        expect(await _storedValue(database, 'enable_meridian_flip'), 'false');
        expect(await _storedValue(database, 'meridian_flip_minutes'), '30');

        // In-memory state reflects the change immediately.
        final state = container.read(appSettingsProvider).requireValue;
        expect(state.enableMeridianFlip, isFalse);
        expect(state.meridianFlipMinutes, 30);

        // A fresh load observes it (no stale-key mismatch).
        container.invalidate(appSettingsProvider);
        final reloaded = await container.read(appSettingsProvider.future);
        expect(reloaded.enableMeridianFlip, isFalse);
        expect(reloaded.meridianFlipMinutes, 30);
      },
    );

    test(
      'setFocuserCompensationConfig persists all three keys and state',
      () async {
        await container.read(appSettingsProvider.future);

        await container
            .read(appSettingsProvider.notifier)
            .setFocuserCompensationConfig(
              tempCompensation: true,
              tempCoefficient: 2.5,
              backlashCompensation: 500,
            );

        expect(await _storedValue(database, 'temp_compensation'), 'true');
        expect(await _storedValue(database, 'temp_coefficient'), '2.5');
        expect(await _storedValue(database, 'backlash_compensation'), '500');

        final state = container.read(appSettingsProvider).requireValue;
        expect(state.tempCompensation, isTrue);
        expect(state.tempCoefficient, 2.5);
        expect(state.backlashCompensation, 500);
      },
    );
  });

  group('failed batched write leaves state unchanged and retryable', () {
    late ProviderContainer container;
    late _MockSettingsDao dao;
    var shouldThrow = true;
    final writes = <Map<String, String>>[];

    setUp(() {
      dao = _MockSettingsDao();
      shouldThrow = true;
      writes.clear();
      // Loads as all-defaults (enableMeridianFlip=true, minutes=5).
      when(() => dao.getAllSettings()).thenAnswer((_) async => {});
      when(() => dao.setSettings(any())).thenAnswer((invocation) async {
        writes.add(
          (invocation.positionalArguments.first as Map).cast<String, String>(),
        );
        if (shouldThrow) {
          throw Exception('disk full');
        }
      });
      container = ProviderContainer(
        overrides: [settingsDaoProvider.overrideWithValue(dao)],
      );
    });

    tearDown(() => container.dispose());

    test(
      'one batched setSettings call carries both keys (never per-field)',
      () async {
        await container.read(appSettingsProvider.future);
        shouldThrow = false;

        await container
            .read(appSettingsProvider.notifier)
            .setMeridianFlipConfig(enableFlip: false, minutes: 30);

        // Exactly one atomic write, carrying BOTH keys — never two single-field
        // setSetting calls that could partially persist.
        expect(writes, hasLength(1));
        expect(
          writes.single.keys,
          containsAll(['enable_meridian_flip', 'meridian_flip_minutes']),
        );
        verifyNever(() => dao.setSetting(any(), any()));
      },
    );

    test('a write failure leaves state at its pre-write values', () async {
      final before = await container.read(appSettingsProvider.future);
      // Sanity: the values we are about to try to set differ from defaults, so
      // "unchanged" is a meaningful assertion.
      expect(before.enableMeridianFlip, isTrue);
      expect(before.meridianFlipMinutes, 5);

      await expectLater(
        container
            .read(appSettingsProvider.notifier)
            .setMeridianFlipConfig(enableFlip: false, minutes: 30),
        throwsA(isA<Exception>()),
      );

      final after = container.read(appSettingsProvider).requireValue;
      expect(
        after.enableMeridianFlip,
        isTrue,
        reason: 'a failed persist must not flip the in-memory toggle',
      );
      expect(
        after.meridianFlipMinutes,
        5,
        reason: 'a failed persist must not change the in-memory minutes',
      );
    });

    test(
      'a retry after a transient failure succeeds and applies state',
      () async {
        await container.read(appSettingsProvider.future);

        await expectLater(
          container
              .read(appSettingsProvider.notifier)
              .setFocuserCompensationConfig(
                tempCompensation: true,
                tempCoefficient: 2.5,
                backlashCompensation: 500,
              ),
          throwsA(isA<Exception>()),
        );
        // State untouched by the failed attempt.
        expect(
          container.read(appSettingsProvider).requireValue.tempCompensation,
          isFalse,
        );

        // The transient fault clears; the identical retry now succeeds.
        shouldThrow = false;
        await container
            .read(appSettingsProvider.notifier)
            .setFocuserCompensationConfig(
              tempCompensation: true,
              tempCoefficient: 2.5,
              backlashCompensation: 500,
            );

        final after = container.read(appSettingsProvider).requireValue;
        expect(after.tempCompensation, isTrue);
        expect(after.tempCoefficient, 2.5);
        expect(after.backlashCompensation, 500);
      },
    );
  });
}
