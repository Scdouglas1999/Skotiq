import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('ActiveOperationsNotifier operation identity', () {
    test('stale completion cannot remove a newer same-type operation', () {
      final notifier = ActiveOperationsNotifier();
      final first = notifier.startOperation(
        type: OperationType.slewToTarget,
        description: 'First slew',
      );
      final second = notifier.startOperation(
        type: OperationType.slewToTarget,
        description: 'Second slew',
      );

      notifier.completeOperation(
        OperationType.slewToTarget,
        operationId: first,
      );

      expect(notifier.state[OperationType.slewToTarget]?.id, second);
      expect(
        notifier.state[OperationType.slewToTarget]?.description,
        'Second slew',
      );
    });

    test('stale progress cannot overwrite a newer same-type operation', () {
      final notifier = ActiveOperationsNotifier();
      final first = notifier.startOperation(
        type: OperationType.autofocus,
        description: 'First autofocus',
      );
      final second = notifier.startOperation(
        type: OperationType.autofocus,
        description: 'Second autofocus',
      );

      notifier.updateProgress(
        OperationType.autofocus,
        operationId: first,
        progress: 0.75,
        currentStep: 'Stale step',
      );

      final current = notifier.state[OperationType.autofocus];
      expect(current?.id, second);
      expect(current?.progress, isNull);
      expect(current?.currentStep, isNull);
    });

    test('matching identity can complete its operation', () {
      final notifier = ActiveOperationsNotifier();
      final id = notifier.startOperation(
        type: OperationType.dither,
        description: 'Dither',
      );

      notifier.completeOperation(OperationType.dither, operationId: id);

      expect(notifier.state[OperationType.dither], isNull);
    });
  });
}
