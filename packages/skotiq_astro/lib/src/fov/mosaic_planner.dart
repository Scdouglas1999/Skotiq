import 'dart:convert';
import 'dart:math' as math;
import '../coordinate_system.dart';
import '../astronomy/astronomy_calculations.dart';
import 'mosaic_geometry.dart';

class MosaicOverlap {
  /// Horizontal overlap percentage (0-1)
  final double horizontal;

  /// Vertical overlap percentage (0-1)
  final double vertical;

  const MosaicOverlap({this.horizontal = 0.15, this.vertical = 0.15});

  MosaicOverlap copyWith({double? horizontal, double? vertical}) {
    return MosaicOverlap(
      horizontal: horizontal ?? this.horizontal,
      vertical: vertical ?? this.vertical,
    );
  }
}

class PlanetariumMosaicPanel {
  /// 0-based place in capture order (see [MosaicPanel]).
  final int index;

  /// 0-based row from the top of the grid as drawn.
  final int row;

  /// 0-based column from the left of the grid as drawn.
  final int column;

  final CelestialCoordinate center;

  /// Camera rotation angle (degrees)
  final double rotation;

  /// Field of view width (degrees)
  final double fovWidth;

  /// Field of view height (degrees)
  final double fovHeight;

  /// Panel priority (lower = higher priority)
  final int priority;

  /// Estimated imaging time (minutes)
  double? imagingTimeMinutes;

  String? label;

  PlanetariumMosaicPanel({
    required this.index,
    required this.row,
    required this.column,
    required this.center,
    required this.rotation,
    required this.fovWidth,
    required this.fovHeight,
    this.priority = 0,
    this.imagingTimeMinutes,
    this.label,
  });

  /// The panel's name: its [label], or "Panel 3".
  String get name => label ?? mosaicPanelName(index);

  /// Get corner coordinates (RA/Dec)
  List<CelestialCoordinate> get corners {
    final halfW = fovWidth / 2;
    final halfH = fovHeight / 2;
    final rotRad = rotation * math.pi / 180;

    final offsets = [
      (-halfW, -halfH), // Bottom-left
      (halfW, -halfH), // Bottom-right
      (halfW, halfH), // Top-right
      (-halfW, halfH), // Top-left
    ];

    return offsets.map((offset) {
      final x = offset.$1 * math.cos(rotRad) - offset.$2 * math.sin(rotRad);
      final y = offset.$1 * math.sin(rotRad) + offset.$2 * math.cos(rotRad);

      // Convert to celestial coordinates (simplified for small FOV)
      final dRa = MosaicPlanner._raOffsetHoursFromDegrees(x, center.dec);
      final dDec = y;

      return CelestialCoordinate(
        ra: MosaicPlanner._normalizeRaHours(center.ra + dRa),
        dec: (center.dec + dDec).clamp(-90, 90),
      );
    }).toList();
  }

  PlanetariumMosaicPanel copyWith({
    int? index,
    int? row,
    int? column,
    CelestialCoordinate? center,
    double? rotation,
    double? fovWidth,
    double? fovHeight,
    int? priority,
    double? imagingTimeMinutes,
    String? label,
  }) {
    return PlanetariumMosaicPanel(
      index: index ?? this.index,
      row: row ?? this.row,
      column: column ?? this.column,
      center: center ?? this.center,
      rotation: rotation ?? this.rotation,
      fovWidth: fovWidth ?? this.fovWidth,
      fovHeight: fovHeight ?? this.fovHeight,
      priority: priority ?? this.priority,
      imagingTimeMinutes: imagingTimeMinutes ?? this.imagingTimeMinutes,
      label: label ?? this.label,
    );
  }
}

class PlanetariumMosaicConfig {
  final CelestialCoordinate center;

  /// Total mosaic width (degrees)
  final double totalWidth;

  /// Total mosaic height (degrees)
  final double totalHeight;

