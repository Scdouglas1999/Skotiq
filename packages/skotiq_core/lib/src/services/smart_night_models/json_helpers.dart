part of '../smart_night_models.dart';

Map<String, dynamic> _darkRequirementToJson(DarkFrameRequirement req) => {
  'gain': req.gain,
  'offset': req.offset,
  'durationSecs': req.durationSecs,
  'binX': req.binX,
  'binY': req.binY,
  'targetTemp': req.targetTemp,
};

List<DarkFrameRequirement> _darkRequirementsFromJson(Object? raw) {
  if (raw is! List) return const [];
  final out = <DarkFrameRequirement>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final m = entry.cast<String, dynamic>();
    final gain = _jsonInt(m['gain'], 0);
    final offset = _jsonInt(m['offset'], 0);
    final durationSecs = _jsonDouble(m['durationSecs'], 0.0);
    final binX = _jsonInt(m['binX'], 1);
    final binY = _jsonInt(m['binY'], 1);
    final temp = m['targetTemp'];
    final targetTemp = temp is num ? temp.toDouble() : null;
    if (durationSecs <= 0) continue;
    out.add(
      DarkFrameRequirement(
        gain: gain,
        offset: offset,
        durationSecs: durationSecs,
        binX: binX,
        binY: binY,
        targetTemp: targetTemp,
      ),
    );
  }
  return List.unmodifiable(out);
}

Map<String, dynamic>? _recommendationToJson(ExposureRecommendation? value) {
  if (value == null) return null;
  return {
    'seconds': value.seconds,
    'limitingFactor': value.limitingFactor.name,
    'allCeilings': value.allCeilings.map((k, v) => MapEntry(k.name, v)),
    'rationale': value.rationale,
    'caveats': value.caveats,
  };
}

ExposureRecommendation? _recommendationFromJson(Object? raw) {
  if (raw == null) return null;
  final json = (raw as Map).cast<String, dynamic>();
  final ceilingsRaw =
      (json['allCeilings'] as Map?)?.cast<String, dynamic>() ?? const {};
  final ceilings = <ExposureLimitingFactor, double>{
    for (final entry in ceilingsRaw.entries)
      _enumByName(
        ExposureLimitingFactor.values,
        entry.key,
        ExposureLimitingFactor.glover,
      ): (entry.value as num)
          .toDouble(),
  };
  return ExposureRecommendation(
    seconds: _jsonDouble(json['seconds'], 0.0),
    limitingFactor: _enumByName(
      ExposureLimitingFactor.values,
      json['limitingFactor'],
      ExposureLimitingFactor.glover,
    ),
    allCeilings: Map.unmodifiable(ceilings),
    rationale: json['rationale'] as String? ?? '',
    caveats: List.unmodifiable(_stringList(json['caveats'])),
  );
}

T _enumByName<T extends Enum>(List<T> values, Object? raw, T fallback) {
  final name = raw as String?;
  if (name == null) return fallback;
  for (final value in values) {
    if (value.name == name) return value;
  }
  return fallback;
}

double _jsonDouble(Object? raw, double fallback) =>
    raw is num ? raw.toDouble() : fallback;

int _jsonInt(Object? raw, int fallback) => raw is num ? raw.toInt() : fallback;

List<String> _stringList(Object? raw) {
  if (raw is! List) return const [];
  return raw.whereType<String>().toList(growable: false);
}

Map<String, double> _stringDoubleMap(Object? raw) {
  if (raw is! Map) {
    return const SmartNightSettings().defaultFrameDurationSecs;
  }
  return raw.map(
    (key, value) =>
        MapEntry(key.toString(), value is num ? value.toDouble() : 0.0),
  );
}
