// What the forecast says, in each state it can be said in.
//
// The forecast is a projection of a noise model, so every phrasing that quotes
// a number also has to carry the assumption it rests on and must never imply a
// date. These tests hold the copy to that.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/depthlock/depthlock_presentation.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'depthlock_test_doubles.dart';

DepthLockGoal _goal({
  required DepthLockState state,
  DepthLockForecast? forecast,
  int evidenceFrames = 48,
  double exposureSecs = 300,
  double threshold = 5,
  double scaleArcsec = 10,
}) {
  final definition = depthLockDefinitionFixture(
    threshold: threshold,
    scaleArcsec: scaleArcsec,
  );
  return depthLockGoalFixture(
    definition: DepthLockGoalDefinition(
      label: definition.label,
      projectId: definition.projectId,
      targetId: definition.targetId,
      profileId: definition.profileId,
      filterName: definition.filterName,
      filterIndex: definition.filterIndex,
      referencePath: definition.referencePath,
      reference: definition.reference,
      acquisition: AcquisitionSettings(
        instrument: definition.acquisition.instrument,
        filter: definition.acquisition.filter,
        exposureSecs: exposureSecs,
        binX: definition.acquisition.binX,
        binY: definition.acquisition.binY,
        gain: definition.acquisition.gain,
        offset: definition.acquisition.offset,
        ccdTempC: definition.acquisition.ccdTempC,
      ),
      temperatureToleranceC: definition.temperatureToleranceC,
      darkPath: definition.darkPath,
      flatPath: definition.flatPath,
      measurement: definition.measurement,
      enabled: definition.enabled,
      automaticCompletion: definition.automaticCompletion,
    ),
    report: depthLockReportFixture(
      state: state,
      evidenceFrames: evidenceFrames,
      forecast: forecast,
    ),
  );
}

