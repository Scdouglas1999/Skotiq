// The autofocus config the run is sent answers the shared cases in
// test_fixtures/autofocus_config/cases.json, which the engine's
// AutofocusConfig reads too (sequencer/src/autofocus_config_fixture_tests.rs).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';
import 'package:skotiq_core/src/models/sequence/autofocus_run.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/providers/focuser_backlash_provider.dart';
import 'package:skotiq_core/src/providers/sequence/sequence_executor/sequence_serializer.dart';
import 'package:skotiq_core/settings.dart' show AppSettingsState;

const _fixturePath = '../../test_fixtures/autofocus_config/cases.json';

AutofocusSettings _settings(Map<String, dynamic> json) {
  const base = AutofocusSettings();
  double? d(String key) => (json[key] as num?)?.toDouble();
  final filters = json['filterSettings'] as Map<String, dynamic>?;
  return base.copyWith(
    method: json['method'] as String?,
    curveFitting: json['curveFitting'] as String?,
    stepSize: json['stepSize'] as int?,
    exposureTime: d('exposureTime'),
    initialOffsetSteps: json['initialOffsetSteps'] as int?,
    numberOfAttempts: json['numberOfAttempts'] as int?,
    useBrightestNStars: json['useBrightestNStars'] as int?,
    outerCropRatio: d('outerCropRatio'),
    innerCropRatio: d('innerCropRatio'),
    binning: json['binning'] as int?,
    rSquaredThreshold: d('rSquaredThreshold'),
    failureHfrToleranceRatio: d('failureHfrToleranceRatio'),
    disableGuidingDuringAf: json['disableGuidingDuringAf'] as bool?,
    focuserSettleTimeMs: json['focuserSettleTimeMs'] as int?,
    exposuresPerPoint: json['exposuresPerPoint'] as int?,
    backlashCompMethod: json['backlashCompMethod'] as String?,
    backlashIn: json['backlashIn'] as int?,
    backlashOut: json['backlashOut'] as int?,
    autofocusFilterName: json['autofocusFilterName'] as String?,
    filterSettings: filters?.map(
      (name, value) => MapEntry(
        name,
        FilterAutofocusConfig.fromJson(value as Map<String, dynamic>),
      ),
    ),
  );
}

AutofocusRun _run(AutofocusSettings settings, Object? spec) {
  if (spec == 'settings') return AutofocusRun.fromSettings(settings);
  final node = spec as Map<String, dynamic>;
  return AutofocusRun.ofNode(
    settings,
    AutofocusNode(
      method: AutofocusMethod.values.byName(switch (node['method'] as String) {
        'hyperbolic' => 'hyperbolic',
        'quadratic' => 'quadratic',
        _ => 'vCurve',
      }),
      stepSize: node['stepSize'] as int,
      stepsOut: node['stepsOut'] as int,
      exposuresPerPoint: node['exposuresPerPoint'] as int,
      exposureDuration: (node['exposureDuration'] as num).toDouble(),
      useSettingsDefaults: node['useSettingsDefaults'] as bool,
      maxDurationSecs: (node['maxDurationSecs'] as num).toDouble(),
    ),
  );
}

Map<String, dynamic> configFor(Map<String, dynamic> testCase) {
  final serializer = Provider(
    (ref) => SequenceSerializer(ref: ref, warn: (_) {}),
  );
  final container = ProviderContainer(
    overrides: [
      measuredFocuserBacklashStepsProvider.overrideWithValue(
        testCase['measuredBacklashIn'] as int?,
      ),
    ],
  );
  try {
    final settings = _settings(testCase['settings'] as Map<String, dynamic>);
    return container
        .read(serializer)
        .autofocusRuntimeConfig(settings, _run(settings, testCase['run']));
  } finally {
    container.dispose();
  }
}

void main() {
  final cases = (jsonDecode(File(_fixturePath).readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();

  test('the fixture has cases', () => expect(cases, isNotEmpty));

  // A run sent before the settings load uses the model's defaults, so they
  // must be the ones a new install stores.
  test('the model defaults backlash as a new install stores it', () {
    const settings = AutofocusSettings();
    const stored = AppSettingsState();
    expect(settings.backlashIn, stored.afBacklashIn);
    expect(settings.backlashOut, stored.afBacklashOut);
  });

  for (final testCase in cases) {
    test('autofocus config: ${testCase['name']}', () {
      // Through JSON so ints and doubles compare the way the engine reads them.
      final sent = jsonDecode(jsonEncode(configFor(testCase)));
      expect(sent, testCase['config']);
    });
  }
}
