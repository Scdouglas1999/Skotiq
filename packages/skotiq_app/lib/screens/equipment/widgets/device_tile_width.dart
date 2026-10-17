import 'package:flutter/widgets.dart';

/// The width of the grid cell a device panel is being laid out in.
///
/// The panel needs its own width to decide whether a readout row fits at 20 px
/// and how many action buttons stay inline — but it CANNOT ask a
/// [LayoutBuilder] for it. The grid puts its rows in an [IntrinsicHeight] so
/// the panels in one row share a height, and `LayoutBuilder` has no intrinsic
/// dimensions: measured live, a card whose readout row and action row were
/// both `LayoutBuilder`s reported an intrinsic height covering only its header,
/// so `IntrinsicHeight` sized the row to that and the actions painted OUTSIDE
/// the panel, over the empty slot below it.
///
/// The grid already computes the cell width, so it simply hands it down. A
/// panel mounted without one (a widget test, a bottom sheet) falls back to the
/// roomy defaults.
class DeviceTileWidth extends InheritedWidget {
  const DeviceTileWidth({
    super.key,
    required this.width,
    required super.child,
  });

  /// The cell's width in logical pixels.
  final double width;

  /// What a panel assumes when nothing told it: the narrowest cell the grid
  /// ever hands out. Assuming INFINITE width instead let a panel mounted on
  /// its own (a widget test, a bottom sheet) keep two full-width buttons
  /// inline and overflow a 320 px box.
  static const double fallbackWidth = 300.0;

  /// The cell width in scope, or [fallbackWidth] when the panel is not inside
  /// a grid.
  static double of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DeviceTileWidth>()?.width ??
      fallbackWidth;

  @override
  bool updateShouldNotify(DeviceTileWidth oldWidget) =>
      oldWidget.width != width;
}
