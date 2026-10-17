import 'package:skotiq_core/skotiq_core.dart';

/// Parse a device-type string (case-insensitive) into [DeviceType], or
/// null if no match. Mirrors the wire-format convention used by the
/// connect-device handler.
DeviceType? parseDeviceType(String value) {
  final normalized = value.toLowerCase();
  for (final dt in DeviceType.values) {
    final name = dt.name.toLowerCase();
    // The trailing underscore is a Dart artefact, not part of the vocabulary:
    // `DeviceType.switch_` is spelled that way only because `switch` is a
    // reserved word. No client guesses `switch_`, and one that sends the
    // obvious `switch` was being told the rig had no switches at all.
    if (name == normalized || name == '${normalized}_') {
      return dt;
    }
  }
  return null;
}

/// Pipe-separated list of valid device-type names, suitable for
/// embedding in a [BadRequestError.expected] field.
String validDeviceTypeList() => DeviceType.values.map((d) => d.name).join('|');
