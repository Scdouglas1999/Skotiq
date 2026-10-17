// Regression tests: the Imaging screen's Guiding and Stack tabs must not
// report measurements they have not made.
//
// Observed on the running release build with the guider Disconnected and no
// stack in progress:
//
//   * Guiding tab — RA RMS / Dec RMS / Total correctly read "---" but
//     "RA Peak 0.00\"" and "Dec Peak 0.00\"" sat right beneath them. A 0.00"
//     peak excursion is a claim of flawless guiding. The suffix was wrong too:
//     the underlying Phd2GuideStats fields are guide-camera PIXELS.
//   * Stack tab — "Average matched pairs 0.0" and "Average alignment residual 0.00 px"
//     while "Rejection Rate" (correctly) showed "--". Both averages are
//     per-aligned-frame metrics that stay at their 0.0 initialiser until a
//     second frame is registered against the reference.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/guiding_panel.dart';
import 'package:skotiq_app/screens/imaging/widgets/stacking_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

/// Guide stats carrying real samples. Values are guide-camera pixels and the
/// built-in guider reports no pixel scale, so they must be labelled px.
class _MeasuredGuideStats extends GuideStatsNotifier {
  _MeasuredGuideStats(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const Phd2GuideStats(
      rmsRa: 0.53,
      rmsDec: 0.57,
      rmsTotal: 0.78,
      peakRa: 1.42,
      peakDec: 1.19,
      frameCount: 37,
    );
  }
}

class _SeededStack extends LiveStackingNotifier {
  _SeededStack(super.ref, LiveStackingStats stats) {
    // ignore: invalid_use_of_protected_member
    state = state.copyWith(stats: stats);
  }
}

Future<void> _drain(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _pumpStackingPanel(
  WidgetTester tester,
  LiveStackingStats stats,
) async {
  await pumpAppScreen(
    tester,
    const SingleChildScrollView(
      child: StackingPanel(colors: SkotiqColors.dark),
    ),
    size: const Size(420, 1600),
    settle: false,
    extraOverrides: [
      isRemoteModeProvider.overrideWithValue(false),
      connectedCameraIdProvider.overrideWithValue(null),
      liveStackingProvider.overrideWith((ref) => _SeededStack(ref, stats)),
    ],
  );
  await _drain(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Imaging > Guiding tab', () {
    testWidgets('with no guide step measured, every error tile is a dash',
        (tester) async {
      await pumpAppScreen(
        tester,
        const GuidingPanel(colors: SkotiqColors.dark),
        size: const Size(520, 1400),
        settle: false,
      );
      await _drain(tester);

      expect(find.text('RA Peak'), findsOneWidget);
      expect(find.text('Dec peak'), findsOneWidget);
      expect(
        find.textContaining('0.00'),
        findsNothing,
        reason: 'a fabricated 0.00 peak excursion reads as perfect guiding',
      );
      // RA RMS + Dec RMS + Total + RA Peak + Dec Peak.
      expect(find.text('—'), findsNWidgets(5));
    });

    testWidgets('measured samples render in pixels, never as arcseconds',
        (tester) async {
      await pumpAppScreen(
        tester,
        const GuidingPanel(colors: SkotiqColors.dark),
        size: const Size(520, 1400),
        settle: false,
        extraOverrides: [
          guideStatsProvider.overrideWith(_MeasuredGuideStats.new),
        ],
      );
      await _drain(tester);

      expect(find.text('1.42 px'), findsOneWidget);
      expect(find.text('1.19 px'), findsOneWidget);
      expect(find.text('0.53 px'), findsOneWidget);
      for (final arcsec in const [
        '1.42"',
        '1.19"',
        '0.53"',
        '0.57"',
        '0.78"'
      ]) {
        expect(
          find.text(arcsec),
          findsNothing,
          reason: 'guide-camera pixels must never be labelled arcseconds',
        );
      }
    });
  });

  group('Imaging > Stack tab', () {
    testWidgets(
        'with no frame aligned, the per-aligned-frame averages dash out',
        (tester) async {
      await _pumpStackingPanel(tester, const LiveStackingStats());

      expect(find.text('Average matched pairs'), findsOneWidget);
      expect(find.text('Average alignment residual'), findsOneWidget);
      expect(
        find.text('0.0'),
        findsNothing,
        reason: 'an unmeasured matched-pair average is not a measurement',
      );
      expect(
        find.text('0.00 px'),
        findsNothing,
        reason: '0.00 px residual reads as sub-pixel-perfect registration',
      );
    });

    testWidgets('the reference frame alone still counts as nothing aligned',
        (tester) async {
      await _pumpStackingPanel(
        tester,
        const LiveStackingStats(
          stackedFrameCount: 1,
          totalFramesAttempted: 1,
        ),
      );

      expect(find.text('0.0'), findsNothing);
      expect(find.text('0.00 px'), findsNothing);
    });

    testWidgets('once a frame is aligned the real averages show through',
        (tester) async {
      await _pumpStackingPanel(
        tester,
        const LiveStackingStats(
          stackedFrameCount: 4,
          totalFramesAttempted: 5,
          avgMatchedPairs: 42.5,
          avgAlignmentResidual: 0.37,
        ),
      );

      // Values carry their unit: matched pairs count stars, the residual is
      // pixels.
      expect(find.text('42.5 stars'), findsOneWidget);
      expect(find.text('0.37 px'), findsOneWidget);
    });
  });
}
