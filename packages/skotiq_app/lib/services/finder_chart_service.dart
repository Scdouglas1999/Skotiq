import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:pdf/pdf.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:pdf/widgets.dart' as pw;

/// Configuration for finder chart rendering
class FinderChartConfig {
  /// Whether to use inverted colors (white background, black stars) for printing
  final bool printMode;

  /// Resolution of the rendered sky chart in pixels (width = height)
  final int chartResolution;

  /// Optional object name to display in the header
  final String? objectName;

  /// Optional object type description
  final String? objectType;

  /// Optional object magnitude
  final double? objectMagnitude;

  /// Optional object size string (e.g., "10' x 6'")
  final String? objectSize;

  /// Whether to include an object details page
  final bool includeDetailsPage;

  const FinderChartConfig({
    this.printMode = false,
    this.chartResolution = 2048,
    this.objectName,
    this.objectType,
    this.objectMagnitude,
    this.objectSize,
    this.includeDetailsPage = false,
  });
}

/// Service for generating PDF finder charts from the planetarium sky view.
///
/// Renders the current sky view to a high-resolution bitmap using the existing
/// SkyCanvasPainter, then embeds it in a PDF document with header/footer metadata.
class FinderChartService {
  FinderChartService._();

  /// Generate a PDF finder chart and save it to [outputPath].
  ///
  /// Uses the current sky view state, render config, and catalog data to produce
  /// a high-resolution chart. Throws on any rendering or I/O failure.
  static Future<void> generateChart({
    required String outputPath,
    required SkyViewState viewState,
    required SkyRenderConfig renderConfig,
    required List<Star> stars,
    required List<DeepSkyObject> dsos,
    required List<ConstellationData> constellations,
    required DateTime observationTime,
    required double latitude,
    required double longitude,
    required FinderChartConfig chartConfig,
    CelestialCoordinate? selectedObject,
    (double, double)? sunPosition,
    (double, double, double)? moonPosition,
    List<PlanetData> planets = const [],
    List<MilkyWayPoint>? milkyWayPoints,
  }) async {
    // Render the sky chart to a bitmap image
    final chartImage = await _renderSkyChart(
      viewState: viewState,
      renderConfig: renderConfig,
      stars: stars,
      dsos: dsos,
      constellations: constellations,
      observationTime: observationTime,
      latitude: latitude,
      longitude: longitude,
      chartConfig: chartConfig,
      selectedObject: selectedObject,
      sunPosition: sunPosition,
      moonPosition: moonPosition,
      planets: planets,
      milkyWayPoints: milkyWayPoints,
    );

    // Build the PDF document
    final pdf = _buildPdf(
      chartImage: chartImage,
      viewState: viewState,
      observationTime: observationTime,
      latitude: latitude,
      longitude: longitude,
      chartConfig: chartConfig,
      faintestPlotted: faintestPlottedMagnitude(stars: stars, dsos: dsos),
    );

    // Write to file
    final file = File(outputPath);
    await file.writeAsBytes(await pdf.save());
  }

  /// The magnitude of the faintest object actually drawn on the chart, or null
  /// when nothing was plotted.
  ///
  /// What a finder chart's reader needs is how deep the paper in their hand
  /// actually goes, so this reports the DATA. A constant "mag limit" derived
  /// from the field of view claims a depth the loaded catalogs may not reach.
  static double? faintestPlottedMagnitude({
    required List<Star> stars,
    required List<DeepSkyObject> dsos,
  }) {
    double? faintest;
    for (final magnitude in [
      ...stars.map((s) => s.magnitude),
      ...dsos.map((d) => d.magnitude),
    ]) {
      if (magnitude == null) continue;
      if (faintest == null || magnitude > faintest) faintest = magnitude;
    }
    return faintest;
  }

