@Tags(['golden'])
library;

// Key-surface design goldens.
//
// Renders a set of the most design-important, deterministically-pumpable real
// skotiq_app surfaces with injected fake/seeded providers and writes each
// captured frame to docs/design/goldens/ for visual review. The PNGs are the
// deliverable; assertions guard only that a real, non-empty image was produced.
//
// Surfaces captured (all under the dark production theme):
//   * surface-sequencer-node-palette.png  — sequencer node palette sidebar
//   * surface-imaging-overlay-hud.png     — imaging live-view overlay chip row + HUD
//   * surface-settings-appearance.png     — Appearance settings section page

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'package:skotiq_app/screens/imaging/widgets/overlay_widgets.dart';
import 'package:skotiq_app/screens/sequencer/widgets/node_palette.dart';
import 'package:skotiq_app/screens/settings/widgets/appearance_settings.dart';

import '../harness/pump_app_screen.dart';
import 'surface_golden_harness.dart';

/// Pumps [child] under the dark production theme inside a [RepaintBoundary] of
/// exactly [size], with [overrides] applied to a [ProviderScope]. Captures the
/// frame to `docs/design/goldens/<fileName>`.
Future<void> pumpAndCapture(
  WidgetTester tester, {
  required String fileName,
  required Size size,
  required List<Override> overrides,
  required Widget child,
  Duration settle = const Duration(milliseconds: 80),
}) async {
  await SurfaceGoldenHarness.ensureFonts();

  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final boundaryKey = GlobalKey();
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: SkotiqTheme.dark,
        home: Scaffold(
          backgroundColor: SkotiqColors.dark.background,
          body: Center(
            child: RepaintBoundary(
              key: boundaryKey,
              child: SizedBox.fromSize(size: size, child: child),
            ),
          ),
        ),
      ),
    ),
  );
  // Drain first-frame async (stream providers, layout) without requiring
  // forever-running animations to settle.
  await tester.pump();
  await tester.pump(settle);

  final file = await SurfaceGoldenHarness.captureBoundary(
    tester,
    boundaryKey,
    fileName: fileName,
  );
  expect(file.existsSync(), isTrue);
  expect(file.lengthSync(), greaterThan(1024));
  expect(tester.takeException(), isNull);
}

/// A framed dark panel so a small surface reads as a screenshot, not a floating
/// widget. Uses the production surface/border tokens.
Widget _panel({required Widget child, EdgeInsets? padding}) {
  const colors = SkotiqColors.dark;
  return Builder(
    builder: (context) => Container(
      padding: padding ?? const EdgeInsets.all(20),
      color: colors.background,
      child: child,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('surface — sequencer node palette', (tester) async {
    // The palette's node-defaults provider transitively reaches the settings
    // DAO + active-profile stream, which open the real database. Use the full
    // app harness (in-memory DB + mock backend) so that whole graph resolves
    // and tears down cleanly, and pin smart-night context to null to avoid the
    // extra DB-backed exposure future.
    await SurfaceGoldenHarness.ensureFonts();

    final boundaryKey = GlobalKey();
    final handle = await pumpAppScreen(
      tester,
      _panel(
        padding: const EdgeInsets.all(12),
        child: RepaintBoundary(
          key: boundaryKey,
          child: SizedBox(
            width: 336,
            height: 696,
            child: ClipRRect(
              borderRadius: SkotiqTokens.borderRadiusMd,
              child: Container(
                decoration: BoxDecoration(
                  color: SkotiqColors.dark.surface,
                  borderRadius: SkotiqTokens.borderRadiusMd,
                  border: Border.all(color: SkotiqColors.dark.border),
                ),
                child: const NodePalette(colors: SkotiqColors.dark),
              ),
            ),
          ),
        ),
      ),
      size: const Size(360, 720),
      theme: SkotiqTheme.dark,
      extraOverrides: [
        smartNightExposureContextProvider.overrideWith((ref) async => null),
      ],
    );
    addTearDown(() async => handle.database.close());

    await tester.pump(const Duration(milliseconds: 80));

    final file = await SurfaceGoldenHarness.captureBoundary(
      tester,
      boundaryKey,
      fileName: 'surface-sequencer-node-palette.png',
    );
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), greaterThan(1024));
    expect(tester.takeException(), isNull);
  });

  testWidgets('surface — imaging live-view overlay HUD', (tester) async {
    await pumpAndCapture(
      tester,
      fileName: 'surface-imaging-overlay-hud.png',
      size: const Size(520, 300),
      overrides: const [],
      child: Container(
        // Stand in for the live image canvas the HUD composites over.
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(-0.2, -0.3),
            radius: 1.1,
            colors: [Color(0xFF1B2433), Color(0xFF05070C)],
          ),
        ),
        padding: const EdgeInsets.all(16),
        child: const Stack(
          children: [
            Align(
              alignment: Alignment.topLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OverlayChip(
                    icon: LucideIcons.timer,
                    label: '300s · Ha',
                    colors: SkotiqColors.dark,
                  ),
                  OverlayChip(
                    icon: LucideIcons.thermometer,
                    label: '-10.0°C',
                    colors: SkotiqColors.dark,
                  ),
                  OverlayChip(
                    icon: LucideIcons.crosshair,
                    label: '0.42 rms',
                    colors: SkotiqColors.dark,
                  ),
                  OverlayChip(
                    icon: LucideIcons.zap,
                    label: 'Gain 100',
                    colors: SkotiqColors.dark,
                  ),
                ],
              ),
            ),
            // The frame's measurements are a Glass ReadoutRow now (05 §14);
            // the values are inline because this surface has no provider
            // scope of its own.
            Align(
              alignment: Alignment.topRight,
              child: Glass(
                child: ReadoutRow(
                  gap: 18,
                  children: [
                    Readout(value: '2.13', unit: 'px', label: 'HFR'),
                    Readout(value: '1842', label: 'Stars'),
                    Readout(value: '1 180', label: 'Median'),
                    Readout(value: '1 304', label: 'Mean'),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  });

  testWidgets('surface — settings appearance section', (tester) async {
    // The settings page reads appSettingsProvider (an AsyncNotifier backed by
    // the DB), so pump through the full app harness which wires an in-memory
    // database + mock backend. Capture the boundary the harness mounts.
    await SurfaceGoldenHarness.ensureFonts();

    final boundaryKey = GlobalKey();
    final handle = await pumpAppScreen(
      tester,
      RepaintBoundary(
        key: boundaryKey,
        child: Container(
          width: 560,
          color: SkotiqColors.dark.background,
          child: const SingleChildScrollView(
            child: AppearanceSettings(),
          ),
        ),
      ),
      size: const Size(620, 900),
      theme: SkotiqTheme.dark,
    );
    addTearDown(() async => handle.database.close());

    await tester.pump(const Duration(milliseconds: 80));

    final file = await SurfaceGoldenHarness.captureBoundary(
      tester,
      boundaryKey,
      fileName: 'surface-settings-appearance.png',
    );
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), greaterThan(1024));
    expect(tester.takeException(), isNull);
  });
}
