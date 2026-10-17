import '../models/sequence/sequence_models.dart';
import '../models/imaging/imaging_models.dart' show FrameType;
import 'package:uuid/uuid.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart'
    show mosaicPanelCenters;

/// Result of mosaic panel generation
class MosaicPanel {
  final double raHours;
  final double decDegrees;
  final int panelIndex;
  final int row;
  final int col;

  const MosaicPanel({
    required this.raHours,
    required this.decDegrees,
    required this.panelIndex,
    required this.row,
    required this.col,
  });

  @override
  String toString() =>
      'Panel $panelIndex [$row,$col]: RA=${raHours.toStringAsFixed(4)}h, Dec=${decDegrees.toStringAsFixed(4)}°';
}

/// Configuration for generating a mosaic
class MosaicConfig {
  final double centerRa;
  final double centerDec;
  final double panelWidthArcmin;
  final double panelHeightArcmin;
  final double overlapPercent;
  final double rotation;
  final int panelsHorizontal;
  final int panelsVertical;

  const MosaicConfig({
    required this.centerRa,
    required this.centerDec,
    required this.panelWidthArcmin,
    required this.panelHeightArcmin,
    this.overlapPercent = 10.0,
    this.rotation = 0.0,
    required this.panelsHorizontal,
    required this.panelsVertical,
  });

  int get totalPanels => panelsHorizontal * panelsVertical;

  /// The mosaic's total angular extent on the sky, in degrees.
  ///
  /// Overlapping panels do NOT add their full width: adjacent centres are
  /// [overlapPercent] closer than a panel width, so an N-panel row spans
  /// `panelWidth * (1 + (N-1) * (1 - overlap))`, not `panelWidth * N`. This is
  /// the same overlap-reduced step [MosaicService.generatePanels] lays the grid
  /// out with, so the reported extent describes the grid that will actually be
  /// imaged.
  (double widthDeg, double heightDeg) get totalExtentDegrees {
    final overlapFactor = 1.0 - (overlapPercent / 100.0);
    final widthDeg =
        panelWidthArcmin * (1 + (panelsHorizontal - 1) * overlapFactor) / 60.0;
    final heightDeg =
        panelHeightArcmin * (1 + (panelsVertical - 1) * overlapFactor) / 60.0;
    return (widthDeg, heightDeg);
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

/// A single filter's contribution to a multi-filter mosaic panel.
///
/// Each panel of a multi-filter mosaic images every entry in
/// [MosaicExposureSettings.filters] in order, accumulating [exposuresPerPanel]
/// subs of [exposureSeconds] through [filterName]. This is the per-filter
/// analogue of the legacy single-filter [MosaicExposureSettings] fields and
/// reuses the same [binning]/[gain]/[offset] semantics so a filter can carry
/// narrowband-specific capture parameters (e.g. higher gain + longer subs for
/// Ha) independent of the broadband channels.
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

/// Exposure settings for each panel.
///
/// Supports two interchangeable shapes:
///
/// * **Single-filter (legacy):** populate [exposureSeconds] /
///   [exposuresPerPanel] / [filterName] / [binning] / [gain] / [offset]
///   directly and leave [filters] null. Every existing caller and the Smart
///   Night recommender produce this shape, so the default constructor and all
///   field semantics are unchanged.
/// * **Multi-filter:** pass a non-empty [filters] list via
///   [MosaicExposureSettings.multiFilter]; each panel images every filter in
///   order. The top-level scalar fields then mirror the first filter so that
///   code reading [exposureSeconds]/[filterName] (e.g. time estimation,
///   summaries) still sees a sensible single value without branching.
///
/// Use [isMultiFilter] to detect which path is active and [resolvedFilters]
/// to iterate the per-filter plan uniformly regardless of shape.
class MosaicExposureSettings {
  final double exposureSeconds;
  final int exposuresPerPanel;
  final String? filterName;
  final int? binning;
  final double? gain;
  final double? offset;

  /// Per-filter exposure plan for a multi-filter mosaic, or null for the
  /// legacy single-filter path. When non-null this is guaranteed non-empty.
  final List<MosaicFilterExposure>? filters;

  const MosaicExposureSettings({
    required this.exposureSeconds,
    required this.exposuresPerPanel,
    this.filterName,
    this.binning,
    this.gain,
    this.offset,
    this.filters,
  });

  /// Build a multi-filter mosaic exposure plan from a non-empty list of
  /// per-filter settings. The scalar fields are seeded from [filters.first]
  /// so single-value readers stay correct without inspecting [filters].
  MosaicExposureSettings.multiFilter({
    required List<MosaicFilterExposure> filters,
  }) : assert(filters.isNotEmpty, 'multiFilter requires at least one filter'),
       exposureSeconds = filters.first.exposureSeconds,
       exposuresPerPanel = filters.first.exposuresPerPanel,
       filterName = filters.first.filterName,
       binning = filters.first.binning,
       gain = filters.first.gain,
       offset = filters.first.offset,
       filters = List.unmodifiable(filters);

  /// True when this carries an explicit per-filter plan ([filters] non-null
  /// and non-empty); false for the legacy single-filter path.
  bool get isMultiFilter => filters != null && filters!.isNotEmpty;

  /// The per-filter plan to image each panel with, regardless of shape.
  ///
  /// For the multi-filter path this is [filters]; for the legacy single-filter
  /// path it is a one-element list synthesized from the scalar fields so
  /// callers can iterate uniformly.
  List<MosaicFilterExposure> get resolvedFilters => isMultiFilter
      ? filters!
      : [
          MosaicFilterExposure(
            exposureSeconds: exposureSeconds,
            exposuresPerPanel: exposuresPerPanel,
            filterName: filterName,
            binning: binning,
            gain: gain,
            offset: offset,
          ),
        ];
}

/// Options for mosaic sequence generation
class MosaicSequenceOptions {
  /// Use serpentine (snake) ordering to minimize slew distance
  final bool serpentineOrdering;

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
    this.serpentineOrdering = true,
    this.autofocusPerPanel = false,
    this.autofocusInterval = 0,
    this.centerAfterSlew = true,
    this.ditherBetweenExposures = false,
    this.ditherPixels,
    this.minAltitude,
    this.maxAltitude,
  });
}

