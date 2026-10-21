// The Darkroom pass view: the pass on its clock first (every stage of every
// filter lane as a block that fills one sub at a time, with the estimated
// rest), then the lane being worked on as a ledger, the image at the depth
// reached with its noise curve, and where the remaining time comes from.
//
// One widget for a running pass and for its record afterwards; it lays itself
// out in three columns on a wide window, two on a narrow one, and one
// scrolling column at the side panel's width.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'pass_gantt.dart';
import 'pass_ledger.dart';
import 'pass_view_charts.dart';
import 'pass_view_parts.dart';

/// Widths at which the view changes its layout.
abstract final class PassViewBreakpoints {
  /// From here up: ledger, image and timing side by side.
  static const double threeColumns = 1200;

  /// From here up: the ledger beside a column with the image and timing.
  static const double twoColumns = 760;

  /// Below this the timeline drops its stage labels.
  static const double stageLabels = 520;
}

class PassView extends StatelessWidget {
  const PassView({super.key, required this.snapshot, this.onStop});

  final PassSnapshot snapshot;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return LayoutBuilder(
      builder: (context, c) {
        final width = c.maxWidth;
        final narrow = width < PassViewBreakpoints.twoColumns;
        final body = narrow
            ? _SingleColumn(snapshot, width: width)
            : (width >= PassViewBreakpoints.threeColumns
                ? _ThreeColumns(snapshot)
                : _TwoColumns(snapshot));
        return ColoredBox(
          color: narrow ? colors.surface : colors.background,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              PassHeader(snapshot: snapshot, compact: narrow, onStop: onStop),
              Expanded(child: body),
            ],
          ),
        );
      },
    );
  }
}

String _passNote(PassSnapshot s) {
  if (s.lanes.isEmpty) {
    final n = s.timeline.drafts.where((d) => d.at <= s.elapsed).length;
    return '$n ${n == 1 ? 'draft' : 'drafts'} of the session\'s masters';
  }
  final subs = s.lanes.fold<int>(0, (n, l) => n + l.subCount);
  final lanes = s.lanes.length;
  final cal = s.lanes.map((l) => l.calibrationNote).whereType<String>().toSet();
  return <String>[
    '$lanes ${lanes == 1 ? 'filter' : 'filters'}',
    '$subs subs',
    if (cal.length == 1) cal.single,
  ].join(' · ');
}

String _laneNote(PassSnapshot s, PassLane lane) {
  final measured = lane.frames.where((f) => s.measured(lane, f)).length;
  final rejected =
      lane.frames.where((f) => s.measured(lane, f) && !f.accepted).length;
  return <String>[
    '$measured of ${lane.subCount} measured',
    if (rejected > 0) '$rejected rejected',
    if (lane.exposureSec != null) '${lane.exposureSec!.round()} s subs',
  ].join(' · ');
}

Widget _timelineSection(PassSnapshot s,
    {required double width, bool compact = false}) {
  return PassSection(
    title: 'Timeline',
    note: compact ? null : _passNote(s),
    padding: EdgeInsets.fromLTRB(
      compact ? SkotiqTokens.spaceMd : SkotiqTokens.spaceLg,
      10,
      compact ? SkotiqTokens.spaceMd : SkotiqTokens.spaceLg,
      12,
    ),
    child: s.lanes.isEmpty && s.timeline.colorSpans.isEmpty
        ? const _Muted('The pass has not reported a stage yet.')
        : PassGantt(
            snapshot: s,
            rowHeight: compact ? 16 : 22,
            rowGap: compact ? 5 : 6,
            labelWidth: compact ? 46 : 52,
            showStageLabels: width >= PassViewBreakpoints.stageLabels,
          ),
  );
}

