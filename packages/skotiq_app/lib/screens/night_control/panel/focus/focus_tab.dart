// The Focus tab (TonightFocus.dc.html): the live V-curve and its points,
// the focuser's position and moves, temperature compensation and this
// session's autofocus runs.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/skotiq_core.dart' show VCurvePoint;
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../localization/skotiq_localizations.dart';
import '../../actions/night_action_controller.dart';
import '../../data/session/session_events_provider.dart';
import '../../data/session/session_format.dart';
import '../../night_control_contracts.dart';
import '../panel_ops.dart';
import '../panel_widgets.dart';
import 'focus_panel_vm.dart';

/// Where "Settings…" goes.
const String kNightAutofocusSettingsRoute = '/settings?section=autofocus';

/// The jog buttons' steps, in board order.
const List<int> kNightFocuserJogSteps = <int>[-500, -100, -10, 10, 100, 500];

/// The most recent runs the tab lists.
const int kNightRecentRunsShown = 5;

class NightFocusTab extends ConsumerWidget {
  const NightFocusTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vm = ref.watch(nightFocusPanelProvider);
    return NightPanelBody(
      children: <Widget>[
        NightAutofocusSection(vm: vm),
        NightFocuserSection(vm: vm),
        if (vm.tempComp != null) NightTempCompSection(tempComp: vm.tempComp!),
        NightRecentRunsSection(runs: vm.recentRuns),
      ],
    );
  }
}

/// `+20`, `−18`.
String _signed(num value) =>
    value > 0 ? '+${nightGrouped(value.round())}' : nightGrouped(value.round());

class NightAutofocusSection extends ConsumerWidget {
  const NightAutofocusSection(
      {super.key,
      required this.vm,
      this.showControls = true,
      this.title,
      this.contextNote});

  final NightFocusPanelVm vm;
  final bool showControls;
  final String? title;
  final String? contextNote;

  /// The V-curve's height on the board.
  static const double chartHeight = 120;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = SkotiqLocalizations.of(context);
    final colors = context.skotiqColors;
    final running = vm.status == NightAutofocusStatus.running;
    final (String? note, MetricTone? tone) = switch (vm.status) {
      NightAutofocusStatus.running => (
          vm.point != null && vm.totalPoints != null
              ? l10n.text(
                  'nightPanelAfRunningPoint',
                  params: <String, String>{
                    'n': '${vm.point}',
                    'total': '${vm.totalPoints}',
                  },
                )
              : l10n.text('nightPanelAfRunning'),
          MetricTone.warning,
        ),
      NightAutofocusStatus.done => (
          l10n.text('nightPanelAfDone'),
          MetricTone.good,
        ),
      NightAutofocusStatus.failed => (
          l10n.text('nightPanelAfFailed'),
          MetricTone.bad,
        ),
      NightAutofocusStatus.idle => (null, null),
    };

    final String? cancelBlocked = !vm.canCommand
        ? l10n.text('nightActWhyNoHost')
        : !running
            ? l10n.text('nightPanelWhyNoAutofocus')
            : null;
    // The same gating as the bar's Autofocus button.
    final runAction = ref
        .watch(nightManualActionsProvider)
        .where((a) => a.id == ManualActionId.autofocus)
        .firstOrNull;
    final runBlocked = runAction == null || runAction.enabled
        ? null
        : runAction.disabledReason?.resolve(l10n);
    final points = vm.points;
    final latest = points.isEmpty ? null : points.length - 1;

