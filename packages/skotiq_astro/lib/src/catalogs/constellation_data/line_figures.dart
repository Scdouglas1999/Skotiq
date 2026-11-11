part of '../constellation_data.dart';

/// All constellation line data
class Constellations {
  static List<ConstellationData> get all => _constellations;

  static ConstellationData? findByAbbreviation(String abbr) {
    return _constellations
        .where((c) => c.abbreviation.toLowerCase() == abbr.toLowerCase())
        .firstOrNull;
  }

  static ConstellationData? findByName(String name) {
    return _constellations
        .where((c) => c.name.toLowerCase() == name.toLowerCase())
        .firstOrNull;
  }

  // Major constellations with stick figure lines
  static final List<ConstellationData> _constellations = [
    ..._lineFigureSet01,
    ..._lineFigureSet02,
    ..._lineFigureSet03,
    ..._lineFigureSet04,
  ];
}
