import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/science/science_models.dart';

void main() {
  group('ScienceLayerType', () {
    test('round-trips db values', () {
      for (final layer in ScienceLayerType.values) {
        expect(ScienceLayerType.fromDbValue(layer.dbValue), equals(layer));
      }
    });
  });

  group('ScienceOverlayState', () {
    test('copyWith updates new visual toggles', () {
      const state = ScienceOverlayState();
      final updated = state.copyWith(
        showUniformityMap: true,
        showClipHighMap: true,
        showClipLowMap: true,
        showFwhmSurface: true,
      );

      expect(updated.showUniformityMap, isTrue);
      expect(updated.showClipHighMap, isTrue);
      expect(updated.showClipLowMap, isTrue);
      expect(updated.showFwhmSurface, isTrue);
    });
  });

  group('SciencePhotometrySelection', () {
    test('round-trips target and comparisons through JSON', () {
      const selection = SciencePhotometrySelection(
        differentialEnabled: true,
        target: PhotometryAnchor(
          objectId: 'target_1',
          label: 'Target A',
          raDegrees: 123.4,
          decDegrees: -22.5,
        ),
        comparisons: [
          PhotometryAnchor(
            objectId: 'comp_1',
            label: 'Comp 1',
            raDegrees: 124.1,
            decDegrees: -22.2,
          ),
          PhotometryAnchor(
            objectId: 'comp_2',
            label: 'Comp 2',
            raDegrees: 124.8,
            decDegrees: -21.9,
          ),
        ],
      );

      final decoded = SciencePhotometrySelection.fromJson(selection.toJson());

      expect(decoded.differentialEnabled, isTrue);
      expect(decoded.target, isNotNull);
      expect(decoded.target!.objectId, equals('target_1'));
      expect(decoded.comparisons, hasLength(2));
      expect(decoded.comparisons.first.objectId, equals('comp_1'));
    });

    test('supports clearing target via copyWith', () {
      const base = SciencePhotometrySelection(
        differentialEnabled: true,
        target: PhotometryAnchor(
          objectId: 'target_1',
          label: 'Target A',
          raDegrees: 10,
          decDegrees: 20,
        ),
      );

      final cleared = base.copyWith(clearTarget: true);

      expect(cleared.target, isNull);
      expect(cleared.differentialEnabled, isTrue);
    });

    test('ignores malformed comparison entries when decoding JSON', () {
      final decoded = SciencePhotometrySelection.fromJson({
        'differentialEnabled': true,
        'target': {
          'objectId': 'target_1',
          'label': 'Target A',
          'raDegrees': 10,
          'decDegrees': 20,
        },
        'comparisons': [
          {
            'objectId': 'comp_1',
            'label': 'Comp 1',
            'raDegrees': 11,
            'decDegrees': 21,
          },
          'bad entry',
          123,
        ],
      });

      expect(decoded.comparisons, hasLength(1));
      expect(decoded.comparisons.single.objectId, equals('comp_1'));
    });
  });
}
