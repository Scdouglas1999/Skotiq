// The Overview tab's blocks. Each takes its view model and nothing else, so
// a test pumps one straight from the fixtures.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../localization/skotiq_localizations.dart';
import '../../data/session/session_format.dart';
import '../../night_control_contracts.dart';
import '../panel_widgets.dart';

/// The most log lines the tab lists.
const int kNightPanelLogLines = 20;

/// "Last frame · #43", its figures against the night median and the
/// histogram.
class NightLastFrameSection extends StatelessWidget {
  const NightLastFrameSection({super.key, required this.frame});

  final NightLastFrameVm? frame;

  @override
  Widget build(BuildContext context) {
    final l10n = SkotiqLocalizations.of(context);
    final frame = this.frame;
    final number = frame?.frameNumber;
    final title = number == null
        ? l10n.text('nightPanelLastFrame')
        : l10n.text(
            'nightPanelLastFrameNumber',
            params: <String, String>{'n': '$number'},
          );
    if (frame == null) {
      return NightPanelSection(
        title: title,
        children: <Widget>[NightPanelNote(l10n.text('nightPanelNoFrame'))],
      );
    }
    final hasDeltas = frame.metrics.any((m) => m.delta != null);
    final histogram = frame.histogram;
    return NightPanelSection(
      title: title,
      trailing: hasDeltas ? l10n.text('nightPanelVsMedian') : null,
      children: <Widget>[
        MetricGrid(
          items: nightMetricItems(frame.metrics, l10n),
          semanticLabel: title,
        ),
        if (histogram != null && histogram.isNotEmpty)
          NightHistogram(bins: histogram),
      ],
    );
  }
}

/// The last frame's histogram as a filled outline, 30 px tall.
class NightHistogram extends StatelessWidget {
  const NightHistogram({super.key, required this.bins});

  final List<int> bins;

  static const double height = 30;

  @override
  Widget build(BuildContext context) {
    final l10n = SkotiqLocalizations.of(context);
    final colors = context.skotiqColors;
    var peak = 0;
    for (var i = 1; i < bins.length; i++) {
      if (bins[i] > bins[peak]) peak = i;
    }
    final percent = bins.length < 2 ? 0 : (100 * peak / (bins.length - 1));
    return Semantics(
      label: l10n.text(
        'nightPanelHistogramSemantics',
        params: <String, String>{'percent': percent.round().toString()},
      ),
      excludeSemantics: true,
      child: SizedBox(
        height: height,
        width: double.infinity,
        child: CustomPaint(
          painter: _HistogramPainter(
            bins: bins,
            line: colors.primary,
            fill: colors.primary.withValues(alpha: SkotiqTokens.opacityMedium),
          ),
        ),
      ),
    );
  }
}

class _HistogramPainter extends CustomPainter {
  _HistogramPainter({
    required this.bins,
    required this.line,
    required this.fill,
  });

  final List<int> bins;
  final Color line;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    if (bins.length < 2) return;
    final top = bins.reduce(math.max);
    if (top <= 0) return;
    final path = Path()..moveTo(0, size.height);
    for (var i = 0; i < bins.length; i++) {
      final x = size.width * i / (bins.length - 1);
      final y = size.height - size.height * bins[i] / top;
      path.lineTo(x, y);
    }
    path
      ..lineTo(size.width, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = fill);
    canvas.drawPath(
      path,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_HistogramPainter old) =>
      !identical(old.bins, bins) || old.line != line || old.fill != fill;
}

/// "Session · 87 frames · 4h 21m" and its counts.
class NightSessionSection extends StatelessWidget {
  const NightSessionSection({super.key, required this.session});

  final NightSessionVm session;

  @override
  Widget build(BuildContext context) {
    final l10n = SkotiqLocalizations.of(context);
    final frames = session.frameCount;
    final elapsed = session.elapsed == null
        ? null
        : nightDuration(session.elapsed!.inSeconds.toDouble());
    final parts = <String>[
      if (frames != null)
        l10n.text(
          'nightPanelFrames',
          params: <String, String>{'count': '$frames'},
        ),
      if (elapsed != null) elapsed,
    ];
    final title = l10n.text('nightPanelSession');
    return NightPanelSection(
      title: title,
      trailing: parts.isEmpty ? null : parts.join(' · '),
      gap: SkotiqTokens.spaceXs,
      children: <Widget>[
        if (session.metrics.isEmpty)
          NightPanelNote(l10n.text('nightPanelSessionEmpty'))
        else
          MetricGrid(
            items: nightMetricItems(session.metrics, l10n),
            semanticLabel: title,
          ),
      ],
    );
  }
}

/// One line per device: a status dot, the device kind, its details.
class NightEquipmentSection extends StatelessWidget {
  const NightEquipmentSection({super.key, required this.rows});

  final List<EquipmentRowVm> rows;

