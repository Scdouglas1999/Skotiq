import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_app/screens/polar_alignment/polar_alignment_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

GoRouter _navigationRouter() {
  return GoRouter(
    initialLocation: '/home',
    routes: [
      GoRoute(
        path: '/home',
        builder: (context, _) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => context.push('/polar-alignment'),
              child: const Text('Open polar alignment'),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/polar-alignment',
        builder: (_, __) => const PolarAlignmentScreen(),
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
  testWidgets(
    'polar alignment UI state persists across navigation',
    (tester) async {
      final handle = await pumpAppScreen(
        tester,
        MaterialApp.router(
          theme: SkotiqTheme.dark,
          routerConfig: _navigationRouter(),
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

      await tester.tap(find.text('Open polar alignment'));
      await tester.pumpAndSettle();

      expect(find.text('Three-point polar alignment'), findsOneWidget);

      await tester.tap(find.text('All-sky'));
      await tester.pumpAndSettle();

      await handle.container
          .read(polarAlignmentUiStateProvider.notifier)
          .setShowCommonSettings(true);
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(LucideIcons.arrowLeft));
      await tester.pumpAndSettle();

      expect(find.text('Open polar alignment'), findsOneWidget);
      expect(
        handle.container.read(polarAlignmentUiStateProvider).mode,
        PolarAlignmentMode.allSky,
      );
      expect(
        handle.container.read(polarAlignmentUiStateProvider).showCommonSettings,
        isTrue,
      );

      await tester.tap(find.text('Open polar alignment'));
      await tester.pumpAndSettle();

      expect(find.text('All-sky polar alignment'), findsOneWidget);
      expect(
        handle.container.read(polarAlignmentUiStateProvider).showCommonSettings,
        isTrue,
      );

      await tester.scrollUntilVisible(
        find.text('Binning'),
        48,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Binning'), findsOneWidget);
    },
  );
}
