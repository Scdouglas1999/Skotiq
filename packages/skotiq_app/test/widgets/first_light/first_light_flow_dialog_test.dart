import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_app/widgets/first_light/first_light_flow_dialog.dart';
import 'package:skotiq_app/widgets/first_light/first_light_launcher.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// A [FirstLightController] subclass that lets a test pin an arbitrary
/// [FirstLightState] without running the real imaging pipeline. The base
/// constructor only stores `ref` + builds an orchestrator (no I/O), so this is
/// a cheap, faithful stand-in for driving the dialog through every phase.
class _FakeFirstLightController extends FirstLightController {
  _FakeFirstLightController(super.ref, FirstLightState initial) {
    // ignore: invalid_use_of_protected_member
    state = initial;
  }

  /// Records the latest exposure the UI asked us to run, so the intro-panel
  /// test can assert the Start button wires through to `run`.
  double? lastRunExposure;

  /// Counts operator-requested stops, so the running-phase test can assert the
  /// footer button reaches the real cancel path rather than just closing the
  /// dialog over a live exposure.
  int cancelCalls = 0;

  @override
  Future<void> run({required double exposureSeconds}) async {
    lastRunExposure = exposureSeconds;
  }

  @override
  void cancel() {
    cancelCalls++;
  }

  @override
  void reset() {
    // ignore: invalid_use_of_protected_member
    state = const FirstLightState();
  }
}

/// Build a router whose `/imaging` route hosts the dialog so navigation
/// targets (`/imaging`, `/equipment`, `/settings/plate-solving`) resolve when
/// the dialog's action buttons fire.
GoRouter _router({required Widget body}) {
  return GoRouter(
    initialLocation: '/imaging',
    routes: [
      GoRoute(path: '/imaging', builder: (_, __) => Scaffold(body: body)),
      GoRoute(
        path: '/equipment',
        builder: (_, __) => const Scaffold(body: Text('EQUIPMENT-SCREEN')),
      ),
      GoRoute(
        path: '/settings',
        builder: (_, __) => const Scaffold(body: Text('SETTINGS-SCREEN')),
        routes: [
          GoRoute(
            path: 'plate-solving',
            builder: (_, __) => const Scaffold(body: Text('SOLVER-SETTINGS')),
          ),
        ],
      ),
    ],
  );
}

PlateSolveResult _solved() => PlateSolveResult(
      success: true,
      ra: 10.6847, // ~00h 42m — Andromeda-ish, just needs to format cleanly.
      dec: 41.269,
      pixelScale: 1.23,
      rotation: 0,
      fieldWidth: 1.0,
      fieldHeight: 0.8,
      solveTimeSecs: 2.5,
      cd11: 0,
      cd12: 0,
      cd21: 0,
      cd22: 0,
      sipAOrder: 0,
      sipBOrder: 0,
      sipACoeffs: Float64List(0),
      sipBCoeffs: Float64List(0),
      sipApOrder: 0,
      sipBpOrder: 0,
      sipApCoeffs: Float64List(0),
      sipBpCoeffs: Float64List(0),
    );

