// The autofocus settings a reader gets before the stored settings have
// loaded, and the estimator's own, are the settings table's defaults.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/settings.dart';

class _NeverLoaded extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() => Completer<AppSettingsState>().future;
}

Map<String, Object> _fields(AutofocusSettings s) => {
  'method': s.method,
  'curveFitting': s.curveFitting,
  'stepSize': s.stepSize,
  'exposureTime': s.exposureTime,
  'initialOffsetSteps': s.initialOffsetSteps,
  'numberOfAttempts': s.numberOfAttempts,
  'useBrightestNStars': s.useBrightestNStars,
  'outerCropRatio': s.outerCropRatio,
  'innerCropRatio': s.innerCropRatio,
  'binning': s.binning,
  'rSquaredThreshold': s.rSquaredThreshold,
  'failureHfrToleranceRatio': s.failureHfrToleranceRatio,
  'disableGuidingDuringAf': s.disableGuidingDuringAf,
  'focuserSettleTimeMs': s.focuserSettleTimeMs,
  'exposuresPerPoint': s.exposuresPerPoint,
  'backlashCompMethod': s.backlashCompMethod,
  'backlashIn': s.backlashIn,
  'backlashOut': s.backlashOut,
  'autofocusFilterName': s.autofocusFilterName,
  'filterSettings': s.filterSettings.length,
};

Map<String, Object> _table() {
  const t = AppSettingsState();
  return {
    'method': t.afMethod,
    'curveFitting': t.afCurveFitting,
    'stepSize': t.afStepSize,
    'exposureTime': t.afExposureTime,
    'initialOffsetSteps': t.afInitialOffsetSteps,
    'numberOfAttempts': t.afNumberOfAttempts,
    'useBrightestNStars': t.afUseBrightestNStars,
    'outerCropRatio': t.afOuterCropRatio,
    'innerCropRatio': t.afInnerCropRatio,
    'binning': t.afBinning,
    'rSquaredThreshold': t.afRSquaredThreshold,
    'failureHfrToleranceRatio': t.afFailureHfrToleranceRatio,
    'disableGuidingDuringAf': t.afDisableGuidingDuringAf,
    'focuserSettleTimeMs': t.afFocuserSettleTimeMs,
    'exposuresPerPoint': t.afExposuresPerPoint,
    'backlashCompMethod': t.afBacklashCompMethod,
    'backlashIn': t.afBacklashIn,
    'backlashOut': t.afBacklashOut,
    'autofocusFilterName': t.afAutofocusFilterName,
    'filterSettings': 0,
  };
}

void main() {
  test('before the settings load, autofocus reads the table defaults', () {
    final container = ProviderContainer(
      overrides: [appSettingsProvider.overrideWith(_NeverLoaded.new)],
    );
    addTearDown(container.dispose);
    expect(_fields(container.read(autofocusSettingsProvider)), _table());
  });

  test('the estimator\'s autofocus settings are the table defaults', () {
    expect(_fields(const SequenceTimeEstimator().autofocus), _table());
  });
}
