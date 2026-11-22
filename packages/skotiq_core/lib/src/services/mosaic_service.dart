import '../models/sequence/sequence_models.dart';
import '../models/imaging/imaging_models.dart' show FrameType;
import 'package:uuid/uuid.dart';
import 'package:skotiq_astro/skotiq_astro.dart'
    show
        MosaicGrid,
        MosaicPanel,
        MosaicStartCorner,
        mosaicPanelCenters,
        mosaicPanelName,
        mosaicPanelTargetName;

class MosaicConfig {
  final double centerRa;
  final double centerDec;
  final double panelWidthArcmin;
  final double panelHeightArcmin;
  final double overlapPercent;
  final double rotation;
  final int panelsHorizontal;
  final int panelsVertical;

  /// Where capture starts, and whether each row reverses (see [MosaicPanel]).
  final MosaicStartCorner startCorner;
  final bool serpentine;

  const MosaicConfig({
    required this.centerRa,
    required this.centerDec,
    required this.panelWidthArcmin,
    required this.panelHeightArcmin,
    this.overlapPercent = 10.0,
    this.rotation = 0.0,
    required this.panelsHorizontal,
    required this.panelsVertical,
    this.startCorner = MosaicStartCorner.topLeft,
    this.serpentine = true,
  });

  int get totalPanels => panelsHorizontal * panelsVertical;

  /// The grid's shape: columns, rows and overlap.
  MosaicGrid get grid => MosaicGrid(
    columns: panelsHorizontal,
    rows: panelsVertical,
    overlapPercent: overlapPercent,
  );

  /// The mosaic's total angular extent on the sky, in degrees, overlap
  /// included ([MosaicGrid.extent]): the grid [MosaicService.generatePanels]
  /// lays out.
  (double widthDeg, double heightDeg) get totalExtentDegrees {
    final (width, height) = grid.extent(panelWidthArcmin, panelHeightArcmin);
    return (width / 60.0, height / 60.0);
  }

  /// Sky area the finished mosaic covers, in square degrees.
  ///
  /// Derived from [totalExtentDegrees], so it accounts for overlap. Summing
  /// the panel areas instead would treat the panels as edge-to-edge and
  /// overstate the coverage of every overlapping mosaic.
  double get totalAreaSquareDegrees {
    final (widthDeg, heightDeg) = totalExtentDegrees;
    return widthDeg * heightDeg;
  }
}

/// One filter's share of every mosaic panel: [exposuresPerPanel] subs of
/// [exposureSeconds] through [filterName], with its own [binning], [gain] and
/// [offset] (narrowband often takes higher gain and longer subs).
class MosaicFilterExposure {
  final String? filterName;
  final double exposureSeconds;
  final int exposuresPerPanel;
  final int? binning;
  final double? gain;
  final double? offset;

  const MosaicFilterExposure({
    required this.exposureSeconds,
    required this.exposuresPerPanel,
    this.filterName,
    this.binning,
    this.gain,
    this.offset,
  });
}

/// What each mosaic panel images: [filters], in order, never empty.
///
/// The scalar fields read the first filter, for summaries that show one
/// value.
class MosaicExposureSettings {
  final List<MosaicFilterExposure> filters;

  /// One filter for every panel.
  MosaicExposureSettings({
    required double exposureSeconds,
    required int exposuresPerPanel,
    String? filterName,
    int? binning,
    double? gain,
    double? offset,
  }) : filters = List.unmodifiable([
         MosaicFilterExposure(
           exposureSeconds: exposureSeconds,
           exposuresPerPanel: exposuresPerPanel,
           filterName: filterName,
           binning: binning,
           gain: gain,
           offset: offset,
         ),
       ]);

  /// Each panel images every one of [filters] in order.
  MosaicExposureSettings.multiFilter({
    required List<MosaicFilterExposure> filters,
  }) : assert(filters.isNotEmpty, 'multiFilter requires at least one filter'),
       filters = List.unmodifiable(filters);

  double get exposureSeconds => filters.first.exposureSeconds;
  int get exposuresPerPanel => filters.first.exposuresPerPanel;
  String? get filterName => filters.first.filterName;
  int? get binning => filters.first.binning;
  double? get gain => filters.first.gain;
  double? get offset => filters.first.offset;
}

class MosaicSequenceOptions {
  /// Add autofocus before each panel
  final bool autofocusPerPanel;

  /// Autofocus interval (0 = every panel, 1 = every other panel, etc.)
  final int autofocusInterval;

  /// Add plate solving/centering after slew
  final bool centerAfterSlew;

  /// Add dithering between exposures
  final bool ditherBetweenExposures;

  /// Dither amount in pixels
  final double? ditherPixels;

  /// Minimum altitude constraint (degrees)
  final double? minAltitude;