/// Validation result for a mosaic configuration
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

/// Service for generating and managing mosaics
class MosaicService {
  const MosaicService();

  /// Convert int binning to BinningMode enum
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

  /// Generate mosaic panels from configuration
  ///
  /// Returns a list of panel coordinates calculated using pure Dart spherical geometry.
  /// This implementation is driver-agnostic and works for both local and remote clients.
  List<MosaicPanel> generatePanels(MosaicConfig config) {
    // Calculate effective step sizes accounting for overlap, converting the
    // panel dimensions from arcminutes to degrees on the sky.
    final overlapFactor = 1.0 - (config.overlapPercent / 100.0);
    final stepRaDeg = config.panelWidthArcmin * overlapFactor / 60.0;
    final stepDecDeg = config.panelHeightArcmin * overlapFactor / 60.0;

    // Delegate the panel-center/overlap/rotation/cos(dec) math to the shared,
    // canonical [mosaicPanelCenters] implementation (in skotiq_planetarium)
    // so the imaging-side layout and the planetarium preview stay identical —
    // one source of truth for panel geometry.
    final centers = mosaicPanelCenters(
      centerRaHours: config.centerRa,
      centerDecDegrees: config.centerDec,
      stepRaDegrees: stepRaDeg,
      stepDecDegrees: stepDecDeg,
      columns: config.panelsHorizontal,
      rows: config.panelsVertical,
      rotationDegrees: config.rotation,
    );

    return centers
        .map(
          (c) => MosaicPanel(
            raHours: c.raHours,
            decDegrees: c.decDegrees,
            panelIndex: c.index,
            row: c.row,
            col: c.col,
          ),
        )
        .toList();
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
    for (final filterExposure in exposure.resolvedFilters) {
      exposureTimePerPanel +=
          filterExposure.exposuresPerPanel * filterExposure.exposureSeconds;
    }
    final totalTimePerPanel = exposureTimePerPanel + overheadPerPanelSecs;
    return config.totalPanels * totalTimePerPanel;
  }

