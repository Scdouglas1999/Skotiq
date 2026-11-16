import 'package:skotiq_bridge/skotiq_bridge.dart'
    show
        ApiFloorSample,
        ApiNightScore,
        ApiNightSky,
        ApiNightTarget,
        ApiSchedulerTarget,
        ApiScoringWeights,
        ApiTargetScoreNow,
        NativeBridge,
        apiRankSchedulerTargets,
        apiScoreTargetsForNight;

/// Where the target scorer runs: the native sequencer in this process, or the
/// linked host's (a phone has no native library).
abstract interface class TargetScoring {
  /// A TargetScheduler step's targets ranked at [nowUnixMs] as the step ranks
  /// them when it decides.
  Future<List<ApiTargetScoreNow>> rankSchedulerTargets({
    required double latitudeDeg,
    required double longitudeDeg,
    required int nowUnixMs,
    required List<ApiSchedulerTarget> targets,
    required ApiScoringWeights weights,
    required List<ApiFloorSample> floor,
  });

  /// Catalog positions scored over a night; only the ones above the floor at
  /// some point of it come back.
  Future<List<ApiNightScore>> scoreTargetsForNight({
    required ApiNightSky sky,
    required List<ApiNightTarget> targets,
    required ApiScoringWeights weights,
  });
}

/// The scorer in this process's native library.
final class NativeTargetScoring implements TargetScoring {
  const NativeTargetScoring();

  @override
  Future<List<ApiTargetScoreNow>> rankSchedulerTargets({
    required double latitudeDeg,
    required double longitudeDeg,
    required int nowUnixMs,
    required List<ApiSchedulerTarget> targets,
    required ApiScoringWeights weights,
    required List<ApiFloorSample> floor,
  }) => NativeBridge.run(
    'rank the TargetScheduler targets',
    () => apiRankSchedulerTargets(
      latitudeDeg: latitudeDeg,
      longitudeDeg: longitudeDeg,
      nowUnixMs: nowUnixMs,
      targets: targets,
      weights: weights,
      floor: floor,
    ),
  );

  @override
  Future<List<ApiNightScore>> scoreTargetsForNight({
    required ApiNightSky sky,
    required List<ApiNightTarget> targets,
    required ApiScoringWeights weights,
  }) => NativeBridge.run(
    'score targets for the night',
    () => apiScoreTargetsForNight(sky: sky, targets: targets, weights: weights),
  );
}

/// The JSON a linked client and its host exchange for the target scorer:
/// the requests a client sends and the scores the host's native scorer
/// returns, field for field.
abstract final class TargetScoringWire {
  static Map<String, Object?> rankRequest({
    required double latitudeDeg,
    required double longitudeDeg,
    required int nowUnixMs,
    required List<ApiSchedulerTarget> targets,
    required ApiScoringWeights weights,
    required List<ApiFloorSample> floor,
  }) => {
    'latitudeDeg': latitudeDeg,
    'longitudeDeg': longitudeDeg,
    'nowUnixMs': nowUnixMs,
    'targets': [
      for (final t in targets)
        {
          'id': t.id,
          'name': t.name,
          'raHours': t.raHours,
          'decDegrees': t.decDegrees,
          'minAltitudeDeg': t.minAltitudeDeg,
          'startAfterUnixSecs': t.startAfterUnixSecs,
          'endBeforeUnixSecs': t.endBeforeUnixSecs,
          'priority': t.priority,
        },
    ],
    'weights': _weights(weights),
    'floor': _floor(floor),
  };

  static ({
    double latitudeDeg,
    double longitudeDeg,
    int nowUnixMs,
    List<ApiSchedulerTarget> targets,
    ApiScoringWeights weights,
    List<ApiFloorSample> floor,
  })
  readRankRequest(Map<String, dynamic> json) => (
    latitudeDeg: _double(json, 'latitudeDeg'),
    longitudeDeg: _double(json, 'longitudeDeg'),
    nowUnixMs: _int(json, 'nowUnixMs'),
    targets: [
      for (final t in _list(json, 'targets'))
        ApiSchedulerTarget(
          id: _string(t, 'id'),
          name: _string(t, 'name'),
          raHours: _double(t, 'raHours'),
          decDegrees: _double(t, 'decDegrees'),
          minAltitudeDeg: _optionalDouble(t, 'minAltitudeDeg'),
          startAfterUnixSecs: _optionalInt(t, 'startAfterUnixSecs'),
          endBeforeUnixSecs: _optionalInt(t, 'endBeforeUnixSecs'),
          priority: _int(t, 'priority'),
        ),
    ],
    weights: _readWeights(_map(json, 'weights')),
    floor: _readFloor(json),
  );

