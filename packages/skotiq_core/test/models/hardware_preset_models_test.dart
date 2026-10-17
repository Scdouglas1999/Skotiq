import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/hardware_presets/hardware_preset_models.dart';

void main() {
  group('OpticalDesign', () {
    test('label is non-empty for every variant', () {
      for (final design in OpticalDesign.values) {
        expect(design.label, isNotEmpty);
      }
    });

    test('fromJson round-trips every variant via name', () {
      for (final design in OpticalDesign.values) {
        expect(OpticalDesign.fromJson(design.name), design);
      }
    });

    test('fromJson throws FormatException on unknown value', () {
      expect(
        () => OpticalDesign.fromJson('parabolic'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => OpticalDesign.fromJson(null),
        throwsA(isA<FormatException>()),
      );
      expect(() => OpticalDesign.fromJson(7), throwsA(isA<FormatException>()));
    });
  });

  group('TelescopePreset', () {
    test('focalRatio is computed from optics', () {
      const t = TelescopePreset(
        id: 't',
        brand: 'Test',
        model: 'Scope',
        focalLengthMm: 800,
        apertureMm: 200,
        design: OpticalDesign.reflectorNewtonian,
      );
      expect(t.focalRatio, closeTo(4.0, 1e-9));
      expect(t.displayName, 'Test Scope');
    });

    test('focalRatio throws on non-positive aperture', () {
      const t = TelescopePreset(
        id: 't',
        brand: 'B',
        model: 'M',
        focalLengthMm: 500,
        apertureMm: 0,
        design: OpticalDesign.refractor,
      );
      expect(() => t.focalRatio, throwsStateError);
    });

    test('JSON round-trips (with and without nativeFocalRatio)', () {
      const withNative = TelescopePreset(
        id: 'tel.x',
        brand: 'Sky-Watcher',
        model: 'Esprit 100ED',
        focalLengthMm: 550,
        apertureMm: 100,
        design: OpticalDesign.refractor,
        nativeFocalRatio: 5.5,
        isBuiltIn: true,
      );
      final decoded = TelescopePreset.fromJson(
        jsonDecode(jsonEncode(withNative.toJson())) as Map<String, dynamic>,
      );
      expect(decoded, withNative);
      expect(decoded.hashCode, withNative.hashCode);

      const withoutNative = TelescopePreset(
        id: 'tel.y',
        brand: 'Custom',
        model: 'Tube',
        focalLengthMm: 300,
        apertureMm: 60,
        design: OpticalDesign.other,
      );
      final decoded2 = TelescopePreset.fromJson(
        jsonDecode(jsonEncode(withoutNative.toJson())) as Map<String, dynamic>,
      );
      expect(decoded2, withoutNative);
      expect(decoded2.nativeFocalRatio, isNull);
    });

    test('fromJson throws on missing required field', () {
      expect(
        () => TelescopePreset.fromJson({
          'brand': 'B',
          'model': 'M',
          'focalLengthMm': 500,
          'apertureMm': 100,
          'design': 'refractor',
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('fromJson throws on non-numeric required field', () {
      expect(
        () => TelescopePreset.fromJson({
          'id': 't',
          'brand': 'B',
          'model': 'M',
          'focalLengthMm': 'not-a-number',
          'apertureMm': 100,
          'design': 'refractor',
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('fromJson throws on unknown design', () {
      expect(
        () => TelescopePreset.fromJson({
          'id': 't',
          'brand': 'B',
          'model': 'M',
          'focalLengthMm': 500,
          'apertureMm': 100,
          'design': 'bogus',
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('copyWith updates and clears fields', () {
      const t = TelescopePreset(
        id: 't',
        brand: 'B',
        model: 'M',
        focalLengthMm: 500,
        apertureMm: 100,
        design: OpticalDesign.refractor,
        nativeFocalRatio: 5.0,
      );
      expect(t.copyWith(model: 'M2').model, 'M2');
      expect(t.copyWith(nativeFocalRatio: 6.0).nativeFocalRatio, 6.0);
      expect(t.copyWith(clearNativeFocalRatio: true).nativeFocalRatio, isNull);
    });
  });

  group('CameraDefaultsPreset', () {
    test('displayName and sensorDiagonal computed', () {
      const c = CameraDefaultsPreset(
        id: 'c',
        brand: 'ZWO',
        model: 'ASI2600MM Pro',
        pixelSizeMicrons: 3.76,
        sensorWidthPx: 6248,
        sensorHeightPx: 4176,
        sensorName: 'Sony IMX571',
        isColor: false,
        recommendedGain: 100,
        recommendedOffset: 50,
      );
      expect(c.displayName, 'ZWO ASI2600MM Pro');
      // APS-C IMX571 diagonal is ~28.3 mm.
      expect(c.sensorDiagonalMm, closeTo(28.3, 0.3));
    });

    test('JSON round-trips (cooled and DSLR null cooling)', () {
      const cooled = CameraDefaultsPreset(
        id: 'cam.x',
        brand: 'ZWO',
        model: 'ASI533MM Pro',
        aliases: ['ASI533MM'],
        pixelSizeMicrons: 3.76,
        sensorWidthPx: 3008,
        sensorHeightPx: 3008,
        sensorName: 'Sony IMX533',
        isColor: false,
        recommendedGain: 100,
        recommendedOffset: 50,
        recommendedBinX: 1,
        recommendedBinY: 1,
        recommendedCoolingTempC: -10,
        isBuiltIn: true,
      );
      final decoded = CameraDefaultsPreset.fromJson(
        jsonDecode(jsonEncode(cooled.toJson())) as Map<String, dynamic>,
      );
      expect(decoded, cooled);
      expect(decoded.hashCode, cooled.hashCode);

      const dslr = CameraDefaultsPreset(
        id: 'cam.dslr',
        brand: 'Canon',
        model: 'EOS Ra',
        pixelSizeMicrons: 4.3,
        sensorWidthPx: 6960,
        sensorHeightPx: 4640,
        sensorName: 'Canon CMOS',
        isColor: true,
        recommendedGain: 0,
        recommendedOffset: 0,
      );
      final decodedDslr = CameraDefaultsPreset.fromJson(
        jsonDecode(jsonEncode(dslr.toJson())) as Map<String, dynamic>,
      );
      expect(decodedDslr, dslr);
      expect(decodedDslr.recommendedCoolingTempC, isNull);
    });

    test('fromJson throws on missing required field', () {
      expect(
        () => CameraDefaultsPreset.fromJson({
          'id': 'c',
          'brand': 'ZWO',
          // model missing
          'pixelSizeMicrons': 3.76,
          'sensorWidthPx': 6248,
          'sensorHeightPx': 4176,
          'sensorName': 'IMX571',
          'isColor': false,
          'recommendedGain': 100,
          'recommendedOffset': 50,
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('fromJson throws on non-numeric required field', () {
      expect(
        () => CameraDefaultsPreset.fromJson({
          'id': 'c',
          'brand': 'ZWO',
          'model': 'X',
          'pixelSizeMicrons': 'big',
          'sensorWidthPx': 6248,
          'sensorHeightPx': 4176,
          'sensorName': 'IMX571',
          'isColor': false,
          'recommendedGain': 100,
          'recommendedOffset': 50,
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('fromJson throws on non-boolean isColor', () {
      expect(
        () => CameraDefaultsPreset.fromJson({
          'id': 'c',
          'brand': 'ZWO',
          'model': 'X',
          'pixelSizeMicrons': 3.76,
          'sensorWidthPx': 6248,
          'sensorHeightPx': 4176,
          'sensorName': 'IMX571',
          'isColor': 'maybe',
          'recommendedGain': 100,
          'recommendedOffset': 50,
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('copyWith updates and clears cooling', () {
      const c = CameraDefaultsPreset(
        id: 'c',
        brand: 'ZWO',
        model: 'X',
        pixelSizeMicrons: 3.76,
        sensorWidthPx: 100,
        sensorHeightPx: 100,
        sensorName: 'S',
        isColor: false,
        recommendedGain: 100,
        recommendedOffset: 50,
        recommendedCoolingTempC: -10,
      );
      expect(c.copyWith(recommendedGain: 120).recommendedGain, 120);
      expect(
        c.copyWith(clearRecommendedCoolingTempC: true).recommendedCoolingTempC,
        isNull,
      );
    });
  });

  group('newHardwarePresetId', () {
    test('produces unique ids that match no built-in id', () {
      final builtInIds = {
        ...builtInTelescopePresets.map((p) => p.id),
        ...builtInCameraDefaultsPresets.map((p) => p.id),
      };
      final generated = <String>{};
      for (var i = 0; i < 1000; i++) {
        final id = newHardwarePresetId();
        expect(
          builtInIds.contains(id),
          isFalse,
          reason: '$id collided with a built-in id',
        );
        expect(generated.add(id), isTrue, reason: '$id was generated twice');
      }
    });
  });

  group('built-in telescope catalog', () {
    test('every focalRatio matches stated f/ratio within 0.1', () {
      // Stated f/ratios from manufacturer marketing, keyed by preset id.
      const stated = {
        'tel.skywatcher.esprit100ed': 5.5,
        'tel.skywatcher.esprit120ed': 7.0,
        'tel.williamoptics.redcat51': 4.9,
        'tel.radian.raptor61': 4.5,
        'tel.askar.fra400': 5.6,
        'tel.skywatcher.quattro200p': 4.0,
        'tel.gso.rc8': 8.0,
        'tel.celestron.edgehd8': 10.0,
        'tel.celestron.c11': 10.0,
        'tel.takahashi.fsq106edx4': 5.0,
        'tel.skywatcher.evostar72ed': 5.8,
        'tel.explorescientific.ed80': 6.0,
        'tel.samyang.135f2': 2.0,
      };
      for (final preset in builtInTelescopePresets) {
        final expected = stated[preset.id];
        expect(
          expected,
          isNotNull,
          reason: 'no stated f/ratio for ${preset.id}',
        );
        expect(
          preset.focalRatio,
          closeTo(expected!, 0.1),
          reason:
              '${preset.displayName} computed f/${preset.focalRatio} '
              'vs stated f/$expected',
        );
        // nativeFocalRatio, when present, must also agree with the stated value.
        if (preset.nativeFocalRatio != null) {
          expect(preset.nativeFocalRatio!, closeTo(expected, 0.1));
        }
      }
    });

    test('contains all required models', () {
      const requiredIds = {
        'tel.skywatcher.esprit100ed',
        'tel.skywatcher.esprit120ed',
        'tel.williamoptics.redcat51',
        'tel.radian.raptor61',
        'tel.askar.fra400',
        'tel.skywatcher.quattro200p',
        'tel.gso.rc8',
        'tel.celestron.edgehd8',
        'tel.celestron.c11',
        'tel.takahashi.fsq106edx4',
        'tel.skywatcher.evostar72ed',
        'tel.explorescientific.ed80',
        'tel.samyang.135f2',
      };
      final ids = builtInTelescopePresets.map((p) => p.id).toSet();
      expect(ids.containsAll(requiredIds), isTrue);
    });

    test('ids are unique', () {
      final ids = builtInTelescopePresets.map((p) => p.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('every entry is built-in and JSON round-trips', () {
      for (final preset in builtInTelescopePresets) {
        expect(preset.isBuiltIn, isTrue);
        final decoded = TelescopePreset.fromJson(
          jsonDecode(jsonEncode(preset.toJson())) as Map<String, dynamic>,
        );
        expect(decoded, preset);
      }
    });
  });

  group('built-in camera catalog', () {
    test('ids are unique', () {
      final ids = builtInCameraDefaultsPresets.map((p) => p.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('contains all required models with correct headline specs', () {
      CameraDefaultsPreset byId(String id) =>
          builtInCameraDefaultsPresets.firstWhere((p) => p.id == id);

      final asi2600mm = byId('cam.zwo.asi2600mm');
      expect(asi2600mm.pixelSizeMicrons, 3.76);
      expect(asi2600mm.sensorWidthPx, 6248);
      expect(asi2600mm.sensorHeightPx, 4176);
      expect(asi2600mm.isColor, isFalse);
      expect(asi2600mm.sensorName, contains('IMX571'));
      expect(asi2600mm.recommendedGain, 100);
      expect(asi2600mm.recommendedOffset, 50);
      expect(asi2600mm.recommendedBinX, 1);

      expect(byId('cam.zwo.asi2600mc').isColor, isTrue);
      expect(byId('cam.zwo.asi2600mc').pixelSizeMicrons, 3.76);

      final asi533mm = byId('cam.zwo.asi533mm');
      expect(asi533mm.sensorWidthPx, 3008);
      expect(asi533mm.sensorHeightPx, 3008);
      expect(asi533mm.isColor, isFalse);
      expect(byId('cam.zwo.asi533mc').isColor, isTrue);

      final asi1600 = byId('cam.zwo.asi1600mm');
      expect(asi1600.pixelSizeMicrons, 3.8);
      expect(asi1600.sensorWidthPx, 4656);
      expect(asi1600.sensorHeightPx, 3520);
      expect(asi1600.sensorName, contains('MN34230'));
      // The well-known unity-gain values.
      expect(asi1600.recommendedGain, 139);
      expect(asi1600.recommendedOffset, 21);

      final asi294 = byId('cam.zwo.asi294mc');
      expect(asi294.pixelSizeMicrons, 4.63);
      expect(asi294.sensorWidthPx, 4144);
      expect(asi294.sensorHeightPx, 2822);
      expect(asi294.isColor, isTrue);
      expect(asi294.recommendedGain, 120);
      expect(asi294.recommendedOffset, 30);

      final asi183 = byId('cam.zwo.asi183mm');
      expect(asi183.pixelSizeMicrons, 2.4);
      expect(asi183.sensorWidthPx, 5496);
      expect(asi183.sensorHeightPx, 3672);
      expect(asi183.recommendedGain, 111);
      expect(asi183.recommendedOffset, 8);

      final asi6200 = byId('cam.zwo.asi6200mm');
      expect(asi6200.pixelSizeMicrons, 3.76);
      expect(asi6200.sensorWidthPx, 9576);
      expect(asi6200.sensorHeightPx, 6388);
      expect(asi6200.sensorName, contains('IMX455'));
      expect(asi6200.isColor, isFalse);

      expect(byId('cam.qhy.qhy268m').sensorName, contains('IMX571'));
      expect(byId('cam.qhy.qhy268m').pixelSizeMicrons, 3.76);
      expect(byId('cam.qhy.qhy183m').pixelSizeMicrons, 2.4);
      expect(byId('cam.qhy.qhy183m').sensorName, contains('IMX183'));
      expect(byId('cam.playerone.poseidonm').pixelSizeMicrons, 3.76);
      expect(byId('cam.playerone.poseidonm').sensorName, contains('IMX571'));

      final canon = byId('cam.canon.eosra');
      expect(canon.pixelSizeMicrons, 4.3);
      expect(canon.sensorWidthPx, 6960);
      expect(canon.sensorHeightPx, 4640);
      expect(canon.isColor, isTrue);
      expect(canon.recommendedGain, 0);
      expect(canon.recommendedOffset, 0);
      expect(canon.recommendedCoolingTempC, isNull);
    });

    test('cooled CMOS use -10C set-point; DSLR has null', () {
      for (final preset in builtInCameraDefaultsPresets) {
        if (preset.id == 'cam.canon.eosra') {
          expect(preset.recommendedCoolingTempC, isNull);
        } else {
          expect(preset.recommendedCoolingTempC, -10);
        }
      }
    });

    test('every entry is built-in and JSON round-trips', () {
      for (final preset in builtInCameraDefaultsPresets) {
        expect(preset.isBuiltIn, isTrue);
        final decoded = CameraDefaultsPreset.fromJson(
          jsonDecode(jsonEncode(preset.toJson())) as Map<String, dynamic>,
        );
        expect(decoded, preset);
      }
    });
  });
}