Widget _imageSection(PassSnapshot s,
    {bool divider = true, bool compact = false}) {
  final (path, caption) = s.image;
  final lane = s.focusLane;
  final depths = lane == null ? const <PassDepth>[] : s.depthsOf(lane);
  final noted = depths.where((d) => d.noise != null).toList();
  final subs = lane == null
      ? 2
      : math.max(
          2,
          lane.span(PassStage.normalize).total ??
              lane.frames.where((f) => f.accepted).length,
        );
  return PassSection(
    title: 'Image',
    note: noted.isEmpty || lane == null
        ? null
        : '${lane.lane} noise ${noted.last.noise!.toStringAsFixed(1)} ADU',
    divider: divider,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        PassImageWell(path: path, caption: caption),
        if (lane != null) ...<Widget>[
          SizedBox(height: compact ? 8 : 12),
          _ChartTitle(
            title: 'Background noise as ${lane.lane} subs stack',
            lane: lane.lane,
          ),
          const SizedBox(height: 4),
          PassNoiseChart(
            depths: depths,
            totalSubs: subs,
            filter: lane.lane,
            height: compact ? 96 : 116,
          ),
        ],
      ],
    ),
  );
}

class _Muted extends StatelessWidget {
  const _Muted(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: SkotiqTypography.caption
            .copyWith(color: context.skotiqColors.textMuted),
      );
}

class _ChartTitle extends StatelessWidget {
  const _ChartTitle({required this.title, required this.lane});
  final String title;
  final String lane;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    Widget key(Widget mark, String label) => Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(width: 12, height: 2, child: mark),
            const SizedBox(width: 4),
            Text(
              label,
              style:
                  SkotiqTypography.captionSm.copyWith(color: colors.textMuted),
            ),
          ],
        );
    return Wrap(
      spacing: 10,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        Text(
          title,
          style: SkotiqTypography.labelStrongSm
              .copyWith(color: colors.textSecondary),
        ),
        key(Container(color: passFilterColor(lane, colors)), 'measured'),
        key(
          Row(
            children: <Widget>[
              Expanded(child: Container(color: colors.textMuted)),
              const SizedBox(width: 2),
              Expanded(child: Container(color: colors.textMuted)),
            ],
          ),
          '1/sqrt(N) from the first sub',
        ),
      ],
    );
  }
}

/// Where the remaining time comes from: each stage's measured seconds per
/// sub, what it took and what is left of it.
class _StageTiming extends StatelessWidget {
  const _StageTiming(this.snapshot);
  final PassSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final mono =
        SkotiqTypography.monoXs.copyWith(color: colors.textPrimary, height: 1);
    final head = SkotiqTypography.captionSm.copyWith(color: colors.textMuted);
    final schedule = snapshot.schedule;
    final ended = snapshot.ended;
    final rows = <Widget>[];
    for (final stage in PassStage.values) {
      final spans = schedule.where((s) => s.stage == stage).toList();
      if (spans.isEmpty) continue;
      var done = 0, total = 0;
      var took = Duration.zero;
      Duration? left = Duration.zero;
      var fromHistory = false;
      var finished = true;
      var notRun = true;
      var failed = false;
      for (final s in spans) {
        done += s.done;
        total += s.total;
        failed = failed || s.failed;
        if (s.state != PassStepState.notRun) notRun = false;
        if (s.state == PassStepState.done || s.state == PassStepState.running) {
          final until =
              s.state == PassStepState.done ? s.end! : snapshot.elapsed;
          took += until - s.start;
        }
        if (s.state == PassStepState.waiting ||
            s.state == PassStepState.running) {
          finished = false;
          if (s.end == null) {
            left = null;
          } else if (left != null) {
            final from =
                s.start > snapshot.elapsed ? s.start : snapshot.elapsed;
            if (s.end! > from) left += s.end! - from;
          }
          fromHistory = fromHistory || s.estimated;
        }
      }
      // Stages that report per sub (or per channel, per draft) have a count.
      final counted = stage == PassStage.calibrate ||
          stage == PassStage.register ||
          stage == PassStage.normalize ||
          stage == PassStage.align ||
          stage == PassStage.draft;
      if (!counted) total = 0;
      final perSub = done > 0 && took > Duration.zero && stage.isLaneStage
          ? (took.inMilliseconds / 1000 / done).toStringAsFixed(1)
          : '';
      final String leftText;
      final Color leftColor;
      if (failed) {
        leftText = 'failed';
        leftColor = colors.error;
      } else if (notRun && ended) {
        leftText = 'not run';
        leftColor = colors.textMuted;
      } else if (finished) {
        leftText = 'done';
        leftColor = colors.textMuted;
      } else if (left == null) {
        leftText = 'unknown';
        leftColor = colors.warning;
      } else {
        leftText = '${fromHistory ? '~' : ''}${passClock(left)}';
        leftColor = colors.textPrimary;
      }
      rows.add(
        SizedBox(
          height: 19,
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  stage.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SkotiqTypography.captionSm.copyWith(
                    color: finished ? colors.textSecondary : colors.textPrimary,
                  ),
                ),
              ),
              _cell(total == 0 ? '' : '$done/$total', 50,
                  mono.copyWith(color: colors.textSecondary)),
              _cell(perSub, 46, mono),
              _cell(took == Duration.zero ? '' : passClock(took), 46,
                  mono.copyWith(color: colors.textSecondary)),
              _cell(leftText, 60, mono.copyWith(color: leftColor)),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: Text('Stage', style: head)),
            _cell('Subs', 50, head),
            _cell('s / sub', 46, head),
            _cell('Took', 46, head),
            _cell(ended ? '' : 'Left', 60, head),
          ],
        ),
        const SizedBox(height: 4),
        ...rows,
        if (!ended) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            'Left is timed from this pass\'s own seconds per sub. ~ marks a '
            'stage timed from an earlier pass because it has not run yet; '
            'unknown, one no pass has timed.',
            style: SkotiqTypography.captionSm.copyWith(color: colors.textMuted),
          ),
        ],
      ],
    );
  }

  static Widget _cell(String t, double w, TextStyle style) => SizedBox(
        width: w,
        child: Text(
          t,
          textAlign: TextAlign.right,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.clip,
          style: style,
        ),
      );
}

