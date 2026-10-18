// Every surface of the backlash wizard, asserted against the owner's real
// hardware numbers.
//
// The three outcomes are the point: a figure is never shown bare, "no
// measurable backlash" reads as a success, and a refusal is a dignified
// first-class outcome carrying native's own words.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/focuser_backlash/focuser_backlash_calibration_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';
import 'backlash_fixtures.dart';

/// Pins an arbitrary [FocuserBacklashCalibrationState] without running the
/// real two-scan routine, and records what the dialog asked for.
///
/// The base constructor only subscribes to the backend event stream (which the
/// harness stubs), so it is a cheap, faithful stand-in.
class _FakeNotifier extends FocuserBacklashCalibrationNotifier {
  _FakeNotifier(super.ref, FocuserBacklashCalibrationState initial) {
    // ignore: invalid_use_of_protected_member
    state = initial;
  }

  int runCalls = 0;
  int cancelCalls = 0;
  int saveCalls = 0;
  int discardCalls = 0;
  int planCalls = 0;

  @override
  Future<void> loadPlan({int? centerPosition}) async => planCalls++;

  @override
  Future<void> run({int? centerPosition}) async => runCalls++;

  /// What the notifier leaves behind after a cancel. Set by the cancellation
  /// tests to the state the core agent produces for an operator-requested
  /// stop: back to idle, plan kept, no error, and a line saying the focuser
  /// has been returned.
  FocuserBacklashCalibrationState? afterCancel;

  @override
  Future<void> cancel() async {
    cancelCalls++;
    final next = afterCancel;
    if (next != null) {
      // ignore: invalid_use_of_protected_member
      state = next;
    }
  }

  @override
  Future<void> save() async => saveCalls++;

  @override
  void discard() => discardCalls++;

  @override
  void reset() {}
}

