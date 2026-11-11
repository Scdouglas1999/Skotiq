/// File and disk sizes as text.
library;

abstract final class ByteFormat {
  static const List<String> _units = <String>['B', 'KiB', 'MiB', 'GiB', 'TiB'];

  /// `512 B`, `1.5 KiB`, `38.4 MiB`, `256 GiB`, `1.8 TiB`.
  ///
  /// Units step by 1024, so the numbers match what Windows reports for the
  /// rig's disks, and carry the binary names that say so: a 1024-step value
  /// labeled "GB" is 7% off what the label claims.
  /// One decimal below 100 of a unit, none from 100 up, so the text keeps
  /// about three significant digits at every size. A negative size reads
  /// `0 B`.
  static String size(int bytes) {
    if (bytes <= 0) return '0 B';
    var value = bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < _units.length - 1) {
      value /= 1024;
      unit++;
    }
    // 1023.96 KB would print as "1024 KB"; show it in the next unit instead.
    if (unit > 0 && unit < _units.length - 1 && value >= 999.5) {
      value /= 1024;
      unit++;
    }
    final digits = unit == 0 || value >= 99.95 ? 0 : 1;
    return '${value.toStringAsFixed(digits)} ${_units[unit]}';
  }
}