    return NightPanelSection(
      title: title ?? l10n.text('nightPanelAutofocus'),
      trailing: note,
      trailingTone: tone,
      children: <Widget>[
        if (contextNote != null && contextNote!.isNotEmpty)
          NightPanelNote(contextNote!),
        if (points.isEmpty)
          NightPanelNote(
            l10n.text(running ? 'nightPanelAfWaiting' : 'nightPanelAfNone'),
          )
        else ...<Widget>[
          SizedBox(
            height: chartHeight,
            child: VCurveChart(
              density: VCurveChartDensity.compact,
              series: <VCurveSeries>[
                VCurveSeries(
                  points: points,
                  color: colors.primary,
                  label: l10n.text('nightPanelAutofocus'),
                  vertexPosition: vm.bestPosition,
                  vertexColor: colors.success,
                  showVertexGuide: vm.bestPosition != null,
                  highlightLatest: running,
                ),
              ],
              focusRange: vm.focusRange,
              gridColor: colors.border,
              textColor: colors.textMuted,
              repaintTick: vm.point ?? points.length,
              semanticsLabel: _chartSemantics(l10n),
            ),
          ),
          if (vm.bestPosition != null || vm.fitQuality != null)
            NightPanelNote(_fitNote(l10n), tone: MetricTone.good),
          _PointsTable(
            points: points,
            starCounts: vm.starCounts,
            highlight: running ? latest : null,
          ),
        ],
        if (showControls)
          NightPanelGrid(
            columns: 2,
            children: <Widget>[
              if (!running)
                NightPanelButton(
                  label: l10n.text('nightPanelRunAutofocus'),
                  semanticLabel: l10n.text('nightPanelRunAutofocusSemantics'),
                  disabledReason: runBlocked,
                  onPressed: runBlocked == null
                      ? () => unawaited(
                            ref
                                .read(nightActionApiProvider)
                                .run(ManualActionId.autofocus),
                          )
                      : null,
                )
              else
                NightPanelButton(
                  label: l10n.text('nightPanelCancelAutofocus'),
                  semanticLabel:
                      l10n.text('nightPanelCancelAutofocusSemantics'),
                  disabledReason: cancelBlocked,
                  onPressed: cancelBlocked == null
                      ? () => vm.startedHere
                          ? ref.read(nightActionApiProvider).cancel()
                          : nightPanelAttempt(
                              context,
                              'nightPanelErrAutofocusCancel',
                              () => ref
                                  .read(nightPanelOpsProvider)
                                  .cancelAutofocus(),
                            )
                      : null,
                ),
              NightPanelButton(
                label: l10n.text('nightPanelSettingsEllipsis'),
                semanticLabel: l10n.text('nightPanelAfSettingsSemantics'),
                onPressed: () =>
                    GoRouter.maybeOf(context)?.go(kNightAutofocusSettingsRoute),
              ),
            ],
          ),
      ],
    );
  }

  String _fitNote(SkotiqLocalizations l10n) {
    final parts = <String>[
      if (vm.fitQuality != null)
        l10n.text(
          'nightPanelAfFit',
          params: <String, String>{'r2': vm.fitQuality!.toStringAsFixed(3)},
        ),
      if (vm.bestPosition != null)
        l10n.text(
          'nightPanelAfMinimum',
          params: <String, String>{
            'position': nightGrouped(vm.bestPosition!),
            'hfr': vm.bestHfr == null
                ? kReadoutUnknown
                : vm.bestHfr!.toStringAsFixed(2),
          },
        ),
    ];
    return parts.join(' · ');
  }

  String _chartSemantics(SkotiqLocalizations l10n) {
    final parts = <String>[
      l10n.text(
        'nightPanelAfChartPoints',
        params: <String, String>{'count': '${vm.points.length}'},
      ),
      if (vm.bestPosition != null)
        l10n.text(
          'nightPanelAfMinimum',
          params: <String, String>{
            'position': nightGrouped(vm.bestPosition!),
            'hfr': vm.bestHfr == null
                ? kReadoutUnknown
                : vm.bestHfr!.toStringAsFixed(2),
          },
        ),
    ];
    return parts.join(', ');
  }
}

/// "#  pos  HFR  [stars]", the newest row in the warning tone while the run
/// goes on.
class _PointsTable extends StatelessWidget {
  const _PointsTable({
    required this.points,
    required this.starCounts,
    required this.highlight,
  });

  final List<VCurvePoint> points;
  final List<int?>? starCounts;
  final int? highlight;

