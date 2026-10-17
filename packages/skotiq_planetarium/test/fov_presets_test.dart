import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

void main() {
  group('FovPreset geometry', () {
    test('computes FOV from sensor + focal length (atan formula)', () {
      // ASI2600 (28.3 x 18.9 mm) on a 480mm scope.
      const preset = FovPreset(
        id: 'a',
        name: 'rig',
        focalLengthMm: 480,
        sensorWidthMm: 28.3,
        sensorHeightMm: 18.9,
        pixelSizeMicrons: 3.76,
      );

      final fov = preset.fovDegrees;
      expect(fov, isNotNull);

      // Reference values from FOV = 2*atan(size / (2*f)).
      final expectedW = 2 * math.atan(28.3 / (2 * 480)) * 180 / math.pi;
      final expectedH = 2 * math.atan(18.9 / (2 * 480)) * 180 / math.pi;
      expect(fov!.$1, closeTo(expectedW, 1e-3));
      expect(fov.$2, closeTo(expectedH, 1e-3));
      // Sanity: a wide-field rig is a few degrees across.
      expect(fov.$1, closeTo(3.376, 0.05));
    });

    test('computes image scale in arcsec/px', () {
      const preset = FovPreset(
        id: 'a',
        name: 'rig',
        focalLengthMm: 480,
        sensorWidthMm: 28.3,
        sensorHeightMm: 18.9,
        pixelSizeMicrons: 3.76,
      );
      // scale = 206265 * (pixel_mm) / f = 206265 * 0.00376 / 480.
      const expected = 206265 * (3.76 / 1000) / 480;
      expect(preset.imageScaleArcsecPerPx, closeTo(expected, 1e-3));
      expect(preset.imageScaleArcsecPerPx, closeTo(1.616, 0.01));
    });

    test('degenerate optics (zero focal length) yield null, not infinity', () {
      const preset = FovPreset(
        id: 'a',
        name: 'rig',
        focalLengthMm: 0,
        sensorWidthMm: 28.3,
        sensorHeightMm: 18.9,
        pixelSizeMicrons: 3.76,
      );
      expect(preset.fovDegrees, isNull);
      expect(preset.imageScaleArcsecPerPx, isNull);
    });

    test('fromEquipment folds reducer into effective focal length', () {
      final preset = FovPreset.fromEquipment(
        id: 'a',
        camera: CameraSensorSpecs.asi2600mm,
        telescope: TelescopeSpecs.ed80, // 480mm
        focalMultiplier: 0.8, // 0.8x reducer
      );
      expect(preset.focalLengthMm, closeTo(384, 1e-6));
      expect(preset.name, contains('ED80'));
      // Reducer widens the field versus native focal length.
      final native = FovPreset.fromEquipment(
        id: 'b',
        camera: CameraSensorSpecs.asi2600mm,
        telescope: TelescopeSpecs.ed80,
      );
      expect(preset.fovDegrees!.$1, greaterThan(native.fovDegrees!.$1));
    });
  });

  group('FovPreset serialization', () {
    test('round-trips through JSON including center + color + PA', () {
      const preset = FovPreset(
        id: 'rig-1',
        name: 'ASI2600 + ED80',
        focalLengthMm: 384,
        sensorWidthMm: 28.3,
        sensorHeightMm: 18.9,
        pixelSizeMicrons: 3.76,
        positionAngleDeg: 37.5,
        color: Color(0xFF42A5F5),
        visible: false,
        center: CelestialCoordinate(ra: 5.59, dec: -5.39),
      );

      final restored = FovPreset.fromJson(preset.toJson());
      expect(restored, isNotNull);
      expect(restored, equals(preset));
      expect(restored!.center!.ra, closeTo(5.59, 1e-9));
      expect(restored.center!.dec, closeTo(-5.39, 1e-9));
      expect(restored.color, const Color(0xFF42A5F5));
      expect(restored.positionAngleDeg, 37.5);
      expect(restored.visible, isFalse);
    });

    test('fromJson returns null on a missing required numeric field', () {
      final bad = {
        'id': 'x',
        'name': 'incomplete',
        // focalLengthMm intentionally absent
        'sensorWidthMm': 28.3,
        'sensorHeightMm': 18.9,
        'pixelSizeMicrons': 3.76,
      };
      expect(FovPreset.fromJson(bad), isNull);
    });

    test('collection round-trips and preserves active id', () {
      const a = FovPreset(
        id: 'a',
        name: 'Wide',
        focalLengthMm: 384,
        sensorWidthMm: 28.3,
        sensorHeightMm: 18.9,
        pixelSizeMicrons: 3.76,
      );
      const b = FovPreset(
        id: 'b',
        name: 'Narrow',
        focalLengthMm: 2032,
        sensorWidthMm: 11.31,
        sensorHeightMm: 11.31,
        pixelSizeMicrons: 3.76,
      );
      const state = FovPresetsState(presets: [a, b], activeId: 'b');

      final restored = FovPresetsState.fromJsonString(state.toJsonString());
      expect(restored.presets, hasLength(2));
      expect(restored.presets.first, equals(a));
      expect(restored.activeId, 'b');
      expect(restored.active, equals(b));
    });

    test('corrupt JSON yields an empty collection rather than throwing', () {
      expect(
        FovPresetsState.fromJsonString('{not valid json').presets,
        isEmpty,
      );
      expect(FovPresetsState.fromJsonString('').presets, isEmpty);
      // Non-map top level.
      expect(FovPresetsState.fromJsonString('[1,2,3]').presets, isEmpty);
    });

    test('one corrupt preset is dropped, valid siblings survive', () {
      const good = FovPreset(
        id: 'good',
        name: 'ok',
        focalLengthMm: 480,
        sensorWidthMm: 23.5,
        sensorHeightMm: 15.6,
        pixelSizeMicrons: 3.9,
      );
      final mixed =
          '{"activeId":"good","presets":[${_jsonOf(good)},{"id":"bad"}]}';
      final restored = FovPresetsState.fromJsonString(mixed);
      expect(restored.presets, hasLength(1));
      expect(restored.presets.single.id, 'good');
      expect(restored.activeId, 'good');
    });

    test('active id pointing at a dropped preset is cleared', () {
      // activeId references a preset that fails to parse -> must be cleared.
      const bad = '{"activeId":"missing","presets":[{"id":"missing"}]}';
      final restored = FovPresetsState.fromJsonString(bad);
      expect(restored.presets, isEmpty);
      expect(restored.activeId, isNull);
    });
  });

  group('FovPresetsNotifier', () {
    test('add selects the new preset; remove clears active when matched', () {
      final notifier = FovPresetsNotifier();
      const a = FovPreset(
        id: 'a',
        name: 'A',
        focalLengthMm: 480,
        sensorWidthMm: 23.5,
        sensorHeightMm: 15.6,
        pixelSizeMicrons: 3.9,
      );
      notifier.add(a);
      expect(notifier.state.activeId, 'a');
      expect(notifier.state.presets, hasLength(1));

      notifier.remove('a');
      expect(notifier.state.presets, isEmpty);
      expect(notifier.state.activeId, isNull);
    });

    test('setActivePositionAngle normalizes into [0,360)', () {
      final notifier = FovPresetsNotifier();
      notifier.add(
        const FovPreset(
          id: 'a',
          name: 'A',
          focalLengthMm: 480,
          sensorWidthMm: 23.5,
          sensorHeightMm: 15.6,
          pixelSizeMicrons: 3.9,
        ),
      );
      notifier.setActivePositionAngle(-30);
      expect(notifier.state.active!.positionAngleDeg, closeTo(330, 1e-9));
      notifier.setActivePositionAngle(450);
      expect(notifier.state.active!.positionAngleDeg, closeTo(90, 1e-9));
    });

    test('setActiveCenter pins and clearActiveCenter un-pins', () {
      final notifier = FovPresetsNotifier();
      notifier.add(
        const FovPreset(
          id: 'a',
          name: 'A',
          focalLengthMm: 480,
          sensorWidthMm: 23.5,
          sensorHeightMm: 15.6,
          pixelSizeMicrons: 3.9,
        ),
      );
      expect(notifier.state.active!.center, isNull);
      notifier.setActiveCenter(const CelestialCoordinate(ra: 10, dec: 20));
      expect(notifier.state.active!.center!.ra, 10);
      notifier.clearActiveCenter();
      expect(notifier.state.active!.center, isNull);
    });

    test('hydrate replaces collection from JSON; blank is a no-op', () {
      final notifier = FovPresetsNotifier();
      notifier.add(
        const FovPreset(
          id: 'pre',
          name: 'pre',
          focalLengthMm: 480,
          sensorWidthMm: 23.5,
          sensorHeightMm: 15.6,
          pixelSizeMicrons: 3.9,
        ),
      );
      notifier.hydrate(''); // no-op keeps existing
      expect(notifier.state.presets.single.id, 'pre');

      const restored = FovPresetsState(
        presets: [
          FovPreset(
            id: 'h',
            name: 'hydrated',
            focalLengthMm: 384,
            sensorWidthMm: 28.3,
            sensorHeightMm: 18.9,
            pixelSizeMicrons: 3.76,
          ),
        ],
        activeId: 'h',
      );
      notifier.hydrate(restored.toJsonString());
      expect(notifier.state.presets.single.id, 'h');
      expect(notifier.state.activeId, 'h');
    });
  });
}

String _jsonOf(FovPreset p) {
  final m = p.toJson();
  final entries = m.entries
      .map((e) {
        final v = e.value;
        final encoded = v is String ? '"$v"' : (v is bool ? '$v' : '$v');
        return '"${e.key}":$encoded';
      })
      .join(',');
  return '{$entries}';
}
