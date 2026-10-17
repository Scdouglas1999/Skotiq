import 'dart:math' as math;

/// Data layer for the hardware-presets library used by Onboarding & First-Light.
///
/// This mirrors the serialize/validate discipline of
/// `services/smart_night/hardware_specs_service.dart`: every `fromJson`
/// rejects missing or non-numeric required fields with a [FormatException]
/// rather than substituting a default: a malformed persisted preset would
/// otherwise reach the imaging train as plausible optics.
///
/// The built-in catalogs ([builtInTelescopePresets], [builtInCameraDefaultsPresets])
/// are `const` and carry real-world manufacturer specifications. User-created
/// presets are constructed with [newHardwarePresetId] for a collision-free id.

/// The optical design family of a telescope. Determines how the imaging train
/// behaves (e.g. refractors are flat-field after a flattener; SCTs/RCs need
/// back-focus discipline) and drives UI grouping in the preset picker.
enum OpticalDesign {
  refractor,
  reflectorNewtonian,
  ritcheyChretien,
  schmidtCassegrain,
  maksutovCassegrain,
  schmidtNewtonian,
  corrector,
  other;

  /// Human-readable label for display in the preset library UI.
  String get label {
    switch (this) {
      case OpticalDesign.refractor:
        return 'Refractor';
      case OpticalDesign.reflectorNewtonian:
        return 'Newtonian Reflector';
      case OpticalDesign.ritcheyChretien:
        return 'Ritchey-Chrétien';
      case OpticalDesign.schmidtCassegrain:
        return 'Schmidt-Cassegrain';
      case OpticalDesign.maksutovCassegrain:
        return 'Maksutov-Cassegrain';
      case OpticalDesign.schmidtNewtonian:
        return 'Schmidt-Newtonian';
      case OpticalDesign.corrector:
        return 'Corrected Lens / Astrograph';
      case OpticalDesign.other:
        return 'Other';
    }
  }

  /// Parses an [OpticalDesign] from its [name] (the round-trip form written by
  /// [TelescopePreset.toJson]). Throws [FormatException] for unknown values —
  /// no silent fallback to [OpticalDesign.other].
  static OpticalDesign fromJson(Object? value) {
    if (value is String) {
      for (final design in OpticalDesign.values) {
        if (design.name == value) return design;
      }
    }
    throw FormatException('Unknown OpticalDesign: $value');
  }
}

/// A telescope / optical-tube preset. Aperture and focal length are the
/// load-bearing fields; [focalRatio] is derived so it can never drift out of
/// sync with the stored optics.
class TelescopePreset {
  final String id;
  final String brand;
  final String model;
  final double focalLengthMm;
  final double apertureMm;
  final OpticalDesign design;

  /// The manufacturer's published native focal ratio, when it differs from the
  /// raw [focalRatio] (e.g. SCTs quote f/10 but rounding of aperture/FL gives
  /// f/10.01). `null` means "use the computed [focalRatio]".
  final double? nativeFocalRatio;

  final bool isBuiltIn;

  const TelescopePreset({
    required this.id,
    required this.brand,
    required this.model,
    required this.focalLengthMm,
    required this.apertureMm,
    required this.design,
    this.nativeFocalRatio,
    this.isBuiltIn = false,
  });

  /// Display name combining brand and model, e.g. `Sky-Watcher Esprit 100ED`.
  String get displayName => '$brand $model';

  /// Focal ratio computed from the optics (focal length / aperture). Always
  /// derived so it cannot contradict the stored [focalLengthMm]/[apertureMm].
  double get focalRatio {
    if (apertureMm <= 0) {
      throw StateError(
        'TelescopePreset $id has non-positive aperture: $apertureMm',
      );
    }
    return focalLengthMm / apertureMm;
  }

