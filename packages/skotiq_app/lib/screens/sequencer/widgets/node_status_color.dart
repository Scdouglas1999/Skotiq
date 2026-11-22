import 'package:flutter/material.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// What a step's run STATUS says and the one color it may paint, wherever a
/// step shows it: the tree row, the ledger and the target header.
enum NodeStatusPresentation {
  running('Running'),
  completed('Completed'),
  failed('Failed'),
  skipped('Skipped'),
  stopped('Stopped');

  const NodeStatusPresentation(this.word);

  final String word;

  /// Null for pending: a step that has not run has no status to report.
  static NodeStatusPresentation? of(NodeStatus? status) => switch (status) {
        NodeStatus.running => running,
        NodeStatus.success => completed,
        NodeStatus.failure => failed,
        NodeStatus.skipped => skipped,
        NodeStatus.cancelled => stopped,
        NodeStatus.pending || null => null,
      };

  Color color(SkotiqColors colors) => switch (this) {
        running => colors.info,
        completed => colors.success,
        failed => colors.error,
        skipped => colors.textMuted,
        stopped => colors.warning,
      };
}

/// The color a run [status] paints on a row; transparent for pending, so the
/// row does not imply a status it does not have.
Color nodeStatusColor(NodeStatus? status, SkotiqColors colors) =>
    NodeStatusPresentation.of(status)?.color(colors) ?? Colors.transparent;