  /// Single panel FOV width (degrees)
  final double panelFovWidth;

  /// Single panel FOV height (degrees)
  final double panelFovHeight;

  final MosaicOverlap overlap;

  /// Camera rotation (degrees)
  final double rotation;

  /// Number of rows (calculated or specified)
  int? rows;

  /// Number of columns (calculated or specified)
  int? columns;

  PlanetariumMosaicConfig({
    required this.center,
    required this.totalWidth,
    required this.totalHeight,
    required this.panelFovWidth,
    required this.panelFovHeight,
    this.overlap = const MosaicOverlap(),
    this.rotation = 0,
    this.rows,
    this.columns,
  });

  PlanetariumMosaicConfig copyWith({
    CelestialCoordinate? center,
    double? totalWidth,
    double? totalHeight,
    double? panelFovWidth,
    double? panelFovHeight,
    MosaicOverlap? overlap,
    double? rotation,
    int? rows,
    int? columns,
  }) {
    return PlanetariumMosaicConfig(
      center: center ?? this.center,
      totalWidth: totalWidth ?? this.totalWidth,
      totalHeight: totalHeight ?? this.totalHeight,
      panelFovWidth: panelFovWidth ?? this.panelFovWidth,
      panelFovHeight: panelFovHeight ?? this.panelFovHeight,
      overlap: overlap ?? this.overlap,
      rotation: rotation ?? this.rotation,
      rows: rows ?? this.rows,
      columns: columns ?? this.columns,
    );
  }
}

class MosaicPlan {
  /// Configuration used to generate this plan
  final PlanetariumMosaicConfig config;

  /// The panels in capture order.
  final List<PlanetariumMosaicPanel> panels;

  final int rows;

  final int columns;

  /// Effective total width after adding all panels
  final double effectiveWidth;

  /// Effective total height after adding all panels
  final double effectiveHeight;

  MosaicPlan({
    required this.config,
    required this.panels,
    required this.rows,
    required this.columns,
    required this.effectiveWidth,
    required this.effectiveHeight,
  });

  int get panelCount => panels.length;

  /// Get estimated total imaging time (minutes)
  double? get totalImagingTime {
    final times = panels.map((p) => p.imagingTimeMinutes).whereType<double>();
    if (times.isEmpty) return null;
    return times.reduce((a, b) => a + b);
  }

  CelestialCoordinate get center => config.center;

  /// Get all panel corners for outline drawing
  List<List<CelestialCoordinate>> get panelOutlines {
    return panels.map((p) => p.corners).toList();
  }
}

class MosaicPlanner {
  // Panel-center geometry is delegated to the shared [mosaicPanelCenters]
  // implementation in mosaic_geometry.dart so the planetarium preview and the
  // imaging-side MosaicService share one source of truth for panel layout.
  // These two helpers stay as thin forwarders because the corner-projection
  // math in [PlanetariumMosaicPanel.corners] still references them.
  static double _normalizeRaHours(double ra) => normalizeRaHours(ra);

  static double _raOffsetHoursFromDegrees(
    double eastOffsetDegrees,
    double decDegrees,
  ) => raOffsetHoursFromDegrees(eastOffsetDegrees, decDegrees);

  /// Calculate required number of panels to cover an area
  static (int rows, int cols) calculatePanelCount({
    required double totalWidth,
    required double totalHeight,
    required double panelWidth,
    required double panelHeight,
    MosaicOverlap overlap = const MosaicOverlap(),
  }) {
    // Effective step size accounting for overlap
    final stepWidth = panelWidth * (1 - overlap.horizontal);
    final stepHeight = panelHeight * (1 - overlap.vertical);

    final cols = (totalWidth / stepWidth).ceil().clamp(1, 100);
    final rows = (totalHeight / stepHeight).ceil().clamp(1, 100);

    return (rows, cols);
  }

