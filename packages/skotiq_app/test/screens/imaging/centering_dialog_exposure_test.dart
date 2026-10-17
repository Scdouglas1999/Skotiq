// Focused truth tests for the CenteringDialog "Solve exposure" field.
//
// What these guard: parsing the field with `double.tryParse(text) ?? 5.0` and
// coercing any non-positive value to 5.0 turns a blank / malformed / zero /
// negative / out-of-range entry into a silent five-second camera exposure the
// user never asked for — and flipping `_isCentering` or probing the solver
// before validating the field commits to the run before it is legal. The
// contract:
//
//   * A bad entry does NO work — no solver detection, no centering service
//     call, no camera exposure, no misleading "running" state — surfaces an
//     inline error, and keeps the typed text editable.
//   * A valid entry is forwarded to CenteringService.centerOnTarget verbatim
//     (same seconds, same target), inside the canonical bounds the headless
//     centering endpoint (`POST /framing/center`) and CenteringService already
//     enforce.
//   * Solver-missing and hardware-failure paths leave the dialog truthful and
//     retryable (Start is offered again), preserving the existing banner/abort
//     behavior.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/centering_dialog.dart';
import 'package:skotiq_app/widgets/plate_solver_required_banner.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Records every call the dialog makes into the (spied) solver + centering
/// services. Created up front in each test so the counters can be asserted
/// even when a bad entry means the providers are never read at all.
class _Recorder {
  int ensureCalls = 0;
  int centerCalls = 0;
  CenteringConfig? lastConfig;
  double? lastTargetRa;
  double? lastTargetDec;
}

/// Spy plate-solve service: records `ensureSolverAvailable` and optionally
/// throws to exercise the missing-solver / detection-failure branches.
class _SpyPlateSolveService extends PlateSolveService {
  _SpyPlateSolveService(super.ref, this._recorder, {this.error});

  final _Recorder _recorder;
  final Object? error;

  @override
  Future<void> ensureSolverAvailable() async {
    _recorder.ensureCalls++;
    if (error != null) throw error!;
  }
}

/// Spy centering service: records the exact `centerOnTarget` arguments and
/// optionally throws to exercise the hardware-failure branch. Everything else
/// (the real settle-poll / plate-solve loop) is bypassed so the widget test
/// stays hermetic.
class _SpyCenteringService extends CenteringService {
  _SpyCenteringService(super.ref, this._recorder, {this.error, this.result});

  final _Recorder _recorder;
  final Object? error;
  final CenteringResult? result;

  @override
  Future<CenteringResult> centerOnTarget({
    required double targetRa,
    required double targetDec,
    required PlateSolverConfig solverConfig,
    CenteringConfig config = const CenteringConfig(),
    void Function(CenteringStatus)? onStatusUpdate,
  }) async {
    _recorder.centerCalls++;
    _recorder.lastConfig = config;
    _recorder.lastTargetRa = targetRa;
    _recorder.lastTargetDec = targetDec;
    if (error != null) throw error!;
    return result ??
        CenteringResult.success(
          finalOffsetArcsec: 3.0,
          iterations: 1,
          iterationHistory: const [],
        );
  }

  // Never reached by these tests, but overridden so an accidental stop() can't
  // fall through to the real provider reads.
  @override
  Future<void> stop() async {}
}

/// Fake app-settings notifier that returns defaults without touching the DB or
/// backend — the dialog only reads astapPath/timeout off it.
class _FakeAppSettingsNotifier extends AppSettingsNotifier {
  _FakeAppSettingsNotifier([this.settings = const AppSettingsState()]);

  final AppSettingsState settings;

  @override
  Future<AppSettingsState> build() async => settings;
}

