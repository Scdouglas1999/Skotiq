// The Imaging screen at the owner's window: a 1920x1080 panel at 125% gives
// a 1536x864 logical window, and with the navigation rail open the screen
// gets about 1308 px of it.
//
// What broke there, pinned:
//  * the viewer toolbar needed 984 px and got 972 with a meridian flip armed,
//    so its trailing group (Abort capture) scrolled off the right edge;
//  * the capture bar's left end reached x=360 and drew over the Guiding chip
//    in the bottom-left corner, cutting its RMS value off under Snapshot.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/imaging_screen.dart';
import 'package:skotiq_app/screens/imaging/widgets/guiding_active_chip.dart';
import 'package:skotiq_app/screens/imaging/widgets/imaging_capture_bar.dart';
import 'package:skotiq_app/widgets/tutorial_keys/imaging_keys.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../golden/surface_golden_harness.dart';
import '../../harness/harness.dart';

/// The screen's share of a 1536x864 window with the rail expanded.
const Size _ownerContent = Size(1308, 774);

/// A frame with the owner's sensor shape (4656x3520), scaled down tenfold so
/// the test does not decode 65 MB of pixels.
CapturedImageData _frame() {
  const width = 466;
  const height = 352;
  final rgba = Uint8List(width * height * 4)
    ..fillRange(0, width * height * 4, 40);
  return CapturedImageData(
    width: width,
    height: height,
    displayData: rgba,
    histogram: List<int>.filled(256, 0),
    stats: const ImageStats(
      hfr: 16.29,
      eccentricity: 0.15,
      starCount: 105,
      median: 528,
      mean: 534,
      stdDev: 40,
      min: 0,
      max: 65535,
      mad: 12,
    ),
    capturedAt: DateTime(2026, 10, 17, 23, 40),
    settings: const ExposureSettings(
      exposureTime: 120,
      gain: 139,
      offset: 21,
      filter: 'Ha',
    ),
    isColor: false,
  );
}

class _ExposingCamera extends CameraStateNotifier {
  _ExposingCamera(super.ref) {
    setConnecting('asi1600', 'ZWO ASI1600MM Pro');
    setConnected();
    setCooling(true);
    setTargetTemp(-10);
    updateTemperature(-10.0, 38);
    setExposing(true, progress: 0.4);
  }
}

class _GuidingGuider extends GuiderStateNotifier {
  _GuidingGuider(super.ref) {
    setConnecting('phd2', 'PHD2');
    setConnected();
    setGuiding(true);
    updateRms(0.31, 0.27, 0.42);
  }
}

class _Exposing extends ExposureProgressNotifier {
  _Exposing() {
    startExposure(120, 7, 36);
    updateProgress(48, 72, 40);
  }
}

class _Stats extends GuideStatsNotifier {
  _Stats(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const Phd2GuideStats(
      rmsRa: 0.31,
      rmsDec: 0.27,
      rmsTotal: 0.42,
      snr: 42.6,
      pixelScale: 1.34,
    );
  }
}

Future<void> _pump(WidgetTester tester) async {
  // The shipped fonts: whether the bar fits is a question about real glyph
  // widths, and the test font's square glyphs are far wider.
  await SurfaceGoldenHarness.ensureFonts();
  final handle = await pumpAppScreen(
    tester,
    const ImagingScreen(),
    size: _ownerContent,
    settle: false,
    extraOverrides: [
      currentImageProvider.overrideWith((ref) => _frame()),
      cameraStateProvider.overrideWith((ref) => _ExposingCamera(ref)),
      exposureProgressProvider.overrideWith((ref) => _Exposing()),
      guiderStateProvider.overrideWith((ref) => _GuidingGuider(ref)),
      phd2StateProvider.overrideWith((ref) => Phd2State.guiding),
      guideStatsProvider.overrideWith((ref) => _Stats(ref)),
      meridianCountdownProvider.overrideWith(
        (ref) => const MeridianCountdownState(
          isArmed: true,
          timeToFlip: Duration(hours: 3, minutes: 6),
          isAutomaticWatchdog: true,
          isSequencerOwned: false,
          disabledReason: null,
          method: MeridianTriggerMethod.minutesPastMeridian,
          hourAngleHours: -3.1,
          sideOfPier: 'East',
        ),
      ),
    ],
  );
  addTearDown(() async => handle.database.close());
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets(
      'the viewer toolbar fits without scrolling, Abort capture included',
      (tester) async {
    await _pump(tester);
    expect(tester.takeException(), isNull);

    expect(find.byTooltip('Abort capture'), findsOneWidget,
        reason: 'non-vacuous: an exposure is in flight');
    expect(find.text('Flip in 3h 6m'), findsOneWidget,
        reason: 'non-vacuous: the flip chip takes its share of the bar');
    final scrollable = tester.state<ScrollableState>(
      find
          .ancestor(
            of: find.byKey(ImagingTutorialKeys.zoomControls),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(scrollable.position.maxScrollExtent, 0,
        reason: 'nothing on the bar sits past its right edge');
  });

  testWidgets('the Guiding chip steps up clear of the capture bar',
      (tester) async {
    await _pump(tester);
    expect(tester.takeException(), isNull);

    final chip = find.byType(GuidingActiveChip);
    expect(find.descendant(of: chip, matching: find.byType(Text)), findsWidgets,
        reason: 'non-vacuous: PHD2 is guiding, so the chip is on screen');
    final chipRect = tester.getRect(chip);
    final barRect = tester.getRect(find.byType(ImagingCaptureBar));
    expect(chipRect.overlaps(barRect), isFalse,
        reason: 'chip $chipRect is drawn under the capture bar $barRect');
  });
}