  static String kindKey(EquipmentKind kind) => switch (kind) {
        EquipmentKind.camera => 'nightPanelEquipCamera',
        EquipmentKind.filterWheel => 'nightPanelEquipFilter',
        EquipmentKind.focuser => 'nightPanelEquipFocuser',
        EquipmentKind.mount => 'nightPanelEquipMount',
        EquipmentKind.guider => 'nightPanelEquipGuider',
        EquipmentKind.rotator => 'nightPanelEquipRotator',
      };

  static String statusKey(EquipmentStatus status) => switch (status) {
        EquipmentStatus.ok => 'nightPanelStatusOk',
        EquipmentStatus.attention => 'nightPanelStatusAttention',
        EquipmentStatus.fault => 'nightPanelStatusFault',
        EquipmentStatus.absent => 'nightPanelStatusAbsent',
      };

  static Color dotColor(EquipmentStatus status, SkotiqColors colors) =>
      switch (status) {
        EquipmentStatus.ok => colors.success,
        EquipmentStatus.attention => colors.warning,
        EquipmentStatus.fault => colors.error,
        EquipmentStatus.absent => colors.textMuted,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = SkotiqLocalizations.of(context);
    final colors = context.skotiqColors;
    return NightPanelSection(
      title: l10n.text('nightPanelEquipment'),
      gap: SkotiqTokens.spaceXs,
      children: <Widget>[
        for (final row in rows) _equipmentRow(row, l10n, colors),
      ],
    );
  }

