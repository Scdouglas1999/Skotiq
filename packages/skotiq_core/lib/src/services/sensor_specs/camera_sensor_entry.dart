import 'published_figure.dart';

/// One row of the curated sensor database: a camera model whose geometry and
/// gain-dependent figures are taken from its manufacturer's own published
/// specification, with [source] naming the document they came from.
///
/// A row only carries a field the manufacturer actually publishes. Canon and
/// Nikon publish sensor size and pixel count but no read noise, full well or
/// QE, so those rows leave those fields empty rather than borrowing a figure
/// from a sensor-database site or a reviewer's measurement.
class CameraSensorEntry {
  const CameraSensorEntry({
    required this.model,
    required this.driverNames,
    required this.sensor,
    required this.widthPx,
    required this.heightPx,
    required this.source,
    this.publishedPixelSizeMicrons,
    this.publishedImageAreaWidthMm,
    this.publishedImageAreaHeightMm,
    this.readNoiseE = const [],
    this.fullWellE = const [],
    this.qePeakFraction,
    this.note,
  }) : assert(
         publishedPixelSizeMicrons != null || publishedImageAreaWidthMm != null,
         'A row needs either a published pixel pitch or a published image '
         'area to derive one from',
       );

  /// The manufacturer's own name for this model.
  final String model;

  /// Every model string a driver is known to report for this exact sensor.
  ///
  /// This list is the whole of the match set: [CameraSensorDatabase] matches a
  /// driver string against it after case/punctuation normalisation and nothing
  /// else. No edit-distance, no substring fallback — a name that is not on a
  /// row's list is a miss, because a near-miss name is usually a *different*
  /// camera (ASI2400MC Pro and ASI2600MC Pro differ by two characters and by
  /// 58% of pixel pitch).
  final List<String> driverNames;

  /// The image sensor part number, as the manufacturer names it.
  final String sensor;

  /// Published pixel count across.
  final int widthPx;

  /// Published pixel count down.
  final int heightPx;

  /// Where every figure in this row came from: document title, revision and
  /// URL, or the product page URL.
  final String source;

  /// Pixel pitch in microns when the manufacturer publishes it directly.
  final double? publishedPixelSizeMicrons;

  /// Published imaging-area width in millimetres. Used to derive the pitch for
  /// rows whose manufacturer publishes an area and a pixel count but no pitch
  /// (every Canon and Nikon body).
  final double? publishedImageAreaWidthMm;

  /// Published imaging-area height in millimetres.
  final double? publishedImageAreaHeightMm;

  /// Read noise in electrons, in the shape(s) the manufacturer published.
  final List<PublishedFigure> readNoiseE;

  /// Full well capacity in electrons, in the shape(s) the manufacturer
  /// published.
  final List<PublishedFigure> fullWellE;

  /// Published peak quantum efficiency as a fraction of 1.
  ///
  /// Peak QE is the maximum of a wavelength curve, so a single number is what
  /// the manufacturer means by it — unlike read noise, quoting it is not a
  /// flattening. Left null where the manufacturer publishes only a curve
  /// graphic and no peak value, which is the case for most of the QHY range.
  final double? qePeakFraction;

  /// Anything a user needs to know to read these figures correctly — a
  /// second readout mode, a crop that differs from the bare sensor, a field
  /// the manufacturer publishes only as a best case.
  final String? note;

  /// Pixel pitch in microns: the published pitch when there is one, otherwise
  /// derived from the published image area and pixel count.
  double get pixelSizeMicrons {
    final published = publishedPixelSizeMicrons;
    if (published != null) return published;
    return publishedImageAreaWidthMm! * 1000 / widthPx;
  }

  /// Whether [pixelSizeMicrons] is quoted or computed, for a provenance line.
  bool get pixelSizeIsDerived => publishedPixelSizeMicrons == null;

  /// Physical sensor width in millimetres.
  double get sensorWidthMm =>
      publishedImageAreaWidthMm ?? widthPx * pixelSizeMicrons / 1000;

  /// Physical sensor height in millimetres.
  double get sensorHeightMm =>
      publishedImageAreaHeightMm ?? heightPx * pixelSizeMicrons / 1000;
}
