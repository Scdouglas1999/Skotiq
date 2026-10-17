import 'camera_sensor_database.dart';
import 'camera_sensor_specs.dart';
import 'published_figure.dart';

/// A sensor geometry reading taken off a camera, live or remembered.
class SensorGeometryReading {
  const SensorGeometryReading({
    required this.widthPx,
    required this.heightPx,
    required this.pixelSizeXMicrons,
    required this.pixelSizeYMicrons,
    this.readAt,
  });

  final int widthPx;
  final int heightPx;
  final double pixelSizeXMicrons;
  final double pixelSizeYMicrons;

  /// When the reading was taken. Null for a live one — it is happening now.
  final DateTime? readAt;

  /// Whether every value is usable. Drivers report zeroes before a camera has
  /// finished initialising.
  bool get isUsable =>
      widthPx > 0 &&
      heightPx > 0 &&
      pixelSizeXMicrons > 0 &&
      pixelSizeYMicrons > 0;

  /// One pitch for a model that stores a scalar. The mean, so a sensor with
  /// non-square pixels is not silently described by its width alone.
  double get meanPixelSizeMicrons =>
      (pixelSizeXMicrons + pixelSizeYMicrons) / 2;
}

/// The values a user typed for their camera. Any non-null field wins outright.
class UserSensorSpecOverrides {
  const UserSensorSpecOverrides({
    this.pixelSizeMicrons,
    this.sensorWidthPx,
    this.sensorHeightPx,
    this.readNoiseE,
    this.fullWellE,
    this.qePeakFraction,
  });

  static const UserSensorSpecOverrides none = UserSensorSpecOverrides();

  final double? pixelSizeMicrons;
  final int? sensorWidthPx;
  final int? sensorHeightPx;
  final double? readNoiseE;
  final double? fullWellE;
  final double? qePeakFraction;

  bool get isEmpty =>
      pixelSizeMicrons == null &&
      sensorWidthPx == null &&
      sensorHeightPx == null &&
      readNoiseE == null &&
      fullWellE == null &&
      qePeakFraction == null;

  Map<String, Object> toJson() => {
    if (pixelSizeMicrons != null) 'pixelSizeUm': pixelSizeMicrons!,
    if (sensorWidthPx != null) 'widthPx': sensorWidthPx!,
    if (sensorHeightPx != null) 'heightPx': sensorHeightPx!,
    if (readNoiseE != null) 'readNoiseE': readNoiseE!,
    if (fullWellE != null) 'fullWellE': fullWellE!,
    if (qePeakFraction != null) 'qePeak': qePeakFraction!,
  };

  /// Reads one camera's overrides back. A field that is not a finite positive
  /// number is treated as absent: a corrupt entry must not become a fact.
  static UserSensorSpecOverrides fromJson(Object? json) {
    if (json is! Map) return none;
    double? number(String key) {
      final raw = json[key];
      final value = raw is num
          ? raw.toDouble()
          : (raw is String ? double.tryParse(raw) : null);
      if (value == null || !value.isFinite || value <= 0) return null;
      return value;
    }

    final width = number('widthPx');
    final height = number('heightPx');
    return UserSensorSpecOverrides(
      pixelSizeMicrons: number('pixelSizeUm'),
      sensorWidthPx: width?.round(),
      sensorHeightPx: height?.round(),
      readNoiseE: number('readNoiseE'),
      fullWellE: number('fullWellE'),
      qePeakFraction: number('qePeak'),
    );
  }
}

/// Everything the resolver is given for one camera.
class CameraSensorSpecInputs {
  const CameraSensorSpecInputs({
    this.cameraName,
    this.cameraId,
    this.gain,
    this.overrides = UserSensorSpecOverrides.none,
    this.liveReading,
    this.rememberedReading,
  });

  /// The friendly model string, tried first because a device id is often an
  /// ASCOM ProgID that names a driver rather than a camera.
  final String? cameraName;

  /// The device id, tried second.
  final String? cameraId;

  /// The gain the camera is set to, so a gain-dependent published figure can
  /// be quoted at the right operating point.
  final int? gain;

  final UserSensorSpecOverrides overrides;
  final SensorGeometryReading? liveReading;
  final SensorGeometryReading? rememberedReading;
}

/// The one place the app decides what a camera's sensor specs are.
///
/// Before this existed, Framing read the live camera and remembered what it
/// saw, while the planner consulted neither — so a pixel size the app had
/// already read off the owner's ASI1600MM-Cool and written to disk was
/// reported on the Plan screen as "not configured". Every surface that needs
/// pixel size, sensor dimensions, read noise, full well or QE goes through
/// [resolve] so they cannot disagree again.
class CameraSensorSpecResolver {
  CameraSensorSpecResolver({CameraSensorDatabase? database})
    : _database = database ?? CameraSensorDatabase.curated;

