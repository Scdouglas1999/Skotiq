// Two ways to lay out a running Darkroom pass, each at the full window and at
// the Darkroom side panel's width.
//
// Timeline: the pass on its clock first (every stage of every filter lane as
// a block that fills one sub at a time, with the estimated rest), then the
// running lane's ledger, the image at the depth reached with its noise curve,
// and where the remaining time comes from.
//
// Field: the subs first (every sub of every lane as a tile with its
// thumbnail, FWHM and weight), the per-sub measurements as small multiples,
// the dither pattern the registration found, and the image with its noise
// curve.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'pass_frames.dart';
import 'pass_gantt.dart';
import 'pass_view_charts.dart';
import 'pass_view_model.dart';
import 'pass_view_parts.dart';

enum PassViewDirection { timeline, field }

/// The pass view for [direction]; [panel] lays it out for the Darkroom side
/// panel rather than the full window.
class PassView extends StatelessWidget {
  const PassView({
    super.key,
    required this.snapshot,
    required this.direction,
    this.panel = false,
  });

  final PassSnapshot snapshot;
  final PassViewDirection direction;
  final bool panel;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final body = switch ((direction, panel)) {
      (PassViewDirection.timeline, false) => _TimelineDesktop(snapshot),
      (PassViewDirection.timeline, true) => _TimelinePanel(snapshot),
      (PassViewDirection.field, false) => _FieldDesktop(snapshot),
      (PassViewDirection.field, true) => _FieldPanel(snapshot),
    };
    return ColoredBox(
      color: panel ? colors.surface : colors.background,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          PassHeader(snapshot: snapshot, compact: panel),
          Expanded(child: body),
        ],
      ),
    );
  }
}

PassLane _focusLane(PassSnapshot s) => s.activeLane ?? s.lanes.last;

String _laneNote(PassSnapshot s, PassLane lane) {
  final measured = lane.frames.where((f) => s.measured(lane, f)).length;
  final rejected =
      lane.frames.where((f) => s.measured(lane, f) && !f.accepted).length;
  return '$measured of ${lane.frames.length} measured'
      '${rejected > 0 ? ' · $rejected rejected' : ''}'
      ' · ${lane.exposureSec.round()} s subs';
}

Widget _imageSection(PassSnapshot s,
    {bool divider = true, bool compact = false}) {
  final (image, caption) = s.image;
  final lead = s.lanes.first;
  final reached = s.depthsReached;
  final accepted = lead.frames.where((f) => f.accepted).length;
  return PassSection(
    title: 'Image',
    note: reached.isEmpty
        ? null
        : '${lead.filter} noise ${reached.last.noise.toStringAsFixed(1)} ADU',
    divider: divider,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        PassImageWell(image: image, caption: caption),
        SizedBox(height: compact ? 8 : 12),
        _ChartTitle(
          title: 'Background noise as ${lead.filter} subs stack',
          keys: const <(String, bool)>[
            ('measured', false),
            ('1/sqrt(N) from 2 subs', true)
          ],
          filter: lead.filter,
        ),
        const SizedBox(height: 4),
        PassNoiseChart(
          depths: reached,
          totalSubs: math.max(accepted, 2),
          filter: lead.filter,
          height: compact ? 92 : 112,
        ),
      ],
    ),
  );
}

class _ChartTitle extends StatelessWidget {
  const _ChartTitle(
      {required this.title, required this.keys, required this.filter});
  final String title;
  final List<(String, bool)> keys;
  final String filter;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: SkotiqTypography.labelStrongSm
                  .copyWith(color: colors.textSecondary)),
        ),
        for (final (label, dashed) in keys) ...<Widget>[
          const SizedBox(width: 10),
          SizedBox(
            width: 12,
            height: 2,
            child: dashed
                ? Row(children: <Widget>[
                    Expanded(child: Container(color: colors.textMuted)),
                    const SizedBox(width: 2),
                    Expanded(child: Container(color: colors.textMuted)),
                  ])
                : Container(color: passFilterColor(filter, colors)),
          ),
          const SizedBox(width: 4),
          Text(label,
              style:
                  SkotiqTypography.captionSm.copyWith(color: colors.textMuted)),
        ],
      ],
    );
  }
}

