// A linked client shows the host's plate solvers. When the host does not say
// which it has, the page says so after a bounded wait instead of spinning.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

void main() {
  test('the host not telling its solvers is an error, then the answer', () {
    fakeAsync((async) {
      final container = ProviderContainer(
        overrides: [isRemoteModeProvider.overrideWithValue(true)],
      );
      addTearDown(container.dispose);
      final sub = container.listen(
        plateSolverDetectionProvider,
        (_, _) {},
      );
      addTearDown(sub.close);

      async.elapse(plateSolverHostWait - const Duration(seconds: 1));
      expect(sub.read().isLoading, isTrue);

      async.elapse(const Duration(seconds: 2));
      expect(sub.read().error, isA<PlateSolverSetupNotTold>());

      container.read(hostPlateSolverSetupProvider.notifier).state = (
        detection: const PlateSolverDetection(),
        preference: null,
      );
      async.elapse(Duration.zero);
      final told = container.read(plateSolverDetectionProvider);
      expect(told.hasError, isFalse, reason: '$told');
      expect(told.valueOrNull, isNotNull);
    });
  });
}
