// Planetarium → sequencer target-queue round trip.
//
// `targetQueueProvider.addTarget` had no production caller, so the sequencer
// Builder's Target Queue panel — which is a pure view over that provider — could
// never be filled by a user. These tests pin the join end to end: the sky-side
// action writes the queue, and the sequencer-side panel renders what it wrote,
// through one shared container (no hand-seeded queue).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planetarium/widgets/info_tab.dart';
import 'package:skotiq_app/screens/sequencer/widgets/target_queue_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

CelestialObject _object(
  String id, {
  required double raHours,
  required double decDeg,
  String? name,
}) {
  return DeepSkyObject(
    id: id,
    name: name ?? id,
    coordinates: CelestialCoordinate(ra: raHours, dec: decDeg),
    type: DsoType.galaxy,
  );
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  Widget Function(SkotiqColors colors) build,
) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(420, 800);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Builder(
          builder: (context) => Scaffold(
            body: build(SkotiqColors.of(context)),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

ProviderContainer _container() {
  final container = ProviderContainer(overrides: [
    inMemoryDatabaseOverride(),
    tickerProvider(TickerCadence.thirtySeconds).overrideWith(
      (ref) => Stream.value(DateTime.utc(2024, 6, 15, 22)),
    ),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  testWidgets('sky-side "Add to target queue" fills the sequencer panel',
      (tester) async {
    final container = _container();
    final m31 = _object('M31', raHours: 0.71, decDeg: 41.27);

    await _pump(
      tester,
      container,
      (colors) => AddToTargetQueueButton(colors: colors, object: m31),
    );

    // Precondition: the queue really is empty, so the panel below can only be
    // showing what this button put there.
    expect(container.read(targetQueueProvider).targets, isEmpty);

    await tester.tap(find.text('Add to target queue'));
    await tester.pump();

    final queued = container.read(targetQueueProvider).targets;
    expect(queued, hasLength(1));
    expect(queued.single.displayName, 'M31');
    expect(queued.single.coordinates.ra, closeTo(0.71, 1e-6));
    expect(queued.single.coordinates.dec, closeTo(41.27, 1e-6));
    expect(queued.single.object, same(m31));

    // Same container, sequencer surface: the panel shows the queued target.
    await _pump(
      tester,
      container,
      (colors) => TargetQueuePanel(colors: colors),
    );
    expect(find.text('Your target queue is empty.'), findsNothing);
    expect(find.text('M31'), findsOneWidget);
  });

  testWidgets('reflects membership instead of queueing a duplicate',
      (tester) async {
    final container = _container();
    final m42 = _object('M42', raHours: 5.59, decDeg: -5.39, name: 'Orion');

    await _pump(
      tester,
      container,
      (colors) => AddToTargetQueueButton(colors: colors, object: m42),
    );

    await tester.tap(find.text('Add to target queue'));
    await tester.pump();

    expect(find.text('In target queue'), findsOneWidget);
    expect(find.text('Add to target queue'), findsNothing);

    // The action is spent, so a second tap cannot grow a second Orion.
    await tester.tap(find.text('In target queue'));
    await tester.pump();
    expect(container.read(targetQueueProvider).targets, hasLength(1));
  });

  testWidgets('a queued target carries into the sequence tree', (tester) async {
    final container = _container();
    container
        .read(currentSequenceProvider.notifier)
        .createSequence(name: 'test');

    await _pump(
      tester,
      container,
      (colors) => AddToTargetQueueButton(
        colors: colors,
        object: _object('NGC 7000', raHours: 20.97, decDeg: 44.34),
      ),
    );
    await tester.tap(find.text('Add to target queue'));
    await tester.pump();

    await _pump(
      tester,
      container,
      (colors) => TargetQueuePanel(colors: colors),
    );
    await tester.tap(find.byTooltip('Add to sequence'));
    await tester.pump();

    final headers = container
        .read(currentSequenceProvider)!
        .nodes
        .values
        .whereType<TargetHeaderNode>()
        .toList();
    expect(headers, hasLength(1));
    expect(headers.single.targetName, 'NGC 7000');
    expect(headers.single.raHours, closeTo(20.97, 1e-6));
    expect(headers.single.decDegrees, closeTo(44.34, 1e-6));
  });
}
