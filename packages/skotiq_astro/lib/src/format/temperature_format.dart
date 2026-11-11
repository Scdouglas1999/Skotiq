/// One formatter for every Celsius readout in the app.
///
/// Why this exists: the equipment cards emitted two different unit formats for
/// the same physical quantity, side by side in one screenshot — the camera read
/// `Sensor Temp 20.0C` and its cooling button read `Cool to -10C`, while the
/// weather card two cards away read `10.0°C` / `-1.5°C` and the dashboard rail
/// rendered the SAME camera value as `20.0°C`. Ad-hoc `'${x.toStringAsFixed(1)}C'`
/// string interpolation is how that drifted; routing every site through here is
/// how it stops drifting again.
library;

/// The degree-Celsius unit suffix. Exposed so callers that must build a
/// composite label (`'Cool to …'`) still use the one canonical string.
const String celsiusSuffix = '°C';

/// Formats [value] as e.g. `-10.5°C`.
///
/// Returns [placeholder] when [value] is null or non-finite: an unread sensor
/// must render as "unknown", never as `0.0°C`, because an operator reading a
/// fabricated zero would act on it.
String formatCelsius(
  double? value, {
  int decimals = 1,
  String placeholder = '---',
}) {
  if (value == null || !value.isFinite) return placeholder;
  return '${value.toStringAsFixed(decimals)}$celsiusSuffix';
}
