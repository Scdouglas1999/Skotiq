// "Is this object in tonight's plan?" — derived from the loaded sequence.
//
// Shaped like observedCatalogIdsProvider / listedCatalogIdsProvider so the sky
// renderer could eventually mark planned DSOs the same way it marks observed
// and listed ones. Today it feeds the object panel's InSequenceBadge.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planetarium/providers/sequenced_object_ids_provider.dart';
import 'package:skotiq_app/screens/planetarium/widgets/info_tab.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

TargetHeaderNode _target(String name) => TargetHeaderNode(
      name: name,
      targetName: name,
      raHours: 0.71,
      decDegrees: 41.27,
    );

void main() {
  group('sequenceTargetMatchKeys', () {
    test('keeps the full name and adds the base designation', () {
      expect(sequenceTargetMatchKeys('M31'), {'M31'});
      expect(sequenceTargetMatchKeys('M31 (Panel 1/9)'), {
        'M31 (Panel 1/9)',
        'M31',
      });
      expect(sequenceTargetMatchKeys('NGC 7000 — East'), contains('NGC'));
    });

    test('an empty or blank name contributes nothing', () {
      expect(sequenceTargetMatchKeys(''), isEmpty);
      expect(sequenceTargetMatchKeys('   '), isEmpty);
    });
  });

  group('sequencedObjectIdsProvider', () {
    test('is empty with no sequence loaded', () {
      final container =
          ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
      addTearDown(container.dispose);
      expect(container.read(sequencedObjectIdsProvider), isEmpty);
    });

    test('tracks the target headers of the loaded sequence', () {
      final container =
          ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
      addTearDown(container.dispose);

      final sequencer = container.read(currentSequenceProvider.notifier);
      sequencer.createSequence(name: 'tonight');
      sequencer.addNode(_target('M31 (Panel 1/9)'));
      sequencer.addNode(_target('NGC7000'));

      final ids = container.read(sequencedObjectIdsProvider);
      expect(ids, containsAll(<String>['M31', 'M31 (Panel 1/9)', 'NGC7000']));
    });
  });

  testWidgets('InSequenceBadge only claims a target that is really planned',
      (tester) async {
    final container =
        ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
    addTearDown(container.dispose);

    const m31 = DeepSkyObject(
      id: 'NGC224',
      name: 'Andromeda Galaxy',
      coordinates: CelestialCoordinate(ra: 0.712, dec: 41.269),
      type: DsoType.galaxy,
      catalogIds: ['M31', 'NGC224'],
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Builder(
            builder: (context) => Scaffold(
              body: InSequenceBadge(
                colors: SkotiqColors.of(context),
                object: m31,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text("In tonight's sequence"), findsNothing);

    // Queue it as a mosaic panel: the badge must still recognise the parent
    // object, matched through its Messier designation.
    final sequencer = container.read(currentSequenceProvider.notifier);
    sequencer.createSequence(name: 'tonight');
    sequencer.addNode(_target('M31 (Panel 1/9)'));
    await tester.pump();

    expect(find.text("In tonight's sequence"), findsOneWidget);
  });
}
