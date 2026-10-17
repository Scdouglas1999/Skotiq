// The planetarium's clock never rewrites the Dashboard's.
//
// A simulated time that escapes its scope leaves the Dashboard header reading
// 17:43 (Aug 14) labelled "Local" against a real 09:20 (Aug 13), LST 14:21:12
// against 05:52, "Dark in 3h 54m" against 12h 19m and a 6% moon against 1% —
// with the app's status bar showing the true clock two inches away — after
// stepping the planetarium transport ~20 h forward and returning. "Dark in" is
// the number a user plans the evening around, and nothing on that card says it
// is fictional.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

void main() {
  testWidgets('leaving the planetarium returns the app clock to now', (
    tester,
  ) async {
    final container = ProviderContainer();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: SimulatedTimeScope(child: SizedBox.shrink()),
        ),
      ),
    );

    container
        .read(observationTimeProvider.notifier)
        .setTime(DateTime(2030, 1, 1, 3, 30));
    expect(container.read(observationTimeProvider).isRealTime, isFalse);

    // The planetarium goes away; every other surface still reads this clock.
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SizedBox.shrink()),
      ),
    );
    await tester.pump();

    final state = container.read(observationTimeProvider);
    expect(state.isRealTime, isTrue);
    expect(
      state.time.difference(DateTime.now()).abs(),
      lessThan(const Duration(minutes: 1)),
      reason: 'a simulated instant must not outlive the screen that made it',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });
}
