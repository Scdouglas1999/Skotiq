import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'calibration_panel.dart';

/// Raw darks, bias and flats Skotiq captured that no library master covers
/// yet, each with a one-click build that registers the result.
class CalibrationWaitingPanel extends ConsumerWidget {
  const CalibrationWaitingPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(calibrationBacklogProvider);
    final notifier = ref.read(calibrationBacklogProvider.notifier);
    final groups =
        state.groups.valueOrNull ?? const <CalibrationBacklogGroup>[];
    final buildable = groups.where((g) {
      final phase = state.builds[g.key]?.phase;
      return g.buildable &&
          phase != CalibrationBuildPhase.queued &&
          phase != CalibrationBuildPhase.building;
    }).length;
    final finished = [
      for (final e in state.builds.entries)
        if (e.value.phase == CalibrationBuildPhase.built) e,
    ];

    return CalibrationSection(
      title: 'Waiting to be built',
      note:
          'Select Night end only for flats taken with the intended optical setup. '
          'They will be built after darks and bias, before the matching lights.',
      actions: [
        if (buildable > 1)
          SkotiqButton(
            label: 'Build all $buildable',
            icon: LucideIcons.layers,
            size: ButtonSize.small,
            onPressed: notifier.buildAll,
          ),
        SkotiqIconButton(
          icon: LucideIcons.refreshCw,
          tooltip: 'Look again',
          size: IconButtonSize.sm,
          onPressed: state.remote ? null : notifier.refresh,
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final key in state.scheduled
              .where((key) => !groups.any((g) => g.key == key)))
            Row(children: [
              Checkbox(
                  value: true, onChanged: (_) => notifier.unscheduleFlat(key)),
              Expanded(
                  child: Text(
                      'Night end: ${key.split('|')[2]} flats · ${key.split('|')[1]}')),
            ]),
          for (final e in finished)
            _BuiltRow(
              status: e.value,
              onDismiss: () => notifier.clearResult(e.key),
            ),
          ..._body(context, state, groups, notifier),
        ],
      ),
    );
  }

  List<Widget> _body(
    BuildContext context,
    CalibrationBacklogState state,
    List<CalibrationBacklogGroup> groups,
    CalibrationBacklogNotifier notifier,
  ) {
    if (state.remote) {
      return const [
        CalibrationEmpty(
          'Calibration frames are built on the imaging computer. Open the '
          'Darkroom there to build them.',
          icon: LucideIcons.server,
        ),
      ];
    }
    final error = state.groups.error;
    if (error != null && !state.groups.hasValue) {
      return [
        _ErrorLine(
          message: 'Could not read the captured calibration frames: $error',
          onRetry: notifier.refresh,
        ),
      ];
    }
    if (!state.groups.hasValue) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: SkotiqTokens.spaceXl),
          child: Center(child: SkotiqSpinner(size: 20)),
        ),
      ];
    }
    if (groups.isEmpty) {
      return const [
        CalibrationEmpty(
          'Nothing is waiting. Every dark, bias and flat Skotiq captured has '
          'a master in the library.',
          icon: LucideIcons.checkCircle2,
        ),
      ];
    }
    final out = <Widget>[];
    String? night;
    for (var i = 0; i < groups.length; i++) {
      final g = groups[i];
      if (g.night != night) {
        night = g.night;
        out.add(CalibrationOverline('Night of ${_nightLabel(g.night)}'));
      }
      final next = i + 1 < groups.length ? groups[i + 1] : null;
      out.add(
        _GroupRow(
          group: g,
          status: state.builds[g.key],
          last: next == null || next.night != g.night,
          onBuild: () => notifier.build(g),
          scheduled: state.scheduled.contains(g.key),
          onSchedule: (on) => notifier.scheduleFlat(g, on),
          onDismiss: () => notifier.dismiss(g),
        ),
      );
    }
    return out;
  }
}

class _GroupRow extends StatelessWidget {
  const _GroupRow({
    required this.group,
    required this.status,
    required this.last,
    required this.onBuild,
    required this.onDismiss,
    required this.scheduled,
    required this.onSchedule,
  });

  final CalibrationBacklogGroup group;
  final CalibrationBuildStatus? status;
  final bool last;
  final VoidCallback onBuild;
  final bool scheduled;
  final ValueChanged<bool> onSchedule;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final phase = status?.phase;
    final busy = phase == CalibrationBuildPhase.queued ||
        phase == CalibrationBuildPhase.building;
    final problem = phase == CalibrationBuildPhase.failed
        ? status!.error
        : (group.missingFiles > 0
            ? '${group.missingFiles} of ${group.frames.length} frames are '
                'not on this computer'
            : (group.frames.length < calibrationBacklogMinFrames
                ? 'A master needs at least $calibrationBacklogMinFrames '
                    'frames'
                : null));