  Widget _equipmentRow(
    EquipmentRowVm row,
    SkotiqLocalizations l10n,
    SkotiqColors colors,
  ) {
    final kind = l10n.text(kindKey(row.kind));
    final details = row.details.map((d) => d.resolve(l10n)).join(' · ');
    final value = details.isNotEmpty
        ? details
        : row.status == EquipmentStatus.absent
            ? l10n.text('nightPanelEquipNone')
            : (row.deviceName ?? kReadoutUnknown);
    final status = l10n.text(statusKey(row.status));
    final semantics = <String>[
      kind,
      if (row.deviceName != null) row.deviceName!,
      status,
      value,
    ].join(', ');
    return Tooltip(
      message: row.deviceName ?? kind,
      child: Semantics(
        label: semantics,
        excludeSemantics: true,
        child: Row(
          children: <Widget>[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: dotColor(row.status, colors),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            SizedBox(
              width: 62,
              child: Text(
                kind,
                style: SkotiqTypography.caption.copyWith(
                  color: colors.textMuted,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceXs),
            Expanded(
              child: Text(
                value,
                style: SkotiqTypography.monoXs.copyWith(
                  color: colors.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The sky: the safety verdict on the right, the readings below. With no
/// weather source the header says so and only what the app knows anyway
/// (the moon) is listed; forecast values carry "forecast" in their labels.
class NightConditionsSection extends StatelessWidget {
  const NightConditionsSection({super.key, required this.conditions});

  final NightConditionsVm conditions;

  @override
  Widget build(BuildContext context) {
    final l10n = SkotiqLocalizations.of(context);
    final (String? note, MetricTone? tone) = switch (conditions.source) {
      ConditionsSource.none => (
          l10n.text('nightPanelNoWeatherSource'),
          MetricTone.warning,
        ),
      ConditionsSource.device || ConditionsSource.forecast => switch (
            conditions.safe) {
          true => (l10n.text('nightPanelSafe'), MetricTone.good),
          false => (l10n.text('nightPanelUnsafe'), MetricTone.bad),
          null => conditions.source == ConditionsSource.forecast
              ? (l10n.text('nightPanelForecastOnly'), null)
              : (null, null),
        },
    };
    final title = l10n.text('nightPanelConditions');
    return NightPanelSection(
      title: title,
      trailing: note,
      trailingTone: tone,
      gap: SkotiqTokens.spaceXs,
      children: <Widget>[
        if (conditions.metrics.isNotEmpty)
          // Three columns: "set 23:09" does not fit a quarter of the panel.
          MetricGrid(
            columns: 3,
            items: nightMetricItems(conditions.metrics, l10n),
            semanticLabel: title,
          ),
      ],
    );
  }
}

/// The night's events, newest first.
class NightLogSection extends StatelessWidget {
  const NightLogSection({super.key, required this.entries});

  final List<NightLogEntryVm> entries;

  @override
  Widget build(BuildContext context) {
    final l10n = SkotiqLocalizations.of(context);
    final colors = context.skotiqColors;
    final shown = entries.take(kNightPanelLogLines);
    return NightPanelSection(
      title: l10n.text('nightPanelLog'),
      divider: false,
      gap: 3,
      children: <Widget>[
        if (entries.isEmpty) NightPanelNote(l10n.text('nightPanelLogEmpty')),
        for (final entry in shown)
          MergeSemantics(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: <Widget>[
                SizedBox(
                  width: 40,
                  child: Text(
                    nightPanelClock(entry.at),
                    style: SkotiqTypography.monoXs.copyWith(
                      color: colors.textMuted,
                    ),
                  ),
                ),
                const SizedBox(width: SkotiqTokens.spaceXs),
                Expanded(
                  child: Text(
                    entry.message.resolve(l10n),
                    style: SkotiqTypography.caption.copyWith(
                      color: entry.tone == MetricTone.neutral
                          ? colors.textSecondary
                          : nightToneColor(entry.tone, colors),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// "Before you start": one row per thing the run needs, with its state
/// mark, what was found and, where there is one, the button that fixes it.
class NightChecklistSection extends StatelessWidget {
  const NightChecklistSection({
    super.key,
    required this.items,
    required this.onAction,
  });

  final List<ChecklistItemVm> items;
  final ValueChanged<ChecklistItemVm> onAction;

  @override
  Widget build(BuildContext context) {
    final l10n = SkotiqLocalizations.of(context);
    final colors = context.skotiqColors;
    final open = items.where((i) => i.state != ChecklistItemState.ok).length;
    final blocked = items.any((i) => i.state == ChecklistItemState.blocked);
    return NightPanelSection(
      title: l10n.text('nightPanelBeforeYouStart'),
      trailing: items.isEmpty
          ? null
          : open == 0
              ? l10n.text('nightPanelAllReady')
              : l10n.text(
                  'nightPanelToLookAt',
                  params: <String, String>{'count': '$open'},
                ),
      trailingTone: items.isEmpty
          ? null
          : open == 0
              ? MetricTone.good
              : blocked
                  ? MetricTone.bad
                  : MetricTone.warning,
      gap: SkotiqTokens.spaceXs,
      children: <Widget>[
        for (final item in items) _row(item, l10n, colors),
      ],
    );
  }

  Widget _row(
    ChecklistItemVm item,
    SkotiqLocalizations l10n,
    SkotiqColors colors,
  ) {
    // Icons, not ✓ / ✕ glyphs: the UI faces have neither.
    final (mark, markKey, tone) = switch (item.state) {
      ChecklistItemState.ok => (
          LucideIcons.check,
          'nightPanelCheckOk',
          MetricTone.good,
        ),
      ChecklistItemState.attention => (
          LucideIcons.alertTriangle,
          'nightPanelCheckAttention',
          MetricTone.warning,
        ),
      ChecklistItemState.blocked => (
          LucideIcons.x,
          'nightPanelCheckBlocked',
          MetricTone.bad,
        ),
    };
    final title = item.title.resolve(l10n);
    final detail = item.detail?.resolve(l10n);
    final action = item.actionLabel?.resolve(l10n);
    final detailColor = item.state == ChecklistItemState.ok
        ? colors.textPrimary
        : nightToneColor(tone, colors);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Expanded(
          child: Semantics(
            label: <String>[
              title,
              l10n.text(markKey),
              if (detail != null) detail,
            ].join(', '),
            excludeSemantics: true,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                SizedBox(
                  width: 14,
                  child: Icon(
                    mark,
                    size: 11,
                    color: nightToneColor(tone, colors),
                  ),
                ),
                const SizedBox(width: SkotiqTokens.spaceXs),
                SizedBox(
                  width: 62,
                  child: Text(
                    title,
                    style: SkotiqTypography.caption.copyWith(
                      color: colors.textMuted,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: SkotiqTokens.spaceXs),
                Expanded(
                  child: Text(
                    detail ?? kReadoutUnknown,
                    style: SkotiqTypography.caption.copyWith(
                      color: detailColor,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (action != null) ...<Widget>[
          const SizedBox(width: SkotiqTokens.spaceXs),
          _ChecklistAction(
            label: action,
            semanticLabel: '$action, $title',
            onPressed: () => onAction(item),
          ),
        ],
      ],
    );
  }
}

/// The small link-colored button at the end of a checklist row.
class _ChecklistAction extends StatelessWidget {
  const _ChecklistAction({
    required this.label,
    required this.semanticLabel,
    required this.onPressed,
  });

  final String label;
  final String semanticLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Semantics(
      button: true,
      enabled: true,
      label: semanticLabel,
      excludeSemantics: true,
      onTap: onPressed,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
        child: ConstrainedBox(
          // The touch-target floor on phones; 24 px with a pointer.
          constraints: BoxConstraints(
            minHeight: SkotiqTouchTarget.minExtent(context, desktopExtent: 24),
            minWidth: SkotiqTouchTarget.minExtent(context),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: SkotiqTokens.spaceXs,
            ),
            child: Center(
              widthFactor: 1,
              child: Text(
                label,
                style: SkotiqTypography.labelSm.copyWith(
                  color: colors.primary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
