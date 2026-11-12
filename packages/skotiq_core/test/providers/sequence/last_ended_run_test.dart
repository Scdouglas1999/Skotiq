// A stopped or dawn-ended run settles idle like a plan that never ran; this
// record is what keeps the night's results on Tonight (qa-pair QP-22).
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  test(
    'records the plan of a run that ends, and forgets it at the next start',
    () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.listen(lastEndedRunProvider, (_, __) {});
      container
          .read(currentSequenceProvider.notifier)
          .createSequence(name: 'M35');
      final id = container.read(currentSequenceProvider)!.id;
      final execution = container.read(runRecordProvider.notifier);

      execution.setLifecycle(SequenceExecutionState.running);
      expect(container.read(lastEndedRunProvider), isNull);
      execution.setLifecycle(SequenceExecutionState.stopping);
      execution.setLifecycle(SequenceExecutionState.idle);
      expect(container.read(lastEndedRunProvider)?.sequenceId, id);

      execution.setLifecycle(SequenceExecutionState.running);
      expect(container.read(lastEndedRunProvider), isNull);
    },
  );
}
