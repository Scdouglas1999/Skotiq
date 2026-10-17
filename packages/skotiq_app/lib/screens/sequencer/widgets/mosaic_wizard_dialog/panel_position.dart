part of '../mosaic_wizard_dialog.dart';

class _PanelPosition {
  final double ra;
  final double dec;
  final int index;
  final int row;
  final int col;
  final bool enabled;

  _PanelPosition({
    required this.ra,
    required this.dec,
    required this.index,
    required this.row,
    required this.col,
    required this.enabled,
  });
}
