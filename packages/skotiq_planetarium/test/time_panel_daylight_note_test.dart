import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/src/providers/planetarium_providers.dart';
import 'package:skotiq_planetarium/src/widgets/time_control_panel.dart';

Future<ProviderContainer> _pumpAt(
  WidgetTester tester,
  DateTime skyTime, {
  bool compact = false,
}) async {
  final container = ProviderContainer();
  container
      .read(observerLocationProvider.notifier)
      .setLocation(latitude: 40.0, longitude: 0.0);
  container.read(observationTimeProvider.notifier).setTime(skyTime);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Scaffold(body: Center(child: TimeControlPanel(compact: compact))),
      ),
    ),
  );
  await tester.pump();
  return container;
}

/// The observation clock ticks; the tree and the container go before the
/// binding checks for pending timers.
Future<void> _finish(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(const SizedBox.shrink());
  container.dispose();
}

void main() {
  // ux walk-2 F10: at 15:37 with the Sun up the planetarium drew a night sky
  // with nothing to say it was daytime.
  testWidgets('with the Sun up the panel says the sky is drawn as if dark', (
    tester,
  ) async {
    final container = await _pumpAt(tester, DateTime.utc(2026, 6, 21, 12));

    expect(find.textContaining('° up · sky drawn as if dark'), findsOneWidget);
    await _finish(tester, container);
  });

  testWidgets('the compact transport carries the note too', (tester) async {
    final container = await _pumpAt(
      tester,
      DateTime.utc(2026, 6, 21, 12),
      compact: true,
    );

    expect(find.textContaining('° up · sky drawn as if dark'), findsOneWidget);
    await _finish(tester, container);
  });

  testWidgets('at night there is no note', (tester) async {
    final container = await _pumpAt(tester, DateTime.utc(2026, 12, 21, 0));

    expect(find.textContaining('sky drawn as if dark'), findsNothing);
    await _finish(tester, container);
  });
}
