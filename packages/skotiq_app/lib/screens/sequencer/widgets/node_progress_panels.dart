import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/snackbar_helper.dart';

part 'node_progress_panels/cooling_progress_panel.dart';
part 'node_progress_panels/autofocus_progress_panel.dart';
part 'node_progress_panels/autofocus_visuals.dart';
part 'node_progress_panels/stat_box.dart';
part 'node_progress_panels/exposure_progress_panel.dart';
part 'node_progress_panels/other_progress_panels.dart';
part 'node_progress_panels/animated_progress_bar.dart';
part 'node_progress_panels/last_known_node_progress.dart';

/// Factory that returns the appropriate progress panel widget for a node type
Widget getProgressPanelForNode({
  required SequenceNode node,
  required SkotiqColors colors,
  required double progressPercent,
  required String? progressDetail,
  InstructionProgressDetail? structuredProgressDetail,
  NodeStatus? nodeStatus,
  String? runFilter,
  NodeExposureTally? exposureTally,
}) {
  // Parse progress detail to extract relevant info
  final detail = progressDetail ?? '';

  if (node is CoolCameraNode || node is WarmCameraNode) {
    return _CoolingProgressPanel(
      colors: colors,
      progressPercent: progressPercent,
      detail: detail,
      isWarming: node is WarmCameraNode,
    );
  }

  if (node is AutofocusNode) {
    return _AutofocusProgressPanel(
      colors: colors,
      progressPercent: progressPercent,
      detail: detail,
    );
  }

  if (node is ExposureNode) {
    return _ExposureProgressPanel(
      colors: colors,
      progressPercent: progressPercent,
      detail: detail,
      structuredDetail: structuredProgressDetail,
      node: node,
      isComplete: nodeStatus == NodeStatus.success,
      isRunning: nodeStatus == NodeStatus.running,
      runFilter: runFilter,
      tally: exposureTally,
    );
  }

  if (node is SlewNode || node is CenterNode) {
    return _SlewProgressPanel(
      colors: colors,
      progressPercent: progressPercent,
      detail: detail,
      isCentering: node is CenterNode,
    );
  }

  if (node is FilterChangeNode) {
    return _FilterProgressPanel(
      colors: colors,
      progressPercent: progressPercent,
      detail: detail,
    );
  }

  // Default panel for other node types
  return _DefaultProgressPanel(
    colors: colors,
    progressPercent: progressPercent,
    detail: detail,
  );
}