Future<(_FakeNotifier, HarnessHandle)> _openHarness(
  WidgetTester tester,
  FocuserBacklashCalibrationState state, {
  bool settle = true,
}) async {
  late _FakeNotifier notifier;
  final handle = await pumpAppScreen(
    tester,
    Builder(
      builder: (context) => Center(
        child: ElevatedButton(
          onPressed: () => FocuserBacklashCalibrationDialog.show(context),
          child: const Text('OPEN'),
        ),
      ),
    ),
    size: const Size(900, 1100),
    settle: settle,
    extraOverrides: [
      focuserBacklashCalibrationProvider.overrideWith((ref) {
        notifier = _FakeNotifier(ref, state);
        return notifier;
      }),
    ],
  );
  await tester.tap(find.text('OPEN'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    // The scanning phases carry a perpetual attention pulse that never
    // settles; two frames lay the dialog out.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }
  return (notifier, handle);
}

Future<_FakeNotifier> _open(
  WidgetTester tester,
  FocuserBacklashCalibrationState state, {
  bool settle = true,
}) async =>
    (await _openHarness(tester, state, settle: settle)).$1;

void main() {
  group('intro', () {
    testWidgets('states the estimate, the travel and the exposure count', (
      tester,
    ) async {
      await _open(
        tester,
        const FocuserBacklashCalibrationState(plan: plan9Points),
      );

      expect(find.textContaining('about 4 minutes 30s'), findsOneWidget);
      expect(find.textContaining('An estimate'), findsOneWidget);
      // The travel the focuser will actually be commanded over, not just the
      // sampled range.
      expect(find.textContaining('6090 to 7150'), findsOneWidget);
      expect(find.textContaining('18'), findsWidgets);
      expect(
          find.textContaining('returned to where it started'), findsOneWidget);
      expect(find.textContaining('Stars in the frame'), findsOneWidget);
      // The one thing the operator must take away about any backlash figure.
      expect(find.textContaining('varies along the travel'), findsOneWidget);
    });

    testWidgets('is declinable and starts on the primary action', (
      tester,
    ) async {
      final notifier = await _open(
        tester,
        const FocuserBacklashCalibrationState(plan: plan9Points),
      );

      expect(find.widgetWithText(SkotiqButton, 'Not now'), findsOneWidget);
      // Dismissal is open before a run starts; only the scan blocks it.
      final dialog = tester.widget<SkotiqDialog>(
        find.byType(SkotiqDialog),
      );
      expect(dialog.closeEnabled, isTrue);
      final guard = tester.widget<PopScope<dynamic>>(
        findByDataKey(FocuserBacklashCalibrationDialog.popGuardKey),
      );
      expect(guard.canPop, isTrue);

      await tester.tap(
        find.widgetWithText(SkotiqButton, 'Measure backlash'),
      );
      await tester.pump();
      expect(notifier.runCalls, 1);
    });

    testWidgets('will not start before the plan is known', (tester) async {
      // The plan-loading well carries an indeterminate bar that never settles.
      await _open(
        tester,
        const FocuserBacklashCalibrationState(),
        settle: false,
      );

      expect(
        find.textContaining('Reading the focuser position and travel limits'),
        findsOneWidget,
      );
      final button = tester.widget<SkotiqButton>(
        find.widgetWithText(SkotiqButton, 'Measure backlash'),
      );
      expect(button.onPressed, isNull);
    });
  });

  group('progress', () {
    testWidgets('names the scan in flight and counts the points', (
      tester,
    ) async {
      await _open(
        tester,
        const FocuserBacklashCalibrationState(
          phase: FocuserBacklashPhase.scanningFromBelow,
          progress: 22,
          status: 'Scanning up from below: point 4 of 9',
          currentPoint: 4,
          totalPoints: 9,
          belowPoints: belowPoints6620,
          scanRange: FocusRange(min: 6340, max: 6900),
        ),
        settle: false,
      );

      expect(find.text('Scanning from below'), findsWidgets);
      expect(find.text('Point 4 of 9'), findsOneWidget);
      expect(find.text('Scanning up from below: point 4 of 9'), findsOneWidget);
      // Both legs are listed so the operator knows a second scan is coming.
      expect(find.text('Scanning from above'), findsOneWidget);
      expect(find.text('Fitting both curves'), findsOneWidget);
      expect(find.byType(VCurveChart), findsOneWidget);
    });

    testWidgets('draws both curves once the second scan is under way', (
      tester,
    ) async {
      await _open(
        tester,
        const FocuserBacklashCalibrationState(
          phase: FocuserBacklashPhase.scanningFromAbove,
          progress: 70,
          status: 'Scanning down from above: point 3 of 9',
          currentPoint: 3,
          totalPoints: 9,
          belowPoints: belowPoints6620,
          abovePoints: abovePoints6515,
          scanRange: FocusRange(min: 6340, max: 6900),
        ),
        settle: false,
      );

      final chart = tester.widget<VCurveChart>(find.byType(VCurveChart));
      expect(chart.series, hasLength(2));
      expect(chart.series[0].points, belowPoints6620);
      expect(chart.series[1].points, abovePoints6515);
      // The live scan is the one whose newest point is ringed.
      expect(chart.series[1].highlightLatest, isTrue);
      expect(chart.series[0].highlightLatest, isFalse);
    });

    testWidgets('cancel reaches the real cancel path', (tester) async {
      final notifier = await _open(
        tester,
        const FocuserBacklashCalibrationState(
          phase: FocuserBacklashPhase.scanningFromBelow,
          status: 'Scanning up from below: point 1 of 9',
          currentPoint: 1,
          totalPoints: 9,
        ),
        settle: false,
      );

      await tester.tap(find.widgetWithText(SkotiqButton, 'Cancel'));
      await tester.pump();
      expect(notifier.cancelCalls, 1);
    });

    testWidgets('a cancel is not a failure', (tester) async {
      const cancelled =
          'The calibration was cancelled; the focuser is back at 6620';
      final notifier = await _open(
        tester,
        const FocuserBacklashCalibrationState(
          phase: FocuserBacklashPhase.scanningFromBelow,
          status: 'Scanning up from below: point 3 of 9',
          currentPoint: 3,
          totalPoints: 9,
          plan: plan9Points,
          belowPoints: belowPoints6620,
        ),
        settle: false,
      );
      notifier.afterCancel = const FocuserBacklashCalibrationState(
        plan: plan9Points,
        status: cancelled,
      );

      await tester.tap(find.widgetWithText(SkotiqButton, 'Cancel'));
      await tester.pumpAndSettle();

      // Not the failure panel, and nothing calling a requested stop an error.
      expect(find.textContaining('This is not a refusal'), findsNothing);
      expect(
        find.textContaining('stopped before it finished'),
        findsNothing,
      );
      final banners = tester.widgetList<SkotiqBanner>(
        find.byType(SkotiqBanner),
      );
      expect(banners.map((b) => b.tone), isNot(contains(BannerTone.error)));
      // It says where the focuser went, and offers the run again.
      expect(find.textContaining(cancelled), findsOneWidget);
      final button = tester.widget<SkotiqButton>(
        find.widgetWithText(SkotiqButton, 'Measure backlash'),
      );
      expect(button.onPressed, isNotNull);
    });

    testWidgets('a failed phase with nothing to report is not an error panel', (
      tester,
    ) async {
      // Belt and braces on the same hazard: whatever phase a cancellation
      // settles on, an error panel with no error in it must never appear.
      await _open(
        tester,
        const FocuserBacklashCalibrationState(
          phase: FocuserBacklashPhase.failed,
          status: 'The calibration was cancelled; the focuser is back at 6620',
          plan: plan9Points,
        ),
      );

      expect(find.textContaining('This is not a refusal'), findsNothing);
      expect(
        find.widgetWithText(SkotiqButton, 'Measure backlash'),
        findsOneWidget,
      );
    });

    testWidgets('cannot be dismissed mid-run', (tester) async {
      await _open(
        tester,
        const FocuserBacklashCalibrationState(
          phase: FocuserBacklashPhase.scanningFromAbove,
          status: 'Scanning down from above: point 2 of 9',
        ),
        settle: false,
      );

      final dialog = tester.widget<SkotiqDialog>(
        find.byType(SkotiqDialog),
      );
      expect(dialog.closeEnabled, isFalse);
      final guard = tester.widget<PopScope<dynamic>>(
        findByDataKey(FocuserBacklashCalibrationDialog.popGuardKey),
      );
      expect(guard.canPop, isFalse);
    });
  });

  group('measured result', () {
    testWidgets('never shows the figure bare', (tester) async {
      await _open(
        tester,
        FocuserBacklashCalibrationState(
          phase: FocuserBacklashPhase.complete,
          progress: 100,
          status: '105 steps of backlash at position 6620',
          result: measuredResult(measured105()),
          scanRange: const FocusRange(min: 6340, max: 6900),
        ),
      );

      expect(find.text('105 steps'), findsOneWidget);
      // The position, the temperature and the date travel with the figure.
      expect(
        find.textContaining('Measured at position 6620 at 14.5 °C on'),
        findsOneWidget,
      );
      expect(find.textContaining('14 September 2026'), findsOneWidget);
      // Confidence and, verbatim, native's grounds for it.
      expect(find.text('High confidence'), findsOneWidget);
      expect(
        find.text(
          'Both fits are tight and the difference is seven times the '
          'resolution limit.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('varies along the travel'), findsOneWidget);
    });

    testWidgets('shows both curves with their own fitted vertices', (
      tester,
    ) async {
      await _open(
        tester,
        FocuserBacklashCalibrationState(
          phase: FocuserBacklashPhase.complete,
          result: measuredResult(measured105()),
          scanRange: const FocusRange(min: 6340, max: 6900),
        ),
      );

      final chart = tester.widget<VCurveChart>(find.byType(VCurveChart));
      expect(chart.series, hasLength(2));
      expect(chart.series[0].vertexPosition, 6620);
      expect(chart.series[1].vertexPosition, 6515);
      expect(chart.series[0].color, isNot(chart.series[1].color));
      expect(find.textContaining('From below — optimum 6620'), findsOneWidget);
      expect(find.textContaining('From above — optimum 6515'), findsOneWidget);
      // The per-scan evidence, including the ceiling the run could expose.
      expect(find.textContaining('R² 0.987'), findsOneWidget);
      expect(find.textContaining('105 steps (resolution limit 15)'),
          findsOneWidget);
      expect(find.textContaining('560 steps total'), findsOneWidget);
    });

    testWidgets('offers save, discard and re-run, each wired', (tester) async {
      final notifier = await _open(
        tester,
        FocuserBacklashCalibrationState(
          phase: FocuserBacklashPhase.complete,
          result: measuredResult(measured105()),
        ),
      );

      await tester.tap(find.widgetWithText(SkotiqButton, 'Re-run'));
      await tester.pump();
      expect(notifier.runCalls, 1);

      await tester.tap(find.widgetWithText(SkotiqButton, 'Save'));
      await tester.pump();
      expect(notifier.saveCalls, 1);

      await tester.tap(find.widgetWithText(SkotiqButton, 'Discard'));
      await tester.pumpAndSettle();
      expect(notifier.discardCalls, 1);
    });

    testWidgets('a lower-travel measurement reports its own position', (
      tester,
    ) async {
      // The same focuser, 83 steps at 2506. If the UI ever printed a figure
      // without its position, these two runs would be indistinguishable.
      await _open(
        tester,
        FocuserBacklashCalibrationState(
          phase: FocuserBacklashPhase.complete,
          result: measuredResult(measured83()),
        ),
      );

      expect(find.text('83 steps'), findsOneWidget);
      expect(
        find.textContaining('Measured at position 2506 at 11.2 °C on'),
        findsOneWidget,
      );
      expect(find.text('Moderate confidence'), findsOneWidget);
    });

    testWidgets('says so when the figure has been saved', (tester) async {
      await _open(
        tester,
        FocuserBacklashCalibrationState(
          phase: FocuserBacklashPhase.complete,
          result: measuredResult(measured105()),
          isSaved: true,
        ),
      );

      expect(
        find.textContaining('Saved — autofocus will compensate 105 steps'),
        findsOneWidget,
      );
      expect(find.widgetWithText(SkotiqButton, 'Done'), findsOneWidget);
      expect(find.widgetWithText(SkotiqButton, 'Save'), findsNothing);
    });
  });

  group('no measurable backlash', () {
    testWidgets('reads as a successful measurement, not a failure', (
      tester,
    ) async {
      await _open(
        tester,
        FocuserBacklashCalibrationState(
          phase: FocuserBacklashPhase.complete,
          progress: 100,
          status: 'No backlash larger than 15 steps was detectable at position '
              '6620',
          result: noBacklashResult(),
        ),
      );

      expect(find.text('No measurable backlash'), findsOneWidget);
      expect(
        find.textContaining('No backlash larger than 15 steps was detectable'),
        findsOneWidget,
      );
      // Nothing on this surface calls it a failure or an error.
      expect(find.textContaining('could not'), findsNothing);
      expect(find.textContaining('failed'), findsNothing);
      expect(find.byType(SkotiqBanner), findsNothing);
      // Saving it is meaningful: it records that the focuser was checked.
      expect(
          find.textContaining('Saving records that this focuser was '
              'checked'),
          findsOneWidget);
      expect(find.widgetWithText(SkotiqButton, 'Save'), findsOneWidget);
      expect(find.widgetWithText(SkotiqButton, 'Discard'), findsOneWidget);
      expect(find.widgetWithText(SkotiqButton, 'Re-run'), findsOneWidget);
      // Both curves are still shown — it is the evidence for the finding.
      expect(find.byType(VCurveChart), findsOneWidget);
    });

    testWidgets('saved copy records the check rather than a figure', (
      tester,
    ) async {
      await _open(
        tester,
        FocuserBacklashCalibrationState(
          phase: FocuserBacklashPhase.complete,
          result: noBacklashResult(),
          isSaved: true,
        ),
      );

      expect(
        find.textContaining('Saved — this focuser is on record as checked'),
        findsOneWidget,
      );
    });
  });

  group('refused', () {
    testWidgets('renders a star-starved refusal verbatim', (tester) async {
      const message =
          'The from-above scan was abandoned after three frames found fewer '
          'than five stars.';
      const remedy =
          'Point at a denser field, or wait for the cloud to pass, and run it '
          'again.';
      final notifier = await _open(
        tester,
        FocuserBacklashCalibrationState(
          phase: FocuserBacklashPhase.refused,
          progress: 100,
          status: message,
          result: refusedResult(
            code: 'scan_abandoned_for_stars',
            message: message,
            remedy: remedy,
          ),
          belowPoints: belowPoints6620,
          scanRange: const FocusRange(min: 6340, max: 6900),
        ),
      );

      expect(
          find.textContaining('Not enough stars to measure'), findsOneWidget);
      expect(find.textContaining(message), findsOneWidget);
      expect(find.text(remedy), findsOneWidget);
      // Dignified, not an error: informational tone, and it says plainly that
      // nothing was changed.
      final banner = tester.widget<SkotiqBanner>(
        find.byType(SkotiqBanner),
      );
      expect(banner.tone, BannerTone.info);
      expect(
        find.textContaining('your backlash setting is untouched'),
        findsOneWidget,
      );
      // The points that WERE collected stay on screen as the evidence.
      expect(find.byType(VCurveChart), findsOneWidget);

      await tester.tap(find.widgetWithText(SkotiqButton, 'Try again'));
      await tester.pump();
      expect(notifier.runCalls, 1);
      expect(find.widgetWithText(SkotiqButton, 'Close'), findsOneWidget);
    });

    testWidgets('a range refusal is toned and iconed differently', (
      tester,
    ) async {
      const message =
          'The measured difference of 640 steps is wider than the 560 steps '
          'this scan reversed the drive train by.';
      const remedy =
          'Raise the autofocus step size so the scan reverses further, then '
          'measure again.';
      await _open(
        tester,
        FocuserBacklashCalibrationState(
          phase: FocuserBacklashPhase.refused,
          result: refusedResult(
            code: 'exceeds_reversal_budget',
            message: message,
            remedy: remedy,
          ),
        ),
      );

      expect(find.textContaining('The measurement ran out of room'),
          findsOneWidget);
      expect(find.textContaining(message), findsOneWidget);
      expect(find.text(remedy), findsOneWidget);
      final banner = tester.widget<SkotiqBanner>(
        find.byType(SkotiqBanner),
      );
      expect(banner.tone, BannerTone.warning);
      // A different family, so a different glyph from the star-starved case.
      expect(banner.icon, isNot(equals(null)));
      expect(find.byType(VCurveChart), findsNothing);
    });

    testWidgets('a poor fit is a fit-quality refusal', (tester) async {
      await _open(
        tester,
        FocuserBacklashCalibrationState(
          phase: FocuserBacklashPhase.refused,
          result: refusedResult(
            code: 'poor_fit',
            message: 'The from-below curve fitted with R² 0.41.',
            remedy: 'Lengthen the exposure so each HFR is better determined.',
          ),
        ),
      );

      expect(
        find.textContaining('The curves do not support a figure'),
        findsOneWidget,
      );
      expect(
        find.text('Lengthen the exposure so each HFR is better determined.'),
        findsOneWidget,
      );
    });
  });

  group('failed', () {
    testWidgets('is distinct from a refusal', (tester) async {
      await _open(
        tester,
        const FocuserBacklashCalibrationState(
          phase: FocuserBacklashPhase.failed,
          status: 'The calibration could not finish',
          errorMessage: 'Focuser disconnected during the from-above scan',
        ),
      );

      final banner = tester.widget<SkotiqBanner>(
        find.byType(SkotiqBanner),
      );
      expect(banner.tone, BannerTone.error);
      expect(
        find.textContaining('Focuser disconnected during the from-above scan'),
        findsOneWidget,
      );
      expect(find.textContaining('This is not a refusal'), findsOneWidget);
      expect(find.widgetWithText(SkotiqButton, 'Try again'), findsOneWidget);
      expect(find.widgetWithText(SkotiqButton, 'Close'), findsOneWidget);
    });
  });

  group('settings', () {
    /// The data key `_CalibrationSettingsSection` tags each control with.
    Finder field(String name) =>
        findByDataKey('backlash-calibration-field-$name');

    /// The text a number or text field is currently showing.
    String fieldText(WidgetTester tester, String name) => tester
        .widget<EditableText>(
          find.descendant(of: field(name), matching: find.byType(EditableText)),
        )
        .controller
        .text;

    /// Enter a value and commit it, then let the settings write land.
    ///
    /// Fields commit on submit, not per keystroke — the same convention the
    /// settings screens use — so an edit needs the done action followed by a
    /// few pumps for the serialized write to reach the provider.
    Future<void> commit(
      WidgetTester tester,
      String name,
      String text,
    ) async {
      await tester.ensureVisible(field(name));
      await tester.enterText(field(name), text);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
    }

    Map<String, dynamic> storedBlob(HarnessHandle handle) {
      final json = handle.container
          .read(appSettingsProvider)
          .value!
          .focuserBacklashCalibrationJson;
      return jsonDecode(json) as Map<String, dynamic>;
    }

    testWidgets('shows the values seeded from the autofocus settings', (
      tester,
    ) async {
      final (_, handle) = await _openHarness(
        tester,
        const FocuserBacklashCalibrationState(plan: plan9Points),
      );

      final settings = handle.container.read(
        focuserBacklashCalibrationSettingsProvider,
      );
      expect(find.text('Settings'), findsOneWidget);
      expect(
        find.textContaining('Seeded from your autofocus settings'),
        findsOneWidget,
      );
      // Every field shows the resolved settings, not a hardcoded default.
      expect(
        double.parse(fieldText(tester, 'step-size')),
        settings.stepSize.toDouble(),
      );
      expect(
        double.parse(fieldText(tester, 'points-a-side')),
        settings.stepsOut.toDouble(),
      );
      expect(
        double.parse(fieldText(tester, 'run-up')),
        settings.clearanceSteps.toDouble(),
      );
      expect(
        double.parse(fieldText(tester, 'exposure')),
        settings.exposureDurationSecs,
      );
      expect(
        double.parse(fieldText(tester, 'exposures-per-point')),
        settings.exposuresPerPoint.toDouble(),
      );
      // Blank means "the camera's configured value".
      expect(fieldText(tester, 'gain'), '');
      expect(fieldText(tester, 'offset'), '');
      // Advanced stays tucked away until asked for.
      expect(find.text('Advanced'), findsOneWidget);
      expect(field('settle'), findsNothing);
    });

    testWidgets('opens the advanced fit thresholds on request', (tester) async {
      await _open(
        tester,
        const FocuserBacklashCalibrationState(plan: plan9Points),
      );

      expect(field('min-stars'), findsNothing);
      await tester
          .ensureVisible(findByDataKey('backlash-calibration-advanced'));
      await tester.tap(findByDataKey('backlash-calibration-advanced'));
      await tester.pumpAndSettle();

      for (final name in [
        'min-stars',
        'r-squared',
        'inner-crop',
        'outer-crop',
        'brightest-stars',
        'settle',
        'outlier-sigma',
        'max-time',
      ]) {
        expect(field(name), findsOneWidget, reason: name);
      }
      // And it collapses again.
      await tester.tap(findByDataKey('backlash-calibration-advanced'));
      await tester.pumpAndSettle();
      expect(field('settle'), findsNothing);
    });

    testWidgets('edits persist through the settings store as the wire map', (
      tester,
    ) async {
      final (_, handle) = await _openHarness(
        tester,
        const FocuserBacklashCalibrationState(plan: plan9Points),
      );

      await commit(tester, 'step-size', '45');

      final stored = storedBlob(handle);
      // The persisted blob IS the wire vocabulary — same snake_case keys.
      expect(stored['step_size'], 45);
      expect(stored['steps_out'], isNotNull);
      expect(stored['method'], 'Quadratic');
      expect(
        handle.container
            .read(focuserBacklashCalibrationSettingsProvider)
            .stepSize,
        45,
      );
    });

    testWidgets('an unusable combination is named and the run stays shut', (
      tester,
    ) async {
      final (_, handle) = await _openHarness(
        tester,
        const FocuserBacklashCalibrationState(plan: plan9Points),
      );

      // The seeded run-up is 3x the step size; stepping to 200 puts the
      // step size past it, the rule native would refuse the run on.
      await commit(tester, 'step-size', '200');
      await tester.pumpAndSettle();

      expect(find.textContaining('must exceed the step size'), findsWidgets);
      final button = tester.widget<SkotiqButton>(
        find.widgetWithText(SkotiqButton, 'Measure backlash'),
      );
      expect(button.onPressed, isNull);
      expect(
        handle.container
            .read(focuserBacklashCalibrationSettingsProvider)
            .isValid,
        isFalse,
      );
    });

    testWidgets('editing a field re-reads the plan', (tester) async {
      final (notifier, _) = await _openHarness(
        tester,
        const FocuserBacklashCalibrationState(plan: plan9Points),
      );
      // The open itself asked for the plan.
      expect(notifier.planCalls, 1);

      await commit(tester, 'points-a-side', '8');
      await tester.pumpAndSettle();

      // The plan on screen would otherwise quote travel for settings that
      // are no longer in force.
      expect(notifier.planCalls, greaterThan(1));
    });

    testWidgets('reset clears the stored choices back to the autofocus seed', (
      tester,
    ) async {
      final (_, handle) = await _openHarness(
        tester,
        const FocuserBacklashCalibrationState(plan: plan9Points),
      );

      await commit(tester, 'points-a-side', '9');
      expect(storedBlob(handle)['steps_out'], 9);

      await tester.ensureVisible(findByDataKey('backlash-calibration-reset'));
      await tester.tap(findByDataKey('backlash-calibration-reset'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      await tester.pumpAndSettle();

      // An empty store is the reset: the provider re-seeds from autofocus.
      expect(
        handle.container
            .read(appSettingsProvider)
            .value!
            .focuserBacklashCalibrationJson,
        '',
      );
      final seeded = handle.container.read(
        focuserBacklashCalibrationSettingsProvider,
      );
      expect(
        double.parse(fieldText(tester, 'points-a-side')),
        seeded.stepsOut.toDouble(),
      );
    });

    testWidgets('binning writes through as the native enum name', (
      tester,
    ) async {
      final (_, handle) = await _openHarness(
        tester,
        const FocuserBacklashCalibrationState(plan: plan9Points),
      );

      await tester.ensureVisible(field('binning'));
      await tester.tap(field('binning'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2×2'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      await tester.pumpAndSettle();

      expect(storedBlob(handle)['binning'], 'Two');
    });
  });
}
