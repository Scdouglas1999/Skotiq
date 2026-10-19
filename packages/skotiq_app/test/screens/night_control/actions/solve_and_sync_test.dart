import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/models/command_action_result.dart';
import 'package:skotiq_app/screens/night_control/actions/night_rig_ops.dart';
import 'package:skotiq_app/screens/night_control/actions/solve_and_sync.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../harness/mock_backend.dart';
import '../../../harness/pump_app_screen.dart' show TestBackendNotifier;
import 'night_action_test_support.dart';

PlateSolveResult _solve(
    {required bool success, double ra = 0, double dec = 0}) {
  final empty = Float64List(0);
  return PlateSolveResult(
    success: success,
    ra: ra,
    dec: dec,
    pixelScale: 1.2,
    rotation: 0,
    fieldWidth: 1,
    fieldHeight: 1,
    solveTimeSecs: 3,
    error: success ? null : 'No match',
    cd11: 0,
    cd12: 0,
    cd21: 0,
    cd22: 0,
    sipAOrder: 0,
    sipBOrder: 0,
    sipACoeffs: empty,
    sipBCoeffs: empty,
    sipApOrder: 0,
    sipBpOrder: 0,
    sipApCoeffs: empty,
    sipBpCoeffs: empty,
  );
}

class _FixedStopwatch extends Stopwatch {
  @override
  Duration get elapsed => const Duration(milliseconds: 3300);
}

class _MockPhd2 extends Mock implements Phd2Controller {}

class _StaticAppSettings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState();
}

void main() {
  group('SolveAndSync', () {
    test('solves the last frame, syncs in hours and records the duration',
        () async {
      final calls = <String>[];
      final result = await SolveAndSync(
        captureSolveFrame: () async {
          calls.add('capture');
          return 'new.fits';
        },
        solve: (path) async {
          calls.add('solve $path');
          return _solve(success: true, ra: 24.15, dec: 15.78);
        },
        sync: (ra, dec) async {
          calls.add('sync ${ra.toStringAsFixed(2)} $dec');
          return CommandActionResult.ok;
        },
        stopwatch: _FixedStopwatch.new,
      ).run(lastFramePath: 'last.fits');

      expect(calls, ['solve last.fits', 'sync 1.61 15.78']);
      expect(result.succeeded, isTrue);
      expect(result.usedLastFrame, isTrue);
      expect(result.solveDuration, const Duration(milliseconds: 3300));
    });

    test(
        'takes a new frame when the last is not at the pointing, and does '
        'not sync a failed solve', () async {
      final calls = <String>[];
      final result = await SolveAndSync(
        captureSolveFrame: () async {
          calls.add('capture');
          return 'new.fits';
        },
        solve: (path) async {
          calls.add('solve $path');
          return _solve(success: false);
        },
        sync: (ra, dec) async {
          calls.add('sync');
          return CommandActionResult.ok;
        },
      ).run();

      expect(calls, ['capture', 'solve new.fits']);
      expect(result.synced, isFalse);
      expect(result.error, 'No match');
      expect(result.solveDuration, isNotNull);
    });
  });

  group('frameAtCurrentPointing', () {
    final frame = CapturedImageData(
      width: 1,
      height: 1,
      displayData: Uint8List(4),
      histogram: const [],
      stats: const ImageStats(min: 0, max: 0, mean: 0, median: 0, stdDev: 0),
      capturedAt: DateTime.utc(2026, 10, 19, 22),
      settings: const ExposureSettings(
        exposureTime: 5,
        gain: 100,
        offset: 50,
        binningX: 1,
        binningY: 1,
        frameType: FrameType.light,
      ),
      filePath: '/frames/last.fits',
    );
    final pointing = FramePointing(
      capturedAt: frame.capturedAt,
      raHours: 1.5,
      decDegrees: 30,
    );
    const mount = MountState(
      connectionState: connected,
      isTracking: true,
      isParked: false,
      ra: 1.5,
      dec: 30,
    );

    test('the frame counts when the mount has not moved', () {
      expect(
        frameAtCurrentPointing(frame: frame, pointing: pointing, mount: mount),
        '/frames/last.fits',
      );
    });

    test('a slew since the frame means a fresh one', () {
      expect(
        frameAtCurrentPointing(
          frame: frame,
          pointing: pointing,
          mount: mount.copyWith(ra: 1.6),
        ),
        isNull,
      );
      expect(
        frameAtCurrentPointing(frame: frame, pointing: null, mount: mount),
        isNull,
      );
      expect(
        frameAtCurrentPointing(
          frame: frame,
          pointing: pointing,
          mount: mount.copyWith(isTracking: false),
        ),
        isNull,
      );
    });
  });

  test('guiding restart waits for SettleDone', () async {
    final backend = mockBackend();
    final phd2 = _MockPhd2();
    final container = ProviderContainer(overrides: [
      backendProvider.overrideWith((ref) => TestBackendNotifier(ref, backend)),
      phd2ControllerProvider.overrideWithValue(phd2),
      appSettingsProvider.overrideWith(_StaticAppSettings.new),
    ]);
    addTearDown(container.dispose);
    when(() => phd2.startGuiding(
          settlePixels: any(named: 'settlePixels'),
          settleTime: any(named: 'settleTime'),
          settleTimeout: any(named: 'settleTimeout'),
        )).thenAnswer((_) async {});

    var settled = false;
    final done = container
        .read(nightRigOpsProvider)
        .startGuidingAndSettle()
        .then((_) => settled = true);
    await settle();
    expect(settled, isFalse);

    backend.emitEvent(const SkotiqEvent(
      timestamp: 0,
      severity: EventSeverity.info,
      category: EventCategory.guiding,
      eventType: 'SettleDone',
      data: {'rms': 0.4},
    ));
    await done;
    expect(settled, isTrue);
  });

  test('guiding restart fails when the star is lost while settling', () async {
    final backend = mockBackend();
    final phd2 = _MockPhd2();
    final container = ProviderContainer(overrides: [
      backendProvider.overrideWith((ref) => TestBackendNotifier(ref, backend)),
      phd2ControllerProvider.overrideWithValue(phd2),
      appSettingsProvider.overrideWith(_StaticAppSettings.new),
    ]);
    addTearDown(container.dispose);
    when(() => phd2.startGuiding(
          settlePixels: any(named: 'settlePixels'),
          settleTime: any(named: 'settleTime'),
          settleTimeout: any(named: 'settleTimeout'),
        )).thenAnswer((_) async {});

    final done = container.read(nightRigOpsProvider).startGuidingAndSettle();
    final expectation = expectLater(done, throwsStateError);
    await settle();
    backend.emitEvent(const SkotiqEvent(
      timestamp: 0,
      severity: EventSeverity.warning,
      category: EventCategory.guiding,
      eventType: 'StarLost',
      data: {},
    ));
    await expectation;
  });
}