  static MosaicPlan generateMosaic(PlanetariumMosaicConfig config) {
    final (calcRows, calcCols) = calculatePanelCount(
      totalWidth: config.totalWidth,
      totalHeight: config.totalHeight,
      panelWidth: config.panelFovWidth,
      panelHeight: config.panelFovHeight,
      overlap: config.overlap,
    );

    final rows = config.rows ?? calcRows;
    final cols = config.columns ?? calcCols;

    final stepWidth = config.panelFovWidth * (1 - config.overlap.horizontal);
    final stepHeight = config.panelFovHeight * (1 - config.overlap.vertical);

    final effectiveWidth = config.panelFovWidth + (cols - 1) * stepWidth;
    final effectiveHeight = config.panelFovHeight + (rows - 1) * stepHeight;

    // Delegate the panel-center/overlap math to the shared, canonical
    // [mosaicPanelCenters] implementation so the preview and the imaging-side
    // MosaicService produce identical layouts. The grid step here is the
    // overlap-reduced spacing (stepWidth/stepHeight, in degrees on the sky);
    // dec is clamped to [-90, 90] afterward as the preview has always done.
    final centers = mosaicPanelCenters(
      centerRaHours: config.center.ra,
      centerDecDegrees: config.center.dec,
      stepRaDegrees: stepWidth,
      stepDecDegrees: stepHeight,
      columns: cols,
      rows: rows,
      rotationDegrees: config.rotation,
    );

    final panels = centers
        .map(
          (c) => PlanetariumMosaicPanel(
            index: c.index,
            row: c.row,
            column: c.col,
            center: CelestialCoordinate(
              ra: c.raHours,
              dec: c.decDegrees.clamp(-90.0, 90.0),
            ),
            rotation: config.rotation,
            fovWidth: config.panelFovWidth,
            fovHeight: config.panelFovHeight,
            priority: c.index,
          ),
        )
        .toList();

    return MosaicPlan(
      config: config,
      panels: panels,
      rows: rows,
      columns: cols,
      effectiveWidth: effectiveWidth,
      effectiveHeight: effectiveHeight,
    );
  }

  static MosaicPlan generateRectangularMosaic({
    required CelestialCoordinate center,
    required int rows,
    required int columns,
    required double panelFovWidth,
    required double panelFovHeight,
    MosaicOverlap overlap = const MosaicOverlap(),
    double rotation = 0,
  }) {
    final stepWidth = panelFovWidth * (1 - overlap.horizontal);
    final stepHeight = panelFovHeight * (1 - overlap.vertical);

    final totalWidth = panelFovWidth + (columns - 1) * stepWidth;
    final totalHeight = panelFovHeight + (rows - 1) * stepHeight;

    return generateMosaic(
      PlanetariumMosaicConfig(
        center: center,
        totalWidth: totalWidth,
        totalHeight: totalHeight,
        panelFovWidth: panelFovWidth,
        panelFovHeight: panelFovHeight,
        overlap: overlap,
        rotation: rotation,
        rows: rows,
        columns: columns,
      ),
    );
  }

  static double slewDistance(
    PlanetariumMosaicPanel from,
    PlanetariumMosaicPanel to,
  ) {
    return AstronomyCalculations.angularSeparation(
      ra1Deg: from.center.ra * 15,
      dec1Deg: from.center.dec,
      ra2Deg: to.center.ra * 15,
      dec2Deg: to.center.dec,
    );
  }

  static double totalSlewDistance(MosaicPlan plan) {
    var total = 0.0;
    final orderedPanels = plan.panels;

    for (var i = 1; i < orderedPanels.length; i++) {
      total += slewDistance(orderedPanels[i - 1], orderedPanels[i]);
    }

    return total;
  }

