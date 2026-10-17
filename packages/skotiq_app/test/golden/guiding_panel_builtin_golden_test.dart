@Tags(['golden'])
library;

// Golden (review-artifact) capture of the imaging GuidingPanel with the
// built-in multi-star guider active and seeded per-star data (Phase F,
// guider-ui).
//
// Before this work the built-in guider only exported aggregate PHD2-style
// stats, so the panel showed an empty graph and no star list when the internal
// guider was running. This golden renders the populated state: the shared
// CompactGuidingGraph fed with seeded points + the new tracked-star list
// (per-star SNR, lock highlight, residual). The PNG in docs/design/goldens/ is
// the deliverable; the assertions only confirm a real, non-empty image plus
// that the load-bearing star-list strings rendered.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'package:skotiq_app/screens/imaging/widgets/guiding_panel.dart';

import '../harness/mock_backend.dart';
import 'surface_golden_harness.dart';

/// Pins the backend provider to a specific [SkotiqBackend] (the mock)
/// without reaching the real bridge.
class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

/// GuiderState seeded as the built-in multi-star guider, connected + guiding,
/// with representative RMS so the panel's stat tiles and `isBuiltinGuider`
/// branch both render.
class _BuiltinGuiderConnected extends GuiderStateNotifier {
  _BuiltinGuiderConnected(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const GuiderState(
      connectionState: DeviceConnectionState.connected,
      deviceId: builtinGuiderDeviceId,
      isGuiding: true,
      rmsRa: 0.42,
      rmsDec: 0.37,
      rmsTotal: 0.56,
    );
  }
}

/// Built-in guider config notifier pre-resolved to defaults so the embedded
/// config form renders immediately instead of spinning a loading shimmer (and
/// without reaching the backend).
class _SeededBuiltinConfig extends BuiltinGuiderConfigNotifier {
  _SeededBuiltinConfig(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const AsyncValue.data(BuiltinGuiderConfig.defaults);
  }
}

const _seededStars = <GuideStar>[
  GuideStar(
      id: 0,
      x: 410,
      y: 286,
      flux: 9100,
      snr: 24.6,
      isLock: true,
      residual: 0.18),
  GuideStar(id: 1, x: 128, y: 512, flux: 6400, snr: 17.2, residual: 0.34),
  GuideStar(id: 2, x: 745, y: 190, flux: 4100, snr: 11.8, residual: 0.51),
  GuideStar(id: 3, x: 612, y: 640, flux: 2800, snr: 8.4, residual: 0.77),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('surface — guiding panel (built-in multi-star guider active)',
      (tester) async {
    await SurfaceGoldenHarness.ensureFonts();

    final backend = mockBackend();

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(380, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final boundaryKey = GlobalKey();
    late ProviderContainer container;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backendProvider
              .overrideWith((ref) => _FixedBackendNotifier(ref, backend)),
          guiderStateProvider
              .overrideWith((ref) => _BuiltinGuiderConnected(ref)),
          builtinGuiderConfigProvider
              .overrideWith((ref) => _SeededBuiltinConfig(ref)),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            container = ProviderScope.containerOf(context);
            return MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: SkotiqTheme.dark,
              home: Scaffold(
                backgroundColor: SkotiqColors.dark.background,
                body: Center(
                  child: RepaintBoundary(
                    key: boundaryKey,
                    child: const SizedBox(
                      width: 360,
                      height: 880,
                      child: GuidingPanel(colors: SkotiqColors.dark),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );

    // Seed the shared graph + the new tracked-star list now that the provider
    // notifiers are materialized. This drives the exact populated state the
    // built-in guider produces at runtime via the guiding status/event path.
    for (final (ra, dec) in const [
      (0.4, -0.2),
      (-0.3, 0.5),
      (0.6, 0.1),
      (-0.5, -0.4),
      (0.2, 0.3),
      (0.1, -0.6),
      (-0.2, 0.2),
      (0.5, -0.1),
    ]) {
      container.read(guideGraphProvider.notifier).addPoint(ra, dec);
    }
    container.read(guideStarsProvider.notifier).setStars(_seededStars);

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    // Load-bearing content: the tracked-star section header + lock row prove the
    // new per-star UI rendered with the seeded data.
    expect(find.text('Tracked Stars (4)'), findsOneWidget);
    expect(find.text('Star 1 (lock)'), findsOneWidget);
    expect(find.text('Star 4'), findsOneWidget);

    final file = await SurfaceGoldenHarness.captureBoundary(
      tester,
      boundaryKey,
      fileName: 'surface-guiding-panel-builtin-multistar.png',
    );
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), greaterThan(1024));
    expect(tester.takeException(), isNull);
  });
}
