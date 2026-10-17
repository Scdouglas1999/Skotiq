part of '../target_node_properties.dart';

class _TriggerSection extends ConsumerWidget {
  final SkotiqColors colors;
  final TargetHeaderNode node;
  final bool isStart;

  const _TriggerSection({
    required this.colors,
    required this.node,
    required this.isStart,
  });

  TargetTrigger? get _current => isStart ? node.startWhen : node.endWhen;
  String get _label => isStart ? 'Start when' : 'End when';
  String get _helpText => isStart
      ? 'Wait until this condition is true before imaging the target. '
          'Common: AltitudeAbove(35°).'
      : 'Stop imaging once this condition becomes true. '
          'Common: AltitudeBelow(30°).';

  void _setTrigger(WidgetRef ref, TargetTrigger? next) {
    if (isStart) {
      ref.read(currentSequenceProvider.notifier).updateNode(
            node.copyWith(startWhen: next),
          );
    } else {
      ref.read(currentSequenceProvider.notifier).updateNode(
            node.copyWith(endWhen: next),
          );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = _current;
    final enabled = current != null;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isStart ? LucideIcons.playCircle : LucideIcons.stopCircle,
                size: 14,
                color: colors.textMuted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _label,
                  style: TextStyle(
                    fontSize: Responsive.fontSize(context, 12),
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
              ),
              NodeToggleSwitch(
                colors: colors,
                value: enabled,
                onChanged: (on) {
                  if (on) {
                    // Default trigger: AltitudeAbove(35°) for start,
                    // AltitudeBelow(30°) for end — matches the SGP/NINA
                    // defaults most amateur users want.
                    _setTrigger(
                        ref,
                        isStart
                            ? const AltitudeAboveTrigger(35.0)
                            : const AltitudeBelowTrigger(30.0));
                  } else {
                    _setTrigger(ref, null);
                  }
                },
              ),
            ],
          ),
          if (current != null) ...[
            const SizedBox(height: 12),
            _TriggerBuilder(
              colors: colors,
              trigger: current,
              onChanged: (next) => _setTrigger(ref, next),
            ),
            const SizedBox(height: 8),
            _TriggerPreview(
              colors: colors,
              node: node,
              trigger: current,
              isStart: isStart,
            ),
          ] else ...[
            const SizedBox(height: 6),
            Text(_helpText,
                style: TextStyle(
                    fontSize: SkotiqTypography.fontSize11,
                    color: colors.textMuted)),
          ],
        ],
      ),
    );
  }
}

/// Trigger editor — dropdown for kind + inline parameter inputs. For
/// compound (And/Or) kinds, renders a list of nested editors so the user
/// can build "wait for X AND Y" with another tap.
class _TriggerBuilder extends StatelessWidget {
  final SkotiqColors colors;
  final TargetTrigger trigger;
  final ValueChanged<TargetTrigger> onChanged;

  const _TriggerBuilder({
    required this.colors,
    required this.trigger,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AccessibleDropdown<String>(
          isExpanded: true,
          value: _kindKey(trigger),
          dropdownColor: colors.surfaceAlt,
          style: TextStyle(
              fontSize: SkotiqTypography.fontSize12, color: colors.textPrimary),
          items: const [
            DropdownMenuItem(
                value: 'AltitudeAbove', child: Text('Altitude above')),
            DropdownMenuItem(
                value: 'AltitudeBelow', child: Text('Altitude below')),
            DropdownMenuItem(value: 'TimeAfter', child: Text('Time after')),
            DropdownMenuItem(value: 'TimeBefore', child: Text('Time before')),
            DropdownMenuItem(
                value: 'HourAngleBetween', child: Text('Hour angle in range')),
            DropdownMenuItem(value: 'And', child: Text('All of (AND)')),
            DropdownMenuItem(value: 'Or', child: Text('Any of (OR)')),
          ],
          onChanged: (next) {
            if (next == null) return;
            onChanged(_defaultForKind(next, current: trigger));
          },
        ),
        const SizedBox(height: 8),
        _ParamsEditor(
          colors: colors,
          trigger: trigger,
          onChanged: onChanged,
        ),
      ],
    );
  }
}
