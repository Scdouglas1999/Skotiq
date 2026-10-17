import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'equipment_blocker_row.dart';

/// Retained so existing call sites and tests that toggle the old collapsible
/// panel still resolve. The side panel's System health block is always shown;
/// it is three key/value rows, not a section that needs opening.
final equipmentHealthExpandedProvider = StateProvider<bool>((ref) => false);

/// The System health block of the Equipment side panel: a [SectionTitle] with
/// the score chip, a [KeyValueList] of the facts behind it, and one row per
/// outstanding insight.
class EquipmentHealthPanel extends ConsumerWidget {
  const EquipmentHealthPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final reportAsync = ref.watch(equipmentHealthReportProvider);
    final snapshots = ref.watch(deviceHealthSnapshotsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SectionTitle(
          icon: LucideIcons.activity,
          title: 'System health',
          trailing: _scoreChip(reportAsync),
        ),
        reportAsync.when(
          data: (report) => _body(colors, report, snapshots),
          // A score that has not arrived is not a score: the block says so in
          // its own rows rather than spinning a wheel in the side panel.
          loading: () => const KeyValueList(
            rows: [('Score', kReadoutUnknown)],
          ),
          error: (error, _) => EquipmentBlockerRow(
            toneColor: colors.error,
            title: 'Health is unavailable',
            detail: '$error',
            showDivider: false,
          ),
        ),
      ],
    );
  }

  Widget _scoreChip(AsyncValue<EquipmentHealthReport> reportAsync) {
    final report = reportAsync.valueOrNull;
    if (report == null) {
      return const SkotiqChip(label: kReadoutUnknown);
    }
    if (!report.assessed) {
      // No evidence is not evidence of health: a rig with no session history
      // and no connected devices must not be reported as a perfect 100.
      return const SkotiqChip(label: 'Not assessed');
    }
    final score = report.score.round();
    return SkotiqChip(
      label: '$score · ${_grade(report.score)}',
      tone: _tone(report.score),
    );
  }

  Widget _body(
    SkotiqColors colors,
    EquipmentHealthReport report,
    List<DeviceHealthSnapshot> snapshots,
  ) {
    final drops = snapshots.fold<int>(
      0,
      (sum, snapshot) => sum + snapshot.disconnectCountLast24h,
    );
    final healthy = snapshots.where((s) => s.isHealthy).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        KeyValueList(
          rows: [
            (
              'Devices',
              snapshots.isEmpty
                  ? kReadoutUnknown
                  : '${snapshots.length} · $drops ${drops == 1 ? 'drop' : 'drops'}',
            ),
            (
              'Heartbeats',
              snapshots.isEmpty
                  ? kReadoutUnknown
                  : '$healthy of ${snapshots.length} healthy',
            ),
            (
              'Score',
              report.assessed ? '${report.score.round()}' : kReadoutUnknown,
            ),
          ],
        ),
        for (var i = 0; i < report.insights.length; i++)
          EquipmentBlockerRow(
            toneColor: _severityColor(report.insights[i].severity, colors),
            title: report.insights[i].title,
            detail: report.insights[i].message,
            showDivider: i < report.insights.length - 1,
          ),
        // Per-device heartbeats. The summary rows above answer "is the rig
        // healthy"; this answers "which device went quiet", which is the whole
        // point of a heartbeat.
        if (snapshots.isNotEmpty) ...[
          const SizedBox(height: SkotiqTokens.spaceMd),
          KeyValueList(
            rows: [
              for (final snapshot in snapshots)
                (snapshot.displayName, _heartbeatLabel(snapshot)),
            ],
          ),
        ],
      ],
    );
  }

  /// What a device's heartbeat says.
  ///
  /// A snapshot with `lastSuccessfulTimestampMs == 0` has NO timestamp; the
  /// age of epoch zero is 56 years, and rendering it beside a green OK dot made
  /// the one widget whose job is to catch a quiet device untrustworthy on the
  /// happy path. No timestamp reads as unknown.
  static String _heartbeatLabel(DeviceHealthSnapshot snapshot) {
    final state = snapshot.isHealthy ? 'OK' : 'Unhealthy';
    if (snapshot.lastSuccessfulTimestampMs <= 0) {
      return '$state - last contact unknown';
    }
    final age = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(snapshot.lastSuccessfulTimestampMs),
    );
    return '$state - ${_formatAge(age)} ago';
  }

  /// `12s` / `4m` / `2h` / `3d`.
  static String _formatAge(Duration age) {
    if (age.isNegative || age.inSeconds < 1) return '0s';
    if (age.inSeconds < 60) return '${age.inSeconds}s';
    if (age.inMinutes < 60) return '${age.inMinutes}m';
    if (age.inHours < 24) return '${age.inHours}h';
    return '${age.inDays}d';
  }

  static Color _severityColor(
    EquipmentHealthSeverity severity,
    SkotiqColors colors,
  ) {
    return switch (severity) {
      EquipmentHealthSeverity.info => colors.info,
      EquipmentHealthSeverity.warning => colors.warning,
      EquipmentHealthSeverity.critical => colors.error,
    };
  }

  static ChipTone _tone(double score) {
    if (score >= _excellentFloor) return ChipTone.success;
    if (score >= _fairFloor) return ChipTone.warning;
    return ChipTone.error;
  }

  static String _grade(double score) {
    if (score >= _excellentFloor) return 'Excellent';
    if (score >= _goodFloor) return 'Good';
    if (score >= _fairFloor) return 'Fair';
    return 'Poor';
  }
}

/// Score floors for the health grade wording.
const double _excellentFloor = 90.0;
const double _goodFloor = 75.0;
const double _fairFloor = 60.0;
