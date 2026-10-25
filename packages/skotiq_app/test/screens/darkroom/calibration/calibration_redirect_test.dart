import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/darkroom/calibration/calibration_library_panel.dart';
import 'package:skotiq_app/screens/settings/settings_catalog.dart';
import 'package:skotiq_app/screens/settings/widgets/calibration_redirect.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the old Settings calibration pages', () {
    test('every old link lands on the Calibration tab', () {
      for (final section in [
        'calibration',
        'dark-library',
        'calibration-library',
      ]) {
        expect(
          calibrationSettingsRedirect(Uri.parse('/settings?section=$section')),
          '/darkroom?tab=calibration',
          reason: section,
        );
      }
      expect(
        calibrationSettingsRedirect(Uri.parse('/settings?section=imaging')),
        isNull,
      );
      expect(calibrationSettingsRedirect(Uri.parse('/settings')), isNull);
    });

    test('the merged keys resolve to the one Calibration entry', () {
      expect(resolveSectionKey('dark-library'), 'calibration');
      expect(resolveSectionKey('calibration-library'), 'calibration');
      expect(resolveSectionKey('calibration'), 'calibration');
    });

    testWidgets('opening the Settings entry goes to the Calibration tab', (
      tester,
    ) async {
      final router = GoRouter(
        initialLocation: '/settings',
        routes: [
          GoRoute(
            path: '/settings',
            builder: (_, __) =>
                const Scaffold(body: CalibrationSettingsRedirect()),
          ),
          GoRoute(
            path: '/darkroom',
            builder: (_, state) => Scaffold(
              body: Text('darkroom ${state.uri.queryParameters['tab']}'),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MaterialApp.router(theme: SkotiqTheme.dark, routerConfig: router),
      );
      await tester.pumpAndSettle();

      expect(find.text('darkroom calibration'), findsOneWidget);
    });
  });

  testWidgets(
      'clearing the library cannot reach a rig selected after the '
      'dialog opened', (tester) async {
    final hostA = _MockNetworkBackend();
    final hostB = _MockNetworkBackend();
    for (final host in [hostA, hostB]) {
      when(
        () => host.getCalibrationMasters(type: any(named: 'type')),
      ).thenAnswer((_) async => const []);
      when(
        () => host.listDarks(),
      ).thenAnswer((_) async => const <RemoteDarkLibraryEntry>[]);
    }
    late _SwappableBackendNotifier notifier;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backendProvider.overrideWith((ref) {
            notifier = _SwappableBackendNotifier(ref, hostA);
            return notifier;
          }),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: SingleChildScrollView(child: CalibrationLibraryPanel()),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byTooltip('Library upkeep'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear the dark and bias library'));
    await tester.pumpAndSettle();
    expect(find.text('Clear the dark and bias library?'), findsOneWidget);

    notifier.switchTo(hostB);
    await tester.pump();
    await tester.tap(find.widgetWithText(SkotiqButton, 'Clear'));
    await tester.pumpAndSettle();

    verifyNever(
      () => hostA.clearDarkLibrary(deleteFiles: any(named: 'deleteFiles')),
    );
    verifyNever(
      () => hostB.clearDarkLibrary(deleteFiles: any(named: 'deleteFiles')),
    );
    expect(find.textContaining('the library was not cleared'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