void main() {
  group('duration', () {
    test('reads in the unit the quantity deserves', () {
      expect(depthLockDuration(2.4), '2.4 h');
      expect(depthLockDuration(0.5), '30 min');
      expect(depthLockDuration(0), '0 min');
    });

    test('hours come from frames and the goal\'s own exposure', () {
      expect(depthLockHours(frames: 18, exposureSecs: 300), closeTo(1.5, 1e-9));
      expect(depthLockHours(frames: 0, exposureSecs: 300), 0);
    });
  });

  group('forecast line', () {
    test('while measuring it quotes time, exposures and the assumption', () {
      final line = depthLockForecastLine(
        _goal(
          state: DepthLockState.collecting,
          // 18 × 480 s = 2.4 h.
          exposureSecs: 480,
          forecast: depthLockForecastFixture(
            framesToThreshold: 18,
            framesToConfirm: 16,
          ),
        ),
      );

      expect(
        line,
        'About 2.4 h more (18 exposures) at the recent sky, then 16 to '
        'confirm.',
      );
    });

    test('while confirming it counts only the confirmation window', () {
      final line = depthLockForecastLine(
        _goal(
          state: DepthLockState.confirmationPending,
          forecast: depthLockForecastFixture(
            framesToThreshold: 0,
            framesToConfirm: 7,
          ),
        ),
      );

      expect(line, 'Confirming — 7 more exposures.');
    });

    test('an unreachable goal names the cap and the two remedies', () {
      final line = depthLockForecastLine(
        _goal(
          state: DepthLockState.collecting,
          threshold: 5,
          scaleArcsec: 10,
          forecast: depthLockForecastFixture(
            reachable: false,
            ceilingScore: 4.1,
          ),
        ),
      );

      expect(
        line,
        'Cannot reach 5.0 at 10″ — the calibration floor caps it at 4.1. '
        'Larger squares or better flats would help.',
      );
      // More hours is exactly what will NOT help, so it must not be offered.
      expect(line, isNot(contains('more exposures')));
      expect(line, isNot(contains('recent sky')));
    });

    test('before the minimum it counts exposures, not time', () {
      final line = depthLockForecastLine(
        _goal(
          state: DepthLockState.insufficientEvidence,
          evidenceFrames: 11,
        ),
      );

      expect(line, '21 more exposures before measuring starts.');
    });

    test('an achieved goal has nothing left to forecast', () {
      expect(
        depthLockForecastLine(
          _goal(
            state: DepthLockState.achieved,
            forecast: depthLockForecastFixture(
              framesToThreshold: 0,
              framesToConfirm: 0,
            ),
          ),
        ),
        isNull,
      );
    });

    test('no forecast, no line — never an invented one', () {
      expect(
        depthLockForecastLine(_goal(state: DepthLockState.collecting)),
        isNull,
      );
    });

    test('never a clock time or a date', () {
      for (final state in DepthLockState.values) {
        final line = depthLockForecastLine(
          _goal(state: state, forecast: depthLockForecastFixture()),
        );
        if (line == null) continue;
        expect(line, isNot(matches(RegExp(r'\d{1,2}:\d{2}'))));
        expect(line.toLowerCase(), isNot(contains('tonight at')));
        expect(line.toLowerCase(), isNot(contains('by ')));
      }
    });
  });

  group('yield line', () {
    test('a noisy night is worth saying', () {
      final line = depthLockYieldLine(
        _goal(
          state: DepthLockState.collecting,
          forecast: depthLockForecastFixture(
            // best/recent = 0.775 → 0.6 of the variance.
            bestFrameNoiseAdu: 1.55,
            recentFrameNoiseAdu: 2.0,
          ),
        ),
      );

      expect(
        line,
        'Tonight\'s exposures are worth about 0.6× your best — sky is noisier '
        '(moon, haze).',
      );
    });

    test('a night as good as the best has nothing to say', () {
      expect(
        depthLockYieldLine(
          _goal(
            state: DepthLockState.collecting,
            forecast: depthLockForecastFixture(
              bestFrameNoiseAdu: 2.0,
              recentFrameNoiseAdu: 2.0,
            ),
          ),
        ),
        isNull,
      );
    });

    test('the line appears exactly below the notice threshold', () {
      // 0.9 yield — above the threshold, so silent.
      final quiet = depthLockYieldLine(
        _goal(
          state: DepthLockState.collecting,
          forecast: depthLockForecastFixture(
            bestFrameNoiseAdu: 0.9487,
            recentFrameNoiseAdu: 1.0,
          ),
        ),
      );
      expect(quiet, isNull);

      // 0.64 yield — below it, so spoken.
      final noisy = depthLockYieldLine(
        _goal(
          state: DepthLockState.collecting,
          forecast: depthLockForecastFixture(
            bestFrameNoiseAdu: 0.8,
            recentFrameNoiseAdu: 1.0,
          ),
        ),
      );
      expect(noisy, contains('0.6×'));
    });
  });

  group('allocation summary', () {
    test('says what each filter still owes', () {
      final summary = depthLockAllocationSummary(<DepthLockGoal>[
        depthLockGoalFixture(
          id: 'ha',
          definition: depthLockDefinitionFixture(filterName: 'Ha'),
          report: depthLockReportFixture(
            state: DepthLockState.achieved,
            forecast: depthLockForecastFixture(
              framesToThreshold: 0,
              framesToConfirm: 0,
            ),
          ),
        ),
        depthLockGoalFixture(
          id: 'oiii',
          definition: depthLockDefinitionFixture(filterName: 'OIII'),
          report: depthLockReportFixture(
            // 34 frames × 360 s = 3.4 h.
            forecast: depthLockForecastFixture(
              framesToThreshold: 18,
              framesToConfirm: 16,
            ),
          ),
        ),
      ]);

      expect(summary, 'Ha · done · OIII · 2.8 h');
    });

    test('a capped filter says so instead of quoting hours', () {
      final summary = depthLockAllocationSummary(<DepthLockGoal>[
        depthLockGoalFixture(
          definition: depthLockDefinitionFixture(filterName: 'SII'),
          report: depthLockReportFixture(
            forecast: depthLockForecastFixture(reachable: false),
          ),
        ),
      ]);

      expect(summary, 'SII · floor limit');
    });

    test('no forecasts, no header line', () {
      expect(
        depthLockAllocationSummary(<DepthLockGoal>[
          depthLockGoalFixture(report: depthLockReportFixture()),
        ]),
        isNull,
      );
      expect(depthLockAllocationSummary(const <DepthLockGoal>[]), isNull);
    });
  });
}
