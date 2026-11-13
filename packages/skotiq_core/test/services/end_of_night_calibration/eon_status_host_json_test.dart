// A linked client mirrors the host's end-of-night status from its JSON, so the
// cap request and its deadline must survive the trip.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/services.dart';

void main() {
  test('phase, message and cap deadline survive the host JSON', () {
    final deadline = DateTime.utc(2026, 11, 2, 20, 12);
    final status = EonStatus(
      phase: EonPhase.waitingForCap,
      message: 'Waiting for the telescope to be capped',
      capDeadline: deadline,
    );
    final mirrored = EonStatus.fromHostJson(status.toJson())!;
    expect(mirrored.phase, EonPhase.waitingForCap);
    expect(mirrored.message, 'Waiting for the telescope to be capped');
    expect(mirrored.capDeadline!.isAtSameMomentAs(deadline), isTrue);
  });

  test('anything that is not a status reads as none', () {
    expect(EonStatus.fromHostJson(null), isNull);
    expect(EonStatus.fromHostJson({'phase': 'nonsense'}), isNull);
  });
}
