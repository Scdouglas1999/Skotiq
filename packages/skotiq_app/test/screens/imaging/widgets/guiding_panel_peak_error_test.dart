// Widget test for the imaging GuidingPanel's per-axis PEAK guide-error readout.
//
// Peak RA/Dec are tracked in the rolling guide stats
// (Phd2GuideStats.peakRa/peakDec) and rendered as a second stat row beside the
// RMS figures. Drives the panel with a guideStatsProvider seeded to known peak
// values and asserts the formatted tiles render.
//
// `Phd2GuideStats` residuals are guide-camera PIXELS (PHD2's RADistanceRaw), so
// the suffix is px unless a real pixel scale is known — the same rule
// guiding_no_measurement_readouts_test.dart pins for the Guiding screen.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/guiding_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/harness.dart';

/// A [GuiderStateNotifier] seeded connected + guiding so the panel renders its
/// stats section (rather than the disconnected warning state).
class _ConnectedGuiderNotifier extends GuiderStateNotifier {
  _ConnectedGuiderNotifier(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const GuiderState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'simulator:guider:0',
      isGuiding: true,
      rmsRa: 0.42,
      rmsDec: 0.37,
      rmsTotal: 0.56,
    );
  }
}

/// A [GuideStatsNotifier] pinned to a known snapshot carrying explicit peak
/// values, so the peak tiles have deterministic content to assert on without
/// pumping synthetic GuideStep events through the backend event stream.
class _SeededGuideStatsNotifier extends GuideStatsNotifier {
  _SeededGuideStatsNotifier(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const Phd2GuideStats(
      rmsRa: 0.42,
      rmsDec: 0.37,
      rmsTotal: 0.56,
      peakRa: 1.23,
      peakDec: 0.89,
      snr: 18.0,
      starMass: 4200,
      frameCount: 100,
    );
  }
}

/// Same snapshot but with a known guide-camera pixel scale, which is the only
/// condition under which these residuals may be shown in arcseconds.
class _ScaledGuideStatsNotifier extends GuideStatsNotifier {
  _ScaledGuideStatsNotifier(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const Phd2GuideStats(
      rmsRa: 0.42,
      rmsDec: 0.37,
      rmsTotal: 0.56,
      peakRa: 1.23,
      peakDec: 0.89,
      snr: 18.0,
      starMass: 4200,
      pixelScale: 2.0,
      frameCount: 100,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders per-axis PEAK guide error from seeded stats',
      (tester) async {
    await pumpAppScreen(
      tester,
      const GuidingPanel(colors: SkotiqColors.dark),
      // Mobile-portrait surface keeps the scrolling panel laid out without the
      // built-in-guider-only sections expanding the tree.
      size: const Size(380, 900),
      extraOverrides: [
        guiderStateProvider.overrideWith(_ConnectedGuiderNotifier.new),
        guideStatsProvider.overrideWith(_SeededGuideStatsNotifier.new),
        // Keep the built-in-guider-only config/star sections out of the tree so
        // the test pins exactly the stat tiles it owns.
        isBuiltinGuiderProvider.overrideWithValue(false),
      ],
      settle: false,
    );
    // Drain the initial frames (the panel polls/animates; settle would time out).
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }

    // The new peak row labels.
    expect(find.text('RA Peak'), findsOneWidget,
        reason: 'The RA peak tile must render alongside RA RMS.');
    expect(find.text('Dec peak'), findsOneWidget,
        reason: 'The Dec peak tile must render alongside Dec RMS.');

    // The seeded peak values, formatted to two decimals. The seeded stats carry
    // no pixel scale, so they stay in guide-camera pixels.
    expect(find.text('1.23 px'), findsOneWidget,
        reason: 'Peak RA must render the seeded value verbatim.');
    expect(find.text('0.89 px'), findsOneWidget,
        reason: 'Peak Dec must render the seeded value verbatim.');
    expect(find.text('1.23"'), findsNothing,
        reason: 'a pixel residual labelled arcsec understates the real error '
            'by the pixel scale.');
  });

  testWidgets('converts to arcseconds only when a pixel scale is known',
      (tester) async {
    await pumpAppScreen(
      tester,
      const GuidingPanel(colors: SkotiqColors.dark),
      size: const Size(380, 900),
      extraOverrides: [
        guiderStateProvider.overrideWith(_ConnectedGuiderNotifier.new),
        guideStatsProvider.overrideWith(_ScaledGuideStatsNotifier.new),
        isBuiltinGuiderProvider.overrideWithValue(false),
      ],
      settle: false,
    );
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }

    // 1.23 px at 2.00"/px.
    expect(find.text('2.46"'), findsOneWidget);
    expect(find.text('1.78"'), findsOneWidget);
  });
}