  factory TelescopePreset.fromJson(Map<String, dynamic> json) {
    return TelescopePreset(
      id: _stringValue(json['id'], 'id'),
      brand: _stringValue(json['brand'], 'brand'),
      model: _stringValue(json['model'], 'model'),
      focalLengthMm: _doubleValue(json['focalLengthMm'], 'focalLengthMm'),
      apertureMm: _doubleValue(json['apertureMm'], 'apertureMm'),
      design: OpticalDesign.fromJson(json['design']),
      nativeFocalRatio: _optionalDoubleValue(
        json['nativeFocalRatio'],
        'nativeFocalRatio',
      ),
      isBuiltIn: _boolValue(json['isBuiltIn'], 'isBuiltIn', orElse: false),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'brand': brand,
    'model': model,
    'focalLengthMm': focalLengthMm,
    'apertureMm': apertureMm,
    'design': design.name,
    if (nativeFocalRatio != null) 'nativeFocalRatio': nativeFocalRatio,
    'isBuiltIn': isBuiltIn,
  };

  TelescopePreset copyWith({
    String? id,
    String? brand,
    String? model,
    double? focalLengthMm,
    double? apertureMm,
    OpticalDesign? design,
    double? nativeFocalRatio,
    bool clearNativeFocalRatio = false,
    bool? isBuiltIn,
  }) {
    return TelescopePreset(
      id: id ?? this.id,
      brand: brand ?? this.brand,
      model: model ?? this.model,
      focalLengthMm: focalLengthMm ?? this.focalLengthMm,
      apertureMm: apertureMm ?? this.apertureMm,
      design: design ?? this.design,
      nativeFocalRatio: clearNativeFocalRatio
          ? null
          : (nativeFocalRatio ?? this.nativeFocalRatio),
      isBuiltIn: isBuiltIn ?? this.isBuiltIn,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is TelescopePreset &&
        other.id == id &&
        other.brand == brand &&
        other.model == model &&
        other.focalLengthMm == focalLengthMm &&
        other.apertureMm == apertureMm &&
        other.design == design &&
        other.nativeFocalRatio == nativeFocalRatio &&
        other.isBuiltIn == isBuiltIn;
  }

  @override
  int get hashCode => Object.hash(
    id,
    brand,
    model,
    focalLengthMm,
    apertureMm,
    design,
    nativeFocalRatio,
    isBuiltIn,
  );

  @override
  String toString() =>
      'TelescopePreset($displayName, ${focalLengthMm.round()}mm, '
      'f/${focalRatio.toStringAsFixed(1)})';
}

/// Camera defaults preset: physical sensor geometry plus sensible acquisition
/// defaults (gain/offset/binning/cooling) so onboarding can pre-fill an
/// equipment profile without the user hunting forum threads.
class CameraDefaultsPreset {
  final String id;
  final String brand;
  final String model;

  /// Alternate names the driver might report (used by name-matching that
  /// mirrors `HardwareSpecsService.matchCamera`).
  final List<String> aliases;

  final double pixelSizeMicrons;
  final int sensorWidthPx;
  final int sensorHeightPx;

  /// Manufacturer sensor part, e.g. `Sony IMX571`.
  final String sensorName;

  final bool isColor;
  final int recommendedGain;
  final int recommendedOffset;

  /// Filter-group recipes; absent entries use this camera’s general defaults.
  final int? broadbandGain;
  final int? broadbandOffset;
  final int? narrowbandGain;
  final int? narrowbandOffset;

  final int recommendedBinX;
  final int recommendedBinY;

  /// Recommended set-point cooling temperature in °C. `null` for cameras
  /// without regulated cooling (e.g. a DSLR), which must remain `null` rather
  /// than collapsing to 0 °C.
  final double? recommendedCoolingTempC;

  final bool isBuiltIn;

  const CameraDefaultsPreset({
    required this.id,
    required this.brand,
    required this.model,
    this.aliases = const [],
    required this.pixelSizeMicrons,
    required this.sensorWidthPx,
    required this.sensorHeightPx,
    required this.sensorName,
    required this.isColor,
    required this.recommendedGain,
    required this.recommendedOffset,
    this.broadbandGain,
    this.broadbandOffset,
    this.narrowbandGain,
    this.narrowbandOffset,

    this.recommendedBinX = 1,
    this.recommendedBinY = 1,
    this.recommendedCoolingTempC,
    this.isBuiltIn = false,
  });

  /// Display name combining brand and model, e.g. `ZWO ASI2600MM Pro`.
  String get displayName => '$brand $model';

  /// Sensor diagonal in millimetres, computed from the pixel pitch and array
  /// dimensions: `sqrt(w² + h²) × pixelPitch`. Useful for sizing the FOV /
  /// flattener compatibility hints in the preset library.
  double get sensorDiagonalMm {
    final widthMm = sensorWidthPx * pixelSizeMicrons / 1000.0;
    final heightMm = sensorHeightPx * pixelSizeMicrons / 1000.0;
    return math.sqrt(widthMm * widthMm + heightMm * heightMm);
  }

  factory CameraDefaultsPreset.fromJson(Map<String, dynamic> json) {
    final aliasesJson = json['aliases'];
    return CameraDefaultsPreset(
      id: _stringValue(json['id'], 'id'),
      brand: _stringValue(json['brand'], 'brand'),
      model: _stringValue(json['model'], 'model'),
      aliases: aliasesJson is List
          ? aliasesJson.map((value) => value.toString()).toList()
          : const [],
      pixelSizeMicrons: _doubleValue(
        json['pixelSizeMicrons'],
        'pixelSizeMicrons',
      ),
      sensorWidthPx: _intValue(json['sensorWidthPx'], 'sensorWidthPx'),
      sensorHeightPx: _intValue(json['sensorHeightPx'], 'sensorHeightPx'),
      sensorName: _stringValue(json['sensorName'], 'sensorName'),
      isColor: _boolValue(json['isColor'], 'isColor'),
      recommendedGain: _intValue(json['recommendedGain'], 'recommendedGain'),
      broadbandGain: json['broadbandGain'] == null
          ? null
          : _intValue(json['broadbandGain'], 'broadbandGain'),
      broadbandOffset: json['broadbandOffset'] == null
          ? null
          : _intValue(json['broadbandOffset'], 'broadbandOffset'),
      narrowbandGain: json['narrowbandGain'] == null
          ? null
          : _intValue(json['narrowbandGain'], 'narrowbandGain'),
      narrowbandOffset: json['narrowbandOffset'] == null
          ? null
          : _intValue(json['narrowbandOffset'], 'narrowbandOffset'),

      recommendedOffset: _intValue(
        json['recommendedOffset'],
        'recommendedOffset',
      ),
      recommendedBinX: json.containsKey('recommendedBinX')
          ? _intValue(json['recommendedBinX'], 'recommendedBinX')
          : 1,
      recommendedBinY: json.containsKey('recommendedBinY')
          ? _intValue(json['recommendedBinY'], 'recommendedBinY')
          : 1,
      recommendedCoolingTempC: _optionalDoubleValue(
        json['recommendedCoolingTempC'],
        'recommendedCoolingTempC',
      ),
      isBuiltIn: _boolValue(json['isBuiltIn'], 'isBuiltIn', orElse: false),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'brand': brand,
    'model': model,
    'aliases': aliases,
    'pixelSizeMicrons': pixelSizeMicrons,
    'sensorWidthPx': sensorWidthPx,
    'sensorHeightPx': sensorHeightPx,
    'sensorName': sensorName,
    'isColor': isColor,
    'recommendedGain': recommendedGain,
    'recommendedOffset': recommendedOffset,
    if (broadbandGain != null) 'broadbandGain': broadbandGain,
    if (broadbandOffset != null) 'broadbandOffset': broadbandOffset,
    if (narrowbandGain != null) 'narrowbandGain': narrowbandGain,
    if (narrowbandOffset != null) 'narrowbandOffset': narrowbandOffset,

    'recommendedBinX': recommendedBinX,
    'recommendedBinY': recommendedBinY,
    if (recommendedCoolingTempC != null)
      'recommendedCoolingTempC': recommendedCoolingTempC,
    'isBuiltIn': isBuiltIn,
  };

  CameraDefaultsPreset copyWith({
    String? id,
    String? brand,
    String? model,
    List<String>? aliases,
    double? pixelSizeMicrons,
    int? sensorWidthPx,
    int? sensorHeightPx,
    String? sensorName,
    bool? isColor,
    int? recommendedGain,
    int? recommendedOffset,
    int? broadbandGain,
    int? broadbandOffset,
    int? narrowbandGain,
    int? narrowbandOffset,

    int? recommendedBinX,
    int? recommendedBinY,
    double? recommendedCoolingTempC,
    bool clearRecommendedCoolingTempC = false,
    bool? isBuiltIn,
  }) {
    return CameraDefaultsPreset(
      id: id ?? this.id,
      brand: brand ?? this.brand,
      model: model ?? this.model,
      aliases: aliases ?? this.aliases,
      pixelSizeMicrons: pixelSizeMicrons ?? this.pixelSizeMicrons,
      sensorWidthPx: sensorWidthPx ?? this.sensorWidthPx,
      sensorHeightPx: sensorHeightPx ?? this.sensorHeightPx,
      sensorName: sensorName ?? this.sensorName,
      isColor: isColor ?? this.isColor,
      recommendedGain: recommendedGain ?? this.recommendedGain,
      recommendedOffset: recommendedOffset ?? this.recommendedOffset,
      broadbandGain: broadbandGain ?? this.broadbandGain,
      broadbandOffset: broadbandOffset ?? this.broadbandOffset,
      narrowbandGain: narrowbandGain ?? this.narrowbandGain,
      narrowbandOffset: narrowbandOffset ?? this.narrowbandOffset,

      recommendedBinX: recommendedBinX ?? this.recommendedBinX,
      recommendedBinY: recommendedBinY ?? this.recommendedBinY,
      recommendedCoolingTempC: clearRecommendedCoolingTempC
          ? null
          : (recommendedCoolingTempC ?? this.recommendedCoolingTempC),
      isBuiltIn: isBuiltIn ?? this.isBuiltIn,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is CameraDefaultsPreset &&
        other.id == id &&
        other.brand == brand &&
        other.model == model &&
        _listEquals(other.aliases, aliases) &&
        other.pixelSizeMicrons == pixelSizeMicrons &&
        other.sensorWidthPx == sensorWidthPx &&
        other.sensorHeightPx == sensorHeightPx &&
        other.sensorName == sensorName &&
        other.isColor == isColor &&
        other.recommendedGain == recommendedGain &&
        other.recommendedOffset == recommendedOffset &&
        other.broadbandGain == broadbandGain &&
        other.broadbandOffset == broadbandOffset &&
        other.narrowbandGain == narrowbandGain &&
        other.narrowbandOffset == narrowbandOffset &&
        other.recommendedBinX == recommendedBinX &&
        other.recommendedBinY == recommendedBinY &&
        other.recommendedCoolingTempC == recommendedCoolingTempC &&
        other.isBuiltIn == isBuiltIn;
  }

  @override
  int get hashCode => Object.hash(
    id,
    brand,
    model,
    Object.hashAll(aliases),
    pixelSizeMicrons,
    sensorWidthPx,
    sensorHeightPx,
    sensorName,
    isColor,
    recommendedGain,
    recommendedOffset,
    broadbandGain,
    broadbandOffset,
    narrowbandGain,
    narrowbandOffset,

    recommendedBinX,
    recommendedBinY,
    recommendedCoolingTempC,
    isBuiltIn,
  );

  @override
  String toString() =>
      'CameraDefaultsPreset($displayName, $sensorName, '
      '$pixelSizeMicronsµm, ${sensorWidthPx}x$sensorHeightPx, '
      '${isColor ? 'color' : 'mono'})';
}

// Field parsing helpers — shared validation discipline (mirrors
// HardwareSpecsService): every required field throws FormatException when
// missing or of the wrong type. No silent defaults.

String _stringValue(Object? value, String field) {
  if (value is String && value.trim().isNotEmpty) return value.trim();
  throw FormatException('Hardware preset requires $field');
}

int _intValue(Object? value, String field) {
  if (value is int) return value;
  if (value is num && value.isFinite) return value.round();
  if (value is String) {
    final parsed = int.tryParse(value);
    if (parsed != null) return parsed;
  }
  throw FormatException('Hardware preset requires numeric $field');
}

double _doubleValue(Object? value, String field) {
  if (value is num && value.isFinite) return value.toDouble();
  if (value is String) {
    final parsed = double.tryParse(value);
    if (parsed != null && parsed.isFinite) return parsed;
  }
  throw FormatException('Hardware preset requires numeric $field');
}

double? _optionalDoubleValue(Object? value, String field) {
  if (value == null) return null;
  return _doubleValue(value, field);
}

bool _boolValue(Object? value, String field, {bool? orElse}) {
  if (value is bool) return value;
  if (value == null && orElse != null) return orElse;
  if (value is String) {
    if (value == 'true') return true;
    if (value == 'false') return false;
  }
  throw FormatException('Hardware preset requires boolean $field');
}

bool _listEquals(List<String> a, List<String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// Id generation for user-created presets.

final math.Random _presetIdRandom = math.Random();

/// Generates a collision-free id for a user-created preset, combining the
/// current epoch milliseconds with random entropy. Built-in presets use stable
/// human-readable ids (e.g. `tel.skywatcher.esprit100ed`) so that persisted
/// references survive catalog reordering; user ids are opaque.
String newHardwarePresetId() {
  final timestamp = DateTime.now().microsecondsSinceEpoch;
  final entropy = _presetIdRandom.nextInt(1 << 32);
  return 'user.$timestamp.${entropy.toRadixString(16).padLeft(8, '0')}';
}

// Built-in telescope catalog. All values are manufacturer-published specs.
// `nativeFocalRatio` is supplied where the marketed f/ratio differs from the
// raw aperture/FL division (e.g. SCTs marketed as f/10 compute to f/10.01).

const List<TelescopePreset> builtInTelescopePresets = [
  TelescopePreset(
    id: 'tel.skywatcher.esprit100ed',
    brand: 'Sky-Watcher',
    model: 'Esprit 100ED',
    focalLengthMm: 550,
    apertureMm: 100,
    design: OpticalDesign.refractor,
    nativeFocalRatio: 5.5,
    isBuiltIn: true,
  ),
  TelescopePreset(
    id: 'tel.skywatcher.esprit120ed',
    brand: 'Sky-Watcher',
    model: 'Esprit 120ED',
    focalLengthMm: 840,
    apertureMm: 120,
    design: OpticalDesign.refractor,
    nativeFocalRatio: 7.0,
    isBuiltIn: true,
  ),
  TelescopePreset(
    id: 'tel.williamoptics.redcat51',
    brand: 'William Optics',
    model: 'RedCat 51',
    focalLengthMm: 250,
    apertureMm: 51,
    design: OpticalDesign.corrector,
    nativeFocalRatio: 4.9,
    isBuiltIn: true,
  ),
  TelescopePreset(
    id: 'tel.radian.raptor61',
    brand: 'Radian',
    model: 'Raptor 61',
    focalLengthMm: 275,
    apertureMm: 61,
    design: OpticalDesign.corrector,
    nativeFocalRatio: 4.5,
    isBuiltIn: true,
  ),
  TelescopePreset(
    id: 'tel.askar.fra400',
    brand: 'Askar',
    model: 'FRA400',
    focalLengthMm: 400,
    apertureMm: 72,
    design: OpticalDesign.refractor,
    nativeFocalRatio: 5.6,
    isBuiltIn: true,
  ),
  TelescopePreset(
    id: 'tel.skywatcher.quattro200p',
    brand: 'Sky-Watcher',
    model: 'Quattro 200P',
    focalLengthMm: 800,
    apertureMm: 200,
    design: OpticalDesign.reflectorNewtonian,
    nativeFocalRatio: 4.0,
    isBuiltIn: true,
  ),
  TelescopePreset(
    id: 'tel.gso.rc8',
    brand: 'GSO',
    model: 'RC8 (Apertura AD8RC)',
    focalLengthMm: 1624,
    apertureMm: 203,
    design: OpticalDesign.ritcheyChretien,
    nativeFocalRatio: 8.0,
    isBuiltIn: true,
  ),
  TelescopePreset(
    id: 'tel.celestron.edgehd8',
    brand: 'Celestron',
    model: 'EdgeHD 8',
    focalLengthMm: 2032,
    apertureMm: 203,
    design: OpticalDesign.schmidtCassegrain,
    nativeFocalRatio: 10.0,
    isBuiltIn: true,
  ),
  TelescopePreset(
    id: 'tel.celestron.c11',
    brand: 'Celestron',
    model: 'C11',
    focalLengthMm: 2800,
    apertureMm: 280,
    design: OpticalDesign.schmidtCassegrain,
    nativeFocalRatio: 10.0,
    isBuiltIn: true,
  ),
  TelescopePreset(
    id: 'tel.takahashi.fsq106edx4',
    brand: 'Takahashi',
    model: 'FSQ-106EDX4',
    focalLengthMm: 530,
    apertureMm: 106,
    design: OpticalDesign.refractor,
    nativeFocalRatio: 5.0,
    isBuiltIn: true,
  ),
  TelescopePreset(
    id: 'tel.skywatcher.evostar72ed',
    brand: 'Sky-Watcher',
    model: 'Evostar 72ED',
    focalLengthMm: 420,
    apertureMm: 72,
    design: OpticalDesign.refractor,
    nativeFocalRatio: 5.8,
    isBuiltIn: true,
  ),
  TelescopePreset(
    id: 'tel.explorescientific.ed80',
    brand: 'Explore Scientific',
    model: 'ED80',
    focalLengthMm: 480,
    apertureMm: 80,
    design: OpticalDesign.refractor,
    nativeFocalRatio: 6.0,
    isBuiltIn: true,
  ),
  TelescopePreset(
    id: 'tel.samyang.135f2',
    brand: 'Samyang',
    model: '135mm f/2 (Rokinon 135)',
    focalLengthMm: 135,
    apertureMm: 67.5,
    design: OpticalDesign.corrector,
    nativeFocalRatio: 2.0,
    isBuiltIn: true,
  ),
];

// Built-in camera-defaults catalog. Pixel size / sensor part / array
// dimensions are manufacturer specs. Gain/offset defaults are the
// community-standard set-points (e.g. ASI1600 unity gain 139/21; ZWO
// IMX571-class 100/50). Cooled CMOS get a -10 °C set-point; the DSLR has none.

const List<CameraDefaultsPreset> builtInCameraDefaultsPresets = [
  CameraDefaultsPreset(
    id: 'cam.zwo.asi2600mm',
    brand: 'ZWO',
    model: 'ASI2600MM Pro',
    aliases: ['ASI2600MM', 'ASI2600MM Pro', 'ZWO ASI2600MM'],
    pixelSizeMicrons: 3.76,
    sensorWidthPx: 6248,
    sensorHeightPx: 4176,
    sensorName: 'Sony IMX571',
    isColor: false,
    recommendedGain: 100,
    recommendedOffset: 50,
    recommendedCoolingTempC: -10,
    isBuiltIn: true,
  ),
  CameraDefaultsPreset(
    id: 'cam.zwo.asi2600mc',
    brand: 'ZWO',
    model: 'ASI2600MC Pro',
    aliases: ['ASI2600MC', 'ASI2600MC Pro', 'ZWO ASI2600MC'],
    pixelSizeMicrons: 3.76,
    sensorWidthPx: 6248,
    sensorHeightPx: 4176,
    sensorName: 'Sony IMX571',
    isColor: true,
    recommendedGain: 100,
    recommendedOffset: 50,
    recommendedCoolingTempC: -10,
    isBuiltIn: true,
  ),
  CameraDefaultsPreset(
    id: 'cam.zwo.asi533mm',
    brand: 'ZWO',
    model: 'ASI533MM Pro',
    aliases: ['ASI533MM', 'ASI533MM Pro', 'ZWO ASI533MM'],
    pixelSizeMicrons: 3.76,
    sensorWidthPx: 3008,
    sensorHeightPx: 3008,
    sensorName: 'Sony IMX533',
    isColor: false,
    recommendedGain: 100,
    recommendedOffset: 50,
    recommendedCoolingTempC: -10,
    isBuiltIn: true,
  ),
  CameraDefaultsPreset(
    id: 'cam.zwo.asi533mc',
    brand: 'ZWO',
    model: 'ASI533MC Pro',
    aliases: ['ASI533MC', 'ASI533MC Pro', 'ZWO ASI533MC'],
    pixelSizeMicrons: 3.76,
    sensorWidthPx: 3008,
    sensorHeightPx: 3008,
    sensorName: 'Sony IMX533',
    isColor: true,
    recommendedGain: 100,
    recommendedOffset: 50,
    recommendedCoolingTempC: -10,
    isBuiltIn: true,
  ),
  CameraDefaultsPreset(
    id: 'cam.zwo.asi1600mm',
    brand: 'ZWO',
    model: 'ASI1600MM Pro',
    aliases: [
      'ASI1600MM',
      'ASI1600MM Pro',
      'ASI1600MM-Pro',
      'ASI1600MM-Cool',
      'ZWO ASI1600MM',
    ],
    pixelSizeMicrons: 3.8,
    sensorWidthPx: 4656,
    sensorHeightPx: 3520,
    sensorName: 'Panasonic MN34230',
    isColor: false,
    // 139/21 is the well-known unity-gain set-point for the MN34230.
    recommendedGain: 139,
    recommendedOffset: 21,
    // Owner-provided broadband/narrowband acquisition recipes.
    broadbandGain: 76,
    broadbandOffset: 15,
    narrowbandGain: 139,
    narrowbandOffset: 21,
    recommendedCoolingTempC: -10,
    isBuiltIn: true,
  ),
  CameraDefaultsPreset(
    id: 'cam.zwo.asi294mc',
    brand: 'ZWO',
    model: 'ASI294MC Pro',
    aliases: ['ASI294MC', 'ASI294MC Pro', 'ZWO ASI294MC'],
    pixelSizeMicrons: 4.63,
    sensorWidthPx: 4144,
    sensorHeightPx: 2822,
    sensorName: 'Sony IMX294',
    isColor: true,
    recommendedGain: 120,
    recommendedOffset: 30,
    recommendedCoolingTempC: -10,
    isBuiltIn: true,
  ),
  CameraDefaultsPreset(
    id: 'cam.zwo.asi183mm',
    brand: 'ZWO',
    model: 'ASI183MM Pro',
    aliases: ['ASI183MM', 'ASI183MM Pro', 'ZWO ASI183MM'],
    pixelSizeMicrons: 2.4,
    sensorWidthPx: 5496,
    sensorHeightPx: 3672,
    sensorName: 'Sony IMX183',
    isColor: false,
    recommendedGain: 111,
    recommendedOffset: 8,
    recommendedCoolingTempC: -10,
    isBuiltIn: true,
  ),
  CameraDefaultsPreset(
    id: 'cam.zwo.asi6200mm',
    brand: 'ZWO',
    model: 'ASI6200MM Pro',
    aliases: ['ASI6200MM', 'ASI6200MM Pro', 'ZWO ASI6200MM'],
    pixelSizeMicrons: 3.76,
    sensorWidthPx: 9576,
    sensorHeightPx: 6388,
    sensorName: 'Sony IMX455',
    isColor: false,
    recommendedGain: 100,
    recommendedOffset: 50,
    recommendedCoolingTempC: -10,
    isBuiltIn: true,
  ),
  CameraDefaultsPreset(
    id: 'cam.qhy.qhy268m',
    brand: 'QHYCCD',
    model: 'QHY268M',
    aliases: ['QHY268M', 'QHY268M Pro', 'QHY 268M'],
    pixelSizeMicrons: 3.76,
    sensorWidthPx: 6280,
    sensorHeightPx: 4210,
    sensorName: 'Sony IMX571',
    isColor: false,
    recommendedGain: 56,
    recommendedOffset: 30,
    recommendedCoolingTempC: -10,
    isBuiltIn: true,
  ),
  CameraDefaultsPreset(
    id: 'cam.qhy.qhy183m',
    brand: 'QHYCCD',
    model: 'QHY183M',
    aliases: ['QHY183M', 'QHY 183M'],
    pixelSizeMicrons: 2.4,
    sensorWidthPx: 5544,
    sensorHeightPx: 3694,
    sensorName: 'Sony IMX183',
    isColor: false,
    recommendedGain: 11,
    recommendedOffset: 30,
    recommendedCoolingTempC: -10,
    isBuiltIn: true,
  ),
  CameraDefaultsPreset(
    id: 'cam.playerone.poseidonm',
    brand: 'Player One',
    model: 'Poseidon-M Pro',
    aliases: ['Poseidon-M', 'Poseidon M', 'Player One Poseidon-M'],
    pixelSizeMicrons: 3.76,
    sensorWidthPx: 6248,
    sensorHeightPx: 4176,
    sensorName: 'Sony IMX571',
    isColor: false,
    recommendedGain: 100,
    recommendedOffset: 50,
    recommendedCoolingTempC: -10,
    isBuiltIn: true,
  ),
  CameraDefaultsPreset(
    id: 'cam.canon.eosra',
    brand: 'Canon',
    model: 'EOS Ra',
    aliases: ['EOS Ra', 'Canon EOS Ra'],
    pixelSizeMicrons: 4.3,
    sensorWidthPx: 6960,
    sensorHeightPx: 4640,
    sensorName: 'Canon CMOS (full-frame)',
    isColor: true,
    // A stock DSLR exposes ISO-mapped gain; 0/0 is the neutral baseline and
    // there is no regulated cooling, so the set-point stays null.
    recommendedGain: 0,
    recommendedOffset: 0,
    isBuiltIn: true,
  ),
];
