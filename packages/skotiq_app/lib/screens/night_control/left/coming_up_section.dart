// "Coming up" while a run is live (next dither, autofocus cadence, flip,
// target switch, dawn) and "The night" before one (sunset, dark, moon, flip,
// dawn). Each row's words are built here from its kind and typed fields; the
// next timed event also says how far off it is.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../localization/skotiq_localizations.dart';
import '../data/plan/night_run_phase_provider.dart';
import '../data/plan/upcoming_provider.dart';
import '../night_control_contracts.dart';
import 'left_section_frame.dart';
import 'night_time_format.dart';

class NightComingUpSection extends ConsumerWidget {
  const NightComingUpSection({super.key});

  /// The most of a row the value takes.
  static const double valueShare = 0.68;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = SkotiqLocalizations.of(context);
    final colors = context.skotiqColors;
    final items = ref.watch(nightUpcomingProvider);
    final live = ref.watch(nightRunPhaseProvider).isRunLive;
    final now = nightNowOnClock(ref);

    // The first event still ahead gets "in 2 h 06 m".
    final next = items
        .where((i) => !i.passed && i.at != null && i.at!.isAfter(now))
        .firstOrNull;

    return NightLeftSectionFrame(
      title: l10n.text(live ? 'nightCtlComingUp' : 'nightCtlTheNight'),
      divider: false,
      gap: 4,
      child: items.isEmpty
          ? NightLeftEmpty(l10n.text('nightCtlNothingUpcoming'))
          : LayoutBuilder(
              // The value keeps its natural width up to a share of the row,
              // flush right; the name takes the rest.
              builder: (context, constraints) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  for (final item in items)
                    _row(
                      l10n,
                      colors,
                      item,
                      valueMaxWidth: constraints.maxWidth * valueShare,
                      inFor: identical(item, next)
                          ? item.at!.difference(now)
                          : null,
                    ),
                ],
              ),
            ),
    );
  }

  Widget _row(
    SkotiqLocalizations l10n,
    SkotiqColors colors,
    UpcomingItemVm item, {
    required double valueMaxWidth,
    Duration? inFor,
  }) {
    final name = nightUpcomingName(l10n, item);
    final value = nightUpcomingValue(l10n, item, inFor: inFor);
    final valueColor =
        item.passed ? colors.textMuted : nightToneColor(item.tone, colors);
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Expanded(
              child: Text(
                name,
                style: SkotiqTypography.caption.copyWith(
                  color: item.passed ? colors.textMuted : colors.textSecondary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
              ),
            ),
            if (value != null) ...<Widget>[
              const SizedBox(width: SkotiqTokens.spaceSm),
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: valueMaxWidth),
                child: Text(
                  value,
                  textAlign: TextAlign.right,
                  style: SkotiqTypography.monoXs.copyWith(color: valueColor),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// "Meridian flip", "Moon 44%".
String nightUpcomingName(SkotiqLocalizations l10n, UpcomingItemVm item) {
  switch (item.kind) {
    case UpcomingKind.dither:
      return l10n.text('nightCtlUpDither');
    case UpcomingKind.autofocus:
      return l10n.text('nightCtlUpAutofocus');
    case UpcomingKind.meridianFlip:
      return l10n.text('nightCtlUpFlip');
    case UpcomingKind.targetSwitch:
      return l10n.text('nightCtlUpTargetSwitch');
    case UpcomingKind.sunset:
      return l10n.text('nightCtlUpSunset');
    case UpcomingKind.astroDark:
      return l10n.text('nightCtlUpAstroDark');
    case UpcomingKind.moon:
      final pct = item.moonIlluminationPct;
      return pct == null
          ? l10n.text('nightCtlUpMoon')
          : l10n.text('nightCtlUpMoonPct', params: {'pct': '${pct.round()}'});
    case UpcomingKind.astroDawn:
      return l10n.text('nightCtlUpAstroDawn');
  }
}

/// "after #45", "6 frames or Δ1 °C", "01:58 · in 2 h 06 m", "≈03:40 · NGC
/// 891", "18:18 · passed", "sets 23:09". Null when the row has nothing to
/// add beside its name.
String? nightUpcomingValue(
  SkotiqLocalizations l10n,
  UpcomingItemVm item, {
  Duration? inFor,
}) {
  final at = item.at;
  final parts = <String>[];
  switch (item.kind) {
    case UpcomingKind.dither:
      if (item.afterFrame case final frame?) {
        parts.add(
            l10n.text('nightCtlUpAfterFrame', params: {'frame': '$frame'}));
      } else if (item.everyFrames case final n?) {
        parts.add(l10n.text('nightCtlUpEveryFrames', params: {'n': '$n'}));
      }
    case UpcomingKind.autofocus:
      final cadence = <String>[
        if (item.everyFrames case final n?)
          l10n.text('nightCtlUpFrames', params: {'n': '$n'}),
        if (item.tempDeltaC case final delta?)
          l10n.text('nightCtlUpTempDelta', params: {'deg': _trim(delta)}),
        if (item.every case final every?)
          l10n.text('nightCtlUpEvery', params: {
            'duration': nightSpan(l10n, every),
          }),
      ];
      if (cadence.isNotEmpty) {
        parts.add(cadence.join(' ${l10n.text('nightCtlUpOr')} '));
      }
    case UpcomingKind.targetSwitch:
      // The switch time is the estimator's.
      if (at != null) parts.add(nightHmMaybeEstimated(at, estimated: true));
      if (item.subject case final subject? when subject.isNotEmpty) {
        parts.add(subject);
      }
    case UpcomingKind.moon:
      parts.add(
        at == null
            ? l10n.text('nightCtlUpMoonNoSet')
            : l10n.text('nightCtlUpMoonSets', params: {'time': nightHm(at)}),
      );
    case UpcomingKind.meridianFlip ||
          UpcomingKind.sunset ||
          UpcomingKind.astroDark ||
          UpcomingKind.astroDawn:
      if (at != null) parts.add(nightHm(at));
  }
  if (item.passed) {
    parts.add(l10n.text('nightCtlUpPassed'));
  } else if (inFor != null) {
    parts.add(
      l10n.text('nightCtlUpIn', params: {'duration': nightSpan(l10n, inFor)}),
    );
  }
  return parts.isEmpty ? null : parts.join(' · ');
}

String _trim(double value) => value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : value.toStringAsFixed(1);
