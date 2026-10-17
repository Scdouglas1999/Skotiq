// Widget + model tests for the Plate Solving settings UX layer.
//
// Imports the model leaf path rather than the public `skotiq_core` barrel.
// Both surfaces export the same `PlateSolverDetection` / `PlateSolverInfo`
// types.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/settings/plate_solving_settings_screen.dart';
import 'package:skotiq_app/screens/settings/widgets/solver_detection_card.dart';
// SolverDetectionCard imports the model leaf directly to avoid a circular
// dependency on the core barrel; the screen-level tests below need the
// detection / preference providers, so they reach in through the barrel.
import 'package:skotiq_core/src/models/plate_solver.dart';
import 'package:skotiq_core/src/backend/network_backend.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/plate_solver_provider.dart';
import 'package:skotiq_core/src/services/plate_solve_service.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _MockPlateSolveService extends Mock implements PlateSolveService {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

Future<void> _pumpCard(
  WidgetTester tester, {
  required PlateSolverDetection detection,
  PlateSolverChoice choice = PlateSolverChoice.auto,
  PlateSolverInfo? verifyInfo,
  String? verifyError,
  PlateSolverInfo? astrometryVerifyInfo,
  String? astrometryVerifyError,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(900, 1200);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: SolverDetectionCard(
              detection: detection,
              choice: choice,
              astapVerifyInfo: verifyInfo,
              astapVerifyError: verifyError,
              astrometryVerifyInfo: astrometryVerifyInfo,
              astrometryVerifyError: astrometryVerifyError,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  registerFallbackValue(const PlateSolverPreference());

  group('SolverDetectionCard', () {
    testWidgets('shows install link when no solver is detected',
        (tester) async {
      await _pumpCard(
        tester,
        detection: const PlateSolverDetection(),
      );

      expect(
        find.textContaining('ASTAP not installed'),
        findsOneWidget,
        reason: 'Banner must call out missing ASTAP plainly',
      );
      expect(
        find.textContaining('Download ASTAP'),
        findsOneWidget,
        reason: 'Install link must surface so users can act on the banner',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows green ready banner with catalog when ASTAP found',
        (tester) async {
      await _pumpCard(
        tester,
        detection: const PlateSolverDetection(
          astapPath: r'C:\Program Files\astap\astap.exe',
          catalogName: 'V17',
          catalogMagnitudeLimit: 17.0,
          catalogPath: r'C:\Program Files\astap',
        ),
      );

      expect(
        find.textContaining('ASTAP detected'),
        findsOneWidget,
        reason: 'Ready banner must announce ASTAP detection',
      );
      expect(
        find.textContaining('V17'),
        findsOneWidget,
        reason: 'Catalog name must appear in the title',
      );
      expect(
        find.textContaining('mag 17'),
        findsOneWidget,
        reason: 'Magnitude limit must be formatted into the title',
      );
      expect(
        find.text(r'C:\Program Files\astap\astap.exe'),
        findsOneWidget,
        reason: 'Path must appear so user can confirm the right install',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows catalog-missing warning when ASTAP path has no catalog',
        (tester) async {
      await _pumpCard(
        tester,
        detection: const PlateSolverDetection(
          astapPath: '/opt/astap/astap',
        ),
      );

      expect(
        find.textContaining('catalog missing'),
        findsOneWidget,
        reason: 'Must surface the catalog-missing distinct state',
      );
      expect(
        find.text('/opt/astap/astap'),
        findsOneWidget,
        reason: 'Path must still surface so user can verify it',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('surfaces verify-info banner when verify succeeded',
        (tester) async {
      await _pumpCard(
        tester,
        detection: const PlateSolverDetection(
          astapPath: r'C:\Program Files\astap\astap.exe',
          catalogName: 'V17',
          catalogMagnitudeLimit: 17.0,
          catalogPath: r'C:\Program Files\astap',
        ),
        verifyInfo: const PlateSolverInfo(
          path: r'C:\Program Files\astap\astap.exe',
          flavour: 'ASTAP',
          versionLine: 'ASTAP version 2024.05.10',
        ),
      );

      expect(
        find.textContaining('ASTAP version 2024.05.10'),
        findsOneWidget,
        reason: 'Verify banner must surface the binary version line',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('surfaces verify error when verify failed', (tester) async {
      await _pumpCard(
        tester,
        detection: const PlateSolverDetection(
          astapPath: r'C:\Program Files\astap\astap.exe',
          catalogName: 'V17',
          catalogMagnitudeLimit: 17.0,
          catalogPath: r'C:\Program Files\astap',
        ),
        verifyError: 'astap.exe exited with status 127',
      );

      expect(
        find.textContaining('astap.exe exited with status 127'),
        findsOneWidget,
        reason: 'Verify error must render verbatim so user can diagnose',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('explicit Astrometry selection is not masked by ready ASTAP',
        (tester) async {
      await _pumpCard(
        tester,
        choice: PlateSolverChoice.astrometry,
        detection: const PlateSolverDetection(
          astapPath: '/opt/astap/astap',
          catalogPath: '/opt/astap',
        ),
      );

      expect(
        find.text('Selected Astrometry.net solver is not installed'),
        findsOneWidget,
      );
      expect(find.textContaining('ASTAP detected'), findsNothing);
    });

    testWidgets('Auto reports Astrometry fallback as ready', (tester) async {
      await _pumpCard(
        tester,
        detection: const PlateSolverDetection(
          astapPath: '/opt/astap/astap',
          astrometryPath: '/usr/bin/solve-field',
        ),
      );

      expect(
        find.text('Astrometry.net ready — Auto fallback active'),
        findsOneWidget,
      );
      expect(find.textContaining('catalog missing'), findsNothing);
    });

    testWidgets('surfaces Astrometry verification result', (tester) async {
      await _pumpCard(
        tester,
        choice: PlateSolverChoice.astrometry,
        detection: const PlateSolverDetection(
          astrometryPath: '/usr/bin/solve-field',
        ),
        astrometryVerifyInfo: const PlateSolverInfo(
          path: '/usr/bin/solve-field',
          flavour: 'Astrometry.net',
          versionLine: 'Revision 0.95',
        ),
      );

      expect(find.textContaining('Revision 0.95'), findsOneWidget);
    });
  });

  group('PlateSolvingSettingsScreen empty states', () {
    testWidgets(
        'renders the 3-step quick-start beneath the banner when no solver '
        'is detected', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 1400);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            inMemoryDatabaseOverride(),
            plateSolverDetectionProvider.overrideWith(
              (ref) async => const PlateSolverDetection(),
            ),
            plateSolverPreferenceProvider.overrideWith(
              (ref) async => const PlateSolverPreference(),
            ),
          ],
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: const PlateSolvingSettingsScreen(),
          ),
        ),
      );
      await tester.pump();
      // Settle the FutureProviders that the screen awaits.
      await tester.pump(const Duration(milliseconds: 200));

      // The detection card itself surfaces "ASTAP not installed".
      expect(
        find.textContaining('ASTAP not installed'),
        findsOneWidget,
        reason: 'Detection banner still surfaces the missing-solver title',
      );

      // The new quick-start panel adds the three guided steps.
      expect(find.text('Get started in 3 steps'), findsOneWidget);
      expect(find.text('Install ASTAP'), findsOneWidget);
      expect(find.text('Download a star catalog'), findsOneWidget);
      expect(find.text('Click re-scan'), findsOneWidget);
      expect(find.textContaining('V17 is recommended'), findsOneWidget);

      // Each step also exposes its own action button.
      expect(
        find.widgetWithText(SkotiqButton, 'Open ASTAP download page'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(SkotiqButton, 'Open ASTAP catalog page'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(SkotiqButton, 'Re-scan now'),
        findsOneWidget,
      );
    });

    testWidgets(
        'shows the catalog-missing hint with a "Browse for catalog '
        'directory" button when ASTAP is detected but no catalog',
        (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 1400);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            inMemoryDatabaseOverride(),
            plateSolverDetectionProvider.overrideWith(
              (ref) async => const PlateSolverDetection(
                astapPath: r'C:\Program Files\astap\astap.exe',
              ),
            ),
            plateSolverPreferenceProvider.overrideWith(
              (ref) async => const PlateSolverPreference(
                catalogPath: r'C:\Program Files\astap',
              ),
            ),
          ],
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: const PlateSolvingSettingsScreen(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(
        find.textContaining(r'Searching for catalogs in C:\Program Files'),
        findsOneWidget,
        reason: 'Catalog hint must name the directory being probed',
      );
      expect(
        find.widgetWithText(SkotiqButton, 'Browse for catalog directory'),
        findsOneWidget,
      );
      // The three-step quick-start must NOT render when ASTAP is detected.
      expect(find.text('Get started in 3 steps'), findsNothing);
    });
  });

  testWidgets('remote Browse edits and saves a path on the imaging host',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 1400);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final service = _MockPlateSolveService();
    when(() => service.setConfig(any())).thenAnswer((_) async {});

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, _MockNetworkBackend()),
          ),
          plateSolveServiceProvider.overrideWithValue(service),
          plateSolverDetectionProvider.overrideWith(
            (ref) async => const PlateSolverDetection(
              astapPath: '/host/old-astap',
              catalogPath: '/host/catalog',
            ),
          ),
          plateSolverPreferenceProvider.overrideWith(
            (ref) async => const PlateSolverPreference(
              astapPath: '/host/old-astap',
            ),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: PlateSolvingSettings()),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    final astapPathInput = find.byKey(
      const ValueKey('plate_solver_astap_path'),
    );
    final browseButton = find.descendant(
      of: astapPathInput,
      matching: find.byType(GestureDetector),
    );
    expect(browseButton, findsOneWidget);
    await tester.tap(browseButton);
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.text('ASTAP executable on imaging host'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Paths on this controlling device are not visible'),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey('remote_host_path_input')),
      '/host/new-astap',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('remote_host_path_submit')));
    await tester.pumpAndSettle();

    verify(
      () => service.setConfig(
        any(
          that: isA<PlateSolverPreference>().having(
            (preference) => preference.astapPath,
            'astapPath',
            '/host/new-astap',
          ),
        ),
      ),
    ).called(1);
    expect(find.text('Plate-solver settings saved.'), findsOneWidget);
  });

  group('PlateSolverChoice serialization', () {
    test('round-trips through serialized form', () {
      for (final choice in PlateSolverChoice.values) {
        final round = PlateSolverChoice.fromSerialized(choice.serialized);
        expect(round, choice);
      }
    });

    test('unknown values collapse to auto', () {
      expect(
          PlateSolverChoice.fromSerialized('nonsense'), PlateSolverChoice.auto);
      expect(PlateSolverChoice.fromSerialized(''), PlateSolverChoice.auto);
    });
  });

  group('PlateSolverDetection', () {
    test('hasAnySolver is false when nothing detected', () {
      const det = PlateSolverDetection();
      expect(det.hasAnySolver, false);
      expect(det.astapReady, false);
    });

    test('astapReady requires both executable and catalog', () {
      const noCatalog = PlateSolverDetection(astapPath: '/opt/astap/astap');
      expect(noCatalog.hasAnySolver, false);
      expect(noCatalog.astapReady, false);

      const ready = PlateSolverDetection(
        astapPath: '/opt/astap/astap',
        catalogPath: '/opt/astap',
      );
      expect(ready.hasAnySolver, true);
      expect(ready.astapReady, true);
    });

    test('astrometry counts as a usable solver without ASTAP', () {
      const det = PlateSolverDetection(astrometryPath: '/usr/bin/solve-field');
      expect(det.hasAnySolver, true);
      expect(det.astapReady, false);
    });
  });
}
