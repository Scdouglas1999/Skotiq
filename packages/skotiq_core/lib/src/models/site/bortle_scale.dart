/// Bortle scale descriptions and limiting magnitudes
class BortleScale {
  static const Map<int, String> descriptions = {
    1: 'Excellent dark-sky site',
    2: 'Typical truly dark site',
    3: 'Rural sky',
    4: 'Rural/suburban transition',
    5: 'Suburban sky',
    6: 'Bright suburban sky',
    7: 'Suburban/urban transition',
    8: 'City sky',
    9: 'Inner-city sky',
  };

  static const Map<int, double> limitingMagnitudes = {
    1: 7.6,
    2: 7.1,
    3: 6.6,
    4: 6.2,
    5: 5.9,
    6: 5.5,
    7: 5.0,
    8: 4.5,
    9: 4.0,
  };

  /// Get limiting magnitude for a Bortle class (1-9)
  static double limitingMagnitude(int bortleClass) {
    return limitingMagnitudes[bortleClass.clamp(1, 9)] ?? 5.9;
  }

  /// Get description for a Bortle class (1-9)
  static String description(int bortleClass) {
    return descriptions[bortleClass.clamp(1, 9)] ?? 'Unknown';
  }
}
