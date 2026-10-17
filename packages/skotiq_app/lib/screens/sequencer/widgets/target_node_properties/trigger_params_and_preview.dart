part of '../target_node_properties.dart';

class _ParamsEditor extends StatelessWidget {
  final SkotiqColors colors;
  final TargetTrigger trigger;
  final ValueChanged<TargetTrigger> onChanged;

  const _ParamsEditor({
    required this.colors,
    required this.trigger,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    switch (trigger) {
      case AltitudeAboveTrigger(altitudeDeg: final v):
        return _altitudeInput(v, (n) => onChanged(AltitudeAboveTrigger(n)));
      case AltitudeBelowTrigger(altitudeDeg: final v):
        return _altitudeInput(v, (n) => onChanged(AltitudeBelowTrigger(n)));
      case TimeAfterTrigger(unixSeconds: final v):
        return _timeInput(v, (n) => onChanged(TimeAfterTrigger(n)));
      case TimeBeforeTrigger(unixSeconds: final v):
        return _timeInput(v, (n) => onChanged(TimeBeforeTrigger(n)));
      case HourAngleBetweenTrigger(minHa: final lo, maxHa: final hi):
        return Row(
          children: [
            Expanded(
              child: NodeNumberInput(
                colors: colors,
                value: lo,
                suffix: 'h',
                min: -12,
                max: 12,
                decimals: 2,
                onChanged: (n) =>
                    onChanged(HourAngleBetweenTrigger(minHa: n, maxHa: hi)),
              ),
            ),
            const SizedBox(width: 8),
            Text(' to ',
                style: TextStyle(
                    fontSize: SkotiqTypography.fontSize12,
                    color: colors.textMuted)),
            const SizedBox(width: 8),
            Expanded(
              child: NodeNumberInput(
                colors: colors,
                value: hi,
                suffix: 'h',
                min: -12,
                max: 12,
                decimals: 2,
                onChanged: (n) =>
                    onChanged(HourAngleBetweenTrigger(minHa: lo, maxHa: n)),
              ),
            ),
          ],
        );
      case AndTrigger(children: final cs) || OrTrigger(children: final cs):
        final isAnd = trigger is AndTrigger;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ...cs.asMap().entries.map(
                  (e) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: _TriggerBuilder(
                            colors: colors,
                            trigger: e.value,
                            onChanged: (next) {
                              final newList = List<TargetTrigger>.from(cs);
                              newList[e.key] = next;
                              onChanged(isAnd
                                  ? AndTrigger(newList)
                                  : OrTrigger(newList));
                            },
                          ),
                        ),
                        IconButton(
                          icon: Icon(LucideIcons.x,
                              size: 14, color: colors.textMuted),
                          tooltip: 'Remove sub-trigger',
                          onPressed: () {
                            final newList = List<TargetTrigger>.from(cs)
                              ..removeAt(e.key);
                            onChanged(isAnd
                                ? AndTrigger(newList)
                                : OrTrigger(newList));
                          },
                        ),
                      ],
                    ),
                  ),
                ),
            TextButton.icon(
              onPressed: () {
                final newList = List<TargetTrigger>.from(cs)
                  ..add(const AltitudeAboveTrigger(35.0));
                onChanged(isAnd ? AndTrigger(newList) : OrTrigger(newList));
              },
              icon: Icon(LucideIcons.plus, size: 14, color: colors.primary),
              label: Text('Add sub-trigger',
                  style: TextStyle(
                      fontSize: SkotiqTypography.fontSize12,
                      color: colors.primary)),
            ),
          ],
        );
    }
  }

  Widget _altitudeInput(double value, ValueChanged<double> onChanged) {
    return NodeNumberInput(
      colors: colors,
      value: value,
      suffix: '°',
      min: -90,
      max: 90,
      decimals: 1,
      onChanged: onChanged,
    );
  }

  Widget _timeInput(int unixSecs, ValueChanged<int> onChanged) {
    return _TimeInputButton(
      colors: colors,
      unixSecs: unixSecs,
      onChanged: onChanged,
    );
  }
}

