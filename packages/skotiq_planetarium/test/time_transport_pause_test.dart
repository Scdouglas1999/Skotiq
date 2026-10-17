// The transport's pause stops the clock.
//
// Pausing at 08:52:23 must not leave the readout at 08:54:15 112 s later, still
// showing the play glyph — exactly 1x wall rate. The time model advances by
// `speedMultiplier` seconds per tick whenever it is not following the wall
// clock, so clearing only `isRealTime` leaves the multiplier at 1.0 and every
// altitude, framing decision and screenshot taken while "paused" is against a
// moving sky.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// The observation clock is a live 1 s `Timer.periodic`, so the tree has to be
/// torn down inside the test body — the framework checks for pending timers
/// before `addTearDown` callbacks run.
Future<void> _close(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(const SizedBox.shrink());
  container.dispose();
}

Future<ProviderContainer> _pumpTransport(WidgetTester tester) async {
  final container = ProviderContainer();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: Center(child: TimeControlPanel())),
      ),
    ),
  );
  await tester.pump();
  return container;
}

void main() {
  testWidgets('pause holds simulated time still', (tester) async {
    final container = await _pumpTransport(tester);

    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();

    final frozen = container.read(observationTimeProvider).time;
    expect(container.read(observationTimeProvider).isPaused, isTrue);

    await tester.pump(const Duration(seconds: 5));

    expect(
      container.read(observationTimeProvider).time,
      frozen,
      reason: 'a control that says paused must stop the sky',
    );
    expect(find.byTooltip('Play'), findsOneWidget);
    await _close(tester, container);
  });

  testWidgets('a paused transport says so rather than reporting 1x', (
    tester,
  ) async {
    final container = await _pumpTransport(tester);

    expect(find.text('1×'), findsOneWidget);
    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();

    expect(find.text('PAUSED'), findsOneWidget);
    expect(find.text('1×'), findsNothing);
    await _close(tester, container);
  });

  testWidgets('play resumes the wall clock', (tester) async {
    final container = await _pumpTransport(tester);

    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();

    expect(container.read(observationTimeProvider).isPaused, isFalse);
    expect(container.read(observationTimeProvider).isRealTime, isTrue);

    final resumed = container.read(observationTimeProvider).time;
    await tester.pump(const Duration(seconds: 2));
    expect(
      container.read(observationTimeProvider).time.isAfter(resumed) ||
          container.read(observationTimeProvider).time == resumed,
      isTrue,
    );
    await _close(tester, container);
  });

  testWidgets('stepping an hour while paused leaves it paused', (tester) async {
    final container = await _pumpTransport(tester);

    await tester.tap(find.byTooltip('Pause'));
    await tester.pump();
    final frozen = container.read(observationTimeProvider).time;

    await tester.tap(find.byTooltip('Forward 1 hour'));
    await tester.pump();

    final stepped = container.read(observationTimeProvider).time;
    expect(stepped, frozen.add(const Duration(hours: 1)));

    await tester.pump(const Duration(seconds: 5));
    expect(container.read(observationTimeProvider).time, stepped);
    await _close(tester, container);
  });
}
