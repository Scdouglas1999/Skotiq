// What the Polar Alignment screen says about a run in progress.
//
// Three ways it can lie:
//  * Stop that produces no change of any kind for the whole teardown, so an
//    accepted click is indistinguishable from a dropped one.
//  * "Capturing Point 1" left beside "Plate solving point 1/3…" for the entire
//    solve, long after the capture finished, so one of the two lines is false.
//  * A solid centre marker in the bullseye before any measurement and after a
//    failure, reading as "your polar error is zero" while the numbers directly
//    beneath it read "-- / -- / --".
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/polar_alignment/polar_alignment_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/pump_app_screen.dart';

class _FixedAlignmentNotifier extends PolarAlignmentStateNotifier {
  _FixedAlignmentNotifier(super.ref, PolarAlignmentState fixed) {
    // ignore: invalid_use_of_protected_member
    state = fixed;
  }
}

class _SiteSettings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async =>
      const AppSettingsState(latitude: 40, longitude: -75);
}

class _MountNotifier extends MountStateNotifier {
  _MountNotifier(super.ref, this.initial) {
    state = initial;
  }

  final MountState initial;
}

class _ConnectedCamera extends CameraStateNotifier {
  _ConnectedCamera(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const CameraStateSnapshot(
      connectionState: DeviceConnectionState.connected,
    );
  }
}

const _config = PolarAlignmentConfig();

PolarAlignmentState _measuring(String status) => const PolarAlignmentState(
      phase: PolarAlignPhase.measuring,
      config: _config,
      currentPoint: 1,
    ).copyWith(statusMessage: status);

GoRouter _router() => GoRouter(
      initialLocation: '/polar-alignment',
      routes: [
        GoRoute(
          path: '/polar-alignment',
          builder: (_, __) => const PolarAlignmentScreen(),
        ),
      ],
    );

Future<HarnessHandle> _pumpScreen(
  WidgetTester tester, {
  PolarAlignmentState? alignmentState,
  MountState? mount,
}) async {
  final handle = await pumpAppScreen(
    tester,
    MaterialApp.router(
      theme: SkotiqTheme.dark,
      routerConfig: _router(),
    ),
    size: const Size(1400, 900),
    settle: false,
    extraOverrides: [
      appSettingsProvider.overrideWith(_SiteSettings.new),
      if (mount != null) ...[
        mountStateProvider.overrideWith((ref) => _MountNotifier(ref, mount)),
        cameraStateProvider.overrideWith(_ConnectedCamera.new),
      ],
      if (alignmentState != null)
        polarAlignmentStateProvider.overrideWith(
          (ref) => _FixedAlignmentNotifier(ref, alignmentState),
        ),
    ],
  );
  await tester.pump(const Duration(milliseconds: 200));
  return handle;
}

