import '../coordinate_system.dart';

part 'constellation_data/line_figures.dart';
part 'constellation_data/line_figure_sets/figures_01.dart';
part 'constellation_data/line_figure_sets/figures_02.dart';
part 'constellation_data/line_figure_sets/figures_03.dart';
part 'constellation_data/line_figure_sets/figures_04.dart';
part 'constellation_data/boundaries.dart';

/// Constellation data with lines and boundaries
class ConstellationData {
  final String abbreviation;
  final String name;
  final List<ConstellationLine> lines;
  final CelestialCoordinate center;

  const ConstellationData({
    required this.abbreviation,
    required this.name,
    required this.lines,
    required this.center,
  });
}

/// A line segment between two stars in a constellation
class ConstellationLine {
  final CelestialCoordinate start;
  final CelestialCoordinate end;
  final String? startStarName;
  final String? endStarName;

  const ConstellationLine({
    required this.start,
    required this.end,
    this.startStarName,
    this.endStarName,
  });
}
