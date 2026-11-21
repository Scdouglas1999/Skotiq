import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'live_stack_formatters.dart';

enum _LogFilter { all, accepted, rejected }

/// Per-frame transparency log for live stacking.
///
/// Surfaces every frame evaluated by the live stacker — whether accepted or
/// rejected — together with star counts, alignment residual, translation/rotation
/// shift, sigma-clipped pixels, and the exact reason for any refusal.
class LiveStackFrameLogPanel extends ConsumerStatefulWidget {
  const LiveStackFrameLogPanel({super.key, required this.colors});

  final SkotiqColors colors;

  @override
  ConsumerState<LiveStackFrameLogPanel> createState() =>
      _LiveStackFrameLogPanelState();
}

class _LiveStackFrameLogPanelState
    extends ConsumerState<LiveStackFrameLogPanel> {
  _LogFilter _filter = _LogFilter.all;
  bool _onlySelectedFilter = false;

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final stack = ref.watch(liveStackingProvider);
    final selectedKey = stack.selectedFilterKey;
    final hasMultipleFilters = stack.availableFilters.length > 1;

    final baseEvents = _onlySelectedFilter && selectedKey != null
        ? (stack.filterStacks[selectedKey]?.events ??
            const <LiveStackFrameEvent>[])
        : stack.frameLog;

    final acceptedCount = baseEvents.where((e) => e.accepted).length;
    final rejectedCount = baseEvents.length - acceptedCount;
    final acceptanceRate =
        baseEvents.isEmpty ? null : (acceptedCount / baseEvents.length * 100.0);

    final filtered = baseEvents.where((e) {
      return switch (_filter) {
        _LogFilter.all => true,
        _LogFilter.accepted => e.accepted,
        _LogFilter.rejected => !e.accepted,
      };
    }).toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionTitle(
          icon: SkotiqIcons.history,
          title: 'Frame log',
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        SkotiqPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              ReadoutRow(
                children: <Readout>[
                  Readout(
                    value: '$acceptedCount',
                    label: 'Accepted',
                    size: ReadoutSize.sm,
                  ),
                  Readout(
                    value: '$rejectedCount',
                    label: 'Rejected',
                    size: ReadoutSize.sm,
                    valueColor: rejectedCount > 0 ? colors.warning : null,
                  ),
                  Readout(
                    value: acceptanceRate != null
                        ? '${acceptanceRate.toStringAsFixed(0)}%'
                        : kReadoutUnknown,
                    label: 'Keep rate',
                    size: ReadoutSize.sm,
                  ),
                ],
              ),
              const SizedBox(height: SkotiqTokens.spaceMd),
              Wrap(
                spacing: SkotiqTokens.spaceXs,
                runSpacing: SkotiqTokens.spaceXs,
                children: <Widget>[
                  _FilterChip(
                    label: 'All (${baseEvents.length})',
                    selected: _filter == _LogFilter.all,
                    colors: colors,
                    onTap: () => setState(() => _filter = _LogFilter.all),
                  ),
                  _FilterChip(
                    label: 'Accepted ($acceptedCount)',
                    selected: _filter == _LogFilter.accepted,
                    colors: colors,
                    onTap: () => setState(() => _filter = _LogFilter.accepted),
                  ),
                  _FilterChip(
                    label: 'Rejected ($rejectedCount)',
                    selected: _filter == _LogFilter.rejected,
                    colors: colors,
                    onTap: () => setState(() => _filter = _LogFilter.rejected),
                  ),
                ],
              ),
              if (hasMultipleFilters && selectedKey != null) ...<Widget>[
                const SizedBox(height: SkotiqTokens.spaceSm),
                SkotiqSwitchRow(
                  label:
                      'Only ${liveStackFilterDisplayName(selectedKey)} filter',
                  value: _onlySelectedFilter,
                  onChanged: (v) => setState(() => _onlySelectedFilter = v),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        Expanded(
          child: filtered.isEmpty
              ? EmptyState.compact(
                  icon: SkotiqIcons.history,
                  title: baseEvents.isEmpty
                      ? 'No frames evaluated yet'
                      : 'No matching frames',
                  body: baseEvents.isEmpty
                      ? 'Each sub-exposure aligned or skipped by the stacker '
                          'appears here with its residual, shift, and rejection '
                          'reason.'
                      : 'Switch the filter above to see the other frames.',
                )
              : ListView.separated(
                  itemCount: filtered.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(height: SkotiqTokens.spaceSm),
                  itemBuilder: (context, index) => _FrameEventRow(
                    event: filtered[index],
                    colors: colors,
                  ),
                ),
        ),
      ],
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.colors,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final SkotiqColors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color:
              selected ? colors.primary.withValues(alpha: 0.16) : colors.well,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
          border: Border.all(
            color: selected
                ? colors.primary.withValues(alpha: 0.7)
                : colors.border,
          ),
        ),
        child: Text(
          label,
          style: SkotiqTypography.caption.copyWith(
            color: selected ? colors.textPrimary : colors.textSecondary,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

class _FrameEventRow extends StatelessWidget {
  const _FrameEventRow({required this.event, required this.colors});

  final LiveStackFrameEvent event;
  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    final local = event.timestamp.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    final timeStr =
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
    final dotColor = liveStackFilterDotColor(event.filterKey, colors);

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.well,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        border: Border.all(
          color: event.accepted
              ? colors.border
              : colors.warning.withValues(alpha: 0.45),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              StatusDot(
                color: event.accepted ? colors.success : colors.warning,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  event.sourceLabel,
                  style: SkotiqTypography.labelSm.copyWith(
                    color: colors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: dotColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      liveStackFilterDisplayName(event.filterKey),
                      style: SkotiqTypography.monoCaption.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Text(
                timeStr,
                style: SkotiqTypography.monoCaption.copyWith(
                  color: colors.textMuted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (event.accepted)
            Wrap(
              spacing: 10,
              runSpacing: 4,
              children: <Widget>[
                _MetricTag(
                  label: 'Res',
                  value: event.sequenceIndex <= 1
                      ? 'Ref'
                      : '${event.alignmentResidualPx.toStringAsFixed(2)} px',
                  colors: colors,
                ),
                if (event.matchedPairs > 0)
                  _MetricTag(
                    label: 'Stars',
                    value: '${event.inlierPairs}/${event.matchedPairs}',
                    colors: colors,
                  ),
                if (event.sequenceIndex > 1)
                  _MetricTag(
                    label: 'Shift',
                    value:
                        '${event.shiftXPx >= 0 ? '+' : ''}${event.shiftXPx.toStringAsFixed(1)}, '
                        '${event.shiftYPx >= 0 ? '+' : ''}${event.shiftYPx.toStringAsFixed(1)}',
                    colors: colors,
                  ),
                if (event.sequenceIndex > 1 && event.rotationDeg.abs() >= 0.005)
                  _MetricTag(
                    label: 'Rot',
                    value: '${event.rotationDeg.toStringAsFixed(2)}°',
                    colors: colors,
                  ),
                if (event.sigmaRejectedPixels > 0)
                  _MetricTag(
                    label: 'Clip',
                    value: formatPixelCount(event.sigmaRejectedPixels),
                    colors: colors,
                  ),
              ],
            )
          else
            Text(
              event.rejectionReason ?? 'Frame rejected',
              style: SkotiqTypography.caption.copyWith(
                color: colors.warning,
              ),
            ),
        ],
      ),
    );
  }
}

class _MetricTag extends StatelessWidget {
  const _MetricTag({
    required this.label,
    required this.value,
    required this.colors,
  });

  final String label;
  final String value;
  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          '$label ',
          style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
        ),
        Text(
          value,
          style: SkotiqTypography.monoCaption.copyWith(
            color: colors.textSecondary,
          ),
        ),
      ],
    );
  }
}
