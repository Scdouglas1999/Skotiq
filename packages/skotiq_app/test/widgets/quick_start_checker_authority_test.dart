import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/router/app_router.dart';
import 'package:skotiq_app/widgets/quick_start_checker.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _RecordingNetworkBackend extends Mock implements NetworkBackend {
  int discardCalls = 0;

  @override
  Future<void> discardCheckpoint() async {
    discardCalls++;
  }
}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

QuickStartContext _context({EquipmentSnapshot? equipmentSnapshot}) =>
    QuickStartContext(
      sessionId: 7,
      sessionName: 'Host A night',
      targetName: 'M31',
      sequenceName: 'M31 sequence',
      completedFrames: 12,
      totalFrames: 20,
      lastSessionDate: DateTime.now().subtract(const Duration(minutes: 10)),
      equipmentSnapshot: equipmentSnapshot,
      totalIntegrationHours: 1.2,
      canResumeFromCheckpoint: true,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('production outer-wrapper topology can show quick start',
      (tester) async {
    final backend = _RecordingNetworkBackend();
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => const Scaffold(body: Text('Dashboard')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          appRouterProvider.overrideWithValue(router),
          backendProvider.overrideWith(
            (ref) => _SwappableBackendNotifier(ref, backend),
          ),
          incompleteSessionsProvider.overrideWith(
            (ref) async => const <SessionRecoveryInfo>[],
          ),
          quickStartContextProvider.overrideWith((ref) async => _context()),
        ],
        child: QuickStartChecker(
          child: MaterialApp.router(
            theme: SkotiqTheme.dark,
            routerConfig: router,
          ),
        ),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(find.text('Start fresh'), findsOneWidget);
  });

  testWidgets('quick-start dialog closes and cannot discard after host switch',
      (tester) async {
    final hostA = _RecordingNetworkBackend();
    final hostB = _RecordingNetworkBackend();
    late _SwappableBackendNotifier notifier;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith((ref) {
            notifier = _SwappableBackendNotifier(ref, hostA);
            return notifier;
          }),
          incompleteSessionsProvider.overrideWith(
            (ref) async => const <SessionRecoveryInfo>[],
          ),
          quickStartContextProvider.overrideWith((ref) async {
            final backend = ref.watch(backendProvider);
            return identical(backend, hostA) ? _context() : null;
          }),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const QuickStartChecker(
            child: Scaffold(body: Text('Dashboard')),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.text('Start fresh'), findsOneWidget);

    notifier.switchTo(hostB);
    await tester.tap(find.text('Start fresh'), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(find.text('Start fresh'), findsNothing);
    expect(hostA.discardCalls, 0);
    expect(hostB.discardCalls, 0);
  });

  testWidgets('start fresh warns when saved device positions are skipped', (
    tester,
  ) async {
    final backend = _RecordingNetworkBackend();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _SwappableBackendNotifier(ref, backend),
          ),
          incompleteSessionsProvider.overrideWith(
            (ref) async => const <SessionRecoveryInfo>[],
          ),
          quickStartContextProvider.overrideWith(
            (ref) async => _context(
              equipmentSnapshot: EquipmentSnapshot(
                filterPosition: 2,
                focuserPosition: 12000,
                capturedAt: DateTime(2026),
              ),
            ),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const QuickStartChecker(
            child: Scaffold(body: Text('Dashboard')),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Start fresh'));
    await tester.tap(find.text('Start fresh'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining(
        'could not restore: filter wheel (not connected), '
        'focuser (not connected)',
      ),
      findsOneWidget,
    );
    expect(backend.discardCalls, 1);
  });

  testWidgets('start fresh does not claim a restore it could not perform', (
    tester,
  ) async {
    final backend = _RecordingNetworkBackend();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _SwappableBackendNotifier(ref, backend),
          ),
          incompleteSessionsProvider.overrideWith(
            (ref) async => const <SessionRecoveryInfo>[],
          ),
          // The session row records no profile id, no sequence id and no
          // equipment snapshot — which is what the dialog is already saying
          // when it prints 'Unknown Profile' / 'No Sequence'. The handler has
          // nothing to restore, so it must not report a successful restore.
          quickStartContextProvider.overrideWith((ref) async => _context()),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const QuickStartChecker(
            child: Scaffold(body: Text('Dashboard')),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Start fresh'));
    await tester.tap(find.text('Start fresh'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Nothing to load'), findsOneWidget);
    expect(find.textContaining('Loaded previous setup'), findsNothing);
    expect(find.textContaining('from frame 1'), findsNothing);
  });

  testWidgets('start fresh re-applies the recorded camera settings', (
    tester,
  ) async {
    final backend = _RecordingNetworkBackend();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _SwappableBackendNotifier(ref, backend),
          ),
          incompleteSessionsProvider.overrideWith(
            (ref) async => const <SessionRecoveryInfo>[],
          ),
          // The snapshot the session row now carries (see
          // SessionStateNotifier._recordEquipmentSnapshot). The whole point of
          // the button is that these land back on the capture settings — a
          // snackbar saying so is not a restore.
          quickStartContextProvider.overrideWith(
            (ref) async => _context(
              equipmentSnapshot: EquipmentSnapshot(
                coolerTargetTemp: -12.5,
                cameraGain: 250,
                cameraOffset: 33,
                capturedAt: DateTime(2026),
              ),
            ),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const QuickStartChecker(
            child: Scaffold(body: Text('Dashboard')),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Start fresh'));
    await tester.tap(find.text('Start fresh'));
    await tester.pumpAndSettle();

    final container = ProviderScope.containerOf(
      tester.element(find.text('Dashboard')),
    );
    expect(container.read(exposureSettingsProvider).gain, 250);
    expect(container.read(exposureSettingsProvider).offset, 33);
    expect(container.read(cameraStateProvider).targetTemp, -12.5);
    expect(find.textContaining('gain/offset'), findsOneWidget);
  });
}