  static bool panelsOverlap(
    PlanetariumMosaicPanel a,
    PlanetariumMosaicPanel b,
  ) {
    // Simple AABB check (doesn't account for rotation properly)
    final aCorners = a.corners;
    final bCorners = b.corners;

    final aMinRa = aCorners.map((c) => c.ra).reduce(math.min);
    final aMaxRa = aCorners.map((c) => c.ra).reduce(math.max);
    final aMinDec = aCorners.map((c) => c.dec).reduce(math.min);
    final aMaxDec = aCorners.map((c) => c.dec).reduce(math.max);

    final bMinRa = bCorners.map((c) => c.ra).reduce(math.min);
    final bMaxRa = bCorners.map((c) => c.ra).reduce(math.max);
    final bMinDec = bCorners.map((c) => c.dec).reduce(math.min);
    final bMaxDec = bCorners.map((c) => c.dec).reduce(math.max);

    return !(aMaxRa < bMinRa ||
        bMaxRa < aMinRa ||
        aMaxDec < bMinDec ||
        bMaxDec < aMinDec);
  }

  /// Calculate optimal rotation angle to minimize number of panels
  static double findOptimalRotation({
    required double targetWidth,
    required double targetHeight,
    required double panelWidth,
    required double panelHeight,
    MosaicOverlap overlap = const MosaicOverlap(),
  }) {
    var minPanels = double.infinity;
    var optimalAngle = 0.0;

    for (var angle = 0.0; angle <= 90; angle += 5) {
      // Rotate the target dimensions
      final rad = angle * math.pi / 180;
      final rotWidth =
          targetWidth * math.cos(rad).abs() +
          targetHeight * math.sin(rad).abs();
      final rotHeight =
          targetWidth * math.sin(rad).abs() +
          targetHeight * math.cos(rad).abs();

      final (rows, cols) = calculatePanelCount(
        totalWidth: rotWidth,
        totalHeight: rotHeight,
        panelWidth: panelWidth,
        panelHeight: panelHeight,
        overlap: overlap,
      );

      final panelCount = rows * cols;
      if (panelCount < minPanels) {
        minPanels = panelCount.toDouble();
        optimalAngle = angle;
      }
    }

    return optimalAngle;
  }
}

class MosaicExporter {
  static String toJson(MosaicPlan plan) {
    final panels = plan.panels
        .map(
          (p) => {
            'index': p.index,
            'name': p.name,
            'row': p.row,
            'column': p.column,
            'ra_hours': p.center.ra,
            'ra_deg': p.center.ra * 15,
            'dec_deg': p.center.dec,
            'rotation_deg': p.rotation,
            'fov_width_deg': p.fovWidth,
            'fov_height_deg': p.fovHeight,
          },
        )
        .toList();

    final data = {
      'center_ra_hours': plan.center.ra,
      'center_dec_deg': plan.center.dec,
      'rows': plan.rows,
      'columns': plan.columns,
      'panel_count': plan.panelCount,
      'effective_width_deg': plan.effectiveWidth,
      'effective_height_deg': plan.effectiveHeight,
      'overlap_horizontal': plan.config.overlap.horizontal,
      'overlap_vertical': plan.config.overlap.vertical,
      'rotation_deg': plan.config.rotation,
      'panels': panels,
    };

    // Indented, fully-escaped, spec-valid JSON. Field order is preserved from
    // the map literal above and panels stay in capture order.
    return const JsonEncoder.withIndent('  ').convert(data);
  }

  static String toCsv(MosaicPlan plan) {
    final buffer = StringBuffer();
    buffer.writeln('Panel,Row,Column,RA_Hours,RA_Degrees,Dec_Degrees,Rotation');

    for (final panel in plan.panels) {
      buffer.writeln(
        '${panel.name},${panel.row},${panel.column},'
        '${panel.center.ra.toStringAsFixed(6)},'
        '${(panel.center.ra * 15).toStringAsFixed(6)},'
        '${panel.center.dec.toStringAsFixed(6)},'
        '${panel.rotation.toStringAsFixed(1)}',
      );
    }

    return buffer.toString();
  }
}
