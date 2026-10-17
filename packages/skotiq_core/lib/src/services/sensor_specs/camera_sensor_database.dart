import 'camera_sensor_entry.dart';
import 'curated_camera_sensors.dart';

/// Looks a driver-reported camera model up in the curated sensor database.
///
/// Matching is deliberately unforgiving. A wrong pixel size silently rescales
/// every image-scale, field-of-view and mosaic figure in the app, and the
/// astronomy camera market is full of model names that differ by one or two
/// characters and by a third of their pixel pitch — ASI2400MC Pro (5.94 um)
/// against ASI2600MC Pro (3.76 um), ASI585MC against ASI533MC, QHY600M
/// against QHY600C. An edit-distance matcher picks whichever of those happens
/// to be in the table and says nothing. So a model either matches a name a row
/// explicitly claims, or it is a miss, and a miss is reported as a miss.
///
/// The only liberties taken with a driver string are ones that cannot change
/// which row wins, because every candidate still has to hit a row's own name
/// exactly:
///
///  * case, spaces, hyphens, underscores and dots are normalised away, so
///    "ASI1600MM-Cool", "asi1600mm cool" and "ASI1600MM_COOL" are one name;
///  * a leading vendor token is dropped ("ZWO ASI533MC Pro" → "ASI533MC Pro"),
///    because ASCOM drivers prepend the brand and the brand is not part of
///    the model;
///  * a trailing serial number is dropped ("QHY268M-6c1d4a8e9f01" →
///    "QHY268M"), because the QHY driver appends the camera's serial to its
///    model string. A tail only counts as a serial if it is at least six
///    characters and contains a digit, which is why "-Cool" and "-PH" survive.
class CameraSensorDatabase {
  CameraSensorDatabase({
    List<CameraSensorEntry> entries = kCuratedCameraSensors,
  }) : _entries = entries,
       _byName = _buildIndex(entries);

  /// The curated database. Const-friendly for callers that just want a lookup.
  static final CameraSensorDatabase curated = CameraSensorDatabase();

  final List<CameraSensorEntry> _entries;
  final Map<String, CameraSensorEntry> _byName;

  /// Every row, in declaration order.
  List<CameraSensorEntry> get entries => List.unmodifiable(_entries);

  static Map<String, CameraSensorEntry> _buildIndex(
    List<CameraSensorEntry> entries,
  ) {
    final index = <String, CameraSensorEntry>{};
    for (final entry in entries) {
      for (final name in entry.driverNames) {
        final key = normalize(name);
        final clash = index[key];
        if (clash != null && clash != entry) {
          // Two rows claiming one name would make the lookup order-dependent
          // and the answer arbitrary. That is a data error, not a runtime
          // condition to degrade around.
          throw StateError(
            'Camera sensor database: "$name" is claimed by both '
            '"${clash.model}" and "${entry.model}".',
          );
        }
        index[key] = entry;
      }
    }
    return index;
  }

  /// Strips case and separators. Nothing semantic is removed, so two different
  /// models can never normalise to the same key.
  static String normalize(String value) =>
      value.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '');

  /// Vendor names an ASCOM or native driver may prepend to the model.
  static const _vendorPrefixes = [
    'zwoptical',
    'zwo',
    'qhyccd',
    'canon',
    'nikon',
  ];

  /// The row for [driverModel], or null when no row claims that name.
  ///
  /// Never returns a row for a name it is merely similar to.
  CameraSensorEntry? lookup(String? driverModel) {
    if (driverModel == null) return null;
    for (final candidate in _candidateKeys(driverModel)) {
      final hit = _byName[candidate];
      if (hit != null) return hit;
    }
    return null;
  }

  /// The first row matched by any of [driverModels], in the order given.
  ///
  /// Callers pass the friendly camera name before the device id, because the
  /// device id is often an ASCOM ProgID that names a driver rather than a
  /// camera.
  CameraSensorEntry? lookupAny(Iterable<String?> driverModels) {
    for (final model in driverModels) {
      final hit = lookup(model);
      if (hit != null) return hit;
    }
    return null;
  }

  /// The keys to try, most literal first.
  Iterable<String> _candidateKeys(String driverModel) {
    final keys = <String>[];
    void add(String? key) {
      if (key != null && key.isNotEmpty && !keys.contains(key)) keys.add(key);
    }

    final serialStripped = _stripTrailingSerial(driverModel);
    for (final form in {driverModel, serialStripped}) {
      final normalized = normalize(form);
      add(normalized);
      add(_stripVendorPrefix(normalized));
    }
    return keys;
  }

  static String? _stripVendorPrefix(String normalized) {
    for (final vendor in _vendorPrefixes) {
      if (normalized.length > vendor.length && normalized.startsWith(vendor)) {
        return normalized.substring(vendor.length);
      }
    }
    return null;
  }

  /// Drops a trailing `-<serial>` segment, as the QHY driver appends.
  ///
  /// A segment counts as a serial only if it is at least [_minSerialLength]
  /// characters and contains a digit, so model suffixes the manufacturer
  /// actually uses — "-Cool", "-PH", "-Pro" — are left alone.
  static const int _minSerialLength = 6;

  static String _stripTrailingSerial(String value) {
    final cut = value.lastIndexOf('-');
    if (cut <= 0) return value;
    final tail = value.substring(cut + 1);
    if (tail.length < _minSerialLength) return value;
    if (!RegExp(r'^[A-Za-z0-9]+$').hasMatch(tail)) return value;
    if (!tail.contains(RegExp('[0-9]'))) return value;
    return value.substring(0, cut);
  }
}
