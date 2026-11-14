/// Angles that are not sexagesimal coordinates: altitude, azimuth, field of
/// view, separations, errors in arcseconds, site latitude and longitude.
library;

abstract final class AngleFormat {
  /// `45.1°`. Used for altitude, azimuth, rotation and field of view.
  static String degrees(double value, {int decimals = 1}) =>
      '${value.toStringAsFixed(decimals)}°';

  /// An angle given in arcseconds, in the unit that reads best at its size:
  /// `4.2"`, `240"`, `1.3°`.
  static String arcsec(double arcsec) {
    final magnitude = arcsec.abs();
    if (magnitude < 100) return '${arcsec.toStringAsFixed(1)}"';
    if (magnitude < 3600) return '${arcsec.round()}"';
    return '${(arcsec / 3600).toStringAsFixed(1)}°';
  }

  /// An angle given in degrees, in the unit that reads best at its size:
  /// `2.50°`, `12.3'`, `45.0"`.
  static String adaptive(double degrees) {
    final magnitude = degrees.abs();
    if (magnitude >= 1) return '${degrees.toStringAsFixed(2)}°';
    final arcmin = degrees * 60;
    if (arcmin.abs() >= 1) return "${arcmin.toStringAsFixed(1)}'";
    return '${(degrees * 3600).toStringAsFixed(1)}"';
  }

  /// `40.1234° N` / `33.8700° S`. The hemisphere is spelled out because a bare
  /// signed number is where a north/south mix-up hides.
  static String latitude(double degrees, {int decimals = 4}) =>
      '${degrees.abs().toStringAsFixed(decimals)}° ${degrees < 0 ? 'S' : 'N'}';

  /// `74.0060° W` / `2.3500° E`.
  static String longitude(double degrees, {int decimals = 4}) =>
      '${degrees.abs().toStringAsFixed(decimals)}° ${degrees < 0 ? 'W' : 'E'}';

  static const List<String> _compass16 = <String>[
    'N', 'NNE', 'NE', 'ENE', 'E', 'ESE', 'SE', 'SSE',
    'S', 'SSW', 'SW', 'WSW', 'W', 'WNW', 'NW', 'NNW', //
  ];

  /// The compass point nearest [degrees] (0 = north, 90 = east), on a rose of
  /// [points] (8 or 16): `NNE`, `SW`.
  static String compass(double degrees, {int points = 16}) {
    assert(points == 8 || points == 16);
    final step = 16 ~/ points;
    final sector = 360 / points;
    final index = (((degrees % 360) + sector / 2) / sector).floor() % points;
    return _compass16[index * step];
  }
}
