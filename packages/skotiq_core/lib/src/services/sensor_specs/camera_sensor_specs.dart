import 'camera_sensor_entry.dart';

/// Where a resolved sensor value came from. Ordered best-first: this is the
/// resolution chain.
enum SensorSpecOrigin {
  /// The user typed it. Always wins; nothing overwrites it.
  userOverride,

  /// Read from the camera that is connected right now.
  connectedCamera,

  /// What this camera reported the last time it was connected.
  rememberedCamera,

  /// The manufacturer's published specification for this model.
  modelDatabase,
}

/// The fields the planner's exposure model and the framing geometry need.
enum SensorSpecField {
  pixelSize('pixel size'),
  sensorWidth('sensor width'),
  sensorHeight('sensor height'),
  readNoise('read noise'),
  fullWell('full well'),
  qePeak('QE');

  const SensorSpecField(this.label);

  /// The field's name in a sentence, lower case.
  final String label;
}

/// One resolved value together with the sentence that says where it came from.
class SensorSpecValue<T> {
  const SensorSpecValue({
    required this.value,
    required this.origin,
    required this.provenance,
  });

  final T value;
  final SensorSpecOrigin origin;

  /// Where this number came from and how good it is, as a phrase that reads as
  /// the tail of `<field> is <value>, <provenance>`.
  final String provenance;
}

/// Everything the app knows about the active camera's sensor, with each value
/// tagged by where it came from.
///
/// A field is null when no tier could supply it. That is the only case the UI
/// is allowed to call unknown.
class ResolvedCameraSensorSpecs {
  const ResolvedCameraSensorSpecs({
    required this.reportedModel,
    required this.databaseEntry,
    this.pixelSizeMicrons,
    this.sensorWidthPx,
    this.sensorHeightPx,
    this.readNoiseE,
    this.fullWellE,
    this.qePeakFraction,
  });

  /// Nothing known at all — no camera in the profile.
  static const ResolvedCameraSensorSpecs none = ResolvedCameraSensorSpecs(
    reportedModel: null,
    databaseEntry: null,
  );

  /// The model string the driver or profile reported, which is what a
  /// "could not identify this camera" message has to name.
  final String? reportedModel;

  /// The curated row that matched [reportedModel], if any.
  final CameraSensorEntry? databaseEntry;

  final SensorSpecValue<double>? pixelSizeMicrons;
  final SensorSpecValue<int>? sensorWidthPx;
  final SensorSpecValue<int>? sensorHeightPx;
  final SensorSpecValue<double>? readNoiseE;
  final SensorSpecValue<double>? fullWellE;
  final SensorSpecValue<double>? qePeakFraction;

  SensorSpecValue<Object>? operator [](SensorSpecField field) =>
      switch (field) {
        SensorSpecField.pixelSize => pixelSizeMicrons,
        SensorSpecField.sensorWidth => sensorWidthPx,
        SensorSpecField.sensorHeight => sensorHeightPx,
        SensorSpecField.readNoise => readNoiseE,
        SensorSpecField.fullWell => fullWellE,
        SensorSpecField.qePeak => qePeakFraction,
      };

  /// Fields no tier could supply, in display order.
  List<SensorSpecField> get unresolvedFields => [
    for (final field in SensorSpecField.values)
      if (this[field] == null) field,
  ];

  /// Whether framing and mosaic geometry can be computed.
  bool get hasGeometry =>
      pixelSizeMicrons != null &&
      sensorWidthPx != null &&
      sensorHeightPx != null;

  /// Whether anything at all resolved.
  bool get isEmpty => unresolvedFields.length == SensorSpecField.values.length;

  /// The best tier any field resolved from, which is what a one-line summary
  /// attributes the set to.
  SensorSpecOrigin? get bestOrigin {
    SensorSpecOrigin? best;
    for (final field in SensorSpecField.values) {
      final origin = this[field]?.origin;
      if (origin == null) continue;
      if (best == null || origin.index < best.index) best = origin;
    }
    return best;
  }

