// "Apply palette" must never look like a dead control.
//
// The reproduced defect: pressing Apply five times produced nothing at all — no
// composite row, no FITS, no toast, no log. Three separate mechanisms conspired
// to make a running (or failing) combine indistinguishable from a no-op:
//
//   1. The button carried no in-flight state. `combiningNarrowband` was tracked
//      on the state but `SkotiqButton` was built without `isLoading`, so a
//      combine that takes tens of seconds renders exactly like an ignored press.
//   2. `runNarrowband` had no re-entrancy guard, so each extra press started
//      ANOTHER native combine to another stamped path — the presses raced
//      instead of being rejected.
//   3. `SessionReviewScreen` toasts an error string once and remembers it, and
//      `runNarrowband`'s pre-flight guard set the same message every time, so
//      only the FIRST failed press ever spoke. Presses 2..N were silent by
//      construction.
//
// (3) is asserted through the screen's own dedupe rule rather than by pumping
// the screen: the rule is "toast when the message differs from the last one
// shown", so a null in between is what makes a repeat audible.

import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/session_review/session_review_controller.dart';
import 'package:skotiq_app/screens/session_review/widgets/narrowband_mixer_panel.dart'
    as nb;
import 'package:skotiq_core/skotiq_core.dart';
// ignore: implementation_imports
import 'package:skotiq_core/src/services/post_session_seam.dart' as seam;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart';

/// A seam whose `combineChannels` blocks until the test releases it, so the
/// in-flight window can actually be observed.
class _BlockingCombineSeam implements PostSessionSeam {
  final gate = Completer<void>();
  int combineCalls = 0;

  @override
  Future<String> combineChannels(Map<String, dynamic> args) async {
    combineCalls++;
    await gate.future;
    return args['output'] as String;
  }

  @override
  Future<seam.IntegrateSessionResult> integrateSession(
          Map<String, dynamic> args) async =>
      throw UnimplementedError();

  @override
  Future<seam.MasterAccumulateResult> masterAccumulate(
          Map<String, dynamic> args) async =>
      throw UnimplementedError();

  @override
  Future<seam.BuildMasterFlatResult> buildMasterFlat(
          Map<String, dynamic> args) async =>
      throw UnimplementedError();

  @override
  Future<seam.SaveFitsMasterResult> saveFitsMaster(
          Map<String, dynamic> args) async =>
      throw UnimplementedError();

  @override
  Future<MosaicStitchResult> stitchMosaic(Map<String, dynamic> args) async =>
      throw UnimplementedError();

  @override
  Future<IntegrationCurve> analyzeNight({
    required List<Map<String, dynamic>> qualities,
    required List<double> weights,
    required List<double> exposuresS,
    double? aggressiveness,
    int? minKeep,
  }) async =>
      throw UnimplementedError();

  @override
  Future<StarPhotometryResult> detectStarsPhotometry({
    required String inputFits,
    int? maxStars,
    int? aperture,
  }) async =>
      throw UnimplementedError();

  @override
  Future<ColorCalibrationResult> colorCalibrate({
    required String inputFits,
    required String outputFits,
    required int channels,
    double? whiteRefBv,
    required List<Map<String, dynamic>> matchedStars,
  }) async =>
      throw UnimplementedError();

  @override
  Future<String> extractBackground(Map<String, dynamic> args) async =>
      throw UnimplementedError();

  @override
  Future<String> deconvolvePreview(Map<String, dynamic> args) async =>
      throw UnimplementedError();

  @override
  Future<String> reduceStarsPreview(Map<String, dynamic> args) async =>
      throw UnimplementedError();

  @override
  Future<Map<String, dynamic>> drizzleIntegrate(
          Map<String, dynamic> args) async =>
      throw UnimplementedError();