/// Small leaf widget so `showTimePicker` has a real BuildContext to
/// anchor against.
class _TimeInputButton extends StatelessWidget {
  final SkotiqColors colors;
  final int unixSecs;
  final ValueChanged<int> onChanged;

  const _TimeInputButton({
    required this.colors,
    required this.unixSecs,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final dt = DateTime.fromMillisecondsSinceEpoch(unixSecs * 1000);
    final hhmm =
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    return GestureDetector(
      onTap: () async {
        final picked = await showTimePicker(
          context: context,
          initialTime: TimeOfDay.fromDateTime(dt),
        );
        if (picked != null) {
          final now = DateTime.now();
          var target = DateTime(
              now.year, now.month, now.day, picked.hour, picked.minute);
          if (target.isBefore(now)) {
            target = target.add(const Duration(days: 1));
          }
          onChanged(target.millisecondsSinceEpoch ~/ 1000);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: colors.surfaceAlt,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          border: Border.all(color: colors.border),
        ),
        child: Row(
          children: [
            Icon(LucideIcons.clock, size: 14, color: colors.textMuted),
            const SizedBox(width: 8),
            Text(hhmm,
                style: TextStyle(
                    fontSize: SkotiqTypography.fontSize13,
                    color: colors.textPrimary)),
          ],
        ),
      ),
    );
  }
}

/// Live preview text for the current trigger. Mirrors the Rust
/// `TargetTrigger::label` plus a short evaluation against the live
/// observer location.
class _TriggerPreview extends ConsumerWidget {
  final SkotiqColors colors;
  final TargetHeaderNode node;
  final TargetTrigger trigger;
  final bool isStart;

  const _TriggerPreview({
    required this.colors,
    required this.node,
    required this.trigger,
    required this.isStart,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = trigger.label;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.eye, size: 12, color: colors.textMuted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${isStart ? "Starts when" : "Ends when"} $summary',
              style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  color: colors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

String _kindKey(TargetTrigger t) {
  switch (t) {
    case AltitudeAboveTrigger():
      return 'AltitudeAbove';
    case AltitudeBelowTrigger():
      return 'AltitudeBelow';
    case TimeAfterTrigger():
      return 'TimeAfter';
    case TimeBeforeTrigger():
      return 'TimeBefore';
    case AndTrigger():
      return 'And';
    case OrTrigger():
      return 'Or';
    case HourAngleBetweenTrigger():
      return 'HourAngleBetween';
  }
}

/// Build a sensible default trigger for the given kind, preserving as
/// much of the user's existing config as possible (e.g. switching
/// AltitudeAbove -> AltitudeBelow keeps the threshold).
TargetTrigger _defaultForKind(String kind, {required TargetTrigger current}) {
  double currentAlt() {
    if (current is AltitudeAboveTrigger) return current.altitudeDeg;
    if (current is AltitudeBelowTrigger) return current.altitudeDeg;
    return 35.0;
  }

  switch (kind) {
    case 'AltitudeAbove':
      return AltitudeAboveTrigger(currentAlt());
    case 'AltitudeBelow':
      return AltitudeBelowTrigger(currentAlt());
    case 'TimeAfter':
      return TimeAfterTrigger(
          (DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch /
                  1000)
              .toInt());
    case 'TimeBefore':
      return TimeBeforeTrigger(
          (DateTime.now().add(const Duration(hours: 6)).millisecondsSinceEpoch /
                  1000)
              .toInt());
    case 'HourAngleBetween':
      return const HourAngleBetweenTrigger(minHa: -1, maxHa: 1);
    case 'And':
      return AndTrigger([current]);
    case 'Or':
      return OrTrigger([current]);
    default:
      return current;
  }
}

// Integration budget editor.
//
// The section is toggle-gated: when the toggle is off, the node has no
// budget configured. When on, the user can set a total time and add
// per-filter rows (Absolute seconds or Ratio). The live preview shows
// the resolved per-filter caps so the user can sanity-check before
// pressing Save.