  /// Maximum altitude constraint (degrees)
  final double? maxAltitude;

  const MosaicSequenceOptions({
    this.autofocusPerPanel = false,
    this.autofocusInterval = 0,
    this.centerAfterSlew = true,
    this.ditherBetweenExposures = false,
    this.ditherPixels,
    this.minAltitude,
    this.maxAltitude,
  });
}

class MosaicValidation {
  final bool isValid;
  final List<String> errors;
  final List<String> warnings;

  const MosaicValidation({
    required this.isValid,
    this.errors = const [],
    this.warnings = const [],
  });

  bool get hasWarnings => warnings.isNotEmpty;
}

class MosaicService {
  const MosaicService();

  /// The [InstructionSetNode] at the root of a graph that
  /// [createMosaicSequence] or [sequenceForPanels] built.
  static InstructionSetNode rootOf(Map<String, SequenceNode> nodes) {
    for (final node in nodes.values) {
      if (node is InstructionSetNode && node.parentId == null) return node;
    }
    throw StateError('The mosaic node graph has no root InstructionSetNode.');
  }

  BinningMode _intToBinningMode(int binning) {
    switch (binning) {
      case 1:
        return BinningMode.one;
      case 2:
        return BinningMode.two;
      case 3:
        return BinningMode.three;
      case 4:
        return BinningMode.four;
      default:
        return BinningMode.one;
    }
  }

  /// The mosaic's panels in capture order, numbered as the app numbers them
  /// everywhere ([mosaicPanelCenters]).
  List<MosaicPanel> generatePanels(MosaicConfig config) {
    final grid = config.grid;
    return mosaicPanelCenters(
      centerRaHours: config.centerRa,
      centerDecDegrees: config.centerDec,
      stepRaDegrees: grid.step(config.panelWidthArcmin) / 60.0,
      stepDecDegrees: grid.step(config.panelHeightArcmin) / 60.0,
      columns: grid.columns,
      rows: grid.rows,
      rotationDegrees: config.rotation,
      startCorner: config.startCorner,
      serpentine: config.serpentine,
    );
  }

  /// Calculate the sky area the mosaic covers, in square degrees.
  ///
  /// Delegates to [MosaicConfig.totalAreaSquareDegrees] so the one definition
  /// of coverage — the overlap-reduced extent the grid is actually laid out
  /// with — is used everywhere, including `POST /api/mosaic/calculate-area`.
  double calculateMosaicArea(MosaicConfig config) =>
      config.totalAreaSquareDegrees;

  /// Estimate total imaging time in seconds (pure Dart implementation).
  ///
  /// [overheadPerPanelSecs] defaults to
  /// 60s — a conservative estimate covering slew + plate-solve + autofocus
  /// + dither between panels for a typical EQ mount + filter wheel rig.
  /// Callers with calibrated equipment profiles should pass a measured value
  /// derived from prior sessions instead of relying on the default. The
  /// settings panel surfaces this so users can lock it in per-rig.
  double estimateMosaicTime(
    MosaicConfig config,
    MosaicExposureSettings exposure, {
    double overheadPerPanelSecs = 60.0,
  }) {
    // Total time = panels * (sum over filters of exposures*time + overhead).
    // The single-filter path resolves to one entry, so the sum reduces to the
    // legacy `exposuresPerPanel * exposureSeconds`; a multi-filter plan sums
    // every channel's contribution since each panel images all of them.
    var exposureTimePerPanel = 0.0;
    for (final filterExposure in exposure.filters) {
      exposureTimePerPanel +=
          filterExposure.exposuresPerPanel * filterExposure.exposureSeconds;
    }
    final totalTimePerPanel = exposureTimePerPanel + overheadPerPanelSecs;
    return config.totalPanels * totalTimePerPanel;
  }

  MosaicValidation validateMosaic(MosaicConfig config) {
    final errors = <String>[];
    final warnings = <String>[];

    if (config.panelWidthArcmin <= 0 || config.panelHeightArcmin <= 0) {
      errors.add('Panel dimensions must be positive');
    }

    if (config.panelWidthArcmin > 360 * 60 ||
        config.panelHeightArcmin > 360 * 60) {
      errors.add('Panel dimensions exceed 360 degrees');
    }

    if (config.panelsHorizontal < 1 || config.panelsVertical < 1) {
      errors.add('Grid size must be at least 1x1');
    }

    if (config.panelsHorizontal > 20 || config.panelsVertical > 20) {
      warnings.add(
        'Large mosaics (>20 panels per dimension) may take very long',
      );
    }

    if (config.centerRa < 0 || config.centerRa >= 24) {
      errors.add('Right Ascension must be between 0 and 24 hours');
    }

    if (config.centerDec < -90 || config.centerDec > 90) {
      errors.add('Declination must be between -90 and 90 degrees');
    }

    if (config.overlapPercent < 0 || config.overlapPercent > 100) {
      errors.add('Overlap must be between 0 and 100 percent');
    }

    if (config.overlapPercent < 5) {
      warnings.add('Low overlap (<5%) may cause stitching issues');
    }

    if (config.overlapPercent > 50) {
      warnings.add('High overlap (>50%) wastes imaging time');
    }

    if (config.totalPanels > 100) {
      warnings.add(
        'More than 100 panels will take multiple nights to complete',
      );
    }

    // Check if target is near celestial poles
    if (config.centerDec.abs() > 80) {
      warnings.add(
        'Targets near celestial poles may have distorted panel layout',
      );
    }

    return MosaicValidation(
      isValid: errors.isEmpty,
      errors: errors,
      warnings: warnings,
    );
  }