  static List<Map<String, Object?>> rankResponse(
    List<ApiTargetScoreNow> scores,
  ) => [
    for (final s in scores)
      {
        'targetId': s.targetId,
        'totalScore': s.totalScore,
        'altitudeScore': s.altitudeScore,
        'moonDistanceScore': s.moonDistanceScore,
        'transitProximityScore': s.transitProximityScore,
        'darknessScore': s.darknessScore,
        'airmassScore': s.airmassScore,
        'altitudeDeg': s.altitudeDeg,
        'azimuthDeg': s.azimuthDeg,
        'airmass': s.airmass.isFinite ? s.airmass : null,
        'moonDistanceDeg': s.moonDistanceDeg,
        'runnable': s.runnable,
        'skipReason': s.skipReason,
      },
  ];

  static List<ApiTargetScoreNow> readRankResponse(List<dynamic> json) => [
    for (final s in json.cast<Map<String, dynamic>>())
      ApiTargetScoreNow(
        targetId: _string(s, 'targetId'),
        totalScore: _double(s, 'totalScore'),
        altitudeScore: _double(s, 'altitudeScore'),
        moonDistanceScore: _double(s, 'moonDistanceScore'),
        transitProximityScore: _double(s, 'transitProximityScore'),
        darknessScore: _double(s, 'darknessScore'),
        airmassScore: _double(s, 'airmassScore'),
        altitudeDeg: _double(s, 'altitudeDeg'),
        azimuthDeg: _double(s, 'azimuthDeg'),
        airmass: _optionalDouble(s, 'airmass') ?? double.infinity,
        moonDistanceDeg: _double(s, 'moonDistanceDeg'),
        runnable: s['runnable'] == true,
        skipReason: s['skipReason'] as String?,
      ),
  ];

  static Map<String, Object?> nightRequest({
    required ApiNightSky sky,
    required List<ApiNightTarget> targets,
    required ApiScoringWeights weights,
  }) => {
    'latitudeDeg': sky.latitudeDeg,
    'longitudeDeg': sky.longitudeDeg,
    'nowUnixMs': sky.nowUnixMs,
    'nightStartUnixMs': sky.nightStartUnixMs,
    'nightEndUnixMs': sky.nightEndUnixMs,
    'moonRaDeg': sky.moonRaDeg,
    'moonDecDeg': sky.moonDecDeg,
    'moonIlluminationPercent': sky.moonIlluminationPercent,
    'floor': _floor(sky.floor),
    // Positions as parallel arrays: a catalog ranking sends thousands.
    'ids': [for (final t in targets) t.id],
    'raDeg': [for (final t in targets) t.raDeg],
    'decDeg': [for (final t in targets) t.decDeg],
    'weights': _weights(weights),
  };

  static ({
    ApiNightSky sky,
    List<ApiNightTarget> targets,
    ApiScoringWeights weights,
  })
  readNightRequest(Map<String, dynamic> json) {
    final ids = _list<String>(json, 'ids');
    final ra = _list<num>(json, 'raDeg');
    final dec = _list<num>(json, 'decDeg');
    if (ra.length != ids.length || dec.length != ids.length) {
      throw const FormatException('ids, raDeg and decDeg differ in length');
    }
    return (
      sky: ApiNightSky(
        latitudeDeg: _double(json, 'latitudeDeg'),
        longitudeDeg: _double(json, 'longitudeDeg'),
        nowUnixMs: _int(json, 'nowUnixMs'),
        nightStartUnixMs: _int(json, 'nightStartUnixMs'),
        nightEndUnixMs: _int(json, 'nightEndUnixMs'),
        moonRaDeg: _optionalDouble(json, 'moonRaDeg'),
        moonDecDeg: _optionalDouble(json, 'moonDecDeg'),
        moonIlluminationPercent: _double(json, 'moonIlluminationPercent'),
        floor: _readFloor(json),
      ),
      targets: [
        for (var i = 0; i < ids.length; i++)
          ApiNightTarget(
            id: ids[i],
            raDeg: ra[i].toDouble(),
            decDeg: dec[i].toDouble(),
          ),
      ],
      weights: _readWeights(_map(json, 'weights')),
    );
  }