  @override
  Widget build(BuildContext context) {
    final l10n = SkotiqLocalizations.of(context);
    final colors = context.skotiqColors;
    final stars = starCounts;
    final showStars = stars != null && stars.any((s) => s != null);

    Widget row(List<String> cells, Color color) {
      final style = SkotiqTypography.monoXs.copyWith(color: color);
      return Row(
        children: <Widget>[
          SizedBox(width: 22, child: Text(cells[0], style: style)),
          for (var c = 1; c < cells.length; c++)
            Expanded(
              child: Text(
                cells[c],
                style: style,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      );
    }

    return Semantics(
      container: true,
      label: l10n.text('nightPanelAfPointsTable'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ExcludeSemantics(
            child: row(
              <String>[
                '#',
                l10n.text('nightPanelAfPos'),
                l10n.text('nightPanelAfHfr'),
                if (showStars) l10n.text('nightPanelAfStars'),
              ],
              colors.textMuted,
            ),
          ),
          for (var i = 0; i < points.length; i++)
            MergeSemantics(
              child: row(
                <String>[
                  '${i + 1}',
                  nightGrouped(points[i].position),
                  points[i].hfr.toStringAsFixed(2),
                  if (showStars)
                    i < stars.length && stars[i] != null
                        ? '${stars[i]}'
                        : kReadoutUnknown,
                ],
                i == highlight ? colors.warning : colors.textPrimary,
              ),
            ),
        ],
      ),
    );
  }
}

class NightFocuserSection extends ConsumerStatefulWidget {
  const NightFocuserSection({super.key, required this.vm});

  final NightFocusPanelVm vm;

  @override
  ConsumerState<NightFocuserSection> createState() =>
      _NightFocuserSectionState();
}

class _NightFocuserSectionState extends ConsumerState<NightFocuserSection> {
  final _goTo = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _goTo.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    final l10n = SkotiqLocalizations.of(context);
    final text = _goTo.text.replaceAll(RegExp(r'\s'), '');
    final target = int.tryParse(text);
    final max = widget.vm.maxPosition;
    if (target == null || target < 0 || (max != null && target > max)) {
      setState(
        () => _error = max == null
            ? l10n.text('nightPanelEnterPosition')
            : l10n.text(
                'nightPanelEnterPositionMax',
                params: <String, String>{'max': nightGrouped(max)},
              ),
      );
      return;
    }
    setState(() => _error = null);
    await nightPanelAttempt(
      context,
      'nightPanelErrFocuser',
      () => ref.read(nightPanelOpsProvider).moveFocuserTo(target),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = SkotiqLocalizations.of(context);
    final colors = context.skotiqColors;
    final vm = widget.vm;
    final String? hostOrDevice = !vm.canCommand
        ? l10n.text('nightActWhyNoHost')
        : !vm.focuserConnected
            ? l10n.text('nightActWhyNoFocuser')
            : null;
    final String? moveBlocked = hostOrDevice ??
        (vm.status == NightAutofocusStatus.running
            ? l10n.text('nightActBusyAutofocus')
            : vm.runLive
                ? l10n.text('nightPanelWhyRunFocuser')
                : null);

    final trailing = <String>[
      if (vm.focuserName != null) vm.focuserName!,
      if (vm.focuserTemp != null) nightCelsius(vm.focuserTemp!),
    ];
    final sub = <String>[
      if (vm.maxPosition != null)
        l10n.text(
          'nightPanelOfMax',
          params: <String, String>{'max': nightGrouped(vm.maxPosition!)},
        ),
      if (vm.focuserMoving) l10n.text('nightPanelMoving'),
    ];

    return NightPanelSection(
      title: l10n.text('nightPanelFocuser'),
      trailing: !vm.focuserConnected
          ? l10n.text('nightPanelFocuserNotConnected')
          : (trailing.isEmpty ? null : trailing.join(' · ')),
      trailingTone: vm.focuserConnected ? null : MetricTone.warning,
      children: <Widget>[
        MergeSemantics(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: <Widget>[
              Semantics(
                label: l10n.text('nightPanelFocuserPosition'),
                child: Text(
                  vm.position == null
                      ? kReadoutUnknown
                      : nightGrouped(vm.position!),
                  style: SkotiqTypography.readoutMd.copyWith(
                    color: vm.position == null
                        ? colors.textMuted
                        : colors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Expanded(
                child: Text(
                  sub.join(' · '),
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textMuted,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        NightPanelGrid(
          columns: kNightFocuserJogSteps.length,
          children: <Widget>[
            for (final steps in kNightFocuserJogSteps)
              NightPanelButton(
                label: _signed(steps),
                mono: true,
                semanticLabel: l10n.text(
                  steps < 0 ? 'nightPanelJogIn' : 'nightPanelJogOut',
                  params: <String, String>{'steps': '${steps.abs()}'},
                ),
                disabledReason: moveBlocked,
                onPressed: moveBlocked == null
                    ? () => nightPanelAttempt(
                          context,
                          'nightPanelErrFocuser',
                          () => ref
                              .read(nightPanelOpsProvider)
                              .moveFocuserBy(steps),
                        )
                    : null,
              ),
          ],
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: SkotiqTextField(
                controller: _goTo,
                hint: l10n.text('nightPanelGoToHint'),
                dense: true,
                mono: true,
                enabled: moveBlocked == null,
                errorText: _error,
                keyboardType: TextInputType.number,
                onSubmitted: (_) => _go(),
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceXs),
            SizedBox(
              width: 56,
              child: NightPanelButton(
                label: l10n.text('nightPanelGoTo'),
                semanticLabel: l10n.text('nightPanelGoToSemantics'),
                disabledReason: moveBlocked,
                onPressed: moveBlocked == null ? _go : null,
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceXs),
            SizedBox(
              width: 52,
              child: NightPanelButton(
                label: l10n.text('nightPanelHalt'),
                semanticLabel: l10n.text('nightPanelHaltSemantics'),
                disabledReason: hostOrDevice,
                onPressed: hostOrDevice == null
                    ? () => nightPanelAttempt(
                          context,
                          'nightPanelErrFocuser',
                          () => ref.read(nightPanelOpsProvider).haltFocuser(),
                        )
                    : null,
              ),
            ),
          ],
        ),
        if (vm.runLive && hostOrDevice == null)
          NightPanelNote(l10n.text('nightPanelWhyRunFocuser')),
      ],
    );
  }
}

class NightTempCompSection extends StatelessWidget {
  const NightTempCompSection({super.key, required this.tempComp});

  final NightTempCompVm tempComp;

  @override
  Widget build(BuildContext context) {
    final l10n = SkotiqLocalizations.of(context);
    final c = tempComp.coefficient;
    final coefficient =
        '${c == c.roundToDouble() ? _signed(c) : nightFixed(c, 1)} /°C';
    final title = l10n.text('nightPanelTempComp');
    return NightPanelSection(
      title: title,
      trailing: l10n.text('nightPanelOn'),
      trailingTone: MetricTone.good,
      children: <Widget>[
        MetricGrid(
          columns: 3,
          semanticLabel: title,
          items: <MetricGridItem>[
            MetricGridItem(
              label: l10n.text('nightPanelCoefficient'),
              value: coefficient,
            ),
            MetricGridItem(
              label: l10n.text('nightPanelReference'),
              value: tempComp.referenceTemp == null
                  ? null
                  : nightCelsius(tempComp.referenceTemp!),
            ),
            MetricGridItem(
              label: l10n.text('nightPanelMovedSince'),
              value: tempComp.movedSince == null
                  ? null
                  : _signed(tempComp.movedSince!),
            ),
          ],
        ),
      ],
    );
  }
}

/// This session's finished autofocus runs, newest first.
class NightRecentRunsSection extends StatelessWidget {
  const NightRecentRunsSection({super.key, required this.runs});

  final List<NightAutofocusRun> runs;

  @override
  Widget build(BuildContext context) {
    final l10n = SkotiqLocalizations.of(context);
    final colors = context.skotiqColors;
    final mono = SkotiqTypography.monoXs.copyWith(color: colors.textPrimary);
    return NightPanelSection(
      title: l10n.text('nightPanelRecentRuns'),
      trailing: l10n.text('nightPanelThisSession'),
      divider: false,
      gap: 3,
      children: <Widget>[
        if (runs.isEmpty) NightPanelNote(l10n.text('nightPanelNoRuns')),
        for (final run in runs.take(kNightRecentRunsShown))
          MergeSemantics(
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 40,
                  child: Text(
                    nightPanelClock(run.at),
                    style: SkotiqTypography.caption.copyWith(
                      color: colors.textMuted,
                    ),
                  ),
                ),
                const SizedBox(width: SkotiqTokens.spaceSm),
                Expanded(
                  child: Text(
                    run.position == null
                        ? kReadoutUnknown
                        : nightGrouped(run.position!),
                    style: mono,
                  ),
                ),
                SizedBox(
                  width: 40,
                  child: Text(
                    run.hfr == null
                        ? kReadoutUnknown
                        : run.hfr!.toStringAsFixed(2),
                    style: mono,
                  ),
                ),
                SizedBox(
                  width: 56,
                  child: Text(
                    run.duration == null
                        ? ''
                        : nightDuration(run.duration!.inSeconds.toDouble()) ??
                            '',
                    textAlign: TextAlign.end,
                    style: SkotiqTypography.caption.copyWith(
                      color: colors.textMuted,
                    ),
                    maxLines: 1,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
