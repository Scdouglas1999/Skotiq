// The shell's mini bar says what holds a run a manual action paused, as
// Tonight's header does: the focuser or mount the action moves is the
// action's, not a step still finishing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/widgets/running_sequence_mini_bar.dart';
import 'package:skotiq_app/services/night_actions/night_action_api.dart';
import 'package:skotiq_app/services/night_actions/night_action_controller.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../../harness/harness.dart';

class _MovingFocuser extends FocuserStateNotifier {
  _MovingFocuser(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = state.copyWith(isMoving: true);
  }
}

Future<void> _pump(WidgetTester tester, ManualActionState action) async {
  await pumpAppScreen(
    tester,
    const RunningSequenceMiniBar(currentLocation: '/weather'),
    size: const Size(1000, 400),
    settle: false,
    extraOverrides: [
      runRecordProvider.overrideWith(
        (ref) => RunRecordNotifier(
          ref,
          const RunRecord(
            lifecycle: SequenceExecutionState.paused,
            heldByAction: true,
          ),
        ),
      ),
      nightActionStateProvider.overrideWithValue(action),
      focuserStateProvider.overrideWith(_MovingFocuser.new),
    ],
  );
  await tester.pump();
}

void main() {
  testWidgets('an autofocus this window runs is named', (tester) async {
    await _pump(
      tester,
      const ManualActionState(
        phase: ManualActionPhase.running,
        active: ManualActionId.autofocus,
        startedRunPause: true,
      ),
    );

    expect(find.text('Paused for autofocus'), findsOneWidget);
    expect(find.text('Pausing: step finishing'), findsNothing);
  });

  testWidgets('an action another window runs is a manual action',
      (tester) async {
    await _pump(tester, ManualActionState.idle);

    expect(find.text('Paused for a manual action'), findsOneWidget);
    expect(find.text('Pausing: step finishing'), findsNothing);
  });
}
