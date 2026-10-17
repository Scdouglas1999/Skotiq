import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/hardware_presets/hardware_preset_models.dart';
import 'package:skotiq_core/src/services/hardware_presets/hardware_presets_service.dart';

void main() {
  group('HardwarePresetsService', () {
    const service = HardwarePresetsService();

    test('built-in telescopes and cameras are returned and searchable', () {
      expect(service.allTelescopes(), isNotEmpty);
      expect(service.allCameras(), isNotEmpty);
      expect(
        service.allTelescopes().every((preset) => preset.isBuiltIn),
        isTrue,
      );

      final esprit = service.searchTelescopes('Esprit 100ED');
      expect(esprit.first.id, 'tel.skywatcher.esprit100ed');

      final asi = service.searchCameras('ASI2600MM Pro');
      expect(asi.first.id, 'cam.zwo.asi2600mm');
    });

    test('search matches across brand, model, and camera aliases', () {
      // Brand-only query returns every ZWO camera.
      final zwo = service.searchCameras('ZWO');
      expect(zwo, isNotEmpty);
      expect(zwo.every((preset) => preset.brand == 'ZWO'), isTrue);

      // Alias-only query (the bare alias, not the display name) still hits.
      final viaAlias = service.searchCameras('ASI533MC');
      expect(viaAlias.map((preset) => preset.id), contains('cam.zwo.asi533mc'));

      // Telescope model substring.
      final redcat = service.searchTelescopes('RedCat');
      expect(redcat.single.id, 'tel.williamoptics.redcat51');
    });

    test('empty query returns the full merged catalog in order', () {
      expect(service.searchTelescopes('   '), service.allTelescopes());
      expect(service.searchCameras(''), service.allCameras());
    });

    test('override with the same id replaces the matching built-in', () {
      const replacement = TelescopePreset(
        id: 'tel.skywatcher.esprit100ed',
        brand: 'Sky-Watcher',
        model: 'Esprit 100ED (reducer)',
        focalLengthMm: 385,
        apertureMm: 100,
        design: OpticalDesign.refractor,
        nativeFocalRatio: 3.85,
        isBuiltIn: false,
      );
      final withOverride = service.withOverrides(
        telescopeOverrides: [replacement],
      );

      final matching = withOverride
          .allTelescopes()
          .where((preset) => preset.id == 'tel.skywatcher.esprit100ed')
          .toList();
      expect(matching, hasLength(1));
      expect(matching.single, replacement);
      expect(matching.single.model, 'Esprit 100ED (reducer)');

      // The total count is unchanged because the override replaced, not added.
      expect(
        withOverride.allTelescopes().length,
        service.allTelescopes().length,
      );
    });

    test(
      'user preset (isBuiltIn:false) with a new id appears in allX first',
      () {
        final customId = newHardwarePresetId();
        final custom = CameraDefaultsPreset(
          id: customId,
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
        final withCustom = service.withOverrides(cameraOverrides: [custom]);

        expect(withCustom.allCameras().first, custom);
        expect(withCustom.allCameras().length, service.allCameras().length + 1);
        expect(withCustom.searchCameras('CoolCam').single.id, customId);
      },
    );

    test('search ranks exact match before startsWith before contains', () {
      const exact = CameraDefaultsPreset(
        id: 'cam.test.exact',
        brand: 'Acme',
        model: 'Orion',
        pixelSizeMicrons: 3.0,
        sensorWidthPx: 100,
        sensorHeightPx: 100,
        sensorName: 'S',
        isColor: false,
        recommendedGain: 0,
        recommendedOffset: 0,
      );
      const startsWith = CameraDefaultsPreset(
        id: 'cam.test.startswith',
        brand: 'Acme',
        model: 'Orion Nebula Special',
        pixelSizeMicrons: 3.0,
        sensorWidthPx: 100,
        sensorHeightPx: 100,
        sensorName: 'S',
        isColor: false,
        recommendedGain: 0,
        recommendedOffset: 0,
      );
      const contains = CameraDefaultsPreset(
        id: 'cam.test.contains',
        brand: 'Acme',
        model: 'Pro Orion Edition',
        pixelSizeMicrons: 3.0,
        sensorWidthPx: 100,
        sensorHeightPx: 100,
        sensorName: 'S',
        isColor: false,
        recommendedGain: 0,
        recommendedOffset: 0,
      );

      // Provide an isolated catalog so only these three participate, and place
      // them in worst-rank-first order to prove ranking, not input order, wins.
      const ranked = HardwarePresetsService(
        cameraCatalog: [contains, startsWith, exact],
      );
      final results = ranked.searchCameras('Orion');
      expect(results.map((preset) => preset.id), [
        'cam.test.exact',
        'cam.test.startswith',
        'cam.test.contains',
      ]);
    });

    test(
      'matchCameraByName resolves reported names to the IMX571 mono preset',
      () {
        final byModel = service.matchCameraByName('ASI2600MM Pro');
        expect(byModel, isNotNull);
        expect(byModel!.id, 'cam.zwo.asi2600mm');
        expect(byModel.sensorName, 'Sony IMX571');
        expect(byModel.isColor, isFalse);

        final byBrandedAlias = service.matchCameraByName('ZWO ASI2600MM');
        expect(byBrandedAlias, isNotNull);
        expect(byBrandedAlias!.id, 'cam.zwo.asi2600mm');
        expect(byBrandedAlias.isColor, isFalse);

        // Normalization tolerates punctuation/case differences.
        final messy = service.matchCameraByName('zwo-asi2600mm-pro');
        expect(messy?.id, 'cam.zwo.asi2600mm');
      },
    );

    test('matchCameraByName does not confuse the mono and color variants', () {
      expect(
        service.matchCameraByName('ASI2600MC Pro')?.id,
        'cam.zwo.asi2600mc',
      );
      expect(
        service.matchCameraByName('ASI2600MM Pro')?.id,
        'cam.zwo.asi2600mm',
      );
    });

    test('matchCameraByName returns null for empty or unknown names', () {
      expect(service.matchCameraByName(null), isNull);
      expect(service.matchCameraByName('   '), isNull);
      expect(service.matchCameraByName('Mystery Camera 42'), isNull);
    });

    test('matchCameraByName prefers a user override over a built-in', () {
      final override = CameraDefaultsPreset(
        id: newHardwarePresetId(),
        brand: 'ZWO',
        model: 'ASI2600MM Pro',
        aliases: const ['ASI2600MM Pro'],
        pixelSizeMicrons: 3.76,
        sensorWidthPx: 6248,
        sensorHeightPx: 4176,
        sensorName: 'Tuned IMX571',
        isColor: false,
        recommendedGain: 120,
        recommendedOffset: 60,
        recommendedCoolingTempC: -15,
        isBuiltIn: false,
      );
      final tuned = service.withOverrides(cameraOverrides: [override]);
      final match = tuned.matchCameraByName('ASI2600MM Pro');
      expect(match, override);
      expect(match!.sensorName, 'Tuned IMX571');
    });

    group('persistence (de)serialization', () {
      test('telescope overrides round-trip through encode/decode', () {
        final originals = [
          TelescopePreset(
            id: newHardwarePresetId(),
            brand: 'Custom Optics',
            model: 'Astrograph 130',
            focalLengthMm: 910,
            apertureMm: 130,
            design: OpticalDesign.refractor,
            nativeFocalRatio: 7.0,
            isBuiltIn: false,
          ),
          const TelescopePreset(
            id: 'tel.skywatcher.esprit100ed',
            brand: 'Sky-Watcher',
            model: 'Esprit 100ED (reducer)',
            focalLengthMm: 385,
            apertureMm: 100,
            design: OpticalDesign.refractor,
            isBuiltIn: false,
          ),
        ];

        final encoded = HardwarePresetsService.encodeTelescopeOverrides(
          originals,
        );
        final decoded = HardwarePresetsService.telescopeOverridesFromJson(
          jsonDecode(encoded),
        );
        expect(decoded, originals);
      });

      test('camera overrides round-trip through encode/decode', () {
        final originals = [
          CameraDefaultsPreset(
            id: newHardwarePresetId(),
            brand: 'Custom',
            model: 'Sensor X',
            aliases: const ['SX', 'Sensor-X'],
            pixelSizeMicrons: 2.9,
            sensorWidthPx: 4144,
            sensorHeightPx: 2822,
            sensorName: 'Custom IMX',
            isColor: true,
            recommendedGain: 90,
            recommendedOffset: 25,
            recommendedBinX: 2,
            recommendedBinY: 2,
            recommendedCoolingTempC: -12.5,
            isBuiltIn: false,
          ),
        ];

        final encoded = HardwarePresetsService.encodeCameraOverrides(originals);
        final decoded = HardwarePresetsService.cameraOverridesFromJson(
          jsonDecode(encoded),
        );
        expect(decoded, originals);
      });

      test('null decodes to an empty override list', () {
        expect(
          HardwarePresetsService.telescopeOverridesFromJson(null),
          isEmpty,
        );
        expect(HardwarePresetsService.cameraOverridesFromJson(null), isEmpty);
      });

      test('non-list JSON throws FormatException', () {
        expect(
          () => HardwarePresetsService.telescopeOverridesFromJson({
            'not': 'a list',
          }),
          throwsFormatException,
        );
        expect(
          () => HardwarePresetsService.cameraOverridesFromJson('not a list'),
          throwsFormatException,
        );
      });

      test('persistence keys are stable, versioned identifiers', () {
        expect(
          HardwarePresetsService.telescopeOverridesSettingKey,
          'hardware_presets.telescopes.v1',
        );
        expect(
          HardwarePresetsService.cameraOverridesSettingKey,
          'hardware_presets.cameras.v1',
        );
      });
    });
  });
}
