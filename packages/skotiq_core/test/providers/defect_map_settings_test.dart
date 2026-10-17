import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/settings_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/defect_map.dart';
import 'package:skotiq_core/src/providers/database_provider.dart';
import 'package:skotiq_core/src/providers/defect_map_provider.dart';

class _FailingSettingsDao extends SettingsDao {
  _FailingSettingsDao(super.db);

  @override
  Future<void> setSetting(String key, String value) async {
    throw StateError('write failed');
  }
}

/// Unit tests for the per-camera defect-map settings
/// provider. Verifies that:
///   1. Defaults are correct (auto-apply off, kernel 3, method median,
///      save_original off).
///   2. Each setter persists to the underlying KV store AND updates the
///      notifier state in lockstep.
///   3. A fresh provider instance round-trips the previously-persisted
///      values from storage.
void main() {
  group('DefectMapSettings', () {
    late SkotiqDatabase db;
    late ProviderContainer container;

    setUp(() {
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    test('defaults are auto-apply off, kernel 3, method median', () async {
      // Force initial load to settle.
      await container.read(allSettingsProvider.future);
      final settings = container.read(defectMapSettingsProvider);
      expect(settings.autoApply, isFalse);
      expect(settings.kernel, DefectMapKernelSize.k3);
      expect(settings.method, DefectMapMethod.median);
      expect(settings.saveOriginal, isFalse);
    });

    test('setters persist to dao and update state', () async {
      // Why pump-and-settle pattern: `allSettingsProvider` is a stream
      // backed by `watchAllSettings`; every dao write fires a stream
      // emission that re-runs the notifier's listener. We need to let
      // those rebroadcasts settle between setter calls before reading
      // the final state, otherwise we may catch the notifier mid-flight.
      Future<void> pump() async {
        // Pump the event loop several times so the broadcast streams
        // can deliver to all subscribers.
        for (var i = 0; i < 5; i++) {
          await Future<void>.delayed(Duration.zero);
        }
      }

      await container.read(allSettingsProvider.future);
      final notifier = container.read(defectMapSettingsProvider.notifier);

      await notifier.setAutoApply(true);
      await pump();
      await notifier.setMethod(DefectMapMethod.gaussian);
      await pump();
      await notifier.setKernel(DefectMapKernelSize.k7);
      await pump();
      await notifier.setSaveOriginal(true);
      await pump();

      // The notifier state should reflect the cumulative result.
      final state = container.read(defectMapSettingsProvider);
      expect(state.autoApply, isTrue);
      expect(state.method, DefectMapMethod.gaussian);
      expect(state.kernel, DefectMapKernelSize.k7);
      expect(state.saveOriginal, isTrue);

      // Read raw KV entries to confirm persistence happened.
      final dao = container.read(settingsDaoProvider);
      expect(await dao.getSetting(DefectMapSettingsKeys.autoApply), 'true');
      expect(
        await dao.getSetting(DefectMapSettingsKeys.method),
        DefectMapMethod.gaussian.wireValue,
      );
      expect(await dao.getSetting(DefectMapSettingsKeys.kernel), '7');
      expect(await dao.getSetting(DefectMapSettingsKeys.saveOriginal), 'true');
    });

    test('round-trips through a fresh provider', () async {
      await container.read(allSettingsProvider.future);
      final notifier = container.read(defectMapSettingsProvider.notifier);
      await notifier.setAutoApply(true);
      await notifier.setMethod(DefectMapMethod.mean);
      await notifier.setKernel(DefectMapKernelSize.k5);
      await notifier.setSaveOriginal(false);

      // Force a fresh provider read by invalidating the settings tree.
      container.invalidate(allSettingsProvider);
      container.invalidate(defectMapSettingsProvider);
      await container.read(allSettingsProvider.future);
      final reloaded = container.read(defectMapSettingsProvider);
      expect(reloaded.autoApply, isTrue);
      expect(reloaded.method, DefectMapMethod.mean);
      expect(reloaded.kernel, DefectMapKernelSize.k5);
      expect(reloaded.saveOriginal, isFalse);
    });

    test('failed persistence leaves the confirmed state unchanged', () async {
      container.dispose();
      container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          settingsDaoProvider.overrideWithValue(_FailingSettingsDao(db)),
        ],
      );
      await container.read(allSettingsProvider.future);
      final notifier = container.read(defectMapSettingsProvider.notifier);

      await expectLater(notifier.setAutoApply(true), throwsStateError);

      expect(container.read(defectMapSettingsProvider).autoApply, isFalse);
    });

    test('DefectMapMethod.fromWire handles unknown values gracefully', () {
      expect(DefectMapMethod.fromWire(null), DefectMapMethod.median);
      expect(DefectMapMethod.fromWire(''), DefectMapMethod.median);
      expect(DefectMapMethod.fromWire('bogus'), DefectMapMethod.median);
      expect(DefectMapMethod.fromWire('gaussian'), DefectMapMethod.gaussian);
    });

    test('DefectMapKernelSize rejects unknown diameters and falls back', () {
      expect(DefectMapKernelSize.fromDiameter(3), DefectMapKernelSize.k3);
      expect(DefectMapKernelSize.fromDiameter(5), DefectMapKernelSize.k5);
      expect(DefectMapKernelSize.fromDiameter(7), DefectMapKernelSize.k7);
      // Invalid diameter falls back to the default.
      expect(DefectMapKernelSize.fromDiameter(4), DefectMapKernelSize.k3);
      expect(DefectMapKernelSize.fromDiameter(0), DefectMapKernelSize.k3);
      expect(DefectMapKernelSize.fromDiameter(99), DefectMapKernelSize.k3);
    });
  });
}
