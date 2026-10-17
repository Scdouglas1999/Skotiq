import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/polar_alignment/polar_alignment_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

GoRouter _router(Widget screen) {
  return GoRouter(
    initialLocation: '/polar-alignment',
    routes: [
      GoRoute(
        path: '/polar-alignment',
        builder: (_, __) => screen,
      ),
      GoRoute(
        path: '/settings/plate-solving',
        builder: (_, __) =>
            const Scaffold(body: Text('plate-solving settings stub')),
      ),
      GoRoute(
        path: '/imaging',
        builder: (_, __) => const Scaffold(body: Text('imaging stub')),
      ),
    ],
  );
}

void main() {
  testWidgets('Done stays disabled until an alignment measurement arrives',
      (tester) async {
    final handle = await pumpAppScreen(
      tester,
      MaterialApp.router(
        theme: SkotiqTheme.dark,
        routerConfig: _router(const PolarAlignmentScreen()),
      ),
      size: const Size(800, 600),
      settle: false,
      extraOverrides: [
        plateSolverDetectionProvider.overrideWith(
          (ref) async => const PlateSolverDetection(
            astapPath: '/opt/astap/astap',
            catalogPath: '/opt/astap',
          ),
        ),
      ],
    );
    when(
      () => handle.backend.startAllSkyPolarAlignment(
        exposureTime: any(named: 'exposureTime'),
        solveTimeout: any(named: 'solveTimeout'),
        binning: any(named: 'binning'),
        isNorth: any(named: 'isNorth'),
        acceptanceThresholdArcsec: any(named: 'acceptanceThresholdArcsec'),
        iterationCadenceSecs: any(named: 'iterationCadenceSecs'),
        gain: any(named: 'gain'),
        offset: any(named: 'offset'),
      ),
    ).thenAnswer((_) async {});
    when(() => handle.backend.stopPolarAlignment()).thenAnswer((_) async {});

    final notifier = handle.container.read(
      polarAlignmentStateProvider.notifier,
    );
    await notifier.startAllSkyAlignment(const PolarAlignmentConfig());
    await tester.pump();

    expect(
      tester
          .widget<SkotiqButton>(
            find.widgetWithText(SkotiqButton, 'Done'),
          )
          .onPressed,
      isNull,
    );

    handle.backend.emitEvent(
      const SkotiqEvent(
        timestamp: 0,
        severity: EventSeverity.info,
        category: EventCategory.polarAlignment,
        eventType: 'PolarAlignment',
        data: {
          'azimuth_error': 12,
          'altitude_error': 8,
          'total_error': 14.4,
        },
      ),
    );
    await tester.pump();

    expect(
      tester
          .widget<SkotiqButton>(
            find.widgetWithText(SkotiqButton, 'Done'),
          )
          .onPressed,
      isNotNull,
    );

    await notifier.stopAlignment();
  });

  testWidgets(
    'selected unavailable solver keeps Start disabled even when another solver is ready',
    (tester) async {
      final handle = await pumpAppScreen(
        tester,
        MaterialApp.router(
          theme: SkotiqTheme.dark,
          routerConfig: _router(const PolarAlignmentScreen()),
        ),
        size: const Size(800, 600),
        settle: false,
        extraOverrides: [
          plateSolverDetectionProvider.overrideWith(
            (ref) async => const PlateSolverDetection(
              astapPath: '/opt/astap/astap',
              catalogPath: '/opt/astap',
            ),
          ),
          plateSolverPreferenceProvider.overrideWith(
            (ref) async => const PlateSolverPreference(
              choice: PlateSolverChoice.astrometry,
            ),
          ),
        ],
      );

      handle.container.read(cameraStateProvider.notifier).setConnected();
      handle.container.read(mountStateProvider.notifier).setConnected();
      await tester.pump(const Duration(milliseconds: 100));

      final start = tester.widget<SkotiqButton>(
        find.widgetWithText(SkotiqButton, 'Start alignment'),
      );
      expect(start.onPressed, isNull);
      expect(
          find.textContaining('Polar alignment plate-solves'), findsOneWidget);
      handle.container.read(mountStateProvider.notifier).setDisconnected();
    },
  );

  testWidgets(
    'PolarAlignmentScreen idle layout does not overflow at 800x600',
    (tester) async {
      await pumpAppScreen(
        tester,
        MaterialApp.router(
          theme: SkotiqTheme.dark,
          routerConfig: _router(const PolarAlignmentScreen()),
        ),
        size: const Size(800, 600),
        settle: false,
        extraOverrides: [
          plateSolverDetectionProvider.overrideWith(
            (ref) async => const PlateSolverDetection(
              astapPath: r'C:\Program Files\astap\astap.exe',
              catalogPath: r'C:\Program Files\astap',
            ),
          ),
        ],
      );

      await tester.pump(const Duration(milliseconds: 100));

      expect(
        tester.takeException(),
        isNull,
        reason: 'Layout should not overflow at mount-tab dialog dimensions',
      );

      expect(find.text('Three-point polar alignment'), findsOneWidget);
    },
  );

  testWidgets(
    'PolarAlignmentScreen uses medium stacked layout without overflow',
    (tester) async {
      await pumpAppScreen(
        tester,
        MaterialApp.router(
          theme: SkotiqTheme.dark,
          routerConfig: _router(const PolarAlignmentScreen()),
        ),
        size: const Size(900, 700),
        settle: false,
        extraOverrides: [
          plateSolverDetectionProvider.overrideWith(
            (ref) async => const PlateSolverDetection(
              astapPath: r'C:\Program Files\astap\astap.exe',
              catalogPath: r'C:\Program Files\astap',
            ),
          ),
        ],
      );

      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
    },
  );
}