  /// Render the sky to a PNG byte buffer using SkyCanvasPainter.
  static Future<Uint8List> _renderSkyChart({
    required SkyViewState viewState,
    required SkyRenderConfig renderConfig,
    required List<Star> stars,
    required List<DeepSkyObject> dsos,
    required List<ConstellationData> constellations,
    required DateTime observationTime,
    required double latitude,
    required double longitude,
    required FinderChartConfig chartConfig,
    CelestialCoordinate? selectedObject,
    (double, double)? sunPosition,
    (double, double, double)? moonPosition,
    List<PlanetData> planets = const [],
    List<MilkyWayPoint>? milkyWayPoints,
  }) async {
    final resolution = chartConfig.chartResolution.toDouble();
    final size = Size(resolution, resolution);

    // Build a render config appropriate for the chart mode
    final chartRenderConfig = chartConfig.printMode
        ? _buildPrintModeConfig(renderConfig)
        : renderConfig;

    // Use a PictureRecorder to capture the SkyCanvasPainter output.
    final recorder = ui.PictureRecorder();
    ui.Picture? picture;
    ui.Image? image;
    try {
      final canvas = Canvas(recorder, Offset.zero & size);

      if (chartConfig.printMode) {
        // Print mode inverts the finished render rather than repainting a
        // light-on-dark sky onto white. The renderer has no star colour in its
        // config — stars, labels and glyphs are all drawn BRIGHT — so a "white
        // background + dark grid" config produces white stars on white paper.
        // Inverting the whole layer turns the sky white and every mark on it
        // dark in one step.
        canvas.saveLayer(Offset.zero & size, Paint()..colorFilter = _invert);
        // Opaque black beneath, so the inverted sheet is pure white rather than
        // transparent (a transparent PNG prints as whatever is behind it).
        canvas.drawRect(
          Offset.zero & size,
          Paint()..color = ImageOverlayColors.shadow,
        );
      }

      // Create the painter with high-quality config (no animations)
      final painter = SkyCanvasPainter(
        viewState: viewState,
        config: chartRenderConfig,
        qualityConfig: const RenderQualityConfig.quality(),
        stars: stars,
        dsos: dsos,
        constellations: constellations,
        observationTime: observationTime,
        latitude: latitude,
        longitude: longitude,
        selectedObject: selectedObject,
        sunPosition: sunPosition,
        moonPosition: moonPosition,
        planets: planets,
        milkyWayPoints: chartConfig.printMode ? null : milkyWayPoints,
        // No animations for static chart
        animationPhase: null,
        selectionAnimationPhase: null,
        popinAnimationPhase: null,
        dsoPopinAnimationPhase: null,
        parallaxPanDelta: null,
      );

      painter.paint(canvas, size);

      if (chartConfig.printMode) {
        canvas.restore();
      }

      picture = recorder.endRecording();
      image = await picture.toImage(
        chartConfig.chartResolution,
        chartConfig.chartResolution,
      );
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        throw StateError('Failed to encode sky chart image to PNG');
      }

      return byteData.buffer.asUint8List();
    } finally {
      image?.dispose();
      picture?.dispose();
      if (recorder.isRecording) {
        recorder.endRecording().dispose();
      }
    }
  }

  /// Inverts RGB and leaves alpha alone. See the print-mode branch in
  /// [_renderSkyChart].
  static const ColorFilter _invert = ColorFilter.matrix(<double>[
    -1, 0, 0, 0, 255, //
    0, -1, 0, 0, 255, //
    0, 0, -1, 0, 255, //
    0, 0, 0, 1, 0, //
  ]);

  /// Build a SkyRenderConfig suitable for print mode.
  ///
  /// The palette stays light-on-dark — [_renderSkyChart] inverts the finished
  /// layer — so the only job here is to drop the large soft washes (ground
  /// gradient, Milky Way) that invert into grey ink over most of the page, and
  /// to brighten the line work that would otherwise invert to near-white.
  static SkyRenderConfig _buildPrintModeConfig(SkyRenderConfig base) {
    return base.copyWith(
      showGroundPlane: false,
      showMilkyWay: false,
      showMountPosition: false,
      // Light lines on the dark render invert to dark lines on paper.
      gridColor: ImageOverlayColors.finderGrid,
      constellationLineColor: ImageOverlayColors.finderConstellation,
      eclipticColor: ImageOverlayColors.finderEcliptic,
      galacticPlaneColor: ImageOverlayColors.finderGalacticPlane,
      horizonColor: ImageOverlayColors.finderHorizon,
      mountPositionColor: ImageOverlayColors.north,
    );
  }

  /// Build the PDF document with chart image, header, and footer.
  static pw.Document _buildPdf({
    required Uint8List chartImage,
    required SkyViewState viewState,
    required DateTime observationTime,
    required double latitude,
    required double longitude,
    required FinderChartConfig chartConfig,
    required double? faintestPlotted,
  }) {
    final pdf = pw.Document(
      title: chartConfig.objectName != null
          ? 'Finder Chart - ${chartConfig.objectName}'
          : 'Finder Chart',
      author: 'Skotiq',
      creator: 'Skotiq Astrophotography Suite',
    );

    final dateFormatter = DateFormat('yyyy-MM-dd HH:mm:ss');
    final dateStr = dateFormatter.format(observationTime);

    final latStr = _formatLatitude(latitude);
    final lonStr = _formatLongitude(longitude);

    final fovStr = _formatFOV(viewState.fieldOfView);
    final raStr = _formatRA(viewState.centerRA);
    final decStr = _formatDec(viewState.centerDec);
    final projectionStr = _projectionName(viewState.projection);

    final image = pw.MemoryImage(chartImage);

    // Chart page
    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(30),
        build: (context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              // Header
              _buildHeader(
                chartConfig: chartConfig,
                dateStr: dateStr,
                latStr: latStr,
                lonStr: lonStr,
              ),
              pw.SizedBox(height: 8),
              pw.Divider(thickness: 0.5),
              pw.SizedBox(height: 8),

              // Chart image - expand to fill available space
              pw.Expanded(
                child: pw.Center(
                  child: pw.Image(image, fit: pw.BoxFit.contain),
                ),
              ),

              // Footer
              pw.SizedBox(height: 8),
              pw.Divider(thickness: 0.5),
              pw.SizedBox(height: 4),
              _buildFooter(
                fovStr: fovStr,
                raStr: raStr,
                decStr: decStr,
                projectionStr: projectionStr,
                faintestPlotted: faintestPlotted,
                chartConfig: chartConfig,
              ),
            ],
          );
        },
      ),
    );

    // Optional details page
    if (chartConfig.includeDetailsPage && chartConfig.objectName != null) {
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          margin: const pw.EdgeInsets.all(30),
          build: (context) {
            return _buildDetailsPage(
              chartConfig: chartConfig,
              dateStr: dateStr,
              latStr: latStr,
              lonStr: lonStr,
              raStr: raStr,
              decStr: decStr,
              fovStr: fovStr,
              latitude: latitude,
              longitude: longitude,
              observationTime: observationTime,
              viewState: viewState,
            );
          },
        ),
      );
    }

    return pdf;
  }

  static pw.Widget _buildHeader({
    required FinderChartConfig chartConfig,
    required String dateStr,
    required String latStr,
    required String lonStr,
  }) {
    final titleText = chartConfig.objectName != null
        ? 'Finder Chart: ${chartConfig.objectName}'
        : 'Finder Chart';

    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                titleText,
                style: pw.TextStyle(
                  fontSize: 18,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              if (chartConfig.objectType != null)
                pw.Text(
                  chartConfig.objectType!,
                  style: const pw.TextStyle(
                    fontSize: 10,
                    color: PdfColors.grey700,
                  ),
                ),
            ],
          ),
        ),
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Text(
              dateStr,
              style: const pw.TextStyle(fontSize: 10),
            ),
            pw.Text(
              '$latStr, $lonStr',
              style: const pw.TextStyle(
                fontSize: 9,
                color: PdfColors.grey700,
              ),
            ),
          ],
        ),
      ],
    );
  }

  static pw.Widget _buildFooter({
    required String fovStr,
    required String raStr,
    required String decStr,
    required String projectionStr,
    required double? faintestPlotted,
    required FinderChartConfig chartConfig,
  }) {
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Row(
          children: [
            _footerItem('FOV', fovStr),
            pw.SizedBox(width: 16),
            _footerItem('Center', '$raStr  $decStr'),
          ],
        ),
        pw.Row(
          children: [
            _footerItem(
              'Faintest plotted',
              faintestPlotted == null
                  ? 'nothing in field'
                  : 'mag ${faintestPlotted.toStringAsFixed(1)}',
            ),
            pw.SizedBox(width: 16),
            _footerItem('Projection', projectionStr),
            if (chartConfig.printMode) ...[
              pw.SizedBox(width: 16),
              pw.Text(
                'Print mode',
                style: const pw.TextStyle(
                  fontSize: 8,
                  color: PdfColors.grey500,
                ),
              ),
            ],
          ],
        ),
        pw.Text(
          'Generated by Skotiq',
          style: const pw.TextStyle(
            fontSize: 7,
            color: PdfColors.grey500,
          ),
        ),
      ],
    );
  }

  static pw.Widget _footerItem(String label, String value) {
    return pw.Row(
      children: [
        pw.Text(
          '$label: ',
          style: const pw.TextStyle(
            fontSize: 8,
            color: PdfColors.grey600,
          ),
        ),
        pw.Text(
          value,
          style: pw.TextStyle(
            fontSize: 8,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
      ],
    );
  }

  static pw.Widget _buildDetailsPage({
    required FinderChartConfig chartConfig,
    required String dateStr,
    required String latStr,
    required String lonStr,
    required String raStr,
    required String decStr,
    required String fovStr,
    required double latitude,
    required double longitude,
    required DateTime observationTime,
    required SkyViewState viewState,
  }) {
    // Compute altitude for the chart center at observation time
    final lst = AstronomyCalculations.localSiderealTime(
      observationTime,
      longitude,
    );
    final (alt, az) = AstronomyCalculations.equatorialToHorizontal(
      raDeg: viewState.centerRA * 15.0,
      decDeg: viewState.centerDec,
      latitudeDeg: latitude,
      lstHours: lst,
    );

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          'Object Details: ${chartConfig.objectName ?? "Unknown"}',
          style: pw.TextStyle(
            fontSize: 16,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
        pw.SizedBox(height: 16),
        pw.Divider(thickness: 0.5),
        pw.SizedBox(height: 16),

        _detailRow('Object Name', chartConfig.objectName ?? 'N/A'),
        if (chartConfig.objectType != null)
          _detailRow('Type', chartConfig.objectType!),
        if (chartConfig.objectMagnitude != null)
          _detailRow(
            'Magnitude',
            chartConfig.objectMagnitude!.toStringAsFixed(1),
          ),
        if (chartConfig.objectSize != null)
          _detailRow('Size', chartConfig.objectSize!),

        pw.SizedBox(height: 16),
        pw.Divider(thickness: 0.5, color: PdfColors.grey300),
        pw.SizedBox(height: 16),

        pw.Text(
          'Observation Context',
          style: pw.TextStyle(
            fontSize: 12,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
        pw.SizedBox(height: 8),

        _detailRow('Date/Time', dateStr),
        _detailRow('Location', '$latStr, $lonStr'),
        _detailRow('Right Ascension', raStr),
        _detailRow('Declination', decStr),
        _detailRow('Altitude', '${alt.toStringAsFixed(1)}\u00b0'),
        _detailRow('Azimuth', '${az.toStringAsFixed(1)}\u00b0'),
        _detailRow('Field of View', fovStr),
        _detailRow(
          'Projection',
          _projectionName(viewState.projection),
        ),

        pw.SizedBox(height: 24),
        pw.Divider(thickness: 0.5, color: PdfColors.grey300),
        pw.SizedBox(height: 8),

        pw.Text(
          'Notes',
          style: pw.TextStyle(
            fontSize: 12,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
        pw.SizedBox(height: 8),
        // Empty box for user notes
        pw.Container(
          height: 200,
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: PdfColors.grey300, width: 0.5),
            borderRadius: pw.BorderRadius.circular(SkotiqTokens.radiusXs),
          ),
        ),

        pw.Spacer(),
        pw.Divider(thickness: 0.5),
        pw.SizedBox(height: 4),
        pw.Text(
          'Generated by Skotiq',
          style: const pw.TextStyle(
            fontSize: 7,
            color: PdfColors.grey500,
          ),
        ),
      ],
    );
  }

  static pw.Widget _detailRow(String label, String value) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 3),
      child: pw.Row(
        children: [
          pw.SizedBox(
            width: 120,
            child: pw.Text(
              label,
              style: const pw.TextStyle(
                fontSize: 10,
                color: PdfColors.grey700,
              ),
            ),
          ),
          pw.Expanded(
            child: pw.Text(
              value,
              style: pw.TextStyle(
                fontSize: 10,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Formatting helpers

  static String _formatLatitude(double lat) {
    final sign = lat >= 0 ? 'N' : 'S';
    return '${lat.abs().toStringAsFixed(4)}\u00b0$sign';
  }

  static String _formatLongitude(double lon) {
    final sign = lon >= 0 ? 'E' : 'W';
    return '${lon.abs().toStringAsFixed(4)}\u00b0$sign';
  }

  static String _formatFOV(double fovDeg) {
    if (fovDeg >= 1) {
      return '${fovDeg.toStringAsFixed(1)}\u00b0';
    } else {
      return '${(fovDeg * 60).toStringAsFixed(1)}\'';
    }
  }

  static String _formatRA(double raHours) =>
      CoordinateFormat.ra(raHours, style: SexagesimalStyle.plainLetters);

  static String _formatDec(double decDeg) => CoordinateFormat.dec(
        decDeg,
        style: SexagesimalStyle.plainLetters,
        seconds: SecondsPrecision.integerFloored,
      );

  static String _projectionName(SkyProjection projection) {
    switch (projection) {
      case SkyProjection.stereographic:
        return 'Stereographic';
      case SkyProjection.orthographic:
        return 'Orthographic';
      case SkyProjection.azimuthalEquidistant:
        return 'Equidistant';
    }
  }

  /// Generate a suggested filename for the chart.
  static String suggestedFilename({String? objectName}) {
    final date = DateFormat('yyyy-MM-dd').format(DateTime.now());
    if (objectName != null) {
      final safeName = objectName.replaceAll(RegExp(r'[^\w\s-]'), '_').trim();
      return 'finder_chart_${safeName}_$date.pdf';
    }
    return 'finder_chart_$date.pdf';
  }
}
