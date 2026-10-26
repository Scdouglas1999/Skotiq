import 'dart:math' as math;

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
    this.gainCurve,
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

  /// Conversion gain and read noise against the driver's gain setting, from
  /// the manufacturer's gain chart. Null when the manufacturer publishes no
  /// chart; the e⁻/ADU of such a camera is then unknown at any gain but the
  /// one it was measured at.
  final SensorGainCurve? gainCurve;

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

/// One point of a manufacturer's gain chart.
class SensorGainPoint {
  const SensorGainPoint({
    required this.gain,
    required this.electronsPerAdu,
    required this.readNoiseE,
  });

  /// Driver gain setting.
  final int gain;

  /// Conversion gain in electrons per ADC count, at the ADC's own resolution
  /// (not the 16-bit pixel container the driver may shift samples into).
  final double electronsPerAdu;

  /// Read noise in electrons.
  final double readNoiseE;
}

/// The value of a [SensorGainCurve] at one driver gain.
class SensorGainReading {
  const SensorGainReading({
    required this.gain,
    required this.electronsPerAdcCount,
    required this.readNoiseE,
    required this.isPublishedPoint,
    required this.isClamped,
  });

  final int gain;
  final double electronsPerAdcCount;
  final double readNoiseE;

  /// True when [gain] is one of the chart's own points.
  final bool isPublishedPoint;

  /// True when [gain] lies outside the chart and the nearest end was used.
  final bool isClamped;

  /// Electrons per count of a pixel container whose full scale is
  /// [containerMaxAdu], for an ADC of [adcBitDepth] bits whose samples the
  /// driver shifts up into that container.
  double electronsPerContainerAdu({
    required int containerMaxAdu,
    required int adcBitDepth,
  }) {
    final adcMax = (1 << adcBitDepth) - 1;
    final scale = containerMaxAdu > adcMax ? containerMaxAdu / adcMax : 1.0;
    return electronsPerAdcCount / scale;
  }
}

/// Conversion gain and read noise against the driver gain setting.
///
/// Between published points the conversion gain is interpolated
/// exponentially in the gain setting (CMOS analog gain is set in decibel
/// steps), and read noise as `rn² = a + b·(e⁻/ADU)²` — a fixed pixel noise
/// plus a readout-chain noise that scales with the conversion gain. Outside
/// the chart the nearest end is used and the reading says so.
class SensorGainCurve {
  const SensorGainCurve({
    required this.adcBitDepth,
    required this.points,
    required this.source,
  });

  /// ADC resolution the [SensorGainPoint.electronsPerAdu] figures refer to.
  final int adcBitDepth;

  /// Published points, in increasing gain order.
  final List<SensorGainPoint> points;

  /// Where the points were read from.
  final String source;

  SensorGainReading? at(int gain) {
    if (points.isEmpty) return null;
    final first = points.first;
    final last = points.last;
    if (gain <= first.gain || gain >= last.gain) {
      final end = gain <= first.gain ? first : last;
      return SensorGainReading(
        gain: gain,
        electronsPerAdcCount: end.electronsPerAdu,
        readNoiseE: end.readNoiseE,
        isPublishedPoint: gain == end.gain,
        isClamped: gain != end.gain,
      );
    }
    for (var i = 0; i < points.length - 1; i++) {
      final lo = points[i];
      final hi = points[i + 1];
      if (gain < lo.gain || gain > hi.gain) continue;
      if (gain == lo.gain || gain == hi.gain) {
        final p = gain == lo.gain ? lo : hi;
        return SensorGainReading(
          gain: gain,
          electronsPerAdcCount: p.electronsPerAdu,
          readNoiseE: p.readNoiseE,
          isPublishedPoint: true,
          isClamped: false,
        );
      }
      final t = (gain - lo.gain) / (hi.gain - lo.gain);
      final ePerAdu = math.exp(
        math.log(lo.electronsPerAdu) +
            t * (math.log(hi.electronsPerAdu) - math.log(lo.electronsPerAdu)),
      );
      final g2lo = lo.electronsPerAdu * lo.electronsPerAdu;
      final g2hi = hi.electronsPerAdu * hi.electronsPerAdu;
      final u = (ePerAdu * ePerAdu - g2lo) / (g2hi - g2lo);
      final rn2 =
          lo.readNoiseE * lo.readNoiseE +
          u * (hi.readNoiseE * hi.readNoiseE - lo.readNoiseE * lo.readNoiseE);
      return SensorGainReading(
        gain: gain,
        electronsPerAdcCount: ePerAdu,
        readNoiseE: math.sqrt(math.max(rn2, 0.0)),
        isPublishedPoint: false,
        isClamped: false,
      );
    }
    return null;
  }
}
