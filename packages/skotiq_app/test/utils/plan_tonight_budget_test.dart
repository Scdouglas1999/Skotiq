// qa-surfaces S26: "Image until: Astronomical dawn" built a plan that imaged
// until 14:56 with dawn at 14:37: the 10 min cool-down and the acquisition
// were not taken out of the window. And the planner header quoted the Moon at
// one instant and a target's rationale at another (52% vs 53%).
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planner/planner_screen.dart';
import 'package:skotiq_app/utils/plan_tonight_sequencer_helper.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  test('the preamble comes out of a fill-to-dawn window', () {
    final start = DateTime(2026, 11, 2, 20);
    final hours = fillWindowBudgetHours(
      start: start,
      end: start.add(const Duration(hours: 2)),
      overhead: const SequenceOverheadConfig(),
    );
    // 600 s cooling + 30 slew + 15 solve + 30 guide = 675 s.
    expect(hours, closeTo((7200 - 675) / 3600, 1e-9));
  });

  test('the header reads the Moon at the middle of the dark', () {
    final dusk = DateTime(2026, 11, 2, 18);
    final dawn = DateTime(2026, 11, 3, 6);
    expect(
      plannerMoonInstant(
          now: DateTime(2026, 11, 2, 11), dusk: dusk, dawn: dawn),
      DateTime(2026, 11, 3, 0),
    );
  });
}