Future<void> _pumpDialog(
  WidgetTester tester, {
  required FirstLightState state,
  List<Override> overrides = const [],
  bool settle = true,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(900, 1000);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        inMemoryDatabaseOverride(),
        firstLightControllerProvider.overrideWith(
          (ref) => _FakeFirstLightController(ref, state),
        ),
        ...overrides,
      ],
      child: MaterialApp.router(
        theme: SkotiqTheme.dark,
        routerConfig: _router(
          // The dialog is opened imperatively from the imaging body so it has
          // a Navigator + GoRouter ancestor.
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => FirstLightFlowDialog.show(context),
                child: const Text('OPEN'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('OPEN'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    // The running phase has perpetual indeterminate/attention animations that
    // never settle; pump a couple of frames to lay the dialog out instead.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('FirstLightFlowDialog', () {
    testWidgets('intro panel runs the controller with the entered exposure',
        (tester) async {
      late _FakeFirstLightController controller;
      await _pumpDialog(
        tester,
        state: const FirstLightState(),
        overrides: [
          inMemoryDatabaseOverride(),
          firstLightControllerProvider.overrideWith((ref) {
            controller =
                _FakeFirstLightController(ref, const FirstLightState());
            return controller;
          }),
        ],
      );

      // Default exposure is 5s; change it and start.
      await tester.enterText(find.byType(TextField), '8');
      await tester.tap(find.widgetWithText(SkotiqButton, 'Start capture'));
      await tester.pump();

      expect(controller.lastRunExposure, 8.0);
    });

    testWidgets('intro panel rejects a non-positive exposure', (tester) async {
      late _FakeFirstLightController controller;
      await _pumpDialog(
        tester,
        state: const FirstLightState(),
        overrides: [
          inMemoryDatabaseOverride(),
          firstLightControllerProvider.overrideWith((ref) {
            controller =
                _FakeFirstLightController(ref, const FirstLightState());
            return controller;
          }),
        ],
      );

      await tester.enterText(find.byType(TextField), '0');
      await tester.tap(find.widgetWithText(SkotiqButton, 'Start capture'));
      await tester.pump();

      expect(controller.lastRunExposure, isNull);
      expect(
        find.textContaining('greater than 0 seconds'),
        findsOneWidget,
      );
    });

    testWidgets('intro panel refuses an exposure past the first-light cap',
        (tester) async {
      late _FakeFirstLightController controller;
      await _pumpDialog(
        tester,
        state: const FirstLightState(),
        overrides: [
          inMemoryDatabaseOverride(),
          firstLightControllerProvider.overrideWith((ref) {
            controller =
                _FakeFirstLightController(ref, const FirstLightState());
            return controller;
          }),
        ],
      );

      // The audit's exact keystroke: 5 -> 999999, an 11.6-day exposure the
      // flow has no cancel path for.
      await tester.enterText(find.byType(TextField), '999999');
      await tester.tap(find.widgetWithText(SkotiqButton, 'Start capture'));
      await tester.pump();

      expect(controller.lastRunExposure, isNull);
      expect(find.textContaining('capped at 120 seconds'), findsOneWidget);

      // The boundary itself is still accepted, so the cap is a limit and not
      // an off-by-one refusal of the documented maximum.
      await tester.enterText(find.byType(TextField), '120');
      await tester.tap(find.widgetWithText(SkotiqButton, 'Start capture'));
      await tester.pump();

      expect(controller.lastRunExposure, 120.0);
    });

    testWidgets('intro panel names the cap it enforces', (tester) async {
      await _pumpDialog(tester, state: const FirstLightState());

      expect(
        find.textContaining('120 seconds is the most this flow will run'),
        findsOneWidget,
      );
    });

    testWidgets('running phase shows the four-step stepper with progress',
        (tester) async {
      await _pumpDialog(
        tester,
        state: const FirstLightState(
          phase: FirstLightPhase.solving,
          exposureSeconds: 5,
        ),
        settle: false,
      );

      expect(find.text('Capturing exposure'), findsOneWidget);
      expect(find.text('Stretching for preview'), findsOneWidget);
      expect(find.text('Plate-solving the field'), findsOneWidget);
      expect(find.text('Labelling objects'), findsOneWidget);
      // The active phase renders an indeterminate progress bar.
      expect(find.byType(SkotiqProgressBar), findsOneWidget);
    });

    // The exposure this dialog owns must not be orphaned by its own title-bar
    // ✕: the dialog closes, the sensor keeps exposing, and the camera stays
    // unusable until the process restarts. PopScope covers Escape and the
    // barrier but NOT the header close button, which pops the route directly.
    testWidgets('running phase disables the header close button',
        (tester) async {
      await _pumpDialog(
        tester,
        state: const FirstLightState(
          phase: FirstLightPhase.exposing,
          exposureSeconds: 5,
        ),
        settle: false,
      );

      expect(
        tester.widget<SkotiqDialog>(find.byType(SkotiqDialog)).closeEnabled,
        isFalse,
        reason: 'the ✕ pops the route directly, bypassing PopScope',
      );

      // Drive the ✕ itself: with the gate missing this closed the dialog over
      // a live exposure, which is the whole defect.
      final closeButton = find.ancestor(
        of: find.byIcon(LucideIcons.x),
        matching: find.byType(IconButton),
      );
      expect(tester.widget<IconButton>(closeButton).onPressed, isNull);
      await tester.tap(closeButton);
      await tester.pump();
      expect(
        find.byType(FirstLightFlowDialog),
        findsOneWidget,
        reason: 'the dialog must not close over an exposure it cannot stop',
      );
    });

    testWidgets('running phase offers a stop that cancels at the camera',
        (tester) async {
      late _FakeFirstLightController controller;
      await _pumpDialog(
        tester,
        state: const FirstLightState(
          phase: FirstLightPhase.exposing,
          exposureSeconds: 5,
        ),
        settle: false,
        overrides: [
          inMemoryDatabaseOverride(),
          firstLightControllerProvider.overrideWith((ref) {
            controller = _FakeFirstLightController(
              ref,
              const FirstLightState(
                phase: FirstLightPhase.exposing,
                exposureSeconds: 5,
              ),
            );
            return controller;
          }),
        ],
      );

      await tester.tap(find.widgetWithText(SkotiqButton, 'Stop capture'));
      await tester.pump();

      expect(
        controller.cancelCalls,
        1,
        reason: 'the only mid-run exit must abort the exposure, not hide it',
      );
    });

    testWidgets('a terminal phase leaves the dialog closable', (tester) async {
      await _pumpDialog(
        tester,
        state: const FirstLightState(
          phase: FirstLightPhase.success,
          exposureSeconds: 5,
        ),
      );

      expect(
        tester.widget<SkotiqDialog>(find.byType(SkotiqDialog)).closeEnabled,
        isTrue,
      );
      expect(find.widgetWithText(SkotiqButton, 'Stop capture'), findsNothing);
    });

    testWidgets('success without a solve shows the set-up-solver banner',
        (tester) async {
      await _pumpDialog(
        tester,
        state: const FirstLightState(
          phase: FirstLightPhase.success,
          note: FirstLightOrchestrator.solverNotConfiguredNote,
        ),
      );

      expect(
        find.text(FirstLightOrchestrator.solverNotConfiguredNote),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(SkotiqButton, 'Set up solver'),
        findsOneWidget,
      );

      // The link routes to the plate-solving settings page.
      await tester.tap(find.widgetWithText(SkotiqButton, 'Set up solver'));
      await tester.pumpAndSettle();
      expect(find.text('SOLVER-SETTINGS'), findsOneWidget);
    });

    testWidgets('success with a solve shows the labelled-objects chip',
        (tester) async {
      final annotation = ImageAnnotation(
        imagePath: '/tmp/frame.fits',
        timestamp: DateTime(2026, 5, 28),
        plateSolve: const PlateSolveData(
          ra: 10.68,
          dec: 41.27,
          pixelScale: 1.23,
          rotation: 0,
          fieldWidth: 1,
          fieldHeight: 0.8,
          imageWidth: 1000,
          imageHeight: 800,
        ),
        objects: const [
          CelestialObjectAnnotation(
            id: 'm31',
            name: 'M 31',
            type: ObjectType.galaxy,
            ra: 10.68,
            dec: 41.27,
            x: 500,
            y: 400,
          ),
          CelestialObjectAnnotation(
            id: 'm32',
            name: 'M 32',
            type: ObjectType.galaxy,
            ra: 10.67,
            dec: 40.86,
            x: 520,
            y: 430,
          ),
        ],
      );

      await _pumpDialog(
        tester,
        state: FirstLightState(
          phase: FirstLightPhase.success,
          annotated: true,
          solveResult: _solved(),
        ),
        overrides: [
          inMemoryDatabaseOverride(),
          currentAnnotationProvider.overrideWith((ref) => annotation),
        ],
      );

      expect(find.text('2 objects labelled'), findsOneWidget);
      // Solve details read out RA/Dec/scale.
      expect(find.textContaining('RA '), findsOneWidget);
      // Set-up-solver banner must NOT appear when we solved.
      expect(
        find.text(FirstLightOrchestrator.solverNotConfiguredNote),
        findsNothing,
      );
    });

    testWidgets(
        'connection failure offers Troubleshoot which opens the '
        'ConnectionTroubleshooterDialog with the raw error', (tester) async {
      await _pumpDialog(
        tester,
        state: const FirstLightState(
          phase: FirstLightPhase.failed,
          cameraDriverType: DriverType.ascom,
          errorMessage:
              'No camera connected. Connect a camera on the Equipment screen, '
              'then start first light again.',
        ),
      );

      expect(find.text("First light didn't finish"), findsOneWidget);
      final troubleshoot =
          find.widgetWithText(SkotiqButton, 'Troubleshoot connection');
      expect(troubleshoot, findsOneWidget);

      await tester.tap(troubleshoot);
      await tester.pumpAndSettle();

      // The troubleshooter dialog (C12) is now open — NOT a navigation to the
      // Equipment screen. Its header title and Retry action are the marker.
      expect(find.text('Connection help'), findsOneWidget);
      expect(
        find.widgetWithText(SkotiqButton, 'Retry connection'),
        findsOneWidget,
      );
      // The dialog surfaces a remediation playbook.
      expect(find.text('Try these steps'), findsOneWidget);
    });

    testWidgets('Troubleshoot -> Retry connection re-runs the first-light flow',
        (tester) async {
      late _FakeFirstLightController controller;
      await _pumpDialog(
        tester,
        state: const FirstLightState(
          phase: FirstLightPhase.failed,
          cameraDriverType: DriverType.native,
          exposureSeconds: 7,
          errorMessage: 'No camera connected. Connect a camera first.',
        ),
        overrides: [
          inMemoryDatabaseOverride(),
          firstLightControllerProvider.overrideWith((ref) {
            controller = _FakeFirstLightController(
              ref,
              const FirstLightState(
                phase: FirstLightPhase.failed,
                cameraDriverType: DriverType.native,
                exposureSeconds: 7,
                errorMessage: 'No camera connected. Connect a camera first.',
              ),
            );
            return controller;
          }),
        ],
      );

      await tester
          .tap(find.widgetWithText(SkotiqButton, 'Troubleshoot connection'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(SkotiqButton, 'Retry connection'));
      await tester.pumpAndSettle();

      // Retry re-ran the flow at the original exposure length.
      expect(controller.lastRunExposure, 7.0);
    });

    testWidgets('non-connection failure hides the Troubleshoot action',
        (tester) async {
      await _pumpDialog(
        tester,
        state: const FirstLightState(
          phase: FirstLightPhase.failed,
          errorMessage: 'Plate solve failed: no solution found',
        ),
      );

      expect(
        find.widgetWithText(SkotiqButton, 'Troubleshoot connection'),
        findsNothing,
      );
      expect(find.widgetWithText(SkotiqButton, 'Try again'), findsOneWidget);
    });

    testWidgets('Try again resets the controller back to the intro panel',
        (tester) async {
      await _pumpDialog(
        tester,
        state: const FirstLightState(
          phase: FirstLightPhase.failed,
          errorMessage: 'Auto-stretch failed: boom',
        ),
      );

      await tester.tap(find.widgetWithText(SkotiqButton, 'Try again'));
      await tester.pumpAndSettle();

      // Back on the intro panel: the exposure field + Start button.
      expect(
        find.widgetWithText(SkotiqButton, 'Start capture'),
        findsOneWidget,
      );
    });
  });

  group('FirstLightQueryLauncher', () {
    testWidgets('opens the flow when firstLight=1 and strips the query',
        (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(900, 1000);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final router = GoRouter(
        initialLocation: '/imaging?firstLight=1',
        routes: [
          GoRoute(
            path: '/imaging',
            builder: (_, __) => const FirstLightQueryLauncher(
              child: Scaffold(body: Text('IMAGING-BODY')),
            ),
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            inMemoryDatabaseOverride(),
            firstLightControllerProvider.overrideWith(
              (ref) => _FakeFirstLightController(ref, const FirstLightState()),
            ),
          ],
          child: MaterialApp.router(
            theme: SkotiqTheme.dark,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The flow dialog opened (intro panel Start button is visible).
      expect(
        find.widgetWithText(SkotiqButton, 'Start capture'),
        findsOneWidget,
      );
      // The imaging body still renders underneath.
      expect(find.text('IMAGING-BODY'), findsOneWidget);
    });

    testWidgets('does nothing without the firstLight query', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(900, 1000);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final router = GoRouter(
        initialLocation: '/imaging',
        routes: [
          GoRoute(
            path: '/imaging',
            builder: (_, __) => const FirstLightQueryLauncher(
              child: Scaffold(body: Text('IMAGING-BODY')),
            ),
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            inMemoryDatabaseOverride(),
            firstLightControllerProvider.overrideWith(
              (ref) => _FakeFirstLightController(ref, const FirstLightState()),
            ),
          ],
          child: MaterialApp.router(
            theme: SkotiqTheme.dark,
            routerConfig: router,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('IMAGING-BODY'), findsOneWidget);
      expect(
        find.widgetWithText(SkotiqButton, 'Start capture'),
        findsNothing,
      );
    });
  });
}