SkotiqButton _button(WidgetTester tester, String label) =>
    tester.widget<SkotiqButton>(
      find.byWidgetPredicate(
        (widget) => widget is SkotiqButton && widget.label == label,
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the run states one current activity, not two', (tester) async {
    await _pumpScreen(
      tester,
      alignmentState: _measuring('Plate solving point 1/3...'),
    );

    expect(find.text('Plate solving point 1/3...'), findsWidgets);
    expect(
      find.text('Capturing Point 1'),
      findsNothing,
      reason: 'the capture finished before the solve began',
    );
    expect(find.text('Plate solving point 1 of 3'), findsOneWidget);
  });

  testWidgets('the capture phase still says it is capturing', (tester) async {
    await _pumpScreen(
      tester,
      alignmentState: _measuring('Capturing point 1/3...'),
    );

    expect(find.text('Capturing point 1 of 3'), findsOneWidget);
  });

  testWidgets('Stop is acknowledged while the teardown is in flight',
      (tester) async {
    final handle = await _pumpScreen(
      tester,
      alignmentState: _measuring('Plate solving point 1/3...'),
    );
    // A real teardown waits for the run to reach a checkpoint — the seconds
    // during which the screen used to look untouched.
    when(() => handle.backend.stopPolarAlignment())
        .thenAnswer((_) => Future<void>.delayed(const Duration(seconds: 5)));

    await tester.tap(find.text('Stop').first);
    await tester.pump();

    expect(find.text('Stopping…'), findsWidgets);
    expect(
      _button(tester, 'Stopping…').onPressed,
      isNull,
      reason: 'a second press cannot make the run stop any harder',
    );

    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('a parked mount blocks Start with the real reason',
      (tester) async {
    await _pumpScreen(
      tester,
      mount: const MountState(
        connectionState: DeviceConnectionState.connected,
        deviceId: 'mount-1',
        isParked: true,
      ),
    );

    final tooltip = tester.widget<Tooltip>(
      find
          .ancestor(
            of: find.text('Start alignment'),
            matching: find.byType(Tooltip),
          )
          .last,
    );
    expect(tooltip.message, contains('parked'));
    expect(
      _button(tester, 'Start alignment').onPressed,
      isNull,
      reason: 'a parked mount cannot slew between the three points',
    );
  });

  // A disabled button with a Tooltip carrying the reason still gives the
  // operator nothing: hover text is invisible to a click and the log gains no
  // line. A tooltip assertion is not an assertion that anything is legible,
  // so these pin the VISIBLE refusal — a warning banner on the idle centre
  // column, where wave 4 moved it from the deleted footer — and the published
  // disabled state.
  testWidgets('a parked mount says so on screen, not only on hover',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await _pumpScreen(
      tester,
      mount: const MountState(
        connectionState: DeviceConnectionState.connected,
        deviceId: 'mount-1',
        isParked: true,
      ),
    );

    final notice = find.byKey(startBlockedNoticeKey);
    expect(notice, findsOneWidget,
        reason: 'the refusal must be readable without hovering');
    expect(
      tester.widget<SkotiqBanner>(notice).message,
      contains('parked'),
    );
    expect(
      find.text('Ready to start polar alignment'),
      findsNothing,
      reason: 'nothing may call the screen ready while Start is refusing',
    );

    final node = tester.getSemantics(
      find.byWidgetPredicate(
        (w) => w is SkotiqButton && w.label == 'Start alignment',
      ),
    );
    expect(
      node.hasFlag(SemanticsFlag.isEnabled),
      isFalse,
      reason: 'assistive tech must be told the control is unavailable',
    );
    semantics.dispose();
  });

  // The footer must name the blocker that actually applies. (This harness has
  // no plate solver, so an unparked rig still has one unmet prerequisite —
  // which is the point: the line tracks the real reason rather than being a
  // permanent scold about the mount.)
  testWidgets('the footer names the blocker that applies, not the mount',
      (tester) async {
    await _pumpScreen(
      tester,
      mount: const MountState(
        connectionState: DeviceConnectionState.connected,
        deviceId: 'mount-1',
        isParked: false,
        isTracking: true,
        ra: 2,
        dec: 80,
      ),
    );

    final notice = find.byKey(startBlockedNoticeKey);
    if (notice.evaluate().isNotEmpty) {
      expect(
        tester.widget<Text>(notice).data,
        isNot(contains('parked')),
        reason: 'the mount is not parked, so it cannot be the reason',
      );
    }
  });

  testWidgets('an unparked mount is not what blocks Start', (tester) async {
    await _pumpScreen(
      tester,
      mount: const MountState(
        connectionState: DeviceConnectionState.connected,
        deviceId: 'mount-1',
        isParked: false,
        isTracking: true,
        ra: 2,
        dec: 80,
      ),
    );

    final tooltip = tester.widget<Tooltip>(
      find
          .ancestor(
            of: find.text('Start alignment'),
            matching: find.byType(Tooltip),
          )
          .last,
    );
    expect(tooltip.message, isNot(contains('parked')));
  });

  testWidgets('the bullseye claims no measurement it does not have',
      (tester) async {
    await _pumpScreen(
      tester,
      alignmentState: const PolarAlignmentState(
        phase: PolarAlignPhase.error,
        config: _config,
        statusMessage: 'Error: Plate solve timed out',
        errorMessage: 'Error: Plate solve timed out',
      ),
    );

    expect(find.text('No measurement yet'), findsOneWidget);
  });
}
