part of '../transient_alert_provider.dart';

/// Parse a TransientAlert from JSON response
List<TransientAlert> _mergeAlerts(
  List<TransientAlert> local,
  List<TransientAlert> external,
) {
  final seen = <String>{};
  return <TransientAlert>[
    for (final alert in [...local, ...external])
      if (alert.id.trim().isNotEmpty && seen.add(alert.id)) alert,
  ];
}

/// Parses one alert received from a remote imaging host. The caller rejects
/// the entire malformed response so corrupt host data cannot masquerade as a
/// trustworthy empty or partial feed.
TransientAlert? _tryParseTransientAlertFromJson(Map<String, dynamic> json) {
  final id = json['id'];
  final name = json['name'];
  final ra = json['raHours'];
  final dec = json['decDegrees'];
  final discoveryMillis = json['discoveryTime'];
  final updatedMillis = json['lastUpdated'];
  if (id is! String ||
      id.trim().isEmpty ||
      name is! String ||
      name.trim().isEmpty ||
      ra is! num ||
      dec is! num ||
      discoveryMillis is! num ||
      updatedMillis is! num) {
    return null;
  }
  final raHours = ra.toDouble();
  final decDegrees = dec.toDouble();
  final magnitude = _finiteJsonDouble(json['magnitude']);
  final peakMagnitude = _finiteJsonDouble(json['peakMagnitude']);
  if (!raHours.isFinite ||
      raHours < 0 ||
      raHours >= 24 ||
      !decDegrees.isFinite ||
      decDegrees < -90 ||
      decDegrees > 90 ||
      (json['magnitude'] != null && magnitude == null) ||
      (json['peakMagnitude'] != null && peakMagnitude == null)) {
    return null;
  }
  final discoveryEpoch = discoveryMillis.toDouble();
  final updatedEpoch = updatedMillis.toDouble();
  const maxDateTimeEpoch = 8640000000000000.0;
  if (!discoveryEpoch.isFinite ||
      discoveryEpoch.abs() > maxDateTimeEpoch ||
      !updatedEpoch.isFinite ||
      updatedEpoch.abs() > maxDateTimeEpoch) {
    return null;
  }

  TransientSource? source;
  for (final candidate in TransientSource.values) {
    if (candidate.name == json['source']) {
      source = candidate;
      break;
    }
  }
  if (source == null) return null;

  TransientType? type;
  for (final candidate in TransientType.values) {
    if (candidate.name == json['type']) {
      type = candidate;
      break;
    }
  }
  if (type == null) return null;

  final priorityValue = json['priority'];
  if (priorityValue is! num ||
      !priorityValue.isFinite ||
      priorityValue != priorityValue.round() ||
      priorityValue < 1 ||
      priorityValue > 10 ||
      (json['sourceUrl'] != null && json['sourceUrl'] is! String) ||
      (json['classification'] != null && json['classification'] is! String) ||
      (json['notes'] != null && json['notes'] is! String)) {
    return null;
  }
  return TransientAlert(
    id: id,
    name: name,
    type: type,
    raHours: raHours,
    decDegrees: decDegrees,
    magnitude: magnitude,
    peakMagnitude: peakMagnitude,
    discoveryTime: DateTime.fromMillisecondsSinceEpoch(discoveryEpoch.round()),
    lastUpdated: DateTime.fromMillisecondsSinceEpoch(updatedEpoch.round()),
    source: source,
    sourceUrl: json['sourceUrl'] is String ? json['sourceUrl'] as String : null,
    priority: priorityValue.toInt(),
    classification: json['classification'] is String
        ? json['classification'] as String
        : null,
    notes: json['notes'] is String ? json['notes'] as String : null,
  );
}

double? _finiteJsonDouble(Object? value) {
  if (value is! num) return null;
  final converted = value.toDouble();
  return converted.isFinite ? converted : null;
}