  static List<Map<String, Object?>> nightResponse(List<ApiNightScore> scores) =>
      [
        for (final s in scores)
          {
            'targetId': s.targetId,
            'totalScore': s.totalScore,
            'altitudeScore': s.altitudeScore,
            'moonDistanceScore': s.moonDistanceScore,
            'transitProximityScore': s.transitProximityScore,
            'darknessScore': s.darknessScore,
            'airmassScore': s.airmassScore,
            'currentAltitudeDeg': s.currentAltitudeDeg,
            'currentAzimuthDeg': s.currentAzimuthDeg,
            'peakAltitudeDeg': s.peakAltitudeDeg,
            'peakAzimuthDeg': s.peakAzimuthDeg,
            'peakUnixMs': s.peakUnixMs,
            'hoursAboveFloor': s.hoursAboveFloor,
            'firstUsableUnixMs': s.firstUsableUnixMs,
            'bestAirmass': s.bestAirmass,
            'moonDistanceDeg': s.moonDistanceDeg,
          },
      ];

  static List<ApiNightScore> readNightResponse(List<dynamic> json) => [
    for (final s in json.cast<Map<String, dynamic>>())
      ApiNightScore(
        targetId: _string(s, 'targetId'),
        totalScore: _double(s, 'totalScore'),
        altitudeScore: _double(s, 'altitudeScore'),
        moonDistanceScore: _double(s, 'moonDistanceScore'),
        transitProximityScore: _double(s, 'transitProximityScore'),
        darknessScore: _double(s, 'darknessScore'),
        airmassScore: _double(s, 'airmassScore'),
        currentAltitudeDeg: _double(s, 'currentAltitudeDeg'),
        currentAzimuthDeg: _double(s, 'currentAzimuthDeg'),
        peakAltitudeDeg: _double(s, 'peakAltitudeDeg'),
        peakAzimuthDeg: _double(s, 'peakAzimuthDeg'),
        peakUnixMs: _int(s, 'peakUnixMs'),
        hoursAboveFloor: _double(s, 'hoursAboveFloor'),
        firstUsableUnixMs: _optionalInt(s, 'firstUsableUnixMs'),
        bestAirmass: _optionalDouble(s, 'bestAirmass'),
        moonDistanceDeg: _double(s, 'moonDistanceDeg'),
      ),
  ];

  static Map<String, Object?> _weights(ApiScoringWeights w) => {
    'altitude': w.altitude,
    'moonDistance': w.moonDistance,
    'transitProximity': w.transitProximity,
    'darkness': w.darkness,
    'airmass': w.airmass,
    'minMoonSeparationDeg': w.minMoonSeparationDeg,
  };

  static ApiScoringWeights _readWeights(Map<String, dynamic> json) =>
      ApiScoringWeights(
        altitude: _double(json, 'altitude'),
        moonDistance: _double(json, 'moonDistance'),
        transitProximity: _double(json, 'transitProximity'),
        darkness: _double(json, 'darkness'),
        airmass: _double(json, 'airmass'),
        minMoonSeparationDeg: _optionalDouble(json, 'minMoonSeparationDeg'),
      );

  static List<List<double>> _floor(List<ApiFloorSample> floor) => [
    for (final s in floor) [s.azimuthDeg, s.altitudeDeg],
  ];

  static List<ApiFloorSample> _readFloor(Map<String, dynamic> json) => [
    for (final pair in _list<List<dynamic>>(json, 'floor'))
      if (pair case [final num az, final num alt])
        ApiFloorSample(azimuthDeg: az.toDouble(), altitudeDeg: alt.toDouble())
      else
        throw const FormatException('a floor sample is [azimuth, altitude]'),
  ];

  static double _double(Map<String, dynamic> json, String key) =>
      _optionalDouble(json, key) ??
      (throw FormatException('"$key" must be a number'));

  static double? _optionalDouble(Map<String, dynamic> json, String key) =>
      switch (json[key]) {
        null => null,
        final num n => n.toDouble(),
        _ => throw FormatException('"$key" must be a number'),
      };

  static int _int(Map<String, dynamic> json, String key) =>
      _optionalInt(json, key) ??
      (throw FormatException('"$key" must be a whole number'));

  static int? _optionalInt(Map<String, dynamic> json, String key) =>
      switch (json[key]) {
        null => null,
        final int n => n,
        _ => throw FormatException('"$key" must be a whole number'),
      };

  static String _string(Map<String, dynamic> json, String key) =>
      switch (json[key]) {
        final String s => s,
        _ => throw FormatException('"$key" must be text'),
      };

  static Map<String, dynamic> _map(Map<String, dynamic> json, String key) =>
      switch (json[key]) {
        final Map<String, dynamic> m => m,
        _ => throw FormatException('"$key" must be an object'),
      };

  static List<T> _list<T>(Map<String, dynamic> json, String key) =>
      switch (json[key]) {
        final List<dynamic> l => l.cast<T>(),
        _ => throw FormatException('"$key" must be a list'),
      };
}