  /// Validate mosaic configuration
  MosaicValidation validateMosaic(MosaicConfig config) {
    final errors = <String>[];
    final warnings = <String>[];

    // Validate panel dimensions
    if (config.panelWidthArcmin <= 0 || config.panelHeightArcmin <= 0) {
      errors.add('Panel dimensions must be positive');
    }

    if (config.panelWidthArcmin > 360 * 60 ||
        config.panelHeightArcmin > 360 * 60) {
      errors.add('Panel dimensions exceed 360 degrees');
    }

    // Validate grid size
    if (config.panelsHorizontal < 1 || config.panelsVertical < 1) {
      errors.add('Grid size must be at least 1x1');
    }

    if (config.panelsHorizontal > 20 || config.panelsVertical > 20) {
      warnings.add(
        'Large mosaics (>20 panels per dimension) may take very long',
      );
    }

    // Validate coordinates
    if (config.centerRa < 0 || config.centerRa >= 24) {
      errors.add('Right Ascension must be between 0 and 24 hours');
    }

    if (config.centerDec < -90 || config.centerDec > 90) {
      errors.add('Declination must be between -90 and 90 degrees');
    }

    // Validate overlap
    if (config.overlapPercent < 0 || config.overlapPercent > 100) {
      errors.add('Overlap must be between 0 and 100 percent');
    }

    if (config.overlapPercent < 5) {
      warnings.add('Low overlap (<5%) may cause stitching issues');
    }

    if (config.overlapPercent > 50) {
      warnings.add('High overlap (>50%) wastes imaging time');
    }

    // Check total panel count
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
  /// [MosaicPanel.panelIndex] to the DB `targets.id` that the panel images,
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
    final panels = generatePanels(config);
    final nodes = <String, SequenceNode>{};
    const uuid = Uuid();
    final rootId = uuid.v4();

    // Reorder panels if using serpentine ordering
    final orderedPanels = options.serpentineOrdering
        ? _applySerpentineOrdering(panels, config.panelsHorizontal)
        : panels;

    // Create target group nodes for each panel
    final targetGroupIds = <String>[];

    for (var i = 0; i < orderedPanels.length; i++) {
      final panel = orderedPanels[i];
      final targetGroupId = uuid.v4();
      final childIds = <String>[];

      // Add autofocus if enabled and at the right interval
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

      // Add slew instruction
      final slewId = uuid.v4();
      childIds.add(slewId);
      nodes[slewId] = SlewNode(
        id: slewId,
        name: 'Slew to Panel ${panel.panelIndex + 1}',
        useTargetCoords: false,
        customRa: panel.raHours,
        customDec: panel.decDegrees,
        parentId: targetGroupId,
        orderIndex: childIds.length - 1,
      );

      // Add centering if enabled
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
      for (final filterExposure in exposure.resolvedFilters) {
        final loopId = uuid.v4();
        childIds.add(loopId);
        final loopOrderIndex = childIds.length - 1;

        // Create exposure node
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

      // Create target header
      nodes[targetGroupId] = TargetHeaderNode(
        id: targetGroupId,
        name: 'Panel ${panel.panelIndex + 1} [${panel.row},${panel.col}]',
        targetName: '$mosaicName Panel ${panel.panelIndex + 1}',
        raHours: panel.raHours,
        decDegrees: panel.decDegrees,
        rotation: config.rotation != 0.0 ? config.rotation : null,
        priority: i,
        minAltitude: options.minAltitude,
        maxAltitude: options.maxAltitude,
        mosaicPanel: MosaicPanelInfo(
          mosaicName: mosaicName,
          panelIndex: panel.panelIndex,
          totalPanels: panels.length,
          row: panel.row,
          column: panel.col,
        ),
        // Stamp the panel's own capture target so frames written under this
        // header attribute to the per-panel `targets` row, not a shared one.
        catalogTargetId: panelTargetId?.call(panel.panelIndex),
        childIds: childIds,
        parentId: rootId,
        orderIndex: i,
      );

      targetGroupIds.add(targetGroupId);
    }

    // Create root instruction set containing all target groups
    nodes[rootId] = InstructionSetNode(
      id: rootId,
      name: mosaicName,
      childIds: targetGroupIds,
    );

    return nodes;
  }

  /// Apply serpentine (snake) ordering to panels to minimize slew distance
  ///
  /// Instead of always going left-to-right, alternate:
  /// Row 0: left -> right
  /// Row 1: right -> left
  /// Row 2: left -> right
  /// etc.
  List<MosaicPanel> _applySerpentineOrdering(
    List<MosaicPanel> panels,
    int panelsHorizontal,
  ) {
    // Group panels by row
    final rowMap = <int, List<MosaicPanel>>{};
    for (final panel in panels) {
      rowMap.putIfAbsent(panel.row, () => []).add(panel);
    }

    // Sort each row by column
    for (final row in rowMap.values) {
      row.sort((a, b) => a.col.compareTo(b.col));
    }

    // Build serpentine ordered list
    final result = <MosaicPanel>[];
    final sortedRows = rowMap.keys.toList()..sort();

    for (var i = 0; i < sortedRows.length; i++) {
      final row = sortedRows[i];
      final rowPanels = rowMap[row]!;

      // Reverse every other row
      if (i.isOdd) {
        result.addAll(rowPanels.reversed);
      } else {
        result.addAll(rowPanels);
      }
    }

    return result;
  }
}