    return CalibrationRow(
      last: last,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 560;
          final info = Row(
            children: [
              _KindMark(kind: group.kind),
              const SizedBox(width: SkotiqTokens.spaceMd),
              SizedBox(
                width: 96,
                child: Text(
                  group.title,
                  style: SkotiqTypography.labelStrong.copyWith(
                    color: colors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceMd),
              Expanded(
                child: Text(
                  group.settings,
                  style: SkotiqTypography.monoSm.copyWith(
                    color: colors.textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceMd),
              SizedBox(
                width: 72,
                child: Text(
                  '${group.frames.length} frames',
                  style: SkotiqTypography.bodySm.copyWith(
                    color: colors.textSecondary,
                  ),
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          );
          final action = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (group.kind == CalibrationFrameKind.flat) ...[
                Checkbox(
                  value: scheduled,
                  onChanged: busy ? null : (on) => onSchedule(on!),
                ),
                const Text('Night end'),
                const SizedBox(width: SkotiqTokens.spaceSm),
              ],
              if (busy)
                _Progress(
                  label: phase == CalibrationBuildPhase.building
                      ? 'Building'
                      : 'Queued',
                )
              else
                SkotiqButton(
                  label: phase == CalibrationBuildPhase.failed
                      ? 'Try again'
                      : 'Build',
                  variant: ButtonVariant.secondary,
                  size: ButtonSize.small,
                  onPressed: group.buildable ? onBuild : null,
                ),
              const SizedBox(width: SkotiqTokens.spaceXs),
              SkotiqIconButton(
                icon: LucideIcons.x,
                tooltip: 'Do not build these frames',
                size: IconButtonSize.sm,
                onPressed: busy ? null : onDismiss,
              ),
            ],
          );
          final problemLine = problem == null
              ? null
              : Padding(
                  padding: EdgeInsets.only(
                    top: SkotiqTokens.spaceXs,
                    left: narrow ? 0 : 14 + SkotiqTokens.spaceMd,
                  ),
                  child: Text(
                    problem,
                    style: SkotiqTypography.caption.copyWith(
                      color: phase == CalibrationBuildPhase.failed
                          ? colors.error
                          : colors.warning,
                    ),
                  ),
                );
          if (narrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                info,
                if (problemLine != null) problemLine,
                const SizedBox(height: SkotiqTokens.spaceXs),
                Align(alignment: Alignment.centerRight, child: action),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: info),
                  const SizedBox(width: SkotiqTokens.spaceLg),
                  action,
                ],
              ),
              if (problemLine != null) problemLine,
            ],
          );
        },
      ),
    );
  }
}

class _BuiltRow extends StatelessWidget {
  const _BuiltRow({required this.status, required this.onDismiss});

  final CalibrationBuildStatus status;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final built = status.build!;
    final kind = switch (built.kind) {
      CalibrationFrameKind.dark => 'dark',
      CalibrationFrameKind.bias => 'bias',
      CalibrationFrameKind.flat => 'flat',
    };
    final leftOut = built.leftOut.isEmpty
        ? ''
        : ' ${built.leftOut.length} left out '
            '(${built.kind == CalibrationFrameKind.flat ? 'banded or obstructed' : 'brighter than the first frames'}).';
    return CalibrationRow(
      child: Row(
        children: [
          Icon(LucideIcons.checkCircle2, size: 14, color: colors.success),
          const SizedBox(width: SkotiqTokens.spaceMd),
          Expanded(
            child: Text(
              'Master $kind built from ${built.framesCombined} of '
              '${built.framesCaptured} frames and added to the library: '
              '${p.basename(built.outputPath)}.$leftOut',
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textPrimary,
              ),
            ),
          ),
          SkotiqIconButton(
            icon: LucideIcons.x,
            tooltip: 'Dismiss',
            size: IconButtonSize.sm,
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}

/// A small square in the kind's tone, so darks, bias and flats read apart.
class _KindMark extends StatelessWidget {
  const _KindMark({required this.kind});

  final CalibrationFrameKind kind;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final color = switch (kind) {
      CalibrationFrameKind.dark => colors.textMuted,
      CalibrationFrameKind.bias => colors.info,
      CalibrationFrameKind.flat => colors.brandWarm,
    };
    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
        border: Border.all(color: color.withValues(alpha: 0.7)),
      ),
    );
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SkotiqSpinner(size: 14, color: colors.primary),
        const SizedBox(width: SkotiqTokens.spaceSm),
        Text(
          label,
          style: SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }
}

class _ErrorLine extends StatelessWidget {
  const _ErrorLine({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceMd),
      child: Row(
        children: [
          Icon(LucideIcons.alertTriangle, size: 14, color: colors.error),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Expanded(
            child: Text(
              message,
              style: SkotiqTypography.bodySm.copyWith(color: colors.error),
            ),
          ),
          SkotiqButton(
            label: 'Retry',
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
            onPressed: onRetry,
          ),
        ],
      ),
    );
  }
}

/// "Oct 21, 2026" from an observing night's `yyyy-mm-dd`.
String _nightLabel(String night) {
  final d = DateTime.tryParse(night);
  if (d == null) return night;
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${months[d.month - 1]} ${d.day}, ${d.year}';
}
