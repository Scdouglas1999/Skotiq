import 'package:flutter/material.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The one colour a run STATUS is allowed to paint on a row.
///
/// Transparent for pending / unknown: a step that has not run has no status to
/// report, and the row must not imply one.
Color nodeStatusColor(NodeStatus? status, SkotiqColors colors) {
  switch (status) {
    case NodeStatus.running:
      return colors.info;
    case NodeStatus.success:
      return colors.success;
    case NodeStatus.failure:
      return colors.error;
    case NodeStatus.skipped:
      return colors.textMuted;
    case NodeStatus.cancelled:
      return colors.warning;
    default:
      return Colors.transparent;
  }
}
