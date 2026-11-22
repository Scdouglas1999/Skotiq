// The Live Darkroom recipe against the engine's operation catalogue
// (test_fixtures/darkroom_ops/catalog.json, held to the engine by
// processing/src/darkroom/catalog_fixture_tests.rs): every op and parameter
// it sends exists at that version, and each value it clamps is clamped to the
// catalogue's bounds.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/live_stack/live_stack_darkroom_provider.dart';
import 'package:skotiq_core/models.dart' show recipeSchemaVersion;

const _everyStep = LiveDarkroomRecipeSettings(
  backgroundExtractEnabled: true,
  denoiseEnabled: true,
  colorBalanceEnabled: true,
  stretchEnabled: true,
  saturationEnabled: true,
  starReduceEnabled: true,
);

LiveDarkroomRecipeSettings _everyValue(double value) => _everyStep.copyWith(
      bgModelOrder: value.isNegative ? -1000000 : 1000000,
      bgSampleSpacing: value,
      bgExclusionPercentile: value,
      denoiseStrength: value,
      denoiseThresholdSigma: value,
      denoiseChromaStrength: value,
      colorRedScale: value,
      colorGreenScale: value,
      colorBlueScale: value,
      stretchD: value,
      stretchB: value,
      stretchSymmetryPoint: value,
      saturationAmount: value,
      saturationProtection: value,
      starReduceAmount: value,
      starReduceThresholdSigma: value,
    );

/// Parameters the recipe sends as given or as a fixed value, not clamped.
const _unclamped = {
  'denoise.scaleCount',
  'stretch.blackPoint',
  'stretch.whitePoint',
  'star_reduce.maskDilatePx',
};

void main() {
  final catalog = jsonDecode(
    File(
      '../../test_fixtures/darkroom_ops/catalog.json',
    ).readAsStringSync(),
  ) as Map<String, dynamic>;
  final ops = {
    for (final op in (catalog['ops'] as List).cast<Map<String, dynamic>>())
      op['id'] as String: op,
  };

  Map<String, dynamic> paramDoc(String opId, String name) =>
      (ops[opId]!['params'] as List).cast<Map<String, dynamic>>().firstWhere(
            (p) => p['name'] == name,
          );

  List<Map<String, dynamic>> steps(LiveDarkroomRecipeSettings settings) =>
      settings.toRecipeSteps(isColor: true);

  test('every op and parameter exists in the catalogue at its version', () {
    for (final step in steps(_everyStep)) {
      final opId = step['opId'] as String;
      expect(ops, contains(opId));
      expect(step['opVersion'], ops[opId]!['version'], reason: opId);
      final names = {
        for (final p in (ops[opId]!['params'] as List)) p['name'] as String,
      };
      for (final name in (step['params'] as Map<String, dynamic>).keys) {
        expect(names, contains(name), reason: '$opId.$name');
      }
    }
  });

  test('the envelope carries the engine schema version', () {
    final envelope =
        jsonDecode(_everyStep.toRecipeJson(filterKey: 'L', isColor: true))
            as Map<String, dynamic>;
    expect(envelope['schemaVersion'], recipeSchemaVersion);
  });

  test('every op comes in the stage order the engine renders', () {
    final stages = [
      for (final step in steps(_everyStep)) ops[step['opId']]!['stage'],
    ];
    expect(stages, [...stages]..sort());
    expect(stages.first, 'linear');
  });

  for (final (bound, value) in [('max', 1e9), ('min', -1e9)]) {
    test('each clamped parameter stops at the catalogue $bound', () {
      final drift = <String>{};
      for (final step in steps(_everyValue(value))) {
        final opId = step['opId'] as String;
        for (final MapEntry(key: name, value: sent)
            in (step['params'] as Map<String, dynamic>).entries) {
          if (_unclamped.contains('$opId.$name')) continue;
          final limit = paramDoc(opId, name)[bound] as num;
          final values = sent is List ? sent.cast<num>() : [sent as num];
          for (final v in values) {
            if (v != limit) drift.add('$opId.$name.$bound');
          }
        }
      }
      expect(drift, isEmpty);
    });
  }
}
