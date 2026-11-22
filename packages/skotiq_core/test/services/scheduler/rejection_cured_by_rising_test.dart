import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/services.dart';

/// Which rejections Plan > Targets shows as "Up <time>" (the target only has
/// to rise) instead of a reason chip. The table is the switch the target
/// list held before the rule moved onto the kind.
void main() {
  test('every rejection kind says whether rising clears it', () {
    const table = <SchedulerRejectionKind, bool>{
      SchedulerRejectionKind.belowHorizon: true,
      SchedulerRejectionKind.tooLowForSite: true,
      SchedulerRejectionKind.behindHorizonProfile: true,
      SchedulerRejectionKind.other: true,
      SchedulerRejectionKind.moonSeparation: false,
      SchedulerRejectionKind.moonIllumination: false,
      SchedulerRejectionKind.moon: false,
      SchedulerRejectionKind.outsideTimeWindow: false,
      SchedulerRejectionKind.filterMissing: false,
      SchedulerRejectionKind.goalsComplete: false,
    };
    expect(table.keys.toSet(), SchedulerRejectionKind.values.toSet());
    for (final entry in table.entries) {
      expect(entry.key.curedByRising, entry.value, reason: entry.key.name);
    }
  });
}
