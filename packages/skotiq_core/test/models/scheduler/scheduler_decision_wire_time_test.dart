// A linked phone in another timezone read the host's local wall clock as its
// own: "Scored at 16:40" on a phone where it was 05:40. The decision's time
// goes on the wire as UTC so it names the same moment on both ends.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';

void main() {
  test('evaluatedAt crosses the wire as the same instant', () {
    final at = DateTime(2026, 11, 25, 16, 40, 55);
    final decision = SchedulerDecision(
      score: 0,
      reasoning: const [],
      scoredCandidates: const [],
      evaluatedAt: at,
    );
    final wire = decision.toJson()['evaluatedAt'] as String;
    expect(wire, endsWith('Z'));
    expect(
      SchedulerDecision.fromJson(
        decision.toJson(),
      ).evaluatedAt.isAtSameMomentAs(at),
      isTrue,
    );
  });
}
