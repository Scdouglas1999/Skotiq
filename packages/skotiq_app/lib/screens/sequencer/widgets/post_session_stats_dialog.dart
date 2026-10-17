import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../run_status_presentation.dart';

/// Dialog showing detailed post-session statistics for a sequence run.
class PostSessionStatsDialog extends StatelessWidget {
  final SkotiqColors colors;
  final String sequenceName;
  final DateTime startedAt;
  final DateTime? endedAt;
  final String status;
  final ParsedRunStats stats;

  const PostSessionStatsDialog({
    super.key,
    required this.colors,
    required this.sequenceName,
    required this.startedAt,
    this.endedAt,
    required this.status,
    required this.stats,
  });

  @override
  Widget build(BuildContext context) {
    final dateFormat = DateFormat('MMM d, yyyy HH:mm:ss');
    return SkotiqDialog(
      title: 'Session summary',
      icon: LucideIcons.barChart3,
      width: SkotiqDialog.widthForm,
      actions: [
        SkotiqButton(
            label: 'Close',
            variant: ButtonVariant.ghost,
            onPressed: () => Navigator.of(context).pop()),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(sequenceName,
              style: SkotiqTypography.bodyStrong
                  .copyWith(color: colors.textPrimary)),
          const SizedBox(height: SkotiqTokens.spaceLg),
          // Time info
          _Section(
            colors: colors,
            title: 'Timing',
            icon: LucideIcons.clock,
            children: [
              _StatRow(
                  colors: colors,
                  label: 'Started',
                  value: dateFormat.format(startedAt)),
              if (endedAt != null)
                _StatRow(
                    colors: colors,
                    label: 'Ended',
                    value: dateFormat.format(endedAt!)),
              _StatRow(
                  colors: colors,
                  label: 'Wall clock',
                  value: stats.formatDuration(stats.wallClockSecs)),
              _StatRow(
                  colors: colors,
                  label: 'Integration time',
                  value: stats.formatDuration(stats.integrationSecs)),
              _StatRow(
                  colors: colors,
                  label: 'Overhead',
                  value: stats.formatDuration(stats.overheadSecs)),
              if (stats.wallClockSecs > 0)
                _StatRow(
                  colors: colors,
                  label: 'Efficiency',
                  value:
                      '${(stats.integrationSecs / stats.wallClockSecs * 100).toStringAsFixed(1)}%',
                ),
            ],
          ),

          const SizedBox(height: 20),

          // Frames
          _Section(
            colors: colors,
            title: 'Frames',
            icon: LucideIcons.camera,
            children: [
              _StatRow(
                  colors: colors,
                  label: 'Captured',
                  value: '${stats.framesCaptured}'),
              _StatRow(
                  colors: colors,
                  label: 'Rejected',
                  value: '${stats.framesRejected}',
                  valueColor: stats.framesRejected > 0 ? colors.warning : null),
              _StatRow(
                  colors: colors,
                  label: 'Accepted',
                  value: '${stats.framesCaptured - stats.framesRejected}'),
            ],
          ),

          const SizedBox(height: 20),

          // Operations
          _Section(
            colors: colors,
            title: 'Operations',
            icon: LucideIcons.settings,
            children: [
              _StatRow(
                  colors: colors,
                  label: 'Autofocus runs',
                  value: '${stats.autofocusRuns}'),
              _StatRow(
                  colors: colors,
                  label: 'Meridian flips',
                  value: '${stats.meridianFlips}'),
              _StatRow(
                  colors: colors,
                  label: 'Dithers',
                  value: '${stats.ditherCount}'),
              _StatRow(
                  colors: colors,
                  label: 'Trigger fires',
                  value: '${stats.triggerFires}'),
            ],
          ),

          // Target/Filter Breakdown
          if (stats.targetBreakdown.isNotEmpty) ...[
            const SizedBox(height: 20),
            _Section(
              colors: colors,
              title: 'Target breakdown',
              icon: LucideIcons.target,
              children: [
                for (final te in stats.targetBreakdown.entries) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 4),
                    child: Text(
                      te.key,
                      style: SkotiqTypography.labelStrong
                          .copyWith(color: colors.textPrimary),
                    ),
                  ),
                  for (final fe in te.value.entries)
                    _StatRow(
                      colors: colors,
                      label: '  ${fe.key.isEmpty ? 'No filter' : fe.key}',
                      value:
                          '${(fe.value['captured'] as num?)?.toInt() ?? 0} frames  |  '
                          '${stats.formatDuration((fe.value['integrationSecs'] as num?)?.toDouble() ?? 0)}',
                    ),
                ],
              ],
            ),
          ],

          // Errors
          if (stats.errorMessages.isNotEmpty) ...[
            const SizedBox(height: 20),
            _Section(
              colors: colors,
              title: 'Errors (${stats.errorMessages.length})',
              icon: LucideIcons.alertTriangle,
              titleColor: colors.error,
              children: [
                for (final msg in stats.errorMessages)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      runFailureMessage(msg),
                      style: SkotiqTypography.caption.copyWith(
                        color: colors.error,
                      ),
                    ),
                  ),
              ],
            ),
          ],

          if (stats.errorMessages
              .any((message) => runFailureMessage(message) != message))
            ExpansionTile(
              title: const Text('Technical details'),
              children: [SelectableText(stats.errorMessages.join('\n'))],
            ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final SkotiqColors colors;
  final String title;
  final IconData icon;
  final Color? titleColor;
  final List<Widget> children;

  const _Section({
    required this.colors,
    required this.title,
    required this.icon,
    this.titleColor,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(title: title, icon: icon),
        const SizedBox(height: SkotiqTokens.spaceSm),
        ...children,
      ],
    );
  }
}

class _StatRow extends StatelessWidget {
  final SkotiqColors colors;
  final String label;
  final String value;
  final Color? valueColor;

  const _StatRow({
    required this.colors,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceXs),
      child: KeyValueList(rows: [(label, value)]),
    );
  }
}