  /// Create a sequence from mosaic panels.
  ///
  /// Generates a complete imaging sequence with one [TargetHeaderNode]
  /// per panel, each carrying its own [MosaicPanelInfo] (mosaic name,
  /// panel index, row, column, total panels). The Rust executor
  /// populates the per-panel `MosaicPanelInfo` into the
  /// `ExecutionContext` at TargetHeader entry, which then flows into
  /// every FITS frame written for that panel (`MOSAIC=1`, `PANELIDX`,
  /// `PANELROW`, `PANELCOL`, `SK-MOSNM`, `SK-PIDX`, `SK-PROW`,
  /// `SK-PCOL`, `SK-NPAN`).
  ///
  /// Every panel is a distinct [TargetHeaderNode] with a stable UUID, so
  /// panel-level resume runs through the executor's
  /// [SessionCheckpoint.nodeStatuses] map: nodes marked `Success` on a previous
  /// run are skipped, and a 3×3 mosaic killed mid-panel-5 resumes at panel 5.
  /// The Wizard checkpoint slot `wizard_states["mosaic"]` is unused on this
  /// path; it is written only when a sequence contains a Rust `Mosaic` node.
  ///
  /// [panelTargetId] optionally maps a panel's 0-based row-major
  /// [MosaicPanel.index] to the DB `targets.id` that the panel images,
  /// which is stamped onto that panel's [TargetHeaderNode.catalogTargetId].
  /// This is what makes a durable mosaic's frames attributable PER PANEL: the
  /// frame-registration path walks to the header's `catalogTargetId`, so each
  /// panel's subs pool into its own `targets` row instead of all panels
  /// sharing one. Without it every panel carries a null id, the project service
  /// pools every panel's subs under the project target, and `integratePanels`
  /// integrates the same field N times.
  /// The key matches [MosaicProjectService.createProject]'s `panelTargetId`
  /// callback so the per-panel `mosaic_panels.target_id` and the per-panel
  /// header `catalogTargetId` line up by index. `null` (or a callback that
  /// returns null for a panel) leaves that header's id null.
  Map<String, SequenceNode> createMosaicSequence({
    required String mosaicName,
    required MosaicConfig config,
    required MosaicExposureSettings exposure,
    MosaicSequenceOptions options = const MosaicSequenceOptions(),
    int? Function(int panelIndex)? panelTargetId,
  }) {
    return sequenceForPanels(
      mosaicName: mosaicName,
      panels: generatePanels(config),
      rotation: config.rotation,
      exposure: exposure,
      options: options,
      panelTargetId: panelTargetId,
    );
  }

