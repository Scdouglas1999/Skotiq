// The Mount tab: Park and Set park only after an explicit confirmation,
// Flip asks a running run to flip and is refused while it is paused, Home's
// caution, and the 300 px layout.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/panel/mount/night_mount_tab.dart';
import 'package:skotiq_app/services/mount_command_service.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../../harness/harness.dart';
import '../scope_panel_test_support.dart';

const _park = ValueKey<String>('nightMount.park');
const _flip = ValueKey<String>('nightMount.flip');
const _home = ValueKey<String>('nightMount.home');
const _setPark = ValueKey<String>('nightMount.setPark');

RecordingMountCommands _commands(HarnessHandle handle) =>
    handle.container.read(mountCommandServiceProvider)
        as RecordingMountCommands;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders the board sections at 300 x 758', (tester) async {
    await pumpPanelTab(tester, const NightMountTab(),
        overrides: panelOverrides());
    expectCleanLayout(tester);
    expect(find.text('Position'), findsOneWidget);
    expect(find.text('Tracking · Sidereal'), findsOneWidget);
    expect(find.text('Move'), findsOneWidget);
    expect(find.text('Go to'), findsOneWidget);
    expect(find.text('NYX-101'), findsOneWidget);
    expect(find.text('01h37m58s'), findsOneWidget);
    expect(find.text('Set park'), findsOneWidget);
    expect(find.textContaining('Swap E/W'), findsNothing);
  });

  testWidgets('lays out at 1.3x text without overflow', (tester) async {
    await pumpPanelTab(
      tester,
      const NightMountTab(),
      overrides: panelOverrides(),
      textScale: 1.3,
    );
    expectCleanLayout(tester);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -2000));
    await tester.pump();
    expectCleanLayout(tester);
  });

  group('Park', () {
    testWidgets('asks first and does nothing when cancelled', (tester) async {
      final handle = await pumpPanelTab(
        tester,
        const NightMountTab(),
        overrides: panelOverrides(),
      );
      await tester.ensureVisible(find.byKey(_park));
      await tester.tap(find.byKey(_park));
      await tester.pumpAndSettle();

      expect(find.text('Park the mount?'), findsOneWidget);
      expect(_commands(handle).calls, isNot(contains('park')),
          reason: 'opening the dialog must not park');

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(_commands(handle).calls, isNot(contains('park')));
      expect(_commands(handle).calls, isNot(contains('togglePark')));
    });

    testWidgets('parks once the operator confirms', (tester) async {
      final handle = await pumpPanelTab(
        tester,
        const NightMountTab(),
        overrides: panelOverrides(),
      );
      await tester.ensureVisible(find.byKey(_park));
      await tester.tap(find.byKey(_park));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.text('Park'),
        ),
      );
      await tester.pumpAndSettle();
      expect(_commands(handle).calls, ['park']);
    });

    testWidgets('during a run the confirmation says what parking does to it',
        (tester) async {
      final handle = await pumpPanelTab(
        tester,
        const NightMountTab(),
        overrides: panelOverrides(
          inputs: panelInputs(runState: SequenceExecutionState.running),
        ),
      );
      await tester.ensureVisible(find.byKey(_park));
      await tester.tap(find.byKey(_park));
      await tester.pumpAndSettle();
      expect(find.textContaining('The run is still loaded'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(_commands(handle).calls, isEmpty);
    });
  });

  testWidgets('Flip now asks a running run to flip', (tester) async {
    final api = RecordingActionApi();
    await pumpPanelTab(
      tester,
      const NightMountTab(),
      overrides: panelOverrides(
        api: api,
        inputs: panelInputs(runState: SequenceExecutionState.running),
      ),
    );
    await tester.ensureVisible(find.byKey(_flip));
    expect(isEnabled(tester, _flip), isTrue);
    await tester.tap(find.byKey(_flip));
    await tester.pump();
    expect(api.calls, ['flipNow']);
  });

  testWidgets('Flip now is disabled while the run is paused and says why',
      (tester) async {
    final api = RecordingActionApi();
    await pumpPanelTab(
      tester,
      const NightMountTab(),
      overrides: panelOverrides(
        api: api,
        inputs: panelInputs(runState: SequenceExecutionState.paused),
      ),
    );
    await tester.ensureVisible(find.byKey(_flip));
    expect(isEnabled(tester, _flip), isFalse);
    expect(tooltipOf(tester, _flip), 'Resume the run to flip it now');

    await tester.tap(find.byKey(_flip), warnIfMissed: false);
    await tester.pump();
    expect(api.calls, isEmpty);
  });

  group('Set park', () {
    testWidgets('explains itself first and does nothing when cancelled',
        (tester) async {
      final handle = await pumpPanelTab(
        tester,
        const NightMountTab(),
        overrides: panelOverrides(),
      );
      await tester.ensureVisible(find.byKey(_setPark));
      await tester.tap(find.byKey(_setPark));
      await tester.pumpAndSettle();

      expect(find.text('Set park here?'), findsOneWidget);
      expect(find.textContaining('Park will go to where the mount points now'),
          findsOneWidget);
      expect(find.textContaining('Nothing moves'), findsOneWidget);
      expect(_commands(handle).calls, isEmpty,
          reason: 'opening the dialog must not set park');

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(_commands(handle).calls, isEmpty);
    });

    testWidgets('stores the park position once confirmed', (tester) async {
      final handle = await pumpPanelTab(
        tester,
        const NightMountTab(),
        overrides: panelOverrides(),
      );
      await tester.ensureVisible(find.byKey(_setPark));
      await tester.tap(find.byKey(_setPark));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.text('Set park'),
        ),
      );
      await tester.pumpAndSettle();
      expect(_commands(handle).calls, ['setParkHere']);
    });

    testWidgets('is refused with the reason when the driver cannot set park',
        (tester) async {
      await pumpPanelTab(
        tester,
        const NightMountTab(),
        overrides: panelOverrides(
          capabilities: const MountCapabilities(canPark: true),
        ),
      );
      await tester.ensureVisible(find.byKey(_setPark));
      expect(isEnabled(tester, _setPark), isFalse);
      expect(tooltipOf(tester, _setPark),
          'This mount cannot store a park position');
    });

    testWidgets('waits while the mount slews', (tester) async {
      await pumpPanelTab(
        tester,
        const NightMountTab(),
        overrides: panelOverrides(
          mount: kTrackingMount.copyWith(isSlewing: true),
        ),
      );
      await tester.ensureVisible(find.byKey(_setPark));
      expect(isEnabled(tester, _setPark), isFalse);
      expect(tooltipOf(tester, _setPark), 'Wait for the mount to stop moving');
    });

    testWidgets('a loaded run owns the mount', (tester) async {
      await pumpPanelTab(
        tester,
        const NightMountTab(),
        overrides: panelOverrides(
          inputs: panelInputs(runState: SequenceExecutionState.running),
        ),
      );
      await tester.ensureVisible(find.byKey(_setPark));
      expect(isEnabled(tester, _setPark), isFalse);
      expect(tooltipOf(tester, _setPark),
          'The run controls this while it is loaded');
    });
  });

  testWidgets('Flip now goes through the action controller when idle',
      (tester) async {
    final api = RecordingActionApi();
    await pumpPanelTab(
      tester,
      const NightMountTab(),
      overrides: panelOverrides(api: api),
    );
    await tester.ensureVisible(find.byKey(_flip));
    await tester.tap(find.byKey(_flip));
    await tester.pump();
    expect(api.calls, ['flipNow']);
  });

  testWidgets("Home warns that it runs the mount's own routine",
      (tester) async {
    final handle = await pumpPanelTab(
      tester,
      const NightMountTab(),
      overrides: panelOverrides(),
    );
    await tester.ensureVisible(find.byKey(_home));
    expect(isEnabled(tester, _home), isTrue);
    expect(tooltipOf(tester, _home), "Uses the mount's own homing routine");

    await tester.tap(find.byKey(_home));
    await tester.pump();
    expect(_commands(handle).calls, ['findHome']);
  });

  testWidgets('a parked mount offers Unpark and refuses Park and Home',
      (tester) async {
    final handle = await pumpPanelTab(
      tester,
      const NightMountTab(),
      overrides: panelOverrides(
        mount: kTrackingMount.copyWith(isParked: true, isTracking: false),
        inputs: panelInputs(mountParked: true, mountTracking: false),
      ),
    );
    await tester.ensureVisible(find.byKey(_park));
    expect(isEnabled(tester, _park), isFalse);
    expect(tooltipOf(tester, _park), 'The mount is parked');
    expect(isEnabled(tester, _home), isFalse);
    const unpark = ValueKey<String>('nightMount.unpark');
    expect(isEnabled(tester, unpark), isTrue);
    await tester.tap(find.byKey(unpark));
    await tester.pump();
    expect(_commands(handle).calls, ['unpark']);
  });

  testWidgets('tracking rates follow the driver and the run', (tester) async {
    final handle = await pumpPanelTab(
      tester,
      const NightMountTab(),
      overrides: panelOverrides(
        capabilities: const MountCapabilities(
          canSetTracking: true,
          canSetTrackingRate: true,
          supportedTrackingRates: [TrackingRate.sidereal],
          canMoveAxis: true,
        ),
      ),
    );
    const lunar = ValueKey<String>('nightMount.rate.lunar');
    expect(isEnabled(tester, lunar), isFalse);
    expect(
        tooltipOf(tester, lunar), 'This mount does not offer the Lunar rate');

    await tester.tap(find.byKey(const ValueKey('nightMount.trackingStop')));
    await tester.pump();
    expect(_commands(handle).calls, ['setTracking:false']);
  });

  testWidgets('a run owns tracking and the move pad', (tester) async {
    await pumpPanelTab(
      tester,
      const NightMountTab(),
      overrides: panelOverrides(
        inputs: panelInputs(runState: SequenceExecutionState.running),
      ),
    );
    const sidereal = ValueKey<String>('nightMount.rate.sidereal');
    expect(isEnabled(tester, sidereal), isFalse);
    expect(
      tooltipOf(tester, sidereal),
      'The run controls this while it is loaded',
    );
    expect(
      find.text('The run controls this while it is loaded'),
      findsWidgets,
      reason: 'the move pad states why it is inert',
    );
  });
}
