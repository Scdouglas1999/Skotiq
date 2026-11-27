// Words the native side writes and the app compares by value, held to the
// fixtures Rust tests write under test_fixtures/wire_words/.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/backend.dart' show kMeridianFlipInstruction;
import 'package:skotiq_core/models.dart';

Object? _fixture(String name) =>
    jsonDecode(File('../../test_fixtures/wire_words/$name').readAsStringSync());

void main() {
  test('the run ids the app matches are the native run\'s', () {
    expect(_fixture('run_ids.json'), {
      'meridianFlipInstruction': kMeridianFlipInstruction,
      'targetBelowFloorTrigger': kTargetBelowFloorTriggerId,
      'targetEndWhenTrigger': kTargetEndWhenTriggerId,
      'weatherUnsafeTrigger': kWeatherUnsafeTriggerId,
    });
  });

  test('every likely cause label is the sequencer\'s, in its order', () {
    final labels = (_fixture('likely_causes.json') as List).cast<String>();
    expect([for (final cause in LikelyCause.values) cause.label], labels);
    for (final cause in LikelyCause.values) {
      expect(LikelyCauseExt.fromLabel(cause.label), cause);
    }
  });

  test('every defect-map method word is the imaging crate\'s', () {
    final words = (_fixture('defect_map_methods.json') as List).cast<String>();
    expect([
      for (final method in DefectMapMethod.values) method.wireValue,
    ], words);
    for (final method in DefectMapMethod.values) {
      expect(DefectMapMethod.fromWire(method.wireValue), method);
    }
  });
}