  /// The mosaic's sequence for [panels] already in capture order: one
  /// [TargetHeaderNode] per panel, as [panelHeader] names and gates it, with
  /// its slew, centering and exposures, under one [InstructionSetNode] named
  /// [mosaicName].
  Map<String, SequenceNode> sequenceForPanels({
    required String mosaicName,
    required List<MosaicPanel> panels,
    required double rotation,
    required MosaicExposureSettings exposure,
    MosaicSequenceOptions options = const MosaicSequenceOptions(),
    int? Function(int panelIndex)? panelTargetId,
  }) {
    final nodes = <String, SequenceNode>{};
    const uuid = Uuid();
    final rootId = uuid.v4();

    final targetGroupIds = <String>[];

    for (var i = 0; i < panels.length; i++) {
      final panel = panels[i];
      final targetGroupId = uuid.v4();
      final childIds = <String>[];

      if (options.autofocusPerPanel &&
          (options.autofocusInterval == 0 ||
              i % (options.autofocusInterval + 1) == 0)) {
        final autofocusId = uuid.v4();
        childIds.add(autofocusId);
        nodes[autofocusId] = AutofocusNode(
          id: autofocusId,
          name: 'Autofocus',
          parentId: targetGroupId,
          orderIndex: childIds.length - 1,
        );
      }

      final slewId = uuid.v4();
      childIds.add(slewId);
      nodes[slewId] = SlewNode(
        id: slewId,
        name: 'Slew to ${mosaicPanelName(panel.index)}',
        useTargetCoords: false,
        customRa: panel.raHours,
        customDec: panel.decDegrees,
        parentId: targetGroupId,
        orderIndex: childIds.length - 1,
      );

      if (options.centerAfterSlew) {
        final centerId = uuid.v4();
        childIds.add(centerId);
        nodes[centerId] = CenterNode(
          id: centerId,
          name: 'Center',
          parentId: targetGroupId,
          orderIndex: childIds.length - 1,
        );
      }

      // Image the panel through every filter in the resolved plan. The
      // single-filter path resolves to a one-element list, so it produces
      // exactly one exposure loop with one exposure node (identical to the
      // legacy shape); a multi-filter plan produces one sibling loop per
      // filter, each repeating that filter's own per-panel sub count, so the
      // panel is fully imaged in every channel before the next panel.
      for (final filterExposure in exposure.filters) {
        final loopId = uuid.v4();
        childIds.add(loopId);
        final loopOrderIndex = childIds.length - 1;

        final exposureId = uuid.v4();
        final exposureChildIds = <String>[exposureId];

        // Add dither if enabled
        if (options.ditherBetweenExposures) {
          final ditherId = uuid.v4();
          exposureChildIds.add(ditherId);
          nodes[ditherId] = DitherNode(
            id: ditherId,
            name: 'Dither',
            parentId: loopId,
            orderIndex: 1,
            pixels: options.ditherPixels ?? 3.0,
          );
        }

        nodes[exposureId] = ExposureNode(
          id: exposureId,
          name: filterExposure.filterName != null
              ? 'Expose ${filterExposure.filterName}'
              : 'Expose',
          durationSecs: filterExposure.exposureSeconds,
          count: 1, // Loop handles the repetition
          frameType: FrameType.light,
          filter: filterExposure.filterName,
          binning: filterExposure.binning != null
              ? _intToBinningMode(filterExposure.binning!)
              : BinningMode.one,
          gain: filterExposure.gain?.toInt(),
          offset: filterExposure.offset?.toInt(),
          parentId: loopId,
          orderIndex: 0,
        );

        nodes[loopId] = LoopNode(
          id: loopId,
          name: filterExposure.filterName != null
              ? '${filterExposure.filterName} Exposure Loop'
              : 'Exposure Loop',
          conditionType: LoopConditionType.count,
          repeatCount: filterExposure.exposuresPerPanel,
          childIds: exposureChildIds,
          parentId: targetGroupId,
          orderIndex: loopOrderIndex,
        );
      }

      nodes[targetGroupId] =
          panelHeader(
            mosaicName: mosaicName,
            panel: panel,
            totalPanels: panels.length,
            rotation: rotation,
            minAltitude: options.minAltitude,
            maxAltitude: options.maxAltitude,
            // Stamp the panel's own capture target so frames written under this
            // header attribute to the per-panel `targets` row, not a shared one.
            catalogTargetId: panelTargetId?.call(panel.index),
          ).copyWith(
            id: targetGroupId,
            childIds: childIds,
            parentId: rootId,
            orderIndex: i,
          );

      targetGroupIds.add(targetGroupId);
    }

    nodes[rootId] = InstructionSetNode(
      id: rootId,
      name: mosaicName,
      childIds: targetGroupIds,
    );

    return nodes;
  }

  /// The target header of one mosaic panel, without children: the one
  /// definition of a panel's name, target name, mosaic identity (stamped
  /// into its frames' FITS headers), rotation and altitude gate. A bare header is what a drawn
  /// mosaic adds to a sequence the operator is building; [sequenceForPanels]
  /// gives the same header its slew, centering and exposures.
  TargetHeaderNode panelHeader({
    required String mosaicName,
    required MosaicPanel panel,
    required int totalPanels,
    required double rotation,
    double? minAltitude,
    double? maxAltitude,
    int? catalogTargetId,
  }) {
    final name = mosaicPanelTargetName(mosaicName, panel.index);
    return TargetHeaderNode(
      name: name,
      targetName: name,
      raHours: panel.raHours,
      decDegrees: panel.decDegrees,
      rotation: rotation != 0.0 ? rotation : null,
      priority: panel.index,
      minAltitude: minAltitude,
      maxAltitude: maxAltitude,
      mosaicPanel: MosaicPanelInfo(
        mosaicName: mosaicName,
        panelIndex: panel.index,
        totalPanels: totalPanels,
        row: panel.row,
        column: panel.col,
      ),
      catalogTargetId: catalogTargetId,
    );
  }
}