/// Where the remaining time comes from: each stage's measured seconds per
/// sub and what is left of it.
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
    // One row per stage, the lanes folded together.
    final rows = <(String, int, int, Duration, Duration?, bool, bool)>[];
    for (final stage in PassStage.values) {
      final spans = schedule.where((s) => s.stage == stage).toList();
      if (spans.isEmpty) continue;
      var done = 0, total = 0;
      var took = Duration.zero;
      Duration? left = Duration.zero;
      var estimated = false;
      var finished = true;
      for (final s in spans) {
        done += s.done;
        total += s.total;
        if (s.state != PassStepState.waiting) {
          final until =
              s.state == PassStepState.done ? s.end! : snapshot.elapsed;
          took += until - s.start;
        }
        if (s.state != PassStepState.done) {
          finished = false;
          if (s.end == null) {
            left = null;
          } else if (left != null) {
            final from =
                s.start > snapshot.elapsed ? s.start : snapshot.elapsed;
            left += s.end! - from;
          }
          estimated = estimated || s.estimated;
        }
      }
      rows.add((
        stage.label,
        done,
        total,
        took,
        finished ? Duration.zero : left,
        estimated,
        finished
      ));
    }
    Widget c(String t, double w,
            {TextAlign a = TextAlign.right, TextStyle? st}) =>
        SizedBox(
          width: w,
          child: Text(t,
              textAlign: a, maxLines: 1, softWrap: false, style: st ?? mono),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(children: <Widget>[
          Expanded(child: Text('Stage', style: head)),
          c('Subs', 52, st: head),
          c('s / sub', 50, st: head),
          c('Took', 46, st: head),
          c('Left', 58, st: head),
        ]),
        const SizedBox(height: 4),
        for (final r in rows)
          SizedBox(
            height: 19,
            child: Row(children: <Widget>[
              Expanded(
                child: Text(r.$1,
                    maxLines: 1,
                    style: SkotiqTypography.captionSm.copyWith(
                        color:
                            r.$7 ? colors.textSecondary : colors.textPrimary)),
              ),
              c(r.$3 == 0 ? '' : '${r.$2}/${r.$3}', 52,
                  st: mono.copyWith(color: colors.textSecondary)),
              c(
                  r.$2 == 0 || r.$3 == 0
                      ? ''
                      : (r.$4.inMilliseconds / 1000 / r.$2).toStringAsFixed(1),
                  50),
              c(r.$4 == Duration.zero ? '' : passClock(r.$4), 46,
                  st: mono.copyWith(color: colors.textSecondary)),
              c(
                r.$7
                    ? 'done'
                    : (r.$5 == null
                        ? 'unknown'
                        : '${r.$6 ? '~' : ''}${passClock(r.$5!)}'),
                58,
                st: mono.copyWith(
                    color: r.$7
                        ? colors.textMuted
                        : (r.$5 == null ? colors.warning : colors.textPrimary)),
              ),
            ]),
          ),
        const SizedBox(height: 6),
        Text(
          'Left comes from this pass\'s own seconds per sub; ~ marks a stage '
          'timed from the last pass because it has not run yet.',
          style: SkotiqTypography.captionSm.copyWith(color: colors.textMuted),
        ),
      ],
    );
  }
}