  final CameraSensorDatabase _database;

  CameraSensorDatabase get database => _database;

  /// Resolves each field independently, best available tier first:
  /// (a) the user's own value, (b) the connected camera, (c) what this camera
  /// reported last time, (d) the manufacturer's published specification,
  /// (e) unknown.
  ///
  /// Per field rather than per tier, because the tiers know different things:
  /// a driver reports geometry but never read noise, and the published
  /// specification has read noise but describes the sensor's default readout
  /// mode rather than the crop the driver is actually delivering.
  ResolvedCameraSensorSpecs resolve(CameraSensorSpecInputs inputs) {
    final reportedModel = _firstNonBlank([inputs.cameraName, inputs.cameraId]);
    final entry = _database.lookupAny([inputs.cameraName, inputs.cameraId]);
    final overrides = inputs.overrides;
    final live = _usable(inputs.liveReading);
    final remembered = _usable(inputs.rememberedReading);
    final modelLabel = entry?.model ?? reportedModel;

    return ResolvedCameraSensorSpecs(
      reportedModel: reportedModel,
      databaseEntry: entry,
      pixelSizeMicrons: _resolveDouble(
        override: overrides.pixelSizeMicrons,
        live: live?.meanPixelSizeMicrons,
        remembered: remembered?.meanPixelSizeMicrons,
        published: entry?.pixelSizeMicrons,
        publishedProvenance: entry == null
            ? null
            : entry.pixelSizeIsDerived
            ? 'derived from the published sensor size and pixel count '
                  'for $modelLabel'
            : 'the published pixel pitch for $modelLabel',
        liveModel: modelLabel,
        rememberedAt: remembered?.readAt,
      ),
      sensorWidthPx: _resolveInt(
        override: overrides.sensorWidthPx,
        live: live?.widthPx,
        remembered: remembered?.widthPx,
        published: entry?.widthPx,
        publishedProvenance: entry == null
            ? null
            : 'the published resolution for $modelLabel',
        liveModel: modelLabel,
        rememberedAt: remembered?.readAt,
      ),
      sensorHeightPx: _resolveInt(
        override: overrides.sensorHeightPx,
        live: live?.heightPx,
        remembered: remembered?.heightPx,
        published: entry?.heightPx,
        publishedProvenance: entry == null
            ? null
            : 'the published resolution for $modelLabel',
        liveModel: modelLabel,
        rememberedAt: remembered?.readAt,
      ),
      readNoiseE: _resolveFigure(
        override: overrides.readNoiseE,
        figures: entry?.readNoiseE,
        gain: inputs.gain,
        higherIsWorse: true,
        unit: 'e⁻',
        modelLabel: modelLabel,
      ),
      fullWellE: _resolveFigure(
        override: overrides.fullWellE,
        figures: entry?.fullWellE,
        gain: inputs.gain,
        higherIsWorse: false,
        unit: 'e⁻',
        modelLabel: modelLabel,
      ),
      qePeakFraction: _resolveDouble(
        override: overrides.qePeakFraction,
        live: null,
        remembered: null,
        published: entry?.qePeakFraction,
        publishedProvenance: entry == null
            ? null
            : 'the published peak QE for $modelLabel',
        liveModel: modelLabel,
        rememberedAt: null,
      ),
    );
  }

  static SensorGeometryReading? _usable(SensorGeometryReading? reading) =>
      (reading != null && reading.isUsable) ? reading : null;

  static String? _firstNonBlank(List<String?> candidates) {
    for (final candidate in candidates) {
      final trimmed = candidate?.trim();
      if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    }
    return null;
  }

  static SensorSpecValue<double>? _resolveDouble({
    required double? override,
    required double? live,
    required double? remembered,
    required double? published,
    required String? publishedProvenance,
    required String? liveModel,
    required DateTime? rememberedAt,
  }) {
    if (override != null) {
      return SensorSpecValue(
        value: override,
        origin: SensorSpecOrigin.userOverride,
        provenance: _overrideProvenance,
      );
    }
    if (live != null) {
      return SensorSpecValue(
        value: live,
        origin: SensorSpecOrigin.connectedCamera,
        provenance: _liveProvenance(liveModel),
      );
    }
    if (remembered != null) {
      return SensorSpecValue(
        value: remembered,
        origin: SensorSpecOrigin.rememberedCamera,
        provenance: _rememberedProvenance(liveModel, rememberedAt),
      );
    }
    if (published != null && publishedProvenance != null) {
      return SensorSpecValue(
        value: published,
        origin: SensorSpecOrigin.modelDatabase,
        provenance: publishedProvenance,
      );
    }
    return null;
  }

