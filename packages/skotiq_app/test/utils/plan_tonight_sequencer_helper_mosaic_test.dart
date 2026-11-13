import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_astro/skotiq_astro.dart' show MosaicPanel;
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/utils/plan_tonight_sequencer_helper.dart';
import 'package:skotiq_app/widgets/add_target_to_sequence_flow.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import '../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _SeededFramingNotifier extends FramingNotifier {
  _SeededFramingNotifier(super.ref, FramingState seed) {
    // ignore: invalid_use_of_protected_member
    state = seed;
  }
}

const _equipment = FramingEquipment(
  cameraName: 'Test Camera',
  sensorWidthMm: 13.5,
  sensorHeightMm: 9,
  pixelSizeMicrons: 3.76,
  pixelsX: 3600,
  pixelsY: 2400,
  telescopeName: 'Test Scope',
  focalLengthMm: 530,
  apertureMm: 106,
);

const _generatedPanels = [
  MosaicPanel(
    index: 0,
    col: 0,
    row: 0,
    raHours: 0.7,
    decDegrees: 41.2,
  ),
  MosaicPanel(
    index: 1,
    col: 1,
    row: 0,
    raHours: 0.8,
    decDegrees: 41.2,
  ),
];

void main() {
  test('framingMosaicNameFor falls back to coords when target name is empty',
      () {
    const target = FramingTarget(
      name: '',
      raHours: 13.5,
      decDegrees: -22.0,
    );
    expect(framingMosaicNameFor(target), 'Mosaic 13.50h -22.0°');
  });

  testWidgets(
      'Auto-build and Add to sequence give the drawn mosaic the same targets',
      (tester) async {
    const target = FramingTarget(
      name: 'M31',
      catalogId: 'M31',
      raHours: 0.712,
      decDegrees: 41.2,
    );
    const framingState = FramingState(
      target: target,
      useCustomEquipment: true,
      customEquipment: _equipment,
      rotation: 15,
      mosaicEnabled: true,
      mosaicConfig: FramingMosaicConfig(columns: 2, rows: 1),
      mosaicPanels: _generatedPanels,
    );
    final editor = CurrentSequenceNotifier();
    late WidgetRef widgetRef;
    late BuildContext widgetContext;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          currentSequenceProvider.overrideWith((ref) => editor),
          framingProvider.overrideWith(
            (ref) => _SeededFramingNotifier(ref, framingState),
          ),
          smartNightExposureContextProvider.overrideWith((ref) async => null),
          siteMinimumAltitudeDegProvider.overrideWithValue(25),
        ],
        child: MaterialApp(
          home: Consumer(builder: (context, ref, _) {
            widgetRef = ref;
            widgetContext = context;
            return const SizedBox.shrink();
          }),
        ),
      ),
    );

    final added = await addFramedTargetToSequencer(
      context: widgetContext,
      ref: widgetRef,
      target: target,
      replaceSequence: true,
    );
    expect(added, isTrue);
    final built = editor.state!.nodes.values
        .whereType<TargetHeaderNode>()
        .toList()
      ..sort((a, b) => a.priority.compareTo(b.priority));
    final bare = bareTargetHeadersForMosaicPanels(
      target: target,
      framingState: framingState,
      minAltitude: 25,
    );

    String describe(TargetHeaderNode h) =>
        '${h.name}|${h.targetName}|${h.raHours}|${h.decDegrees}|'
        '${h.rotation}|${h.minAltitude}|${h.mosaicPanel?.toJson()}';
    expect(built.map(describe), bare.map(describe));
    // Panel 1 is the panel the canvas numbers first, where the run starts.
    expect(built.first.raHours, _generatedPanels.first.raHours);
    expect(built.first.decDegrees, _generatedPanels.first.decDegrees);
    expect(built.first.minAltitude, 25);
    expect(built.first.childIds, isNotEmpty, reason: 'Auto-build images');
  });

  testWidgets('appending a framed mosaic preserves the complete node tree', (
    tester,
  ) async {
    final editor = CurrentSequenceNotifier();
    editor.createSequence(name: 'Existing plan');
    editor.addNode(DelayNode(id: 'existing-delay', seconds: 1));
    final originalRootId = editor.state!.rootNodeId!;
    bool? added;

    const target = FramingTarget(
      name: 'M31',
      catalogId: 'M31',
      raHours: 0.712,
      decDegrees: 41.2,
    );
    const framingState = FramingState(
      target: target,
      useCustomEquipment: true,
      customEquipment: _equipment,
      mosaicEnabled: true,
      mosaicConfig: FramingMosaicConfig(
        columns: 2,
        rows: 1,
        overlapPercent: 15,
      ),
      mosaicPanels: _generatedPanels,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          currentSequenceProvider.overrideWith((ref) => editor),
          framingProvider.overrideWith(
            (ref) => _SeededFramingNotifier(ref, framingState),
          ),
          smartNightExposureContextProvider.overrideWith((ref) async => null),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () async {
                added = await addFramedTargetToSequencer(
                  context: context,
                  ref: ref,
                  target: target,
                );
              },
              child: const Text('Append mosaic'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Append mosaic'));
    await tester.pumpAndSettle();

    expect(added, isTrue);
    final sequence = editor.state!;
    expect(sequence.rootNodeId, originalRootId);
    expect(sequence.nodes.values.whereType<TargetHeaderNode>(), hasLength(2));

    final root = sequence.nodes[originalRootId]!;
    expect(root.childIds.where((id) => id == 'existing-delay'), hasLength(1));
    final generatedRootChildren = root.childIds
        .map((id) => sequence.nodes[id]!)
        .where((node) => node.id != 'existing-delay')
        .toList();
    expect(generatedRootChildren, everyElement(isA<TargetHeaderNode>()));
    expect(generatedRootChildren, hasLength(2));

    for (final node in sequence.nodes.values) {
      expect(node.childIds.toSet(), hasLength(node.childIds.length));
      if (node.id == originalRootId) continue;
      expect(node.parentId, isNotNull, reason: '${node.name} is orphaned');
      final parent = sequence.nodes[node.parentId];
      expect(parent, isNotNull, reason: '${node.name} has a missing parent');
      expect(
        parent!.childIds.where((id) => id == node.id),
        hasLength(1),
        reason: '${node.name} is not linked exactly once by its parent',
      );
    }

    final reachable = <String>{};
    void visit(String id) {
      if (!reachable.add(id)) return;
      for (final childId in sequence.nodes[id]!.childIds) {
        visit(childId);
      }
    }

    visit(originalRootId);
    expect(reachable, hasLength(sequence.nodes.length));
  });
}
