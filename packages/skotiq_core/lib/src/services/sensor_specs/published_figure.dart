/// How a manufacturer published a gain-dependent sensor figure.
///
/// Read noise, full well and QE all move with gain on the CMOS sensors these
/// cameras use, and manufacturers publish them in three different shapes:
///
///  * with a driver gain attached ("when the gain is 100 … the read noise is as
///    low as 1.5e", ZWO ASI6200 manual) — [PublishedFigureKind.atDriverGain];
///  * with a label that is not a driver gain ("1.2e @30db gain", ZWO ASI1600
///    manual) — [PublishedFigureKind.atQuotedLabel];
///  * as a bare range across the whole gain axis ("Read Noise 1.0-3.3e", ZWO
///    ASI2600 manual) — [PublishedFigureKind.range].
///
/// Flattening any of those into "the sensor's read noise" would be a
/// fabrication, so a figure always carries the shape it was published in and
/// [CameraSensorSpecResolver] reports it that way.
enum PublishedFigureKind {
  /// A single value the manufacturer tied to a specific driver gain value.
  atDriverGain,

  /// A single value the manufacturer tied to a label that is not a driver gain
  /// (a dB figure, a named readout mode).
  atQuotedLabel,

  /// A low/high pair spanning the gain axis with no per-gain attribution.
  range,

  /// A single value published with no operating point at all, which is how
  /// every manufacturer here quotes full well ("Full well 20ke").
  unattributed,
}

/// One gain-dependent figure exactly as its manufacturer published it.
class PublishedFigure {
  const PublishedFigure._({
    required this.kind,
    required this.low,
    required this.high,
    this.driverGain,
    this.quotedLabel,
  });

  /// A value the manufacturer tied to a driver gain, e.g. ZWO's HCG threshold.
  const PublishedFigure.atGain(double value, {required int gain})
    : this._(
        kind: PublishedFigureKind.atDriverGain,
        low: value,
        high: value,
        driverGain: gain,
      );

  /// A value quoted against something other than a driver gain, such as the
  /// ASI1600 manual's "1.2e @30db gain". The label is carried verbatim: ZWO
  /// does not publish the mapping from dB to its driver's gain units, so
  /// converting it here would invent a number.
  const PublishedFigure.atLabel(double value, {required String label})
    : this._(
        kind: PublishedFigureKind.atQuotedLabel,
        low: value,
        high: value,
        quotedLabel: label,
      );

  /// A published low/high range with no per-gain attribution.
  const PublishedFigure.range({required double low, required double high})
    : this._(kind: PublishedFigureKind.range, low: low, high: high);

  /// A single published value with no operating point stated.
  const PublishedFigure.unattributed(double value)
    : this._(kind: PublishedFigureKind.unattributed, low: value, high: value);

  final PublishedFigureKind kind;

  /// The smaller published value (equal to [high] for a single figure).
  final double low;

  /// The larger published value (equal to [low] for a single figure).
  final double high;

  /// The driver gain this figure was published at, when there is one.
  final int? driverGain;

  /// The manufacturer's own wording for the operating point, when it is not a
  /// driver gain.
  final String? quotedLabel;

  bool get isRange => kind == PublishedFigureKind.range;

  /// The value to plan with when the goal is not to overstate the camera.
  ///
  /// For noise-like quantities the safe end is the larger value, for
  /// capacity-like quantities the smaller one, so the caller says which it
  /// wants rather than this class guessing from the field name.
  double conservativeValue({required bool higherIsWorse}) =>
      higherIsWorse ? high : low;

  /// A phrase naming the operating point, for a provenance sentence.
  ///
  /// Reads as the tail of "… the published figure", e.g. "at gain 100".
  String get operatingPointPhrase => switch (kind) {
    PublishedFigureKind.atDriverGain => 'at gain $driverGain',
    PublishedFigureKind.atQuotedLabel => 'at $quotedLabel',
    PublishedFigureKind.range => 'across its full gain range',
    PublishedFigureKind.unattributed => 'with no gain stated',
  };
}