  static SensorSpecValue<int>? _resolveInt({
    required int? override,
    required int? live,
    required int? remembered,
    required int? published,
    required String? publishedProvenance,
    required String? liveModel,
    required DateTime? rememberedAt,
  }) {
    final resolved = _resolveDouble(
      override: override?.toDouble(),
      live: live?.toDouble(),
      remembered: remembered?.toDouble(),
      published: published?.toDouble(),
      publishedProvenance: publishedProvenance,
      liveModel: liveModel,
      rememberedAt: rememberedAt,
    );
    if (resolved == null) return null;
    return SensorSpecValue(
      value: resolved.value.round(),
      origin: resolved.origin,
      provenance: resolved.provenance,
    );
  }

  /// Resolves a gain-dependent figure without flattening it.
  ///
  /// No tier between the user and the database can supply one: a camera driver
  /// reports geometry and temperature, never read noise or QE.
  static SensorSpecValue<double>? _resolveFigure({
    required double? override,
    required List<PublishedFigure>? figures,
    required int? gain,
    required bool higherIsWorse,
    required String unit,
    required String? modelLabel,
  }) {
    if (override != null) {
      return SensorSpecValue(
        value: override,
        origin: SensorSpecOrigin.userOverride,
        provenance: _overrideProvenance,
      );
    }
    if (figures == null || figures.isEmpty || modelLabel == null) return null;

    final atGain =
        figures
            .where((figure) => figure.kind == PublishedFigureKind.atDriverGain)
            .toList()
          ..sort((a, b) => a.driverGain!.compareTo(b.driverGain!));

    if (gain != null) {
      for (final figure in atGain) {
        if (figure.driverGain == gain) {
          return SensorSpecValue(
            value: figure.low,
            origin: SensorSpecOrigin.modelDatabase,
            provenance:
                'the published figure for $modelLabel at your gain of $gain',
          );
        }
      }
      // Two published points either side of the configured gain is the one
      // case where the curve itself is published, so interpolating along it
      // states something the manufacturer actually said.
      for (var i = 0; i < atGain.length - 1; i++) {
        final lower = atGain[i];
        final upper = atGain[i + 1];
        if (gain > lower.driverGain! && gain < upper.driverGain!) {
          final t =
              (gain - lower.driverGain!) /
              (upper.driverGain! - lower.driverGain!);
          return SensorSpecValue(
            value: lower.low + (upper.low - lower.low) * t,
            origin: SensorSpecOrigin.modelDatabase,
            provenance:
                'interpolated between the published figures for $modelLabel '
                'at gain ${lower.driverGain} and gain ${upper.driverGain}',
          );
        }
      }
    }

    // A published range with no per-gain attribution: take the end that does
    // not flatter the camera and say that is what happened.
    for (final figure in figures) {
      if (!figure.isRange) continue;
      final value = figure.conservativeValue(higherIsWorse: higherIsWorse);
      return SensorSpecValue(
        value: value,
        origin: SensorSpecOrigin.modelDatabase,
        provenance:
            'the ${higherIsWorse ? 'high' : 'low'} end of the published '
            '${_formatNumber(figure.low)}–${_formatNumber(figure.high)} '
            '$unit range for $modelLabel, because the manufacturer does not '
            'publish it per gain',
      );
    }

    final figure = figures.first;
    return SensorSpecValue(
      value: figure.low,
      origin: SensorSpecOrigin.modelDatabase,
      provenance: switch (figure.kind) {
        // The operating point is the whole point of these two: the reader has
        // to be able to tell that the figure is not quoted at their gain.
        PublishedFigureKind.atQuotedLabel =>
          'the published figure for $modelLabel, which the manufacturer '
              'quotes only ${figure.operatingPointPhrase}',
        PublishedFigureKind.unattributed =>
          'the published figure for $modelLabel, which the manufacturer '
              'quotes ${figure.operatingPointPhrase}',
        PublishedFigureKind.atDriverGain || PublishedFigureKind.range =>
          'the published figure for $modelLabel '
              '${figure.operatingPointPhrase}',
      },
    );
  }

  static const String _overrideProvenance = 'the value you entered';

  static String _liveProvenance(String? model) => model == null
      ? 'read from the connected camera'
      : 'read from the connected $model';

  static String _rememberedProvenance(String? model, DateTime? at) {
    final subject = model ?? 'this camera';
    if (at == null) {
      return 'remembered from the last time $subject was connected';
    }
    return 'remembered from $subject on ${_formatDate(at)}';
  }

  static String _formatDate(DateTime value) {
    final local = value.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')}';
  }

  static String _formatNumber(double value) {
    if (value == value.roundToDouble() && value.abs() < 1000) {
      return value.round().toString();
    }
    return value.toStringAsFixed(1);
  }
}