void main() {
  Future<_Recorder> pumpDialog(
    WidgetTester tester, {
    EquipmentProfileModel? profile,
    Object? ensureError,
    Object? centerError,
    CenteringResult? centerResult,
    double? targetRa = 12.34,
    double? targetDec = -45.67,
    AppSettingsState settings = const AppSettingsState(),
  }) async {
    final recorder = _Recorder();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeEquipmentProfileProvider.overrideWithValue(profile),
          appSettingsProvider.overrideWith(
            () => _FakeAppSettingsNotifier(settings),
          ),
          plateSolveServiceProvider.overrideWith(
            (ref) => _SpyPlateSolveService(ref, recorder, error: ensureError),
          ),
          centeringServiceProvider.overrideWith(
            (ref) => _SpyCenteringService(
              ref,
              recorder,
              error: centerError,
              result: centerResult,
            ),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Scaffold(
            body: CenteringDialog(targetRa: targetRa, targetDec: targetDec),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return recorder;
  }

  Future<void> tapStart(WidgetTester tester) async {
    await tester.tap(find.text('Start centering'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  String fieldText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  void expectDidNoWork(WidgetTester tester, _Recorder recorder) {
    // No solver probe, no centering (hence no camera exposure).
    expect(recorder.ensureCalls, 0, reason: 'must not probe the solver');
    expect(recorder.centerCalls, 0, reason: 'must not start centering');
    // Not in a misleading "running" state: Start is still offered, Abort is not.
    expect(find.text('Start centering'), findsOneWidget);
    expect(find.text('Abort'), findsNothing);
  }

  group('invalid Solve exposure does no work', () {
    testWidgets('malformed text', (tester) async {
      final recorder = await pumpDialog(tester);
      await tester.enterText(find.byType(TextField), 'abc');
      await tapStart(tester);

      expectDidNoWork(tester, recorder);
      expect(find.text('Solve exposure must be a number in seconds.'),
          findsOneWidget);
      expect(fieldText(tester), 'abc', reason: 'typed text preserved');
    });

    testWidgets('zero', (tester) async {
      final recorder = await pumpDialog(tester);
      await tester.enterText(find.byType(TextField), '0');
      await tapStart(tester);

      expectDidNoWork(tester, recorder);
      expect(find.textContaining('between 0.01 and 600 s'), findsOneWidget);
      expect(fieldText(tester), '0');
    });

    testWidgets('negative', (tester) async {
      final recorder = await pumpDialog(tester);
      await tester.enterText(find.byType(TextField), '-5');
      await tapStart(tester);

      expectDidNoWork(tester, recorder);
      expect(find.textContaining('between 0.01 and 600 s'), findsOneWidget);
      expect(fieldText(tester), '-5');
    });

    testWidgets('NaN', (tester) async {
      // double.tryParse('NaN') yields NaN (finite==false), so this exercises
      // the non-finite guard rather than the unparseable guard.
      final recorder = await pumpDialog(tester);
      await tester.enterText(find.byType(TextField), 'NaN');
      await tapStart(tester);

      expectDidNoWork(tester, recorder);
      expect(find.text('Solve exposure must be a number in seconds.'),
          findsOneWidget);
      expect(fieldText(tester), 'NaN');
    });

    testWidgets('Infinity', (tester) async {
      // double.tryParse('Infinity') yields Infinity — also non-finite.
      final recorder = await pumpDialog(tester);
      await tester.enterText(find.byType(TextField), 'Infinity');
      await tapStart(tester);

      expectDidNoWork(tester, recorder);
      expect(find.text('Solve exposure must be a number in seconds.'),
          findsOneWidget);
      expect(fieldText(tester), 'Infinity');
    });

    testWidgets('above the 600s upper bound', (tester) async {
      final recorder = await pumpDialog(tester);
      await tester.enterText(find.byType(TextField), '601');
      await tapStart(tester);

      expectDidNoWork(tester, recorder);
      expect(find.textContaining('between 0.01 and 600 s'), findsOneWidget);
      expect(fieldText(tester), '601');
    });

    testWidgets('empty', (tester) async {
      final recorder = await pumpDialog(tester);
      await tester.enterText(find.byType(TextField), '');
      await tapStart(tester);

      expectDidNoWork(tester, recorder);
      expect(find.textContaining('Enter a solve exposure'), findsOneWidget);
    });

    testWidgets('a malformed persisted profile default is still validated',
        (tester) async {
      // The field is populated from the profile's persisted default, but a
      // bad persisted value (here 0.0) must NOT be trusted on Start — it is
      // revalidated like any typed entry.
      final recorder = await pumpDialog(
        tester,
        profile: const EquipmentProfileModel(
          name: 'Test',
          defaultCenteringExposure: 0.0,
        ),
      );
      expect(fieldText(tester), '0.0',
          reason: 'populated from profile default');

      await tapStart(tester);

      expectDidNoWork(tester, recorder);
      expect(find.textContaining('between 0.01 and 600 s'), findsOneWidget);
    });
  });

  testWidgets('valid exposure is forwarded to centering verbatim',
      (tester) async {
    final recorder = await pumpDialog(tester);
    await tester.enterText(find.byType(TextField), '2.5');
    await tester.tap(find.text('Start centering'));
    await tester.pumpAndSettle();

    expect(recorder.ensureCalls, 1);
    expect(recorder.centerCalls, 1);
    expect(recorder.lastConfig!.exposureTime, 2.5,
        reason: 'exact seconds forwarded, no default substitution');
    expect(recorder.lastTargetRa, 12.34);
    expect(recorder.lastTargetDec, -45.67);
    // No lingering validation error on the happy path.
    expect(
        find.text('Solve exposure must be a number in seconds.'), findsNothing);
  });

  // Shipping 6.0.0 hard-coded `syncMount: false` here, so the correction step
  // re-issued the slew that produced the mis-pointed frame and centering could
  // only ever end on "Maximum iterations". The dialog must carry the user's
  // configured preference, and the default must be the one that converges.
  testWidgets('centering syncs the mount by default', (tester) async {
    final recorder = await pumpDialog(tester);
    await tester.enterText(find.byType(TextField), '3');
    await tester.tap(find.text('Start centering'));
    await tester.pumpAndSettle();

    expect(recorder.centerCalls, 1);
    expect(recorder.lastConfig!.syncMount, isTrue);
  });

  testWidgets('centering honours the configured sync preference',
      (tester) async {
    final recorder = await pumpDialog(
      tester,
      settings: const AppSettingsState(centeringSyncMount: false),
    );
    await tester.enterText(find.byType(TextField), '3');
    await tester.tap(find.text('Start centering'));
    await tester.pumpAndSettle();

    expect(recorder.centerCalls, 1);
    expect(recorder.lastConfig!.syncMount, isFalse);
  });

  testWidgets('a missing solver shows the banner and stays retryable',
      (tester) async {
    final recorder = await pumpDialog(
      tester,
      ensureError: const SolverNotAvailableError('No plate solver configured'),
    );
    await tester.enterText(find.byType(TextField), '3');
    await tester.tap(find.text('Start centering'));
    await tester.pumpAndSettle();

    // Probed the solver, surfaced the banner, never started centering.
    expect(recorder.ensureCalls, 1);
    expect(recorder.centerCalls, 0);
    expect(find.byType(PlateSolverRequiredBanner), findsOneWidget);
    // Retryable: Start is offered again, Abort is gone.
    expect(find.text('Start centering'), findsOneWidget);
    expect(find.text('Abort'), findsNothing);
  });

  testWidgets('a hardware failure stays truthful and retryable',
      (tester) async {
    final recorder = await pumpDialog(
      tester,
      centerError: Exception('camera fault'),
    );
    await tester.enterText(find.byType(TextField), '3');
    await tester.tap(find.text('Start centering'));
    // Explicit pumps (not pumpAndSettle) so the error SnackBar's dismiss timer
    // can't stall settling; the result section renders on the setState above.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Centering was attempted (with the real value) and reported as failed.
    expect(recorder.centerCalls, 1);
    expect(recorder.lastConfig!.exposureTime, 3.0);
    expect(find.text('Centering Failed'), findsOneWidget);
    // Retryable: not stuck in the running state.
    expect(find.text('Start centering'), findsOneWidget);
    expect(find.text('Abort'), findsNothing);
  });
}