  /// The resolved values on one line, e.g.
  /// `3.8 µm · 4656 × 3520 · 1.2 e⁻ read noise · 20,000 e⁻ well · 60% QE`.
  ///
  /// Only resolved values appear. An unresolved field is left out rather than
  /// printed as a placeholder; [unresolvedFields] is what names it.
  String get valueSummary {
    final parts = <String>[
      if (pixelSizeMicrons != null)
        '${_trimZeros(pixelSizeMicrons!.value, 2)} µm',
      if (sensorWidthPx != null && sensorHeightPx != null)
        '${sensorWidthPx!.value} × ${sensorHeightPx!.value}',
      if (readNoiseE != null)
        '${_trimZeros(readNoiseE!.value, 2)} e⁻ read noise',
      if (fullWellE != null) '${_grouped(fullWellE!.value)} e⁻ well',
      if (qePeakFraction != null)
        '${(qePeakFraction!.value * 100).round()}% QE',
    ];
    return parts.join(' · ');
  }

  /// Where the set as a whole came from, in four words, for a trailing label.
  String? get originLabel => switch (bestOrigin) {
    SensorSpecOrigin.userOverride => 'Set by you',
    SensorSpecOrigin.connectedCamera => 'From the camera',
    SensorSpecOrigin.rememberedCamera => 'Remembered',
    SensorSpecOrigin.modelDatabase => 'Published specs',
    null => null,
  };

  /// Where every resolved value came from, as one labelled sentence per
  /// distinct source phrase.
  ///
  /// Grouped by phrase and labelled with the fields it covers, rather than
  /// collapsed to one line per tier. Collapsing by tier swallowed exactly the
  /// clause that matters most: on a camera whose every figure comes from the
  /// published specification, "the published pixel pitch" and "the published
  /// read noise, which the manufacturer quotes only at 30 dB gain" are the
  /// same tier and very different claims, and only the first was surviving.
  String get provenanceSentence {
    final byPhrase = <String, List<SensorSpecField>>{};
    for (final field in SensorSpecField.values) {
      final value = this[field];
      if (value == null) continue;
      byPhrase.putIfAbsent(value.provenance, () => []).add(field);
    }
    if (byPhrase.isEmpty) return '';
    return byPhrase.entries
        .map(
          (entry) => _capitalize('${_fieldList(entry.value)}: ${entry.key}.'),
        )
        .join(' ');
  }

  /// "read noise, full well and QE", for a provenance clause.
  static String _fieldList(List<SensorSpecField> fields) {
    final labels = fields.map((field) => field.label).toList();
    if (labels.length == 1) return labels.first;
    final last = labels.removeLast();
    return '${labels.join(', ')} and $last';
  }

  static String _capitalize(String value) =>
      value.isEmpty ? value : value[0].toUpperCase() + value.substring(1);

  static String _trimZeros(double value, int decimals) {
    var text = value.toStringAsFixed(decimals);
    while (text.contains('.') && (text.endsWith('0') || text.endsWith('.'))) {
      text = text.substring(0, text.length - 1);
    }
    return text;
  }

  /// Thousands separators without pulling in a locale: these are electron
  /// counts in a technical readout, not currency.
  static String _grouped(double value) {
    final digits = value.round().toString();
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }
}

/// The phrase that marks a planner caveat as being about an unresolvable
/// sensor spec.
///
/// The producer ([sensorSpecCaveat]) and the recognisers (the Plan screen's
/// risk banner, the Smart Night builder's prompt) share it, so a reworded
/// caveat cannot silently stop being recognised — which is how the old banner
/// came to collapse caveats by sniffing for the words "not configured".
const String _sensorSpecCaveatMarker = 'is not published for';

/// The caveat for a sensor field that missed at every tier of the chain.
///
/// Names the camera, because the remedy depends on which camera the app could
/// not find figures for, and names the estimate being used in its place so the
/// number on screen is never unexplained.
String sensorSpecCaveat({
  required SensorSpecField field,
  required String cameraLabel,
  required String estimate,
}) {
  final subject = '${field.label[0].toUpperCase()}${field.label.substring(1)}';
  return '$subject $_sensorSpecCaveatMarker $cameraLabel; '
      'planning with $estimate.';
}

/// The caveat for a saved override the app could not parse. Separate from
/// [sensorSpecCaveat] because the remedy is different: the user's own entry is
/// being ignored and they need to know.
const String unreadableSensorOverridesCaveat =
    'Your saved camera specs could not be read; planning from the published '
    'figures for this camera instead.';

/// Whether [caveat] is about sensor specs, and so belongs in the one sensor
/// banner rather than being printed as a separate problem.
bool isSensorSpecCaveat(String caveat) =>
    caveat.contains(_sensorSpecCaveatMarker) ||
    caveat == unreadableSensorOverridesCaveat;
