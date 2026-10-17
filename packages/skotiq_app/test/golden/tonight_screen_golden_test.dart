@Tags(['golden'])
library;

// Review-PNG golden for the one-tap "Tonight" screen (Phase F one-tap flow).
// Written to `docs/design/goldens/` for a reviewer to eyeball — not a
// pixel-diff guard; the assertion only confirms a real, non-empty image was
// produced (the harness prints the absolute PNG path).
//
//   * tonight-one-tap.png — TonightBodyView, idle with a seeded pick
//
// TonightBodyView is the stateless body of the screen, driven here with a
// seeded `OneTapTonightState` + an `AsyncData` target so the capture needs no
// DB / network / framing assistant / executor.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/tonight/one_tap_tonight_controller.dart';
import 'package:skotiq_app/screens/tonight/tonight_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart'
    as planetarium;
import 'package:skotiq_ui/skotiq_ui.dart';

import 'surface_golden_harness.dart';

void main() {
  setUpAll(SurfaceGoldenHarness.ensureFonts);

  const seededTarget = TargetSuggestion(
    targetId: 42,
    targetName: 'M51 — Whirlpool Galaxy',
    catalogId: 'M51',
    raHours: 13.5,
    decDegrees: 47.2,
    totalScore: 91,
    objectType: 'Spiral Galaxy',
    reasoning: 'Highest scoring target tonight: 78° peak altitude, 5.2 h above '
        '30°, and well clear of the Moon. The autopilot would slew here next.',
    visibility: planetarium.TargetVisibilityInfo(
      currentAltitude: 72,
      currentAzimuth: 180,
      transitAltitude: 78,
      peakAltitude: 78,
      hoursAboveMinAlt: 5.2,
      airmass: 1.1,
      moonDistance: 100,
    ),
  );

  testWidgets('tonight one-tap screen — idle with seeded pick (dark)',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final boundaryKey = GlobalKey();

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          debugShowCheckedModeBanner: false,
          home: Builder(
            builder: (context) {
              const colors = SkotiqColors.dark;
              return Scaffold(
                backgroundColor: colors.background,
                body: Center(
                  child: RepaintBoundary(
                    key: boundaryKey,
                    child: SizedBox(
                      width: 440,
                      height: 1440,
                      child: TonightBodyView(
                        colors: colors,
                        state: const OneTapTonightState(),
                        activeRun: null,
                        targetAsync: const AsyncData(seededTarget),
                        onGo: () async {},
                        onReset: () {},
                        onRefreshPick: () {},
                        morningSessionAsync: const AsyncData(null),
                        onRefreshMorningReport: () {},
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    final file = await SurfaceGoldenHarness.captureBoundary(
      tester,
      boundaryKey,
      fileName: 'tonight-one-tap.png',
    );
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), greaterThan(1024));
  });
}