  @override
  Stream<({String phase, double fraction})> integrationProgress() =>
      const Stream.empty();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the mixer panel', () {
    Future<List<(String, List<List<double>>)>> pumpAndTapApply(
      WidgetTester tester, {
      required bool busy,
    }) async {
      final calls = <(String, List<List<double>>)>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: nb.NarrowbandMixerPanel(
                busy: busy,
                channels: const [
                  nb.NarrowbandChannelRef(
                      masterId: 1, filter: 'Ha', label: 'Ha'),
                  nb.NarrowbandChannelRef(
                      masterId: 2, filter: 'OIII', label: 'OIII'),
                  nb.NarrowbandChannelRef(
                      masterId: 3, filter: 'SII', label: 'SII'),
                ],
                onApply: (palette, weights) => calls.add((palette, weights)),
              ),
            ),
          ),
        ),
      );
      // pump(), never pumpAndSettle(): the in-flight spinner animates forever,
      // so settling would time out precisely in the state under test.
      await tester.pump();
      await tester.ensureVisible(find.byType(SkotiqButton));
      await tester.pump();
      await tester.tap(find.byType(SkotiqButton), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 300));
      return calls;
    }

    testWidgets('hands back the SHO matrix when idle', (tester) async {
      final calls = await pumpAndTapApply(tester, busy: false);
      expect(calls, hasLength(1));
      expect(calls.single.$1, 'SHO');
      // SHO → R=SII, G=Ha, B=OIII, in channel order Ha / OIII / SII.
      expect(calls.single.$2, [
        [0.0, 1.0, 0.0],
        [0.0, 0.0, 1.0],
        [1.0, 0.0, 0.0],
      ]);
    });

    testWidgets('shows it is working and refuses a second press', (
      tester,
    ) async {
      final calls = await pumpAndTapApply(tester, busy: true);
      expect(
        calls,
        isEmpty,
        reason: 'A press while a combine is running must not start another.',
      );
      expect(
        find.text('Combining…'),
        findsOneWidget,
        reason:
            'Without an in-flight label the control looks identical before, '
            'during and after a press — which is what made a running combine '
            'indistinguishable from a dead button.',
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });

  group('runNarrowband', () {
    late SkotiqDatabase db;
    late ProviderContainer container;
    late int sessionId;
    late int targetId;
    late _BlockingCombineSeam blockingSeam;

    setUp(() async {
      db = mockDatabase();
      blockingSeam = _BlockingCombineSeam();
      container = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(db),
        postSessionSeamProvider.overrideWithValue(blockingSeam),
      ]);

      final sessions = container.read(sessionsDaoProvider);
      final images = container.read(imagesDaoProvider);
      final targets = container.read(targetsDaoProvider);
      final masters = container.read(integratedMastersDaoProvider);

      targetId = await targets.createTarget(
        TargetsCompanion.insert(name: 'NGC 7000', ra: 20.97, dec: 44.5),
      );
      sessionId = await sessions.createSession(
        ImagingSessionsCompanion.insert(startTime: DateTime.now()),
      );

      for (final filter in ['Ha', 'OIII']) {
        await images.createImage(
          CapturedImagesCompanion.insert(
            filePath: 'C:/subs/$filter.fits',
            fileName: '$filter.fits',
            sessionId: Value(sessionId),
            targetId: Value(targetId),
            exposureDuration: 300,
            frameType: const Value('light'),
            filter: Value(filter),
            isAccepted: const Value(true),
            capturedAt: DateTime.now(),
          ),
        );
        await masters.insertMaster(
          targetId: targetId,
          name: 'NGC 7000 · $filter',
          masterFitsPath: 'C:/masters/ngc7000_$filter.fits',
          status: IntegratedMasterStatus.finalized,
          accumulationMode: AccumulationMode.batch,
          channels: 1,
          width: 100,
          height: 80,
          filter: filter,
        );
      }
    });

    tearDown(() async {
      if (!blockingSeam.gate.isCompleted) blockingSeam.gate.complete();
      container.dispose();
      await db.close();
    });

    SessionReviewController controller() => container.read(
          sessionReviewControllerProvider(SessionReviewScope.session(sessionId))
              .notifier,
        );

    SessionReviewState state() => container.read(
          sessionReviewControllerProvider(
              SessionReviewScope.session(sessionId)),
        );

    Future<void> waitUntilLoaded() async {
      for (var i = 0; i < 50 && state().loading; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    test('a second press while combining does not start a second combine',
        () async {
      final c = controller();
      await waitUntilLoaded();

      final first = c.runNarrowband('hoo', const []);
      // Let the first call reach the (blocked) seam.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(state().combiningNarrowband, isTrue);
      expect(blockingSeam.combineCalls, 1);

      final second = await c.runNarrowband('hoo', const []);
      expect(
        second,
        isNull,
        reason: 'The re-entrant press must be rejected, not queued.',
      );
      expect(
        blockingSeam.combineCalls,
        1,
        reason:
            'A second native combine would write a second stamped FITS and the '
            'two runs would race to set narrowbandComposite.',
      );

      blockingSeam.gate.complete();
      expect(await first, isNotNull);
      expect(state().combiningNarrowband, isFalse);
    });

    test('a repeated pre-flight failure is re-announced, not swallowed',
        () async {
      final c = controller();
      await waitUntilLoaded();

      const onlyOne = <NarrowbandChannelRef>[
        NarrowbandChannelRef(
          masterId: 1,
          label: 'Ha',
          fitsPath: 'C:/masters/only_ha.fits',
        ),
      ];

      // Replay SessionReviewScreen's real dedupe over the ACTUAL sequence of
      // states the screen would rebuild on, rather than simulating it: the
      // whole point is whether a cleared state ever appears between two
      // identical failures.
      final seen = <String?>[state().error];
      final sub = container.listen<SessionReviewState>(
        sessionReviewControllerProvider(SessionReviewScope.session(sessionId)),
        (_, next) => seen.add(next.error),
        fireImmediately: false,
      );
      addTearDown(sub.close);

      for (var press = 0; press < 5; press++) {
        expect(
          await c.runNarrowband('sho', const [], channels: onlyOne),
          isNull,
        );
      }

      String? lastShown;
      var toasts = 0;
      for (final error in seen) {
        if (error == null) {
          lastShown = null;
        } else if (error != lastShown) {
          lastShown = error;
          toasts++;
        }
      }

      expect(
        toasts,
        5,
        reason:
            'Five presses against an unchanged precondition must speak five '
            'times. Going quiet after the first is exactly the reported '
            '"pressed it five times and nothing happened". Observed error '
            'sequence: $seen',
      );
      expect(state().error, contains('at least two finalized'));
      expect(
        state().error,
        contains('with a finished FITS on disk'),
        reason: 'The message has to say what is actually missing, or the user '
            'cannot tell a mis-click from an unmet precondition.',
      );
    });
  });
}
