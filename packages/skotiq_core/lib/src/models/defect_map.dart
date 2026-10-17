/// Models for the defect-map / bad-pixel cosmetic correction pipeline.
///
/// A defect map is keyed by `(cameraId, width, height, temperatureBucket)`.
/// Temperature is bucketed to the nearest 5 C and stored in
/// deci-degrees-Celsius so it round-trips losslessly through the FFI
/// boundary as an `int`.
library;

/// Replacement method used to fill a defective pixel during per-frame
/// correction. The wire-form identifier matches the Rust
/// [`skotiq_imaging::defect_map::CorrectionMethod`] enum and is
/// what gets persisted in settings + pushed to the bridge.
enum DefectMapMethod {
  /// Median of healthy neighbours (default — robust to outliers,
  /// preserves frame statistics, handles hot/cold pixels symmetrically).
  median('median'),

  /// Plain mean of healthy neighbours (faster but a single hot neighbour
  /// skews the result — recommended only when the user wants smoother
  /// fills than median produces).
  mean('mean'),

  /// Gaussian-weighted mean of healthy neighbours (smoothest fills
  /// near sharp features like stars, but slightly more expensive).
  gaussian('gaussian');

  final String wireValue;
  const DefectMapMethod(this.wireValue);

  static DefectMapMethod fromWire(
    String? value, {
    DefectMapMethod fallback = DefectMapMethod.median,
  }) {
    if (value == null || value.isEmpty) return fallback;
    for (final m in DefectMapMethod.values) {
      if (m.wireValue == value) return m;
    }
    return fallback;
  }

  /// Human-readable label for the settings UI.
  String get label {
    switch (this) {
      case DefectMapMethod.median:
        return 'Median (recommended)';
      case DefectMapMethod.mean:
        return 'Mean';
      case DefectMapMethod.gaussian:
        return 'Gaussian-weighted';
    }
  }
}

/// Kernel diameter for defect-map correction. Restricted to the three
/// sensible UI choices: 3x3, 5x5, 7x7. The detector validates the
/// input rather than silently accepting arbitrary kernels.
enum DefectMapKernelSize {
  k3(3),
  k5(5),
  k7(7);

  final int diameter;
  const DefectMapKernelSize(this.diameter);

  static DefectMapKernelSize fromDiameter(
    int diameter, {
    DefectMapKernelSize fallback = DefectMapKernelSize.k3,
  }) {
    for (final k in DefectMapKernelSize.values) {
      if (k.diameter == diameter) return k;
    }
    return fallback;
  }

  /// Human-readable label for the settings UI.
  String get label => '${diameter}x$diameter';
}

/// A temperature bucket: the nearest 5 C, expressed in deci-degrees
/// Celsius (so -22.5C is `-225`). Wraps the small set of valid integer
/// values to keep the rest of the codebase from juggling raw ints with
/// implicit semantics.
class DefectMapTemperatureBucket {
  final int decicelsius;

  const DefectMapTemperatureBucket(this.decicelsius);

  /// Bucket a temperature in degrees Celsius to the nearest 5 C.
  factory DefectMapTemperatureBucket.fromCelsius(double celsius) {
    final bucketed = (celsius / 5.0).round() * 5.0;
    return DefectMapTemperatureBucket((bucketed * 10).round());
  }

  /// The bucket as a floating-point Celsius value.
  double get celsius => decicelsius / 10.0;

  /// Human-readable label like `-20.0C` or `+7.5C`.
  String get label {
    final sign = decicelsius >= 0 ? '+' : '';
    return '$sign${celsius.toStringAsFixed(1)}C';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DefectMapTemperatureBucket &&
          runtimeType == other.runtimeType &&
          decicelsius == other.decicelsius;

  @override
  int get hashCode => decicelsius.hashCode;

  @override
  String toString() => 'DefectMapTemperatureBucket($label)';
}

/// Status of the defect map for a given camera and temperature bucket.
///
/// Returned by the service after build / clear / status queries. A
/// `null` result from a status query means there is no stored map yet
/// for the requested combination — callers should treat that as
/// "calibration not yet run" rather than as an error.
class DefectMapStatus {
  /// Camera identifier (e.g. `native:zwo:ASI2600MC`).
  final String cameraId;

  /// Sensor width in pixels.
  final int width;

  /// Sensor height in pixels.
  final int height;

  /// The temperature bucket this map was built at.
  final DefectMapTemperatureBucket temperatureBucket;

  /// Number of pixels flagged defective in the map.
  final int defectivePixelCount;

  /// When the map was last (re)built, in seconds since the Unix epoch.
  /// May be 0 if the source timestamp could not be read.
  final int lastRebuiltUnixSeconds;

  /// User preference: whether the map should be applied to lights at
  /// capture time. Independent of whether the map exists on disk.
  final bool applyDuringCapture;

  /// Whether a serialised `.ndm` file is present on disk.
  final bool storedOnDisk;

  const DefectMapStatus({
    required this.cameraId,
    required this.width,
    required this.height,
    required this.temperatureBucket,
    required this.defectivePixelCount,
    required this.lastRebuiltUnixSeconds,
    required this.applyDuringCapture,
    required this.storedOnDisk,
  });

  /// DateTime of last rebuild, if the timestamp is non-zero.
  DateTime? get lastRebuiltAt => lastRebuiltUnixSeconds == 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(
          lastRebuiltUnixSeconds * 1000,
          isUtc: true,
        );

  DefectMapStatus copyWith({
    String? cameraId,
    int? width,
    int? height,
    DefectMapTemperatureBucket? temperatureBucket,
    int? defectivePixelCount,
    int? lastRebuiltUnixSeconds,
    bool? applyDuringCapture,
    bool? storedOnDisk,
  }) {
    return DefectMapStatus(
      cameraId: cameraId ?? this.cameraId,
      width: width ?? this.width,
      height: height ?? this.height,
      temperatureBucket: temperatureBucket ?? this.temperatureBucket,
      defectivePixelCount: defectivePixelCount ?? this.defectivePixelCount,
      lastRebuiltUnixSeconds:
          lastRebuiltUnixSeconds ?? this.lastRebuiltUnixSeconds,
      applyDuringCapture: applyDuringCapture ?? this.applyDuringCapture,
      storedOnDisk: storedOnDisk ?? this.storedOnDisk,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DefectMapStatus &&
          runtimeType == other.runtimeType &&
          cameraId == other.cameraId &&
          width == other.width &&
          height == other.height &&
          temperatureBucket == other.temperatureBucket &&
          defectivePixelCount == other.defectivePixelCount &&
          lastRebuiltUnixSeconds == other.lastRebuiltUnixSeconds &&
          applyDuringCapture == other.applyDuringCapture &&
          storedOnDisk == other.storedOnDisk;

  @override
  int get hashCode => Object.hash(
    cameraId,
    width,
    height,
    temperatureBucket,
    defectivePixelCount,
    lastRebuiltUnixSeconds,
    applyDuringCapture,
    storedOnDisk,
  );

  @override
  String toString() =>
      'DefectMapStatus(camera=$cameraId, ${width}x$height, '
      '${temperatureBucket.label}, defects=$defectivePixelCount, '
      'apply=$applyDuringCapture, onDisk=$storedOnDisk)';
}
