import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The flat wizard's last step: build a master flat from each filter's
/// frames of the run that just finished and add it to the calibration
/// library, where the Darkroom and live calibration find it by filter.
class FlatBuildMasterStep extends ConsumerStatefulWidget {
  const FlatBuildMasterStep({super.key});

  @override
  ConsumerState<FlatBuildMasterStep> createState() =>
      _FlatBuildMasterStepState();
}

class _FlatBuildMasterStepState extends ConsumerState<FlatBuildMasterStep> {
  /// Backlog group key per filter, fixed when the build is asked for so the
  /// outcome stays readable after the group leaves the waiting list.
  final Map<String, String> _requested = {};

  CalibrationBacklogGroup? _groupFor(
    FlatRunFilterOutput output,
    List<CalibrationBacklogGroup> groups,
  ) {
    final paths = output.paths.toSet();
    for (final g in groups) {
      if (g.kind != CalibrationFrameKind.flat) continue;
      if (g.frames.any((f) => paths.contains(f.filePath))) return g;
    }
    return null;
  }

  void _buildAll(
    FlatRunOutput run,
    List<CalibrationBacklogGroup> groups,
  ) {
    final notifier = ref.read(calibrationBacklogProvider.notifier);
    for (final output in run.filters.values) {
      final group = _groupFor(output, groups);
      if (group == null || !group.buildable) continue;
      setState(() => _requested[output.filter] = group.key);
      notifier.build(group);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final run = ref.watch(flatRunOutputProvider);
    if (run.isEmpty) return const SizedBox.shrink();
    final backlog = ref.watch(calibrationBacklogProvider);
    final groups = backlog.groups.valueOrNull ?? const [];

    final rows = <Widget>[];
    var buildable = 0;
    var running = 0;
    var built = 0;
    for (final output in run.filters.values) {
      final key = _requested[output.filter];
      final group = _groupFor(output, groups);
      final status = backlog.builds[key ?? group?.key];
      final String state;
      Color tone = colors.textSecondary;
      switch (status?.phase) {
        case CalibrationBuildPhase.queued:
          state = 'Queued';
          running++;
        case CalibrationBuildPhase.building:
          state = 'Building';
          running++;
        case CalibrationBuildPhase.built:
          final b = status!.build!;
          state = 'In the library, ${b.framesCombined} of '
              '${b.framesCaptured} frames';
          tone = colors.success;
          built++;
        case CalibrationBuildPhase.failed:
          state = status!.error ?? 'Failed';
          tone = colors.error;
        case null:
          if (run.remote) {
            state = '${output.paths.length} frames on the imaging computer';
          } else if (output.paths.length < calibrationBacklogMinFrames) {
            state = 'A master flat needs at least '
                '$calibrationBacklogMinFrames frames';
            tone = colors.warning;
          } else if (group == null) {
            state = backlog.groups.isLoading
                ? 'Finding the frames'
                : 'Already covered by a master flat';
          } else {
            state = '${group.frames.length} frames ready';
            buildable++;
          }
      }
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceXs),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 72,
                child: Text(
                  output.filter,
                  style: SkotiqTypography.labelStrong.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  state,
                  style: SkotiqTypography.bodySm.copyWith(color: tone),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      padding: SkotiqTokens.paddingLg,
      decoration: SkotiqDecorations.panel(colors),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Build master flat',
            style: SkotiqTypography.sectionTitle.copyWith(
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          Text(
            run.remote
                ? 'These flats were saved on the imaging computer. Build their '
                    'masters in the Darkroom there, under Calibration.'
                : 'Bias-subtracts and combines each filter\'s flats, then adds '
                    'the master to the calibration library so builds and live '
                    'calibration use it.',
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          ...rows,
          const SizedBox(height: SkotiqTokens.spaceMd),
          Wrap(
            spacing: SkotiqTokens.spaceSm,
            runSpacing: SkotiqTokens.spaceSm,
            children: [
              if (!run.remote && built < run.filters.length)
                SkotiqButton(
                  label: run.filters.length == 1
                      ? 'Build master flat'
                      : 'Build master flats',
                  icon: LucideIcons.layers,
                  isLoading: running > 0,
                  onPressed: buildable > 0 && running == 0
                      ? () => _buildAll(run, groups)
                      : null,
                ),
              SkotiqButton(
                label: 'Open Calibration',
                variant: ButtonVariant.ghost,
                onPressed: () => context.go('/darkroom?tab=calibration'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
