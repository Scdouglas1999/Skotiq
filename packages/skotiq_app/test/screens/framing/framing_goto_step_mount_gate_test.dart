// Guided Framing step 4 ("GoTo & Frame") must not claim to be Ready when the
// mount is disconnected.
//
// [SlewDropdownButton] gates itself on `mountState.connectionState ==
// connected`, but this step's badge was driven by `hasTarget` alone. With the
// mount disconnected the step therefore showed a GREEN "Ready" pill over a
// button that swallowed every click in silence — no toast, no dialog, no log
// line — so the operator had no way to learn why nothing happened.
//
// Pinned here: the badge tracks the button's own enabling predicate, and the
// disabled state explains itself in words.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/widgets/framing_actions_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _SeededFramingNotifier extends FramingNotifier {
  _SeededFramingNotifier(super.ref, FramingState seed) {
    // ignore: invalid_use_of_protected_member
    state = seed;
  }
}

/// Seeds [MountStateNotifier] with a fixed connection state.
///
/// [parked] is spelled out because `MountState.isParked` DEFAULTS TO TRUE (an
/// unknown mount is assumed parked until its first status poll), and step 4
/// now refuses to claim readiness over a parked mount — see
/// framing_goto_readiness_test.dart. Leaving it implicit made this fixture
/// mean "connected AND parked" without saying so.
class _SeededMountNotifier extends MountStateNotifier {
  _SeededMountNotifier(
    super.ref,
    DeviceConnectionState connectionState, {
    bool parked = false,
  }) {
    // ignore: invalid_use_of_protected_member
    state = MountState(connectionState: connectionState, isParked: parked);
  }
}

const _target = FramingTarget(
  name: 'M42',
  raHours: 5.5,
  decDegrees: -5.4,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpRail(
    WidgetTester tester, {
    required DeviceConnectionState mount,
    FramingState framing = const FramingState(target: _target),
  }) async {
    await pumpAppScreen(
      tester,
      const SingleChildScrollView(
        child: SizedBox(width: 500, child: FramingActionRail()),
      ),
      size: const Size(700, 1400),
      extraOverrides: [
        framingProvider.overrideWith(
          (ref) => _SeededFramingNotifier(ref, framing),
        ),
        mountStateProvider.overrideWith(
          (ref) => _SeededMountNotifier(ref, mount),
        ),
        framingFOVProvider.overrideWith(
          (ref) async => const FramingEquipmentResult(
            status: EquipmentStatus.noProfile,
          ),
        ),
      ],
    );
    await tester.pump();
  }

  testWidgets('mount disconnected: step 4 says so instead of "Ready"',
      (tester) async {
    await pumpRail(tester, mount: DeviceConnectionState.disconnected);

    expect(find.text('GoTo & Frame'), findsOneWidget);
    // 'No mount', not 'Mount not connected': the longer string overflowed the
    // rail (39 px even in the 254 px desktop sidebar, 82 px on a phone in
    // landscape). The assertion that matters is unchanged — the step names the
    // reason it cannot run instead of claiming readiness — and the full
    // instruction is still asserted below.
    expect(
      find.text('No mount'),
      findsOneWidget,
      reason: 'the step must name the reason it cannot run',
    );
    // Step 3 ("Solve latest camera frame") legitimately reads "Ready", so the
    // rail carries exactly ONE Ready badge here. Two would mean step 4 is still
    // claiming readiness over a dead button — the defect.
    expect(
      find.text('Ready'),
      findsOneWidget,
      reason: 'a green "Ready" over a dead slew button is the defect',
    );
    // And the dead button explains itself.
    expect(
      find.text('Connect the mount in Equipment to enable slewing.'),
      findsOneWidget,
    );
  });

  testWidgets('mount connected: step 4 is Ready with no excuse text',
      (tester) async {
    await pumpRail(tester, mount: DeviceConnectionState.connected);

    expect(find.text('No mount'), findsNothing);
    expect(
      find.text('Connect the mount in Equipment to enable slewing.'),
      findsNothing,
    );
    expect(find.text('Slew to Target'), findsOneWidget);
    // Both step 3 and step 4 are now legitimately Ready.
    expect(find.text('Ready'), findsNWidgets(2));
  });

  testWidgets('no target still reports "No target", not the mount',
      (tester) async {
    await pumpRail(
      tester,
      mount: DeviceConnectionState.disconnected,
      framing: const FramingState(),
    );

    expect(find.text('No target'), findsOneWidget);
    expect(find.text('No mount'), findsNothing);
    expect(
      find.text('Resolve a target above to enable slewing.'),
      findsOneWidget,
    );
  });
}
