import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/transient_alert_badge.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../harness/mock_database.dart' show inMemoryDatabaseOverride;

void main() {
  testWidgets('a newer alert replaces the older pulse stop timer', (
    tester,
  ) async {
    final countProvider = StateProvider<int>((ref) => 0);
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        activeTransientAlertsProvider.overrideWith(
          (ref) => Stream.value(const <TransientAlert>[]),
        ),
        unacknowledgedAlertCountProvider.overrideWith(
          (ref) => ref.watch(countProvider),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: TransientAlertBadge()),
        ),
      ),
    );
    await tester.pump();

    container.read(countProvider.notifier).state = 1;
    await tester.pump();
    await tester.pump();
    final dynamic state = tester.state(find.byType(TransientAlertBadge));
    expect(state.debugPulseControllerForTesting.isAnimating, isTrue);

    await tester.pump(const Duration(seconds: 2));
    container.read(countProvider.notifier).state = 2;
    await tester.pump();
    await tester.pump();

    // The first alert's timer fires here. It must not stop the second alert's
    // fresh pulse sequence.
    await tester.pump(const Duration(milliseconds: 1700));
    expect(state.debugPulseControllerForTesting.isAnimating, isTrue);

    await tester.pump(const Duration(seconds: 2));
    expect(state.debugPulseControllerForTesting.isAnimating, isFalse);
  });
}