/// The color stage's channel fits: how far each channel master sat from
/// the luminance master before alignment.
class _ChannelFits extends StatelessWidget {
  const _ChannelFits(this.snapshot);
  final PassSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final mono =
        SkotiqTypography.monoXs.copyWith(color: colors.textPrimary, height: 1);
    final head = SkotiqTypography.captionSm.copyWith(color: colors.textMuted);
    final align = snapshot.timeline.colorSpans
        .firstWhere((s) => s.stage == PassStage.align);
    final state = align.stateAt(snapshot.elapsed);
    if (state == PassStepState.waiting) {
      return Text(
        'Each channel master is fitted onto ${snapshot.lanes.first.filter} once every lane has its master.',
        style: SkotiqTypography.captionSm.copyWith(color: colors.textMuted),
      );
    }
    Widget c(String t, double w,
            {TextStyle? st, TextAlign a = TextAlign.right}) =>
        SizedBox(
            width: w,
            child: Text(t, textAlign: a, maxLines: 1, style: st ?? mono));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(children: <Widget>[
          c('', 34, a: TextAlign.left, st: head),
          c('Shift px', 52, st: head),
          c('Rotation', 60, st: head),
          c('Stars', 42, st: head),
          c('Resid. px', 56, st: head),
        ]),
        const SizedBox(height: 4),
        for (final f in snapshot.timeline.channelFits)
          SizedBox(
            height: 19,
            child: Row(children: <Widget>[
              SizedBox(width: 34, child: PassFilterKey(f.filter)),
              if (f.failure != null)
                Expanded(
                  child: Text(
                    'not placed: ${f.failure}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: SkotiqTypography.captionSm
                        .copyWith(color: colors.error),
                  ),
                ),
              if (f.failure == null) ...<Widget>[
                c(Offset(f.dx, f.dy).distance.toStringAsFixed(1), 52),
                c('${f.rotationDeg.toStringAsFixed(3)}°', 60),
                c(passGrouped(f.inliers), 42),
                c(f.rmsPx.toStringAsFixed(2), 56),
              ],
            ]),
          ),
      ],
    );
  }
}

class _TimelineDesktop extends StatelessWidget {
  const _TimelineDesktop(this.s);
  final PassSnapshot s;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final lane = _focusLane(s);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          color: colors.surface,
          child: PassSection(
            title: 'Pass',
            note: '${s.lanes.length} filters · '
                '${s.lanes.fold<int>(0, (n, l) => n + l.frames.length)} subs · '
                '${s.timeline.calibrationNote ?? ''}',
            padding: const EdgeInsets.fromLTRB(
                SkotiqTokens.spaceLg, 10, SkotiqTokens.spaceLg, 12),
            child: PassGantt(snapshot: s),
          ),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                flex: 13,
                child: _Column(
                  children: <Widget>[
                    PassSection(
                      title: 'Subs · ${lane.filter}',
                      note: _laneNote(s, lane),
                      padding: const EdgeInsets.fromLTRB(
                          SkotiqTokens.spaceLg, 10, SkotiqTokens.spaceMd, 10),
                      child: PassLedger(snapshot: s, lane: lane, rowHeight: 19),
                    ),
                    PassSection(
                      title: 'Filters',
                      note: 'each lane integrates to its own master',
                      divider: false,
                      padding: const EdgeInsets.fromLTRB(
                          SkotiqTokens.spaceLg, 10, SkotiqTokens.spaceMd, 10),
                      child: _LaneSummary(s),
                    ),
                  ],
                ),
              ),
              Expanded(
                flex: 9,
                child: _Column(
                    children: <Widget>[_imageSection(s, divider: false)]),
              ),
              SizedBox(
                width: 330,
                child: _Column(
                  last: true,
                  children: <Widget>[
                    PassSection(title: 'Time', child: _StageTiming(s)),
                    PassSection(
                      title: 'Channels',
                      note: 'fitted onto ${s.lanes.first.filter}',
                      divider: false,
                      child: _ChannelFits(s),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

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
      child: ClipRect(
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      ),
    );
  }
}

class _TimelinePanel extends StatelessWidget {
  const _TimelinePanel(this.s);
  final PassSnapshot s;

  @override
  Widget build(BuildContext context) {
    final lane = _focusLane(s);
    return ClipRect(
      child: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            PassSection(
              title: 'Pass',
              note:
                  '${s.lanes.fold<int>(0, (n, l) => n + l.frames.length)} subs',
              child: PassGantt(
                  snapshot: s,
                  rowHeight: 16,
                  rowGap: 5,
                  labelWidth: 40,
                  showStageLabels: false),
            ),
            _imageSection(s, compact: true),
            PassSection(
              title: 'Subs · ${lane.filter}',
              note: _laneNote(s, lane),
              divider: false,
              child: PassLedger(
                  snapshot: s, lane: lane, rowHeight: 17, compact: true),
            ),
          ],
        ),
      ),
    );
  }
}

