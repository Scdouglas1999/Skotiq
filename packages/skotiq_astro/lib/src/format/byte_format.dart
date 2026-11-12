/// File and disk sizes as text.
library;

/// A family of size units: how far apart they step and what they are called.
enum ByteUnits {
  /// Steps of 1024, the numbers Windows reports for a disk, under the names
  /// that say so: a 1024-step value labeled "GB" is 7% off what the label
  /// claims.
  binary(1024, <String>['B', 'KiB', 'MiB', 'GiB', 'TiB']),

  /// Steps of 1000, the numbers on a drive's box and in macOS and Linux file
  /// managers.
  decimal(1000, <String>['B', 'kB', 'MB', 'GB', 'TB']);

  const ByteUnits(this.step, this.names);

  final int step;
  final List<String> names;
}

abstract final class ByteFormat {
  /// The unit family every size in the app is shown in. Changing this one
  /// line changes all of them, and the size of a limit a person enters as a
  /// number of gigabytes ([bytesPerGiga]).
  static const ByteUnits units = ByteUnits.binary;

  /// `512 B`, `1.5 KiB`, `38.4 MiB`, `256 GiB`, `1.8 TiB` (in [units]).
  ///
  /// One decimal below 100 of a unit, none from 100 up, so the text keeps
  /// about three significant digits at every size. A negative size reads
  /// `0 B`.
  static String size(int bytes) {
    if (bytes <= 0) return '0 B';
    final step = units.step;
    final names = units.names;
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= step && unit < names.length - 1) {
      value /= step;
      unit++;
    }
    // 1023.96 of a unit would print as "1024"; show it in the next unit.
    if (unit > 0 && unit < names.length - 1 && value >= 999.5) {
      value /= step;
      unit++;
    }
    final digits = unit == 0 || value >= 99.95 ? 0 : 1;
    return '${value.toStringAsFixed(digits)} ${names[unit]}';
  }

  /// The name of the megabyte-sized unit, for text about a rough amount
  /// ("about 60 MiB").
  static String get megaUnit => units.names[2];

  /// The name of the gigabyte-sized unit, for text about a rough amount or a
  /// field a person fills in as a number of gigabytes.
  static String get gigaUnit => units.names[3];

  static int get bytesPerMega => units.step * units.step;

  /// Bytes in one of [gigaUnit]: what "25" means in a limit entered in
  /// gigabytes, so the text can show the limit as the number entered.
  static int get bytesPerGiga => units.step * units.step * units.step;
}