/// The color stage's channel fits: how far each channel master sat from the
/// first one before alignment, or why it could not be placed.
class _ChannelFits extends StatelessWidget {
  const _ChannelFits(this.snapshot);
  final PassSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final mono =
        SkotiqTypography.monoXs.copyWith(color: colors.textPrimary, height: 1);
    final head = SkotiqTypography.captionSm.copyWith(color: colors.textMuted);
    final fits = <PassChannelFit>[
      for (final f in snapshot.timeline.channelFits)
        if (f.at <= snapshot.elapsed) f,
    ];
    if (fits.isEmpty) {
      final lead =
          snapshot.lanes.isEmpty ? 'the first' : snapshot.lanes.first.lane;
      return _Muted(
        snapshot.ended
            ? 'No channel was aligned in this pass.'
            : 'Each channel master is fitted onto $lead once every lane has '
                'its master.',
      );
    }
    Widget c(String t, double w, TextStyle st) => SizedBox(
          width: w,
          child: Text(t, textAlign: TextAlign.right, maxLines: 1, style: st),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            const SizedBox(width: 40),
            c('Shift px', 52, head),
            c('Rotation', 60, head),
            c('Stars', 42, head),
            c('Resid. px', 56, head),
          ],
        ),
        const SizedBox(height: 4),
        for (final f in fits)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(width: 40, child: PassFilterKey(f.lane)),
                if (f.failure != null)
                  Expanded(
                    child: Text(
                      'not placed: ${passReadableReason(f.failure!)}',
                      style: SkotiqTypography.captionSm
                          .copyWith(color: colors.error),
                    ),
                  )
                else ...<Widget>[
                  c(f.shift?.toStringAsFixed(1) ?? '', 52, mono),
                  c(
                    f.rotationDeg == null
                        ? ''
                        : '${f.rotationDeg!.toStringAsFixed(3)}°',
                    60,
                    mono,
                  ),
                  c(f.inliers == null ? '' : passGrouped(f.inliers!), 42, mono),
                  c(f.rmsPx?.toStringAsFixed(2) ?? '', 56, mono),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

/// One row per lane: what it kept, its integration, its median FWHM and,
/// once written, its master's noise.
class _LaneSummary extends StatelessWidget {
  const _LaneSummary(this.s, {this.compact = false});
  final PassSnapshot s;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final mono =
        SkotiqTypography.monoXs.copyWith(color: colors.textPrimary, height: 1);
    final head = SkotiqTypography.captionSm.copyWith(color: colors.textMuted);
    Widget c(String t, double w, TextStyle st) => SizedBox(
          width: w,
          child: Text(t, textAlign: TextAlign.right, maxLines: 1, style: st),
        );
    String state(PassLane lane) {
      if (lane.failure != null) return 'stopped';
      for (final span in lane.spans.reversed) {
        final st = span.stateAt(s.elapsed, ended: s.ended);
        if (st == PassStepState.done) {
          return span.stage == PassStage.write || span.stage == PassStage.finish
              ? 'master written'
              : '${span.stage.label} done';
        }
        if (st == PassStepState.running) return span.stage.verb.toLowerCase();
      }
      return s.ended ? 'not run' : 'waiting';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            const SizedBox(width: 40),
            c('Kept', 48, head),
            c('Time', 56, head),
            c('FWHM px', 58, head),
            if (!compact) c('Noise ADU', 66, head),
            const SizedBox(width: 14),
            Expanded(child: Text('State', style: head)),
          ],
        ),
        const SizedBox(height: 4),
        for (final lane in s.lanes)
          Builder(
            builder: (context) {
              final measured = <PassFrame>[
                for (final f in lane.frames)
                  if (s.measured(lane, f)) f,
              ];
              final kept = measured.where((f) => f.accepted).toList();
              final fwhm = kept.map((f) => f.fwhm).whereType<double>().toList()
                ..sort();
              final exposure = kept.fold<double>(
                0,
                (sum, f) => sum + (f.exposureSec ?? lane.exposureSec ?? 0),
              );
              final active = s.focusLane == lane && !s.ended;
              return SizedBox(
                height: 19,
                child: Row(
                  children: <Widget>[
                    SizedBox(width: 40, child: PassFilterKey(lane.lane)),
                    c(
                      measured.isEmpty ? '' : '${kept.length}/${lane.subCount}',
                      48,
                      mono,
                    ),
                    c(exposure <= 0 ? '' : passIntegration(exposure), 56, mono),
                    c(
                      fwhm.isEmpty
                          ? ''
                          : fwhm[fwhm.length ~/ 2].toStringAsFixed(2),
                      58,
                      mono,
                    ),
                    if (!compact)
                      c(
                        s.written(lane) && lane.masterNoise != null
                            ? lane.masterNoise!.toStringAsFixed(1)
                            : '',
                        66,
                        mono,
                      ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        state(lane),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: SkotiqTypography.captionSm.copyWith(
                          color: lane.failure != null
                              ? colors.error
                              : (active
                                  ? colors.primary
                                  : colors.textSecondary),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        for (final lane in s.lanes)
          if (lane.failure != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '${lane.lane} stopped: ${lane.failure}',
                style: SkotiqTypography.captionSm.copyWith(color: colors.error),
              ),
            ),
      ],
    );
  }
}

bool _hasColorStages(PassSnapshot s) =>
    s.timeline.colorSpans.containsKey(PassStage.align) ||
    s.timeline.colorSpans.containsKey(PassStage.combine) ||
    s.timeline.channelFits.isNotEmpty;

class _Column extends StatelessWidget {
  const _Column({required this.children, this.last = false});
  final List<Widget> children;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(
          top: BorderSide(color: colors.border),
          right: last ? BorderSide.none : BorderSide(color: colors.border),
        ),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}

List<Widget> _ledgerSections(PassSnapshot s, {bool compact = false}) {
  final lane = s.focusLane;
  final drafts = <PassDraft>[
    for (final d in s.timeline.drafts)
      if (d.at <= s.elapsed) d,
  ];
  final pad = compact
      ? const EdgeInsets.symmetric(
          horizontal: SkotiqTokens.spaceMd, vertical: 10)
      : const EdgeInsets.fromLTRB(
          SkotiqTokens.spaceLg, 10, SkotiqTokens.spaceMd, 10);
  return <Widget>[
    if (lane != null)
      PassSection(
        title: 'Subs · ${lane.lane}',
        note: _laneNote(s, lane),
        padding: pad,
        child: lane.frames.isEmpty
            ? const _Muted('The subs are listed once this lane starts.')
            : PassLedger(
                snapshot: s,
                lane: lane,
                rowHeight: compact ? 18 : 19,
                compact: compact,
              ),
      ),
    if (drafts.isNotEmpty || (s.lanes.isEmpty && !s.ended))
      PassSection(
        title: 'Drafts',
        note:
            compact ? null : 'one per master, background, denoise and stretch',
        padding: pad,
        child: drafts.isEmpty
            ? const _Muted('Each master is drafted in turn.')
            : _DraftList(s, drafts),
      ),
    if (s.lanes.isNotEmpty)
      PassSection(
        title: 'Filters',
        note: compact ? null : 'each lane integrates to its own master',
        divider: compact,
        padding: pad,
        child: _LaneSummary(s, compact: compact),
      ),
  ];
}

List<Widget> _timingSections(PassSnapshot s) => <Widget>[
      PassSection(title: 'Time', child: _StageTiming(s)),
      if (_hasColorStages(s))
        PassSection(
          title: 'Channels',
          note: s.lanes.isEmpty ? null : 'fitted onto ${s.lanes.first.lane}',
          divider: false,
          child: _ChannelFits(s),
        ),
    ];

class _ThreeColumns extends StatelessWidget {
  const _ThreeColumns(this.s);
  final PassSnapshot s;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return LayoutBuilder(
      builder: (context, c) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ColoredBox(
            color: colors.surface,
            child: _timelineSection(s, width: c.maxWidth),
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(
                    flex: 13, child: _Column(children: _ledgerSections(s))),
                Expanded(
                  flex: 9,
                  child: _Column(
                      children: <Widget>[_imageSection(s, divider: false)]),
                ),
                SizedBox(
                  width: 330,
                  child: _Column(last: true, children: _timingSections(s)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TwoColumns extends StatelessWidget {
  const _TwoColumns(this.s);
  final PassSnapshot s;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return LayoutBuilder(
      builder: (context, c) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ColoredBox(
            color: colors.surface,
            child: _timelineSection(s, width: c.maxWidth),
          ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(child: _Column(children: _ledgerSections(s))),
                SizedBox(
                  width: math.min(380, c.maxWidth * 0.42),
                  child: _Column(
                    last: true,
                    children: <Widget>[
                      _imageSection(s),
                      ..._timingSections(s),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SingleColumn extends StatelessWidget {
  const _SingleColumn(this.s, {required this.width});
  final PassSnapshot s;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _timelineSection(s, width: width, compact: true),
          _imageSection(s, compact: true),
          ..._ledgerSections(s, compact: true),
          ..._timingSections(s),
        ],
      ),
    );
  }
}

/// The drafts rendered so far, with how long each took.
class _DraftList extends StatelessWidget {
  const _DraftList(this.s, this.drafts);
  final PassSnapshot s;
  final List<PassDraft> drafts;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final start = s.timeline.colorSpans[PassStage.draft]?.start;
    var previous = start;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final d in drafts)
          Builder(builder: (context) {
            final took = previous == null ? null : d.at - previous!;
            previous = d.at;
            return SizedBox(
              height: 19,
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      d.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: SkotiqTypography.captionSm
                          .copyWith(color: colors.textPrimary),
                    ),
                  ),
                  Text(
                    took == null ? '' : passClock(took),
                    style: SkotiqTypography.monoXs
                        .copyWith(color: colors.textSecondary),
                  ),
                ],
              ),
            );
          }),
      ],
    );
  }
}
