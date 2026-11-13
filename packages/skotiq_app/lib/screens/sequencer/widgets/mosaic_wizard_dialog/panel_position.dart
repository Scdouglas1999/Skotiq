part of '../mosaic_wizard_dialog.dart';

/// A panel on the wizard's planner, and whether the operator kept it.
class _PanelPosition {
  final MosaicPanel panel;
  final bool enabled;

  const _PanelPosition(this.panel, {required this.enabled});

  double get ra => panel.raHours;
  double get dec => panel.decDegrees;
  int get index => panel.index;
  int get row => panel.row;
  int get col => panel.col;
}
