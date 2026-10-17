import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/providers/hardware_presets_provider.dart';
import 'package:skotiq_core/src/services/hardware_presets/hardware_presets_service.dart';

/// End-to-end provider test for the hardware-presets library.
///
/// We override `databaseProvider` with an in-memory Drift instance so override
/// persistence hits the real `app_settings` schema (no mocks), then drive the
/// notifier through save / edit-built-in / delete paths and verify that
/// overrides survive a fresh notifier load.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  /// Reads the notifier from a second container backed by the SAME database so
  /// the persisted override blobs hydrate a fresh `_load()`.
  Future<HardwarePresetsService> readFromFreshContainer(
    Future<void> Function(ProviderContainer fresh) body,
  ) async {
    final fresh = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    try {
      final notifier = fresh.read(hardwarePresetsServiceProvider.notifier);
      await notifier.loaded;
      await body(fresh);
      return fresh.read(hardwarePresetsServiceProvider);
    } finally {
      fresh.dispose();
    }
  }

  test(
    'loaded resolves and yields the built-ins-only base on fresh install',
    () async {
      final notifier = container.read(hardwarePresetsServiceProvider.notifier);
      expect(notifier.isLoaded, isFalse);
      await notifier.loaded;
      expect(notifier.isLoaded, isTrue);

      final service = container.read(hardwarePresetsServiceProvider);
      expect(service.allTelescopes(), builtInTelescopePresets);
      expect(service.allCameras(), builtInCameraDefaultsPresets);
      expect(
        service.allTelescopes().every((preset) => preset.isBuiltIn),
        isTrue,
      );
    },
  );

  test(
    'saving a custom telescope persists JSON and survives a fresh load',
    () async {
      final notifier = container.read(hardwarePresetsServiceProvider.notifier);
      await notifier.loaded;

      final custom = TelescopePreset(
        id: newHardwarePresetId(),
        brand: 'Custom Optics',
        model: 'Astrograph 130',
        focalLengthMm: 910,
        apertureMm: 130,
        design: OpticalDesign.refractor,
        nativeFocalRatio: 7.0,
        isBuiltIn: false,
      );
      await notifier.saveTelescopePreset(custom);

      // In-memory state reflects the new preset, overrides-first.
      final live = container.read(hardwarePresetsServiceProvider);
      expect(live.allTelescopes().first, custom);
      expect(live.allTelescopes().length, builtInTelescopePresets.length + 1);

      // The convenience read provider sees it too.
      expect(container.read(telescopePresetsProvider).first, custom);

      // The JSON blob was actually written under the versioned key.
      final settingsDao = container.read(settingsDaoProvider);
      final raw = await settingsDao.getSetting(
        HardwarePresetsService.telescopeOverridesSettingKey,
      );
      expect(raw, isNotNull);
      final decoded = HardwarePresetsService.telescopeOverridesFromJson(
        jsonDecode(raw!),
      );
      expect(decoded, [custom]);

      // A fresh notifier backed by the same DB hydrates the override.
      final reloaded = await readFromFreshContainer((_) async {});
      expect(reloaded.allTelescopes().first, custom);
      expect(
        reloaded.allTelescopes().length,
        builtInTelescopePresets.length + 1,
      );
    },
  );

  test('saving a custom camera persists and survives a fresh load', () async {
    final notifier = container.read(hardwarePresetsServiceProvider.notifier);
    await notifier.loaded;

    final custom = CameraDefaultsPreset(
      id: newHardwarePresetId(),
      brand: 'Homebrew',
      model: 'CoolCam 9000',
      aliases: const ['CC9000'],
      pixelSizeMicrons: 5.0,
      sensorWidthPx: 1000,
      sensorHeightPx: 1000,
      sensorName: 'Custom CMOS',
      isColor: false,
      recommendedGain: 50,
      recommendedOffset: 10,
      isBuiltIn: false,
    );
    await notifier.saveCameraPreset(custom);

    expect(container.read(cameraDefaultsPresetsProvider).first, custom);

    final reloaded = await readFromFreshContainer((_) async {});
    expect(reloaded.allCameras().first, custom);
    expect(reloaded.matchCameraByName('CoolCam 9000'), custom);
  });

  test('editing a built-in telescope stores an override copy that wins', () async {
    final notifier = container.read(hardwarePresetsServiceProvider.notifier);
    await notifier.loaded;

    const builtInId = 'tel.skywatcher.esprit100ed';
    final original = builtInTelescopePresets.firstWhere(
      (preset) => preset.id == builtInId,
    );

    // Save an edited copy that (deliberately) still claims isBuiltIn: true — the
    // notifier must coerce it to a user-owned override so it can be persisted.
    final edited = original.copyWith(
      focalLengthMm: 385,
      model: 'Esprit 100ED (reducer)',
      isBuiltIn: true,
    );
    await notifier.saveTelescopePreset(edited);

    final service = container.read(hardwarePresetsServiceProvider);
    final matching = service
        .allTelescopes()
        .where((preset) => preset.id == builtInId)
        .toList();
    // The override replaced the built-in; the id still appears exactly once and
    // the count is unchanged (replace, not add).
    expect(matching, hasLength(1));
    expect(matching.single.focalLengthMm, 385);
    expect(matching.single.model, 'Esprit 100ED (reducer)');
    expect(matching.single.isBuiltIn, isFalse);
    expect(service.allTelescopes().length, builtInTelescopePresets.length);

    // It survives a reload (built-in still cannot win back).
    final reloaded = await readFromFreshContainer((_) async {});
    final reloadedMatch = reloaded.allTelescopes().firstWhere(
      (preset) => preset.id == builtInId,
    );
    expect(reloadedMatch.focalLengthMm, 385);
    expect(reloadedMatch.isBuiltIn, isFalse);
  });

  test('editing a built-in camera stores an override copy that wins', () async {
    final notifier = container.read(hardwarePresetsServiceProvider.notifier);
    await notifier.loaded;

    const builtInId = 'cam.zwo.asi2600mm';
    final original = builtInCameraDefaultsPresets.firstWhere(
      (preset) => preset.id == builtInId,
    );
    final edited = original.copyWith(
      sensorName: 'Tuned IMX571',
      recommendedGain: 120,
      isBuiltIn: true,
    );
    await notifier.saveCameraPreset(edited);

    final service = container.read(hardwarePresetsServiceProvider);
    final match = service.allCameras().firstWhere(
      (preset) => preset.id == builtInId,
    );
    expect(match.sensorName, 'Tuned IMX571');
    expect(match.recommendedGain, 120);
    expect(match.isBuiltIn, isFalse);
    expect(service.allCameras().length, builtInCameraDefaultsPresets.length);
  });

  test('deleting a built-in telescope throws StateError', () async {
    final notifier = container.read(hardwarePresetsServiceProvider.notifier);
    await notifier.loaded;
    expect(
      () => notifier.deleteTelescopePreset('tel.skywatcher.esprit100ed'),
      throwsStateError,
    );
  });

  test('deleting a built-in camera throws StateError', () async {
    final notifier = container.read(hardwarePresetsServiceProvider.notifier);
    await notifier.loaded;
    expect(
      () => notifier.deleteCameraPreset('cam.zwo.asi2600mm'),
      throwsStateError,
    );
  });

  test(
    'deleting a custom telescope removes it and persists the removal',
    () async {
      final notifier = container.read(hardwarePresetsServiceProvider.notifier);
      await notifier.loaded;

      final custom = TelescopePreset(
        id: newHardwarePresetId(),
        brand: 'Custom Optics',
        model: 'Astrograph 130',
        focalLengthMm: 910,
        apertureMm: 130,
        design: OpticalDesign.refractor,
        isBuiltIn: false,
      );
      await notifier.saveTelescopePreset(custom);
      expect(
        container.read(hardwarePresetsServiceProvider).allTelescopes(),
        contains(custom),
      );

      await notifier.deleteTelescopePreset(custom.id);
      final after = container.read(hardwarePresetsServiceProvider);
      expect(after.allTelescopes(), isNot(contains(custom)));
      expect(after.allTelescopes(), builtInTelescopePresets);

      // The removal was persisted: a fresh load has no overrides.
      final reloaded = await readFromFreshContainer((_) async {});
      expect(reloaded.allTelescopes(), builtInTelescopePresets);
    },
  );

  test('deleting a custom camera removes it', () async {
    final notifier = container.read(hardwarePresetsServiceProvider.notifier);
    await notifier.loaded;

    final custom = CameraDefaultsPreset(
      id: newHardwarePresetId(),
      brand: 'Homebrew',
      model: 'CoolCam 9000',
      pixelSizeMicrons: 5.0,
      sensorWidthPx: 1000,
      sensorHeightPx: 1000,
      sensorName: 'Custom CMOS',
      isColor: false,
      recommendedGain: 50,
      recommendedOffset: 10,
      isBuiltIn: false,
    );
    await notifier.saveCameraPreset(custom);
    expect(
      container.read(hardwarePresetsServiceProvider).allCameras(),
      contains(custom),
    );

    await notifier.deleteCameraPreset(custom.id);
    expect(
      container.read(hardwarePresetsServiceProvider).allCameras(),
      builtInCameraDefaultsPresets,
    );
  });

  test('saving the same custom id twice replaces in place (upsert)', () async {
    final notifier = container.read(hardwarePresetsServiceProvider.notifier);
    await notifier.loaded;

    final id = newHardwarePresetId();
    final first = TelescopePreset(
      id: id,
      brand: 'Custom',
      model: 'V1',
      focalLengthMm: 500,
      apertureMm: 100,
      design: OpticalDesign.refractor,
      isBuiltIn: false,
    );
    await notifier.saveTelescopePreset(first);
    final second = first.copyWith(model: 'V2', focalLengthMm: 600);
    await notifier.saveTelescopePreset(second);

    final service = container.read(hardwarePresetsServiceProvider);
    final matches = service
        .allTelescopes()
        .where((preset) => preset.id == id)
        .toList();
    expect(matches, hasLength(1));
    expect(matches.single.model, 'V2');
    expect(matches.single.focalLengthMm, 600);
    expect(service.allTelescopes().length, builtInTelescopePresets.length + 1);
  });

  test(
    'a malformed persisted blob surfaces as a FormatException on load',
    () async {
      // Seed a non-list JSON payload directly, then build a fresh notifier and
      // confirm the load future rejects rather than silently falling back.
      final settingsDao = container.read(settingsDaoProvider);
      await settingsDao.setSetting(
        HardwarePresetsService.telescopeOverridesSettingKey,
        jsonEncode({'not': 'a list'}),
      );

      final fresh = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)],
      );
      addTearDown(fresh.dispose);
      final notifier = fresh.read(hardwarePresetsServiceProvider.notifier);
      await expectLater(notifier.loaded, throwsFormatException);
    },
  );
}
