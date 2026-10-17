import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/services/mosaic_service.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';

void main() {
  late MosaicService service;

  setUp(() {
    service = const MosaicService();
  });

  group('MosaicService - Panel Generation', () {
    test('generates correct number of panels for simple 3x3 grid', () {
      const config = MosaicConfig(
        centerRa: 12.0,
        centerDec: 30.0,
        panelWidthArcmin: 60.0,
        panelHeightArcmin: 40.0,
        panelsHorizontal: 3,
        panelsVertical: 3,
      );

      final panels = service.generatePanels(config);

      expect(panels.length, equals(9));
    });

    test('generates panels with correct indices and positions', () {
      const config = MosaicConfig(
        centerRa: 12.0,
        centerDec: 30.0,
        panelWidthArcmin: 60.0,
        panelHeightArcmin: 40.0,
        panelsHorizontal: 2,
        panelsVertical: 2,
      );

      final panels = service.generatePanels(config);

      expect(panels.length, equals(4));

      // Check indices are sequential
      for (var i = 0; i < panels.length; i++) {
        expect(panels[i].panelIndex, equals(i));
      }

      // Check row/col assignments
      expect(panels[0].row, equals(0));
      expect(panels[0].col, equals(0));
      expect(panels[1].row, equals(0));
      expect(panels[1].col, equals(1));
      expect(panels[2].row, equals(1));
      expect(panels[2].col, equals(0));
      expect(panels[3].row, equals(1));
      expect(panels[3].col, equals(1));
    });

    test('generates single panel correctly', () {
      const config = MosaicConfig(
        centerRa: 12.0,
        centerDec: 30.0,
        panelWidthArcmin: 60.0,
        panelHeightArcmin: 40.0,
        panelsHorizontal: 1,
        panelsVertical: 1,
      );

      final panels = service.generatePanels(config);

      expect(panels.length, equals(1));

      // Single panel should be centered at mosaic center
      expect(panels[0].raHours, closeTo(12.0, 0.01));
      expect(panels[0].decDegrees, closeTo(30.0, 0.1));
    });

    test('handles large mosaic configurations', () {
      const config = MosaicConfig(
        centerRa: 12.0,
        centerDec: 30.0,
        panelWidthArcmin: 30.0,
        panelHeightArcmin: 20.0,
        panelsHorizontal: 10,
        panelsVertical: 10,
      );

      final panels = service.generatePanels(config);

      expect(panels.length, equals(100));
    });

    test('respects overlap percentage in panel calculations', () {
      const config = MosaicConfig(
        centerRa: 12.0,
        centerDec: 30.0,
        panelWidthArcmin: 60.0,
        panelHeightArcmin: 40.0,
        overlapPercent: 10.0,
        panelsHorizontal: 2,
        panelsVertical: 1,
      );

      final panels = service.generatePanels(config);

      expect(panels.length, equals(2));

      // With 10% overlap, panels should be closer together than without
      final separation = (panels[1].raHours - panels[0].raHours).abs();

      // Expected separation is 90% of panel width (accounting for overlap)
      // 60 arcmin = 1 degree = 1/15 hours
      // With 10% overlap: 0.9 * 60 / 60 / 15 = 0.06 hours
      expect(separation, lessThan(0.07)); // Allow some margin for projection
    });

    test('applies rotation to panel layout', () {
      const configNoRotation = MosaicConfig(
        centerRa: 12.0,
        centerDec: 30.0,
        panelWidthArcmin: 60.0,
        panelHeightArcmin: 40.0,
        rotation: 0.0,
        panelsHorizontal: 2,
        panelsVertical: 1,
      );

      const configWithRotation = MosaicConfig(
        centerRa: 12.0,
        centerDec: 30.0,
        panelWidthArcmin: 60.0,
        panelHeightArcmin: 40.0,
        rotation: 90.0,
        panelsHorizontal: 2,
        panelsVertical: 1,
      );

      final panelsNoRot = service.generatePanels(configNoRotation);
      final panelsRot = service.generatePanels(configWithRotation);

      // With 90° rotation, what was horizontal should become vertical
      // Dec separation should be larger with rotation
      final decSepNoRot =
          (panelsNoRot[1].decDegrees - panelsNoRot[0].decDegrees).abs();
      final decSepRot = (panelsRot[1].decDegrees - panelsRot[0].decDegrees)
          .abs();

      expect(decSepRot, greaterThan(decSepNoRot));
    });

    test('normalizes RA hours when mosaic spans across 0h', () {
      const config = MosaicConfig(
        centerRa: 23.98,
        centerDec: 10.0,
        panelWidthArcmin: 120.0,
        panelHeightArcmin: 60.0,
        panelsHorizontal: 3,
        panelsVertical: 1,
      );

      final panels = service.generatePanels(config);

      expect(panels.length, 3);
      expect(
        panels.every((panel) => panel.raHours >= 0.0 && panel.raHours < 24.0),
        isTrue,
      );
    });
  });

  group('MosaicService - Area Calculation', () {
    test('edge-to-edge grid sums the panel areas', () {
      const config = MosaicConfig(
        centerRa: 12.0,
        centerDec: 30.0,
        panelWidthArcmin: 60.0,
        panelHeightArcmin: 60.0,
        overlapPercent: 0.0,
        panelsHorizontal: 2,
        panelsVertical: 2,
      );

      final area = service.calculateMosaicArea(config);

      // 2x2 grid of 60'x60' panels with NO overlap = 2°x2° = 4 sq°
      expect(area, closeTo(4.0, 0.01));
    });

    test('overlap reduces the reported coverage', () {
      // The same 2x2 grid at the DEFAULT 10% overlap. Adjacent centres are
      // 0.9° apart, so the grid spans 1° + 0.9° = 1.9° per axis, not 2°.
      // Ignoring overlap would report 4 sq°, ~10% per axis too much.
      const config = MosaicConfig(
        centerRa: 12.0,
        centerDec: 30.0,
        panelWidthArcmin: 60.0,
        panelHeightArcmin: 60.0,
        panelsHorizontal: 2,
        panelsVertical: 2,
      );

      expect(config.overlapPercent, 10.0, reason: 'default overlap changed');
      expect(service.calculateMosaicArea(config), closeTo(1.9 * 1.9, 0.001));
      final (widthDeg, heightDeg) = config.totalExtentDegrees;
      expect(widthDeg, closeTo(1.9, 0.001));
      expect(heightDeg, closeTo(1.9, 0.001));
    });

    test('a 3x3 at the default overlap does not claim a full 3 panels of '
        'sky per axis', () {
      const config = MosaicConfig(
        centerRa: 12.0,
        centerDec: 30.0,
        panelWidthArcmin: 60.0,
        panelHeightArcmin: 60.0,
        panelsHorizontal: 3,
        panelsVertical: 3,
      );

      // 1 + 2*0.9 = 2.8° per axis -> 7.84 sq°, not the 9 sq° the panel areas
      // sum to.
      expect(service.calculateMosaicArea(config), closeTo(7.84, 0.001));
    });

    test('a single panel is its own extent regardless of overlap', () {
      const config = MosaicConfig(
        centerRa: 12.0,
        centerDec: 30.0,
        panelWidthArcmin: 90.0,
        panelHeightArcmin: 60.0,
        overlapPercent: 40.0,
        panelsHorizontal: 1,
        panelsVertical: 1,
      );

      // 90' x 60' = 1.5° x 1° = 1.5 sq° — nothing to overlap with.
      expect(service.calculateMosaicArea(config), closeTo(1.5, 0.01));
    });

    test('calculateMosaicArea and MosaicConfig agree', () {
      const config = MosaicConfig(
        centerRa: 3.0,
        centerDec: -12.0,
        panelWidthArcmin: 47.0,
        panelHeightArcmin: 31.0,
        overlapPercent: 22.5,
        panelsHorizontal: 4,
        panelsVertical: 3,
      );

      expect(
        service.calculateMosaicArea(config),
        closeTo(config.totalAreaSquareDegrees, 1e-12),
      );
    });
  });

  group('MosaicService - Time Estimation', () {
    test('estimates correct time for simple mosaic', () {
      const config = MosaicConfig(
        centerRa: 12.0,
        centerDec: 30.0,
        panelWidthArcmin: 60.0,
        panelHeightArcmin: 40.0,
        panelsHorizontal: 2,
        panelsVertical: 2,
      );

      const exposure = MosaicExposureSettings(
        exposureSeconds: 60.0,
        exposuresPerPanel: 10,
      );

      final time = service.estimateMosaicTime(config, exposure);

      // 4 panels * (10 * 60s exposure + 60s overhead) = 4 * 660s = 2640s
      expect(time, equals(2640.0));
    });

    test('respects custom overhead', () {
      const config = MosaicConfig(
        centerRa: 12.0,
        centerDec: 30.0,
        panelWidthArcmin: 60.0,
        panelHeightArcmin: 40.0,
        panelsHorizontal: 1,
        panelsVertical: 1,
      );

      const exposure = MosaicExposureSettings(
        exposureSeconds: 60.0,
        exposuresPerPanel: 10,
      );

      final time = service.estimateMosaicTime(
        config,
        exposure,
        overheadPerPanelSecs: 120.0,
      );

      // 1 panel * (10 * 60s + 120s) = 720s
      expect(time, equals(720.0));
    });
  });

  group('MosaicService - Validation', () {
    test('validates correct configuration', () {
      const config = MosaicConfig(
        centerRa: 12.0,
        centerDec: 30.0,
        panelWidthArcmin: 60.0,
        panelHeightArcmin: 40.0,
        panelsHorizontal: 3,
        panelsVertical: 3,
      );

      final validation = service.validateMosaic(config);

      expect(validation.isValid, isTrue);
      expect(validation.errors, isEmpty);
    });

    test('rejects invalid RA', () {
      const config = MosaicConfig(
        centerRa: 25.0, // Invalid: must be < 24
        centerDec: 30.0,
        panelWidthArcmin: 60.0,
        panelHeightArcmin: 40.0,
        panelsHorizontal: 3,
        panelsVertical: 3,
      );

      final validation = service.validateMosaic(config);

      expect(validation.isValid, isFalse);
      expect(validation.errors, isNotEmpty);
      expect(
        validation.errors.any((e) => e.contains('Right Ascension')),
        isTrue,
      );
    });

    test('rejects invalid declination', () {
      const config = MosaicConfig(
        centerRa: 12.0,
        centerDec: 95.0, // Invalid: must be <= 90
        panelWidthArcmin: 60.0,
        panelHeightArcmin: 40.0,
        panelsHorizontal: 3,
        panelsVertical: 3,
      );

      final validation = service.validateMosaic(config);

      expect(validation.isValid, isFalse);
      expect(validation.errors.any((e) => e.contains('Declination')), isTrue);
    });

    test('rejects invalid panel dimensions', () {
      const config = MosaicConfig(
        centerRa: 12.0,
        centerDec: 30.0,
        panelWidthArcmin: -10.0, // Invalid: must be positive
        panelHeightArcmin: 40.0,
        panelsHorizontal: 3,
        panelsVertical: 3,
      );

      final validation = service.validateMosaic(config);

      expect(validation.isValid, isFalse);
      expect(validation.errors.any((e) => e.contains('dimensions')), isTrue);
    });

    test('rejects invalid grid size', () {
      const config = MosaicConfig(
        centerRa: 12.0,
        centerDec: 30.0,
        panelWidthArcmin: 60.0,
        panelHeightArcmin: 40.0,
        panelsHorizontal: 0, // Invalid: must be >= 1
        panelsVertical: 3,
      );

      final validation = service.validateMosaic(config);

      expect(validation.isValid, isFalse);
      expect(validation.errors.any((e) => e.contains('Grid size')), isTrue);
    });

    test('warns about low overlap', () {
      const config = MosaicConfig(
        centerRa: 12.0,
        centerDec: 30.0,
        panelWidthArcmin: 60.0,
        panelHeightArcmin: 40.0,
        overlapPercent: 2.0, // Low overlap
        panelsHorizontal: 3,
        panelsVertical: 3,
      );

      final validation = service.validateMosaic(config);

      expect(validation.isValid, isTrue);
      expect(validation.hasWarnings, isTrue);
      expect(validation.warnings.any((w) => w.contains('overlap')), isTrue);
    });

    test('warns about high overlap', () {
      const config = MosaicConfig(
        centerRa: 12.0,
        centerDec: 30.0,
        panelWidthArcmin: 60.0,
        panelHeightArcmin: 40.0,
        overlapPercent: 60.0, // High overlap
        panelsHorizontal: 3,
        panelsVertical: 3,
      );

      final validation = service.validateMosaic(config);

      expect(validation.isValid, isTrue);
      expect(validation.hasWarnings, isTrue);
      expect(validation.warnings.any((w) => w.contains('overlap')), isTrue);
    });

    test('warns about large mosaics', () {
      const config = MosaicConfig(
        centerRa: 12.0,
        centerDec: 30.0,
        panelWidthArcmin: 60.0,
        panelHeightArcmin: 40.0,
        panelsHorizontal: 25, // Large grid
        panelsVertical: 25,
      );

      final validation = service.validateMosaic(config);

      expect(validation.isValid, isTrue);
      expect(validation.hasWarnings, isTrue);
      expect(validation.warnings.any((w) => w.contains('20 panels')), isTrue);
    });

    test('warns about polar regions', () {
      const config = MosaicConfig(
        centerRa: 12.0,
        centerDec: 85.0, // Near north celestial pole
        panelWidthArcmin: 60.0,
        panelHeightArcmin: 40.0,
        panelsHorizontal: 3,
        panelsVertical: 3,
      );

      final validation = service.validateMosaic(config);

      expect(validation.isValid, isTrue);
      expect(validation.hasWarnings, isTrue);
      expect(validation.warnings.any((w) => w.contains('poles')), isTrue);
    });
  });

  group('MosaicService - Sequence Generation', () {
    test('generates sequence with correct number of target groups', () {
      const config = MosaicConfig(
        centerRa: 12.0,
        centerDec: 30.0,
        panelWidthArcmin: 60.0,
        panelHeightArcmin: 40.0,
        panelsHorizontal: 2,
        panelsVertical: 2,
      );

      const exposure = MosaicExposureSettings(
        exposureSeconds: 60.0,
        exposuresPerPanel: 10,
      );

      final nodes = service.createMosaicSequence(
        mosaicName: 'Test Mosaic',
        config: config,
        exposure: exposure,
      );

      // Count target group nodes
      final targetGroups = nodes.values.whereType<TargetHeaderNode>().toList();
      expect(targetGroups.length, equals(4)); // 2x2 grid
    });

    test('stamps panel identity and a complete parent-child graph', () {
      const config = MosaicConfig(
        centerRa: 12.0,
        centerDec: 30.0,
        panelWidthArcmin: 60.0,
        panelHeightArcmin: 40.0,
        panelsHorizontal: 2,
        panelsVertical: 2,
      );
      const exposure = MosaicExposureSettings(
        exposureSeconds: 60.0,
        exposuresPerPanel: 10,
      );

      final nodes = service.createMosaicSequence(
        mosaicName: 'Test Mosaic',
        config: config,
        exposure: exposure,
      );
      final root = nodes.values.whereType<InstructionSetNode>().single;
      final headers = nodes.values.whereType<TargetHeaderNode>().toList()
        ..sort(
          (a, b) =>
              a.mosaicPanel!.panelIndex.compareTo(b.mosaicPanel!.panelIndex),
        );

      expect(root.childIds, hasLength(4));
      expect(headers, hasLength(4));
      for (var i = 0; i < headers.length; i++) {
        final header = headers[i];
        expect(header.parentId, root.id);
        expect(root.childIds.where((id) => id == header.id), hasLength(1));
        expect(
          header.mosaicPanel,
          const MosaicPanelInfo(
            mosaicName: 'Test Mosaic',
            panelIndex: 0,
            totalPanels: 4,
            row: 0,
            column: 0,
          ).copyWith(panelIndex: i, row: i ~/ 2, column: i % 2),
        );
      }

      for (final node in nodes.values) {
        if (node.id == root.id) continue;
        final parent = nodes[node.parentId];
        expect(parent, isNotNull, reason: '${node.name} has no parent');
        expect(parent!.childIds.where((id) => id == node.id), hasLength(1));
      }
    });

    test('generates sequence with slew and center nodes', () {
      const config = MosaicConfig(
        centerRa: 12.0,
        centerDec: 30.0,
        panelWidthArcmin: 60.0,
        panelHeightArcmin: 40.0,
        panelsHorizontal: 1,
        panelsVertical: 1,
      );

      const exposure = MosaicExposureSettings(
        exposureSeconds: 60.0,
        exposuresPerPanel: 10,
      );

      final nodes = service.createMosaicSequence(
        mosaicName: 'Test Mosaic',
        config: config,
        exposure: exposure,
      );

      final slewNodes = nodes.values.whereType<SlewNode>().toList();
      final centerNodes = nodes.values.whereType<CenterNode>().toList();

      expect(slewNodes.length, equals(1));
      expect(centerNodes.length, equals(1));
    });

    test('generates sequence with correct loop configuration', () {
      const config = MosaicConfig(
        centerRa: 12.0,
        centerDec: 30.0,
        panelWidthArcmin: 60.0,
        panelHeightArcmin: 40.0,
        panelsHorizontal: 1,
        panelsVertical: 1,
      );

      const exposure = MosaicExposureSettings(
        exposureSeconds: 60.0,
        exposuresPerPanel: 20,
      );

      final nodes = service.createMosaicSequence(
        mosaicName: 'Test Mosaic',
        config: config,
        exposure: exposure,
      );

      final loopNodes = nodes.values.whereType<LoopNode>().toList();

      expect(loopNodes.length, equals(1));
      expect(loopNodes[0].repeatCount, equals(20));
    });

    test('includes autofocus when enabled', () {
      const config = MosaicConfig(
        centerRa: 12.0,
        centerDec: 30.0,
        panelWidthArcmin: 60.0,
        panelHeightArcmin: 40.0,
        panelsHorizontal: 2,
        panelsVertical: 1,
      );

      const exposure = MosaicExposureSettings(
        exposureSeconds: 60.0,
        exposuresPerPanel: 10,
      );

      const options = MosaicSequenceOptions(autofocusPerPanel: true);

      final nodes = service.createMosaicSequence(
        mosaicName: 'Test Mosaic',
        config: config,
        exposure: exposure,
        options: options,
      );

      final autofocusNodes = nodes.values.whereType<AutofocusNode>().toList();
      expect(autofocusNodes.length, equals(2)); // One per panel
    });

    test('respects autofocus interval', () {
      const config = MosaicConfig(
        centerRa: 12.0,
        centerDec: 30.0,
        panelWidthArcmin: 60.0,
        panelHeightArcmin: 40.0,
        panelsHorizontal: 4,
        panelsVertical: 1,
      );

      const exposure = MosaicExposureSettings(
        exposureSeconds: 60.0,
        exposuresPerPanel: 10,
      );

      const options = MosaicSequenceOptions(
        autofocusPerPanel: true,
        autofocusInterval: 1, // Every other panel
      );

      final nodes = service.createMosaicSequence(
        mosaicName: 'Test Mosaic',
        config: config,
        exposure: exposure,
        options: options,
      );

      final autofocusNodes = nodes.values.whereType<AutofocusNode>().toList();
      expect(autofocusNodes.length, equals(2)); // Panels 0 and 2
    });

    test('includes dither when enabled', () {
      const config = MosaicConfig(
        centerRa: 12.0,
        centerDec: 30.0,
        panelWidthArcmin: 60.0,
        panelHeightArcmin: 40.0,
        panelsHorizontal: 1,
        panelsVertical: 1,
      );

      const exposure = MosaicExposureSettings(
        exposureSeconds: 60.0,
        exposuresPerPanel: 10,
      );

      const options = MosaicSequenceOptions(
        ditherBetweenExposures: true,
        ditherPixels: 5.0,
      );

      final nodes = service.createMosaicSequence(
        mosaicName: 'Test Mosaic',
        config: config,
        exposure: exposure,
        options: options,
      );

      final ditherNodes = nodes.values.whereType<DitherNode>().toList();
      expect(ditherNodes.length, equals(1));
      expect(ditherNodes[0].pixels, equals(5.0));
    });

    test('omits center when disabled', () {
      const config = MosaicConfig(
        centerRa: 12.0,
        centerDec: 30.0,
        panelWidthArcmin: 60.0,
        panelHeightArcmin: 40.0,
        panelsHorizontal: 1,
        panelsVertical: 1,
      );

      const exposure = MosaicExposureSettings(
        exposureSeconds: 60.0,
        exposuresPerPanel: 10,
      );

      const options = MosaicSequenceOptions(centerAfterSlew: false);

      final nodes = service.createMosaicSequence(
        mosaicName: 'Test Mosaic',
        config: config,
        exposure: exposure,
        options: options,
      );

      final centerNodes = nodes.values.whereType<CenterNode>().toList();
      expect(centerNodes, isEmpty);
    });

    test('applies altitude constraints to target groups', () {
      const config = MosaicConfig(
        centerRa: 12.0,
        centerDec: 30.0,
        panelWidthArcmin: 60.0,
        panelHeightArcmin: 40.0,
        panelsHorizontal: 1,
        panelsVertical: 1,
      );

      const exposure = MosaicExposureSettings(
        exposureSeconds: 60.0,
        exposuresPerPanel: 10,
      );

      const options = MosaicSequenceOptions(
        minAltitude: 30.0,
        maxAltitude: 70.0,
      );

      final nodes = service.createMosaicSequence(
        mosaicName: 'Test Mosaic',
        config: config,
        exposure: exposure,
        options: options,
      );

      final targetGroups = nodes.values.whereType<TargetHeaderNode>().toList();
      expect(targetGroups[0].minAltitude, equals(30.0));
      expect(targetGroups[0].maxAltitude, equals(70.0));
    });

    test('sets correct exposure parameters', () {
      const config = MosaicConfig(
        centerRa: 12.0,
        centerDec: 30.0,
        panelWidthArcmin: 60.0,
        panelHeightArcmin: 40.0,
        panelsHorizontal: 1,
        panelsVertical: 1,
      );

      const exposure = MosaicExposureSettings(
        exposureSeconds: 120.0,
        exposuresPerPanel: 10,
        filterName: 'Ha',
        binning: 2,
        gain: 100.0,
        offset: 10.0,
      );

      final nodes = service.createMosaicSequence(
        mosaicName: 'Test Mosaic',
        config: config,
        exposure: exposure,
      );

      final exposureNodes = nodes.values.whereType<ExposureNode>().toList();
      expect(exposureNodes.length, equals(1));
      expect(exposureNodes[0].durationSecs, equals(120.0));
      expect(exposureNodes[0].filter, equals('Ha'));
      expect(exposureNodes[0].binning, equals(BinningMode.two));
      expect(exposureNodes[0].gain, equals(100));
      expect(exposureNodes[0].offset, equals(10));
    });
  });

  group('MosaicService - Serpentine Ordering', () {
    test('applies serpentine ordering correctly', () {
      const config = MosaicConfig(
        centerRa: 12.0,
        centerDec: 30.0,
        panelWidthArcmin: 60.0,
        panelHeightArcmin: 40.0,
        panelsHorizontal: 3,
        panelsVertical: 2,
      );

      const exposure = MosaicExposureSettings(
        exposureSeconds: 60.0,
        exposuresPerPanel: 1,
      );

      const options = MosaicSequenceOptions(serpentineOrdering: true);

      final nodes = service.createMosaicSequence(
        mosaicName: 'Test Mosaic',
        config: config,
        exposure: exposure,
        options: options,
      );

      final targetGroups = nodes.values.whereType<TargetHeaderNode>().toList();

      // With serpentine ordering for 3x2 grid:
      // Row 0: 0,1,2 (left to right)
      // Row 1: 5,4,3 (right to left)
      // So order should be: 0,1,2,5,4,3

      // Check that adjacent target groups alternate direction
      expect(targetGroups.length, equals(6));

      // First three should be in same row
      // Next three should be in next row
      final firstRowCount = targetGroups
          .take(3)
          .where(
            (t) =>
                t.targetName.contains('Panel 1') ||
                t.targetName.contains('Panel 2') ||
                t.targetName.contains('Panel 3'),
          )
          .length;
      expect(firstRowCount, equals(3));
    });
  });

  group('MosaicService - Per-panel capture target (blocker a)', () {
    const config = MosaicConfig(
      centerRa: 12.0,
      centerDec: 30.0,
      panelWidthArcmin: 60.0,
      panelHeightArcmin: 40.0,
      panelsHorizontal: 3,
      panelsVertical: 2,
    );
    const exposure = MosaicExposureSettings(
      exposureSeconds: 60.0,
      exposuresPerPanel: 1,
    );

    test('stamps a DISTINCT catalogTargetId per panel from the callback', () {
      // A null catalogTargetId on every panel header collapses the capture: the
      // frame-registration walk attributes every panel's subs to the SAME target
      // and integratePanels pools one field into all N panels. With the
      // per-panel callback each header carries its own id (panelIndex + 100),
      // so frames stay attributable per panel.
      final nodes = service.createMosaicSequence(
        mosaicName: 'Test Mosaic',
        config: config,
        exposure: exposure,
        // serpentine off so orderIndex lines up with panelIndex for a clean
        // assertion; the stamping keys off panel.panelIndex either way.
        options: const MosaicSequenceOptions(serpentineOrdering: false),
        panelTargetId: (panelIndex) => 100 + panelIndex,
      );

      final headers = nodes.values.whereType<TargetHeaderNode>().toList()
        ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
      expect(headers, hasLength(6));

      final ids = headers.map((h) => h.catalogTargetId).toList();
      // Six panels -> six distinct, non-null capture targets.
      expect(
        ids.whereType<int>(),
        hasLength(6),
        reason: 'every panel header must carry a non-null catalogTargetId',
      );
      expect(
        ids.toSet(),
        hasLength(6),
        reason: 'each panel must attribute to its OWN target (no pooling)',
      );
      // Each id resolves to its own panel index (header order == panel index
      // with serpentine off).
      expect(ids, equals(const [100, 101, 102, 103, 104, 105]));
    });

    test('leaves catalogTargetId null when no callback is supplied', () {
      // The legacy/manual path (no durable per-panel targets) must be
      // unchanged: headers stay null so manual mosaics keep their honest
      // "unattributed" behaviour rather than silently pooling.
      final nodes = service.createMosaicSequence(
        mosaicName: 'Test Mosaic',
        config: config,
        exposure: exposure,
      );
      final headers = nodes.values.whereType<TargetHeaderNode>();
      expect(headers, isNotEmpty);
      expect(
        headers.every((h) => h.catalogTargetId == null),
        isTrue,
        reason: 'no callback => every panel header keeps a null target id',
      );
    });

    test('a callback returning null for a panel leaves that header null', () {
      // A sparse map (only some panels have a durable target row yet) must not
      // crash and must stamp only the panels the callback resolves.
      final nodes = service.createMosaicSequence(
        mosaicName: 'Test Mosaic',
        config: config,
        exposure: exposure,
        options: const MosaicSequenceOptions(serpentineOrdering: false),
        panelTargetId: (panelIndex) =>
            panelIndex.isEven ? 200 + panelIndex : null,
      );
      final headers = nodes.values.whereType<TargetHeaderNode>().toList()
        ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
      expect(
        headers.map((h) => h.catalogTargetId).toList(),
        equals(const [200, null, 202, null, 204, null]),
      );
    });
  });

  group('MosaicService - W1 altitude gate', () {
    test('minAltitude option flows onto every panel TargetHeader', () {
      // When the wizard / framing call sites default minAltitude to the Smart
      // Night floor, each panel header must carry that minAltitude so the
      // serializer emits `min_altitude` and the executor installs a
      // `start_when AltitudeAbove` wait.
      const config = MosaicConfig(
        centerRa: 12.0,
        centerDec: 30.0,
        panelWidthArcmin: 60.0,
        panelHeightArcmin: 40.0,
        panelsHorizontal: 2,
        panelsVertical: 2,
      );
      const exposure = MosaicExposureSettings(
        exposureSeconds: 60.0,
        exposuresPerPanel: 1,
      );

      final nodes = service.createMosaicSequence(
        mosaicName: 'Test Mosaic',
        config: config,
        exposure: exposure,
        options: const MosaicSequenceOptions(minAltitude: 30.0),
      );

      final headers = nodes.values.whereType<TargetHeaderNode>().toList();
      expect(headers, hasLength(4));
      expect(
        headers.every((h) => h.minAltitude == 30.0),
        isTrue,
        reason: 'every panel must gate on the configured altitude floor',
      );
      expect(headers.every((h) => h.hasAltitudeConstraints), isTrue);
    });
  });

  group('MosaicService - Multi-filter per panel', () {
    const config = MosaicConfig(
      centerRa: 12.0,
      centerDec: 30.0,
      panelWidthArcmin: 60.0,
      panelHeightArcmin: 40.0,
      panelsHorizontal: 2,
      panelsVertical: 1,
    );

    final exposure = MosaicExposureSettings.multiFilter(
      filters: const [
        MosaicFilterExposure(
          exposureSeconds: 300.0,
          exposuresPerPanel: 12,
          filterName: 'Ha',
          binning: 1,
          gain: 200.0,
          offset: 50.0,
        ),
        MosaicFilterExposure(
          exposureSeconds: 300.0,
          exposuresPerPanel: 8,
          filterName: 'OIII',
          binning: 1,
          gain: 200.0,
          offset: 50.0,
        ),
        MosaicFilterExposure(
          exposureSeconds: 120.0,
          exposuresPerPanel: 4,
          filterName: 'SII',
          binning: 2,
          gain: 120.0,
          offset: 20.0,
        ),
      ],
    );

    test('multiFilter constructor mirrors the first filter into scalars', () {
      expect(exposure.isMultiFilter, isTrue);
      expect(exposure.filters, hasLength(3));
      // Scalar fields seed from filters.first so single-value readers stay
      // correct without inspecting the per-filter plan.
      expect(exposure.exposureSeconds, equals(300.0));
      expect(exposure.exposuresPerPanel, equals(12));
      expect(exposure.filterName, equals('Ha'));
      expect(exposure.binning, equals(1));
      expect(exposure.gain, equals(200.0));
      expect(exposure.offset, equals(50.0));
    });

    test('multiFilter rejects an empty filter list', () {
      expect(
        () => MosaicExposureSettings.multiFilter(filters: const []),
        throwsA(isA<AssertionError>()),
      );
    });

    test('single-filter settings resolve to a one-element plan', () {
      const single = MosaicExposureSettings(
        exposureSeconds: 60.0,
        exposuresPerPanel: 10,
        filterName: 'L',
      );
      expect(single.isMultiFilter, isFalse);
      expect(single.resolvedFilters, hasLength(1));
      expect(single.resolvedFilters.single.filterName, equals('L'));
      expect(single.resolvedFilters.single.exposuresPerPanel, equals(10));
    });

    test('every panel images the full filter set in order', () {
      final nodes = service.createMosaicSequence(
        mosaicName: 'SHO Mosaic',
        config: config,
        exposure: exposure,
        options: const MosaicSequenceOptions(serpentineOrdering: false),
      );

      final headers = nodes.values.whereType<TargetHeaderNode>().toList()
        ..sort((a, b) => a.orderIndex.compareTo(b.orderIndex));
      expect(headers, hasLength(2), reason: '2x1 grid => two panels');

      // 3 filters per panel => 3 exposure loops per panel.
      for (final header in headers) {
        final loops = header.childIds
            .map((id) => nodes[id])
            .whereType<LoopNode>()
            .toList();
        expect(loops, hasLength(3));

        // Loops appear in filter order with each filter's own sub count.
        final exposureNodes = loops
            .map(
              (loop) => loop.childIds
                  .map((id) => nodes[id])
                  .whereType<ExposureNode>()
                  .single,
            )
            .toList();
        expect(
          exposureNodes.map((e) => e.filter).toList(),
          equals(['Ha', 'OIII', 'SII']),
        );
        expect(loops.map((l) => l.repeatCount).toList(), equals([12, 8, 4]));
      }
    });

    test('per-filter capture parameters ride onto each exposure node', () {
      final nodes = service.createMosaicSequence(
        mosaicName: 'SHO Mosaic',
        config: config,
        exposure: exposure,
        options: const MosaicSequenceOptions(serpentineOrdering: false),
      );

      final byFilter = <String?, ExposureNode>{};
      for (final node in nodes.values.whereType<ExposureNode>()) {
        byFilter[node.filter] = node;
      }

      expect(byFilter['SII']!.durationSecs, equals(120.0));
      expect(byFilter['SII']!.binning, equals(BinningMode.two));
      expect(byFilter['SII']!.gain, equals(120));
      expect(byFilter['SII']!.offset, equals(20));
      expect(byFilter['Ha']!.binning, equals(BinningMode.one));
      expect(byFilter['Ha']!.gain, equals(200));
    });

    test('time estimate sums every channel per panel', () {
      // 2 panels * ((12*300 + 8*300 + 4*120) exposure + 60 overhead)
      // = 2 * (3600 + 2400 + 480 + 60) = 2 * 6540 = 13080
      final time = service.estimateMosaicTime(config, exposure);
      expect(time, equals(13080.0));
    });

    test('single-filter sequence is unchanged (one loop per panel)', () {
      const single = MosaicExposureSettings(
        exposureSeconds: 60.0,
        exposuresPerPanel: 10,
        filterName: 'L',
      );
      final nodes = service.createMosaicSequence(
        mosaicName: 'Lum Mosaic',
        config: config,
        exposure: single,
        options: const MosaicSequenceOptions(serpentineOrdering: false),
      );
      final loops = nodes.values.whereType<LoopNode>().toList();
      // Two panels, one loop each.
      expect(loops, hasLength(2));
      expect(loops.every((l) => l.repeatCount == 10), isTrue);
      final exposures = nodes.values.whereType<ExposureNode>().toList();
      expect(exposures, hasLength(2));
      expect(exposures.every((e) => e.filter == 'L'), isTrue);
    });
  });
}