List<PassOffsetPoint> _offsets(PassSnapshot s) {
  final active = s.activeSpan;
  return <PassOffsetPoint>[
    for (final lane in s.lanes)
      for (final f in lane.frames)
        if (s.measured(lane, f) && f.dx != null)
          PassOffsetPoint(
            f.dx!,
            f.dy!,
            lane.filter,
            current: active != null &&
                active.$1 == lane &&
                active.$2.stage == PassStage.register &&
                active.$2.doneAt(s.elapsed) == f.index,
          ),
  ];
}

const List<PassMetricStrip> _strips = <PassMetricStrip>[
  PassMetricStrip(label: 'FWHM', unit: 'px', value: _fwhm, decimals: 1),
  PassMetricStrip(label: 'Stars', unit: '', value: _stars, decimals: 0),
  PassMetricStrip(label: 'Eccentricity', unit: '', value: _ecc, decimals: 2),
  PassMetricStrip(label: 'Background', unit: 'ADU', value: _bkg, decimals: 0),
  PassMetricStrip(label: 'Residual', unit: 'px', value: _rms, decimals: 2),
];
double? _fwhm(PassFrame f) => f.fwhm;
double? _stars(PassFrame f) => f.stars?.toDouble();
double? _ecc(PassFrame f) => f.eccentricity;
double? _bkg(PassFrame f) => f.background;
double? _rms(PassFrame f) => f.isReference ? null : f.rmsPx;

class _StageTrack extends StatelessWidget {
  const _StageTrack(this.s, {this.compact = false});
  final PassSnapshot s;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final schedule = s.schedule;
    final stages = <PassStage>[
      PassStage.calibrate,
      PassStage.register,
      PassStage.normalize,
      PassStage.integrate,
      PassStage.align,
      PassStage.combine,
      PassStage.draft,
    ];
    return Row(
      children: <Widget>[
        for (var i = 0; i < stages.length; i++) ...<Widget>[
          if (i > 0) SizedBox(width: compact ? 3 : 4),
          Expanded(
            child: Builder(builder: (context) {
              final spans = schedule
                  .where((x) =>
                      x.stage == stages[i] ||
                      (stages[i] == PassStage.integrate &&
                          x.stage == PassStage.write))
                  .toList();
              final doneLanes =
                  spans.where((x) => x.state == PassStepState.done).length;
              final running =
                  spans.any((x) => x.state == PassStepState.running);
              final all = spans.isNotEmpty && doneLanes == spans.length;
              final fraction = spans.isEmpty ? 0.0 : doneLanes / spans.length;
              final tone = all
                  ? colors.textSecondary
                  : (running ? colors.primary : colors.textMuted);
              final count = stages[i].index <= PassStage.write.index
                  ? '${spans.where((x) => x.stage == stages[i]).where((x) => x.state == PassStepState.done).length}/${s.lanes.length}'
                  : '';
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (!compact)
                    Row(children: <Widget>[
                      Flexible(
                        child: Text(
                          stages[i].label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: (running
                                  ? SkotiqTypography.labelStrongSm
                                  : SkotiqTypography.captionSm)
                              .copyWith(
                                  color: running ? colors.textPrimary : tone),
                        ),
                      ),
                      if (!compact && count.isNotEmpty) ...<Widget>[
                        const SizedBox(width: 6),
                        Text(count,
                            style: SkotiqTypography.monoXs
                                .copyWith(fontSize: 9, color: tone)),
                      ],
                    ]),
                  if (!compact) const SizedBox(height: 4),
                  SizedBox(
                    height: 3,
                    child: LayoutBuilder(
                      builder: (context, c) => Stack(children: <Widget>[
                        Container(color: colors.border),
                        Container(
                          width: c.maxWidth *
                              (running && fraction == 0 ? 0.08 : fraction),
                          color:
                              running ? colors.primary : colors.textSecondary,
                        ),
                      ]),
                    ),
                  ),
                ],
              );
            }),
          ),
        ],
      ],
    );
  }
}

