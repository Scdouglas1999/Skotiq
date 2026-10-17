import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/utils/plan_tonight_sequencer_helper.dart';
import 'package:skotiq_core/skotiq_core.dart';
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
  FramingMosaicPanel(
    index: 0,
    column: 0,
    row: 0,
    centerRaHours: 0.7,
    centerDecDegrees: 41.2,
    name: 'Panel 1',
  ),
  FramingMosaicPanel(
    index: 1,
    column: 1,
    row: 0,
    centerRaHours: 0.8,
    centerDecDegrees: 41.2,
    name: 'Panel 2',
  ),
];

void main() {
  group('buildFramingMosaicConfig', () {
    const target = FramingTarget(
      name: 'M31',
      catalogId: 'M31',
      raHours: 0.7122222, // ~10.68 deg
      decDegrees: 41.2,
    );

    test('passes through framing UI knobs to the service-layer geometry', () {
      const framingState = FramingState(
        rotation: 12.0,
        mosaicEnabled: true,
        mosaicConfig: FramingMosaicConfig(
          columns: 3,
          rows: 2,
          overlapPercent: 18.0,
          serpentine: true,
        ),
      );

      final config = buildFramingMosaicConfig(
        target: target,
        framingState: framingState,
        panelWidthArcmin: 45.0,
        panelHeightArcmin: 30.0,
      );

      expect(config.centerRa, target.raHours);
      expect(config.centerDec, target.decDegrees);
      expect(config.panelsHorizontal, 3);
      expect(config.panelsVertical, 2);
      expect(config.totalPanels, 6);
      expect(config.overlapPercent, 18.0);
      expect(config.panelWidthArcmin, 45.0);
      expect(config.panelHeightArcmin, 30.0);
      // Rotation falls back to framing state when no override is given.
      expect(config.rotation, 12.0);
    });

    test('rotation override beats framing state rotation', () {
      const framingState = FramingState(
        rotation: 12.0,
        mosaicEnabled: true,
        mosaicConfig: FramingMosaicConfig(columns: 2, rows: 2),
      );
      final config = buildFramingMosaicConfig(
        target: target,
        framingState: framingState,
        panelWidthArcmin: 60.0,
        panelHeightArcmin: 40.0,
        rotationOverrideDegrees: -45.0,
      );
      expect(config.rotation, -45.0);
    });
  });

  group('MosaicService.createMosaicSequence (from framing config)', () {
    test(
        'emits one TargetHeaderNode per panel + a single InstructionSetNode '
        'root, distinct from the single-target path', () {
      const target = FramingTarget(
        name: 'M51',
        raHours: 13.5,
        decDegrees: 47.2,
      );
      const framingState = FramingState(
        mosaicEnabled: true,
        mosaicConfig: FramingMosaicConfig(
          columns: 2,
          rows: 3, // 6 panels total
          overlapPercent: 10.0,
        ),
      );

      final config = buildFramingMosaicConfig(
        target: target,
        framingState: framingState,
        panelWidthArcmin: 60.0,
        panelHeightArcmin: 40.0,
      );

      const exposure = MosaicExposureSettings(
        exposureSeconds: 60.0,
        exposuresPerPanel: 5,
        filterName: 'L',
        binning: 1,
      );

      const mosaicService = MosaicService();
      final nodes = mosaicService.createMosaicSequence(
        mosaicName: framingMosaicNameFor(target),
        config: config,
        exposure: exposure,
      );

      // Exactly one InstructionSetNode root.
      final roots = nodes.values
          .whereType<InstructionSetNode>()
          .where((n) => n.parentId == null);
      expect(roots.length, 1);
      expect(roots.first.name, 'M51 Mosaic');

      // 6 panels => 6 TargetHeaderNodes (one per panel). Each panel has a
      // distinct (raHours, decDegrees) and a `targetName` derived from the
      // mosaic name so the per-frame FITS path can identify which mosaic
      // the panel belongs to.
      final targetHeaders = nodes.values.whereType<TargetHeaderNode>().toList();
      expect(targetHeaders.length, 6);

      // All panel target names reference the parent mosaic.
      for (final h in targetHeaders) {
        expect(h.targetName, startsWith('M51 Mosaic Panel '));
      }

      // Panel centers are unique — confirms the geometry actually produced
      // 6 distinct coordinates rather than 6 copies of the target center.
      final centers = targetHeaders
          .map((h) => '${h.raHours.toStringAsFixed(6)},'
              '${h.decDegrees.toStringAsFixed(6)}')
          .toSet();
      expect(centers.length, 6);
    });

    test('framingMosaicNameFor falls back to coords when target name is empty',
        () {
      const target = FramingTarget(
        name: '',
        raHours: 13.5,
        decDegrees: -22.0,
      );
      expect(framingMosaicNameFor(target), 'Mosaic 13.50h -22.0°');
    });
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
