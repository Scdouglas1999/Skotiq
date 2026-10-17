import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

/// The object details panel must not re-solve rise/set/transit every second.
///
/// The panel root watched `observationTimeProvider`, which a 1 Hz
/// `Timer.periodic` drives, so the whole subtree rebuilt once a second. Two
/// places in that subtree then each called
/// `AstronomyCalculations.calculateObjectVisibility` — 289 altitude samples
/// across a 24 h window, plus bisection of every horizon crossing and a ternary
/// transit search — on the UI isolate. Every one of those solves is anchored on
/// `nightDateOf(...)`, which changes only at local noon, so the same answer was
/// recomputed on the order of 86,400 times a night.
void main() {
  const target = DeepSkyObject(
    id: 'M31',
    name: 'Andromeda Galaxy',
    coordinates: CelestialCoordinate(ra: 0.712, dec: 41.269),
    type: DsoType.galaxy,
    magnitude: 3.44,
  );

  /// Drive observation time explicitly: Flutter pumps fake timers, while the
  /// aligned ticker schedules against real DateTime.now(). Mixing those two
  /// clocks makes the number of ticks depend on the wall-clock millisecond.
  Future<ProviderContainer> pumpPanel(
    WidgetTester tester, {
    required List<Override> overrides,
  }) async {
    final container = ProviderContainer(overrides: overrides);
    // The sky is drawn from the observer's site; without one the view renders
    // its no-site state instead.
    container
        .read(observerLocationProvider.notifier)
        .setLocation(latitude: 40.0, longitude: -74.0);
    container
        .read(observationTimeProvider.notifier)
        .setTime(DateTime(2026, 3, 14, 22, 0, 0));
    container.read(observationTimeProvider.notifier).pause();

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ObjectDetailsPanel(object: target),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return container;
  }

  Future<void> advanceSecond(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    container
        .read(observationTimeProvider.notifier)
        .fastForward(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('a second of wall clock does not re-solve visibility', (
    tester,
  ) async {
    var solves = 0;
    final container = await pumpPanel(
      tester,
      overrides: [
        objectVisibilityProvider.overrideWith((ref, key) {
          solves++;
          return AstronomyCalculations.calculateObjectVisibility(
            raDeg: key.raDeg,
            decDeg: key.decDeg,
            date: key.nightDate,
            latitudeDeg: key.latitudeDeg,
            longitudeDeg: key.longitudeDeg,
            minAltitude: key.minAltitude,
          );
        }),
      ],
    );

    final afterFirstFrame = solves;
    expect(
      afterFirstFrame,
      greaterThan(0),
      reason:
          'the panel must actually be solving for this test to mean '
          'anything',
    );

    // Five ticks of the 1 Hz observation clock, all inside the same minute.
    for (var i = 0; i < 5; i++) {
      await advanceSecond(tester, container);
    }

    expect(
      solves,
      afterFirstFrame,
      reason: 'nothing the solve depends on moved, so no solve may be re-run',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });

  testWidgets('the panel subtree is not rebuilt by the 1 Hz clock', (
    tester,
  ) async {
    final container = await pumpPanel(tester, overrides: const []);

    final name = find.text('Andromeda Galaxy').first;
    expect(name, findsOneWidget);
    final before = tester.widget<Text>(name);

    for (var i = 0; i < 5; i++) {
      await advanceSecond(tester, container);
    }

    expect(
      identical(tester.widget<Text>(name), before),
      isTrue,
      reason:
          'a rebuild would have constructed a new Text; the panel must sit '
          'on observationMinuteProvider, not the per-second clock',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });

  testWidgets('crossing a minute retains the same night visibility memo', (
    tester,
  ) async {
    final keys = <ObjectVisibilityKey>[];
    final container = await pumpPanel(
      tester,
      overrides: [
        objectVisibilityProvider.overrideWith((ref, key) {
          keys.add(key);
          return AstronomyCalculations.calculateObjectVisibility(
            raDeg: key.raDeg,
            decDeg: key.decDeg,
            date: key.nightDate,
            latitudeDeg: key.latitudeDeg,
            longitudeDeg: key.longitudeDeg,
            minAltitude: key.minAltitude,
          );
        }),
      ],
    );

    keys.clear();
    for (var i = 0; i < 61; i++) {
      await advanceSecond(tester, container);
    }

    // The clock crossed 22:01, but the night it belongs to did not change, so
    // the key is unchanged and the memo still holds.
    expect(
      keys,
      isEmpty,
      reason:
          'the solve is keyed on the night, which a minute boundary does '
          'not move',
    );
    expect(
      container.read(observationMinuteProvider),
      DateTime(2026, 3, 14, 22, 1),
      reason: 'the clock really did advance past the minute boundary',
    );

    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });
}