class _FieldDesktop extends StatelessWidget {
  const _FieldDesktop(this.s);
  final PassSnapshot s;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(
          child: _Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    SkotiqTokens.spaceLg, 12, SkotiqTokens.spaceLg, 12),
                child: _StageTrack(s),
              ),
              Container(height: 1, color: colors.border),
              PassSection(
                title: 'Subs',
                note:
                    '${s.lanes.fold<int>(0, (n, l) => n + l.frames.where((f) => s.measured(l, f)).length)} of '
                    '${s.lanes.fold<int>(0, (n, l) => n + l.frames.length)} measured',
                padding: const EdgeInsets.fromLTRB(
                    SkotiqTokens.spaceLg, 10, SkotiqTokens.spaceLg, 12),
                child: PassFrameField(snapshot: s),
              ),
              Expanded(
                child: PassSection(
                  title: 'Per sub',
                  note: 'one line per filter',
                  divider: false,
                  expand: true,
                  padding: const EdgeInsets.fromLTRB(
                      SkotiqTokens.spaceLg, 10, SkotiqTokens.spaceLg, 10),
                  child: LayoutBuilder(
                    builder: (context, c) => Align(
                      alignment: Alignment.topCenter,
                      child: PassMetricStrips(
                        snapshot: s,
                        strips: _strips,
                        bandHeight:
                            math.min(64, (c.maxHeight - 16) / _strips.length),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          width: 470,
          child: _Column(
            last: true,
            children: <Widget>[
              _imageSection(s),
              Expanded(
                child: PassSection(
                  title: 'Registration',
                  note: _registrationNote(s),
                  divider: false,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      PassOffsetScatter(points: _offsets(s), size: 170),
                      const SizedBox(width: SkotiqTokens.spaceMd),
                      Expanded(child: _ChannelFits(s)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

String _registrationNote(PassSnapshot s) {
  final rms = <double>[
    for (final lane in s.lanes)
      for (final f in lane.frames)
        if (s.measured(lane, f) && f.rmsPx != null && !f.isReference) f.rmsPx!,
  ];
  if (rms.isEmpty) return 'offsets onto each lane\'s reference';
  final mean = rms.reduce((a, b) => a + b) / rms.length;
  return '${rms.length} subs · mean residual ${mean.toStringAsFixed(2)} px';
}

class _FieldPanel extends StatelessWidget {
  const _FieldPanel(this.s);
  final PassSnapshot s;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  SkotiqTokens.spaceMd, 10, SkotiqTokens.spaceMd, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Builder(builder: (context) {
                    final colors = context.skotiqColors;
                    final active = s.activeSpan;
                    final stage = active?.$2.stage;
                    final order = <PassStage>[
                      PassStage.calibrate,
                      PassStage.register,
                      PassStage.normalize,
                      PassStage.integrate,
                      PassStage.align,
                      PassStage.combine,
                      PassStage.draft,
                    ];
                    final at = stage == PassStage.write
                        ? 4
                        : (stage == null ? 7 : order.indexOf(stage) + 1);
                    return Text(
                      stage == null
                          ? 'All 7 stages done'
                          : 'Stage $at of 7 · ${stage.label}',
                      style: SkotiqTypography.captionSm
                          .copyWith(color: colors.textSecondary),
                    );
                  }),
                  const SizedBox(height: 6),
                  _StageTrack(s, compact: true),
                ],
              ),
            ),
            PassSection(
              title: 'Subs',
              note:
                  '${s.lanes.fold<int>(0, (n, l) => n + l.frames.where((f) => s.measured(l, f)).length)} of '
                  '${s.lanes.fold<int>(0, (n, l) => n + l.frames.length)} measured',
              child: _PanelField(s),
            ),
            _imageSection(s, compact: true),
            PassSection(
              title: 'Registration',
              note: _registrationNote(s),
              divider: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      PassOffsetScatter(points: _offsets(s), size: 150),
                      const SizedBox(width: SkotiqTokens.spaceMd),
                      Expanded(child: _OffsetReadouts(s)),
                    ],
                  ),
                  const SizedBox(height: SkotiqTokens.spaceSm),
                  PassMetricStrips(
                    snapshot: s,
                    strips: const <PassMetricStrip>[
                      PassMetricStrip(label: 'FWHM', unit: 'px', value: _fwhm),
                      PassMetricStrip(
                          label: 'Residual',
                          unit: 'px',
                          value: _rms,
                          decimals: 2),
                    ],
                    bandHeight: 40,
                  ),
                  const SizedBox(height: SkotiqTokens.spaceMd),
                  _ChannelFits(s),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The registration numbers beside the panel's scatter.
class _OffsetReadouts extends StatelessWidget {
  const _OffsetReadouts(this.s);
  final PassSnapshot s;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final frames = <PassFrame>[
      for (final lane in s.lanes)
        for (final f in lane.frames)
          if (s.measured(lane, f) && f.dx != null) f,
    ];
    final shifts = frames.map((f) => f.shift!).toList()..sort();
    final rms = frames
        .where((f) => !f.isReference)
        .map((f) => f.rmsPx)
        .whereType<double>()
        .toList();
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(value,
                    style: SkotiqTypography.monoSm
                        .copyWith(color: colors.textPrimary, height: 1.2)),
                Text(label,
                    style: SkotiqTypography.captionSm
                        .copyWith(color: colors.textMuted)),
              ]),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        row('subs registered', '${frames.length}'),
        row('largest shift',
            shifts.isEmpty ? '-' : '${shifts.last.toStringAsFixed(1)} px'),
        row(
            'mean residual',
            rms.isEmpty
                ? '-'
                : '${(rms.reduce((a, b) => a + b) / rms.length).toStringAsFixed(2)} px'),
      ],
    );
  }
}

class _PanelField extends StatelessWidget {
  const _PanelField(this.s);
  final PassSnapshot s;

  @override
  Widget build(BuildContext context) =>
      PassFrameField(snapshot: s, thumbnails: false, labelWidth: 58);
}

/// One row per filter lane: what it has kept, its integration, its median
/// FWHM and, once written, its master's noise.
class _LaneSummary extends StatelessWidget {
  const _LaneSummary(this.s);
  final PassSnapshot s;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final mono =
        SkotiqTypography.monoXs.copyWith(color: colors.textPrimary, height: 1);
    final head = SkotiqTypography.captionSm.copyWith(color: colors.textMuted);
    Widget c(String t, double w,
            {TextStyle? st, TextAlign a = TextAlign.right}) =>
        SizedBox(
            width: w,
            child: Text(t, textAlign: a, maxLines: 1, style: st ?? mono));
    String state(PassLane lane) {
      for (final span in lane.spans.reversed) {
        final st = span.stateAt(s.elapsed);
        if (st == PassStepState.done) {
          return span.stage == PassStage.write
              ? 'master written'
              : '${span.stage.label} done';
        }
        if (st == PassStepState.running) return span.stage.verb.toLowerCase();
      }
      return 'waiting';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(children: <Widget>[
          c('', 34, st: head, a: TextAlign.left),
          c('Kept', 52, st: head),
          c('Integration', 76, st: head),
          c('FWHM px', 62, st: head),
          c('Noise ADU', 70, st: head),
          const SizedBox(width: 16),
          Expanded(child: Text('State', style: head)),
        ]),
        const SizedBox(height: 4),
        for (final lane in s.lanes)
          Builder(builder: (context) {
            final measured = [
              for (final f in lane.frames)
                if (s.measured(lane, f)) f
            ];
            final kept = measured.where((f) => f.accepted).toList();
            final fwhm = kept.map((f) => f.fwhm).whereType<double>().toList()
              ..sort();
            final written = lane.span(PassStage.write).stateAt(s.elapsed) ==
                PassStepState.done;
            final active = s.activeLane == lane;
            return SizedBox(
              height: 19,
              child: Row(children: <Widget>[
                SizedBox(width: 34, child: PassFilterKey(lane.filter)),
                c(
                    measured.isEmpty
                        ? ''
                        : '${kept.length}/${lane.frames.length}',
                    52),
                c(
                    kept.isEmpty
                        ? ''
                        : passIntegration(kept.length * lane.exposureSec),
                    76),
                c(fwhm.isEmpty ? '' : fwhm[fwhm.length ~/ 2].toStringAsFixed(2),
                    62),
                c(
                    written && lane.masterNoise != null
                        ? lane.masterNoise!.toStringAsFixed(1)
                        : '',
                    70),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(state(lane),
                      maxLines: 1,
                      style: SkotiqTypography.captionSm.copyWith(
                          color:
                              active ? colors.primary : colors.textSecondary)),
                ),
              ]),
            );
          }),
      ],
    );
  }
}
