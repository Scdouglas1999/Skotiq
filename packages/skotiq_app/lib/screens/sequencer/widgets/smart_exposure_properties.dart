// SmartExposure properties editor.
//
// Tabular per-filter editor for the SmartExposureNode. Each row holds one
// FilterPlan (filter, count, duration, gain, offset, binning, dither cadence)
// and rows are drag-and-drop reorderable to change the rotation order.
//
// The editor wraps its inputs in IgnorePointer-on-canEdit-off the same way
// ExposureProperties does so a running sequence can't be
// mutated through this surface.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../accessible_dropdown.dart';
import '../../imaging/widgets/depthlock/depthlock_presentation.dart';
import 'node_property_widgets.dart';

class SmartExposureProperties extends ConsumerWidget {
  final SkotiqColors colors;
  final SmartExposureNode node;

  const SmartExposureProperties({
    super.key,
    required this.colors,
    required this.node,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(activeEquipmentProfileProvider);
    final filterNames = profile?.filterNames ?? <String>[];
    final canEdit = ref.watch(canEditSequenceProvider);
    final exposureContext =
        ref.watch(smartNightExposureContextProvider).valueOrNull;

    return IgnorePointer(
      ignoring: !canEdit,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Smart Exposure',
            style: TextStyle(
              fontSize: Responsive.fontSize(context, 13),
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'One row per filter. Drag rows to reorder rotation.',
            style: TextStyle(
              fontSize: Responsive.fontSize(context, 11),
              color: colors.textMuted,
            ),
          ),
          const SizedBox(height: 12),

          // Filter plan list
          _PlanList(
            colors: colors,
            node: node,
            filterNames: filterNames,
            exposureContext: exposureContext,
            loopMode: node.loopUntilStopped && node.rotateFilters,
            onPlansChanged: (newPlans) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(plans: newPlans),
                  );
            },
          ),

          // Add row button
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () {
              final defaultFilter =
                  filterNames.isNotEmpty ? filterNames.first : '';
              final defaultIndex = filterNames.isNotEmpty ? 0 : null;
              final durationSecs = _recommendedExposureSeconds(
                exposureContext,
                defaultFilter,
                fallbackSecs: 60.0,
              );
              final newPlans = List<FilterPlan>.from(node.plans)
                ..add(FilterPlan(
                  filterName: defaultFilter,
                  filterIndex: defaultIndex,
                  count: 10,
                  durationSecs: durationSecs,
                ));
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(plans: newPlans),
                  );
            },
            icon: Icon(LucideIcons.plus, size: 14, color: colors.primary),
            label: Text(
              'Add Filter Plan',
              style: TextStyle(
                fontSize: Responsive.fontSize(context, 12),
                color: colors.primary,
              ),
            ),
          ),

          // Author the counts from what the bound goals still need, rather
          // than from a guess.
          const SizedBox(height: 8),
          PlanCountsFromGoalsButton(
            colors: colors,
            node: node,
            onPlansChanged: (newPlans) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(plans: newPlans),
                  );
            },
          ),

          // Global toggles
          const SizedBox(height: 16),
          NodePropertyField(
            colors: colors,
            label: 'Rotate filters',
            child: NodeToggleSwitch(
              colors: colors,
              value: node.rotateFilters,
              onChanged: (v) {
                // Turning rotation off must also drop loop-until-stopped:
                // loop mode is only reachable through the "Switch Filter
                // Every Frame" toggle (shown only while rotate is on), so a
                // stranded loopUntilStopped=true would lock every Count to
                // "— looping" with no control left to clear it.
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(
                        rotateFilters: v,
                        loopUntilStopped: v ? node.loopUntilStopped : false,
                      ),
                    );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              node.rotateFilters
                  ? 'Round-robin: RGRGRG…'
                  : 'Drain each filter before moving on: RRRGGGBBB…',
              style: TextStyle(
                fontSize: Responsive.fontSize(context, 11),
                color: colors.textMuted,
              ),
            ),
          ),

          NodePropertyField(
            colors: colors,
            label: 'Dither on Filter Change',
            child: NodeToggleSwitch(
              colors: colors,
              value: node.ditherOnFilterChange,
              onChanged: (v) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(ditherOnFilterChange: v),
                    );
              },
            ),
          ),

          if (node.rotateFilters) ...[
            NodePropertyField(
              colors: colors,
              label: 'Switch Filter Every Frame',
              child: NodeToggleSwitch(
                colors: colors,
                // Drives "loop until stopped" mode: 1 sub per filter,
                // round-robin, looping until the target's window ends (or the
                // integration budget). In this mode the per-filter Counts and
                // Batch Size are irrelevant — the loop is bounded by time, not
                // by drained counts. Off → today's count-draining behaviour.
                value: node.loopUntilStopped,
                onChanged: (v) {
                  ref.read(currentSequenceProvider.notifier).updateNode(
                        // Force a clean 1-sub rotation when enabling. We leave
                        // batchSize at its stored value when turning OFF so the
                        // numeric Batch Size control reappears as the user left
                        // it (the Rust executor only coerces it while loop mode
                        // is on).
                        node.copyWith(
                          loopUntilStopped: v,
                          batchSize: v ? 1 : node.batchSize,
                        ),
                      );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                node.loopUntilStopped
                    ? '1 sub per filter, looping until the target’s window '
                        'ends (or the integration budget). Per-filter Counts are '
                        'ignored in this mode.'
                    : 'Takes Batch Size subs per filter before rotating to the next.',
                style: TextStyle(
                  fontSize: Responsive.fontSize(context, 11),
                  color: colors.textMuted,
                ),
              ),
            ),
            // The unbounded-loop hint: in loop mode, if there's neither an
            // integration budget nor a bounding target window, the executor
            // will fail closed (errors-are-a-feature). Surface that here so the
            // user fixes it at edit time rather than at runtime.
            if (node.loopUntilStopped &&
                node.integrationBudgetSecs <= 0 &&
                !_hasBoundingTargetWindow(ref))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: colors.warning.withValues(alpha: 0.12),
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline8),
                    border: Border.all(
                        color: colors.warning.withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(LucideIcons.alertTriangle,
                          size: 14, color: colors.warning),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Nothing bounds this loop. Set an integration budget '
                          'below, or place this node under a target with an end '
                          'condition (ends-when / ends-before) — otherwise the '
                          'run will refuse to start.',
                          style: TextStyle(
                            fontSize: Responsive.fontSize(context, 11),
                            color: colors.warning,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            // The numeric Batch Size only matters in the (non-loop) case. It's
            // hidden in loop mode (batch is forced to 1). Always shown in
            // non-loop mode so it can be raised from the default of 1 — a batch
            // size of 1 (one sub per visit before rotating) is perfectly valid.
            if (!node.loopUntilStopped)
              NodePropertyField(
                colors: colors,
                label: 'Batch Size (per visit)',
                child: NodeNumberInput(
                  colors: colors,
                  value: node.batchSize.toDouble(),
                  min: 1,
                  max: 999,
                  onChanged: (v) {
                    ref.read(currentSequenceProvider.notifier).updateNode(
                          node.copyWith(batchSize: v.toInt().clamp(1, 999)),
                        );
                  },
                ),
              ),
          ],

          // Integration budget
          const SizedBox(height: 12),
          _BudgetInput(
            colors: colors,
            node: node,
            onChanged: (secs) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(integrationBudgetSecs: secs),
                  );
            },
          ),

          // Estimate summary
          const SizedBox(height: 12),
          _EstimateSummary(colors: colors, node: node),
        ],
      ),
    );
  }

  /// True when this node sits (directly or transitively) under a
  /// [TargetHeaderNode] that has an end condition — `endWhen` (an
  /// altitude/time crossing trigger) or the legacy `endBefore` wall-clock
  /// cutoff. In loop-until-stopped mode that target window is what bounds the
  /// otherwise-unbounded rotation, so the editor only warns when no such
  /// window (and no integration budget) exists.
  ///
  /// Walks parents via [SequenceNode.parentId]; cheap (depth is small) and
  /// runs only while the warning predicate is being evaluated.
  bool _hasBoundingTargetWindow(WidgetRef ref) {
    final sequence = ref.read(currentSequenceProvider);
    if (sequence == null) return false;
    final nodes = sequence.nodes;
    var currentId = node.parentId;
    final seen = <String>{};
    while (currentId != null && seen.add(currentId)) {
      final parent = nodes[currentId];
      if (parent == null) break;
      if (parent is TargetHeaderNode &&
          (parent.endWhen != null || parent.endBefore != null)) {
        return true;
      }
      currentId = parent.parentId;
    }
    return false;
  }
}

class _PlanList extends StatelessWidget {
  final SkotiqColors colors;
  final SmartExposureNode node;
  final List<String> filterNames;
  final SmartNightExposureContext? exposureContext;

  /// When true (loop-until-stopped), per-filter Count inputs are replaced by a
  /// read-only "looping" note because the counts are ignored.
  final bool loopMode;
  final ValueChanged<List<FilterPlan>> onPlansChanged;

  const _PlanList({
    required this.colors,
    required this.node,
    required this.filterNames,
    required this.exposureContext,
    required this.loopMode,
    required this.onPlansChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (node.plans.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colors.surfaceAlt,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          border: Border.all(color: colors.border),
        ),
        child: Row(
          children: [
            Icon(LucideIcons.alertCircle, size: 14, color: colors.textMuted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'No filter plans yet — add one below.',
                style: TextStyle(
                  fontSize: Responsive.fontSize(context, 12),
                  color: colors.textMuted,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: node.plans.length,
      onReorderItem: (oldIndex, newIndex) {
        final newPlans = List<FilterPlan>.from(node.plans);
        final moved = newPlans.removeAt(oldIndex);
        newPlans.insert(newIndex, moved);
        onPlansChanged(newPlans);
      },
      itemBuilder: (context, index) {
        final plan = node.plans[index];
        return _PlanRow(
          key: ValueKey('smart-exposure-plan-$index-${plan.filterName}'),
          colors: colors,
          plan: plan,
          index: index,
          filterNames: filterNames,
          exposureContext: exposureContext,
          loopMode: loopMode,
          onChanged: (updated) {
            final newPlans = List<FilterPlan>.from(node.plans);
            newPlans[index] = updated;
            onPlansChanged(newPlans);
          },
          onDelete: () {
            final newPlans = List<FilterPlan>.from(node.plans)..removeAt(index);
            onPlansChanged(newPlans);
          },
        );
      },
    );
  }
}

class _PlanRow extends StatelessWidget {
  final SkotiqColors colors;
  final FilterPlan plan;
  final int index;
  final List<String> filterNames;
  final SmartNightExposureContext? exposureContext;
  final bool loopMode;
  final ValueChanged<FilterPlan> onChanged;
  final VoidCallback onDelete;

  const _PlanRow({
    super.key,
    required this.colors,
    required this.plan,
    required this.index,
    required this.filterNames,
    required this.exposureContext,
    required this.loopMode,
    required this.onChanged,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final recommendation = exposureContext?.recommendForFilter(plan.filterName);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.all(10),
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
                ReorderableDragStartListener(
                  index: index,
                  child: Icon(
                    LucideIcons.gripVertical,
                    size: 16,
                    color: colors.textMuted,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(child: _buildFilterDropdown(context)),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: onDelete,
                  icon: Icon(
                    LucideIcons.trash2,
                    size: 14,
                    color: colors.error,
                  ),
                  tooltip: 'Remove plan',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            const SizedBox(height: 6),
            _FieldPair(
              first: NodePropertyField(
                colors: colors,
                label: 'Count',
                // Loop-until-stopped ignores per-filter counts — surface a
                // read-only "looping" placeholder instead of an editable
                // field so the user isn't misled into tuning a number that
                // does nothing.
                child: loopMode
                    ? Container(
                        height: 38,
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: colors.surface,
                          borderRadius:
                              BorderRadius.circular(SkotiqTokens.radiusInline8),
                          border: Border.all(color: colors.border),
                        ),
                        child: Text(
                          '— looping',
                          style: TextStyle(
                            fontSize: Responsive.fontSize(context, 12),
                            color: colors.textMuted,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      )
                    : NodeNumberInput(
                        colors: colors,
                        value: plan.count.toDouble(),
                        min: 0,
                        max: 9999,
                        onChanged: (v) =>
                            onChanged(plan.copyWith(count: v.toInt())),
                      ),
              ),
              second: NodePropertyField(
                colors: colors,
                label: 'Duration',
                child: NodeNumberInput(
                  colors: colors,
                  value: plan.durationSecs,
                  suffix: 's',
                  min: 0.001,
                  max: 3600,
                  decimals: 1,
                  onChanged: (v) => onChanged(plan.copyWith(durationSecs: v)),
                ),
              ),
            ),
            if (recommendation != null) ...[
              const SizedBox(height: 2),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => onChanged(
                    plan.copyWith(durationSecs: recommendation.seconds),
                  ),
                  icon: Icon(
                    LucideIcons.sparkles,
                    size: 13,
                    color: colors.primary,
                  ),
                  label: Text(
                    'Suggested ${_formatExposureSeconds(recommendation.seconds)}',
                    style: TextStyle(
                      fontSize: Responsive.fontSize(context, 11),
                      color: colors.primary,
                    ),
                  ),
                ),
              ),
            ],
            _FieldPair(
              first: NodePropertyField(
                colors: colors,
                label: 'Gain',
                child: NodeNumberInput(
                  colors: colors,
                  value: (plan.gain ?? 0).toDouble(),
                  min: 0,
                  max: 1000,
                  onChanged: (v) => onChanged(plan.copyWith(gain: v.toInt())),
                ),
              ),
              second: NodePropertyField(
                colors: colors,
                label: 'Offset',
                child: NodeNumberInput(
                  colors: colors,
                  value: (plan.offset ?? 0).toDouble(),
                  min: 0,
                  max: 1000,
                  onChanged: (v) => onChanged(plan.copyWith(offset: v.toInt())),
                ),
              ),
            ),
            _FieldPair(
              first: NodePropertyField(
                colors: colors,
                label: 'Binning',
                child: NodeDropdown<BinningMode>(
                  colors: colors,
                  value: plan.binning,
                  items: BinningMode.values,
                  labelBuilder: (b) => b.label,
                  onChanged: (v) => onChanged(plan.copyWith(binning: v)),
                ),
              ),
              second: NodePropertyField(
                colors: colors,
                label: 'Dither every',
                child: NodeNumberInput(
                  colors: colors,
                  value: (plan.ditherEvery ?? 0).toDouble(),
                  suffix: ' frames',
                  min: 0,
                  max: 100,
                  onChanged: (v) {
                    final n = v.toInt();
                    onChanged(plan.copyWith(ditherEvery: n == 0 ? null : n));
                  },
                ),
              ),
            ),
            DepthGoalSelector(
              colors: colors,
              plan: plan,
              loopMode: loopMode,
              onChanged: onChanged,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterDropdown(BuildContext context) {
    if (filterNames.isEmpty) {
      // No profile filter wheel — fall back to a free-text input so the
      // user can still author rows offline. They'll be invalid until a
      // filter wheel is configured (SmartExposureFilterWheelMissingRule
      // catches this).
      return NodeTextInput(
        colors: colors,
        value: plan.filterName,
        hint: 'Filter name (no profile filters)',
        onChanged: (v) => onChanged(plan.copyWith(filterName: v)),
      );
    }

    // Resolve current selection by name → index, or fall back to the
    // first filter when the persisted name no longer matches the profile
    // (e.g. profile was edited after the plan was created).
    final currentIndex = filterNames.indexOf(plan.filterName);
    final effectiveIndex = currentIndex >= 0 ? currentIndex : 0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border),
      ),
      child: DropdownButtonHideUnderline(
        child: AccessibleDropdown<int>(
          value: effectiveIndex,
          isExpanded: true,
          icon:
              Icon(LucideIcons.chevronDown, size: 14, color: colors.textMuted),
          dropdownColor: colors.surface,
          // Named family: a `DropdownButton`'s own `style` replaces the
          // ambient one rather than merging with it, so a bare TextStyle
          // here drops the app font and the selected filter renders in
          // whatever the platform falls back to - tofu boxes where "Ha"
          // and "OIII" should be.
          style: TextStyle(
            fontFamily: SkotiqTypography.fontFamily,
            fontSize: Responsive.fontSize(context, 12),
            color: colors.textPrimary,
          ),
          items: [
            for (var i = 0; i < filterNames.length; i++)
              DropdownMenuItem(
                value: i,
                child: Text(filterNames[i]),
              ),
          ],
          onChanged: (newIndex) {
            if (newIndex == null) return;
            onChanged(plan.copyWith(
              filterName: filterNames[newIndex],
              filterIndex: newIndex,
            ));
          },
        ),
      ),
    );
  }
}

/// Two labelled fields side by side, stacked when the pane is too narrow to
/// hold both.
///
/// The properties pane is about 230px of content at its default width, which
/// is not enough for two of these: the "Duration" label wrapped onto two
/// lines and its own value was clipped to the first digit of "180.0", and
/// "Dither every ... frames" overflowed its row outright. Widen the pane and
/// they pair up again.
class _FieldPair extends StatelessWidget {
  const _FieldPair({required this.first, required this.second});

  final Widget first;
  final Widget second;

  /// Below this, a pair becomes two rows. Each half needs room for a label
  /// that does not wrap, the gap, and a field wide enough for its value and
  /// its unit.
  static const double breakpoint = 320;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < breakpoint) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [first, second],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: first),
            const SizedBox(width: 8),
            Expanded(child: second),
          ],
        );
      },
    );
  }
}

class _BudgetInput extends StatefulWidget {
  final SkotiqColors colors;
  final SmartExposureNode node;
  final ValueChanged<double> onChanged;

  const _BudgetInput({
    required this.colors,
    required this.node,
    required this.onChanged,
  });

  @override
  State<_BudgetInput> createState() => _BudgetInputState();
}

class _BudgetInputState extends State<_BudgetInput> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.node.integrationBudgetSecs > 0
          ? formatHumanDurationSecs(widget.node.integrationBudgetSecs)
          : '',
    );
  }

  @override
  void didUpdateWidget(covariant _BudgetInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.node.integrationBudgetSecs !=
        widget.node.integrationBudgetSecs) {
      _controller.text = widget.node.integrationBudgetSecs > 0
          ? formatHumanDurationSecs(widget.node.integrationBudgetSecs)
          : '';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Integration Budget (optional)',
          style: TextStyle(
            fontSize: Responsive.fontSize(context, 12),
            color: colors.textPrimary,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: colors.surfaceAlt,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            border: Border.all(color: colors.border),
          ),
          child: TextField(
            controller: _controller,
            style: TextStyle(
              fontSize: Responsive.fontSize(context, 12),
              color: colors.textPrimary,
            ),
            decoration: InputDecoration(
              border: InputBorder.none,
              hintText: 'e.g. 4h 30m, 2h, 90m (blank = no cap)',
              hintStyle: TextStyle(
                fontSize: Responsive.fontSize(context, 11),
                color: colors.textMuted,
              ),
            ),
            onChanged: (raw) {
              if (raw.trim().isEmpty) {
                widget.onChanged(0.0);
                return;
              }
              final parsed = parseHumanDurationSecs(raw);
              if (parsed != null) {
                widget.onChanged(parsed);
              }
              // Unparseable input is left in the field until the user
              // fixes it; we don't silently zero the budget.
            },
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Stops early once the budget is reached, regardless of unfilled counts.',
          style: TextStyle(
            fontSize: Responsive.fontSize(context, 10),
            color: colors.textMuted,
          ),
        ),
      ],
    );
  }
}

double _recommendedExposureSeconds(
  SmartNightExposureContext? context,
  String? filterName, {
  required double fallbackSecs,
}) {
  final recommendation = context?.recommendForFilter(filterName);
  final seconds = recommendation?.seconds;
  if (seconds == null || !seconds.isFinite || seconds <= 0) {
    return fallbackSecs;
  }
  return seconds;
}

String _formatExposureSeconds(double seconds) {
  final rounded = seconds.roundToDouble();
  if ((seconds - rounded).abs() < 0.05) {
    return '${rounded.toInt()}s';
  }
  return '${seconds.toStringAsFixed(1)}s';
}

class _EstimateSummary extends ConsumerWidget {
  final SkotiqColors colors;
  final SmartExposureNode node;

  const _EstimateSummary({required this.colors, required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final integration = node.totalIntegrationSecs;
    // Wall-clock comes from the SAME estimator that drives the timeline, the
    // tree-row chip, and the run-dashboard total — built from the shared
    // overhead model (findings 5/9/16) — so this figure agrees with them
    // instead of a divergent flat 20% approximation. We locate this node's
    // entry in the freshly-walked sequence timing (it carries the
    // download/dither/filter-change overhead the estimator models per plan).
    final overhead = ref.watch(sequencerOverheadConfigProvider);
    final sequence = ref.watch(currentSequenceProvider);
    double wallClock;
    if (sequence != null) {
      final estimator = SequenceTimeEstimator(overhead: overhead);
      final timings =
          estimator.estimateSequenceTiming(sequence, DateTime.now());
      final timing = timings.where((t) => t.nodeId == node.id).firstOrNull;
      if (timing != null) {
        wallClock = timing.duration.inMilliseconds / 1000.0;
      } else {
        // Node not yet in the walked tree (e.g. detached while editing) —
        // fall back to the integration figure (clamped to budget) so the line
        // still shows a sensible number rather than vanishing.
        wallClock = node.integrationBudgetSecs > 0 &&
                node.integrationBudgetSecs < integration
            ? node.integrationBudgetSecs
            : integration;
      }
    } else {
      wallClock = node.integrationBudgetSecs > 0 &&
              node.integrationBudgetSecs < integration
          ? node.integrationBudgetSecs
          : integration;
    }

    // In loop-until-stopped mode the per-plan counts are ignored, so a fixed
    // "Integration: Xh" figure would be a lie. The total is whatever fits in
    // the bound: the integration budget if set, otherwise "until window end".
    final loop = node.loopUntilStopped;
    final integrationLine = loop
        ? (node.integrationBudgetSecs > 0
            ? 'Integration: up to ${formatHumanDurationSecs(node.integrationBudgetSecs)} (looping)'
            : 'Integration: until the target’s window ends (looping)')
        : 'Integration: ${formatHumanDurationSecs(integration)}';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: SkotiqDecorations.tintedBadge(
        colors.primary,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(loop ? LucideIcons.repeat : LucideIcons.clock,
                  size: 14, color: colors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  integrationLine,
                  style: TextStyle(
                    fontSize: Responsive.fontSize(context, 13),
                    fontWeight: FontWeight.w500,
                    color: colors.primary,
                  ),
                ),
              ),
            ],
          ),
          // Wall-clock approximation only makes sense for a bounded run.
          // In loop mode without a budget there's no finite figure.
          if (!loop || node.integrationBudgetSecs > 0) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(LucideIcons.alarmClock, size: 14, color: colors.textMuted),
                const SizedBox(width: 8),
                Text(
                  'Wall clock (approx): ${formatHumanDurationSecs(wallClock)}',
                  style: TextStyle(
                    fontSize: Responsive.fontSize(context, 11),
                    color: colors.textMuted,
                  ),
                ),
              ],
            ),
          ],
          if (node.plans.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              _planSummary(node),
              style: TextStyle(
                fontSize: Responsive.fontSize(context, 11),
                color: colors.textMuted,
                fontFamily: 'monospace',
              ),
            ),
          ],
          // The estimate is the authored plan run in full. A depth goal can
          // only shorten it, so the number above is an upper bound rather than
          // a prediction once one is bound.
          if (node.plans.any((plan) => plan.depthGoal != null)) ...[
            const SizedBox(height: 4),
            Text(
              'A bound depth goal can finish a filter before its count; this '
              'estimate assumes it does not.',
              style: TextStyle(
                fontSize: Responsive.fontSize(context, 11),
                color: colors.textMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _planSummary(SmartExposureNode node) {
    if (node.loopUntilStopped) {
      // Counts are ignored — show "filter · 1 each · looping" so the summary
      // reflects the round-robin-forever shape, not fixed counts.
      final filters = node.plans
          .map((p) => p.filterName.isEmpty ? '#?' : p.filterName)
          .join('·');
      return '$filters · 1 each · looping';
    }
    return node.plans
        .map((p) =>
            '${p.filterName}: ${p.count}×${p.durationSecs.toStringAsFixed(0)}s')
        .join(' • ');
  }
}

/// Binds one filter plan to a DepthLock goal.
///
/// The binding carries the goal's REVISION, not just its id: editing a goal
/// archives its evidence and starts the measurement over, and a plan authored
/// against the old revision must not complete on the new one's verdict. So the
/// row shows the binding's staleness rather than silently following the goal.
///
/// The row hides itself when this filter has no goals and the plan is not
/// bound to one — a sequence editor for someone who has never marked a region
/// should not carry an empty control explaining a feature they are not using.
class DepthGoalSelector extends ConsumerWidget {
  const DepthGoalSelector({
    super.key,
    required this.colors,
    required this.plan,
    required this.onChanged,
    this.loopMode = false,
  });

  final SkotiqColors colors;
  final FilterPlan plan;
  final ValueChanged<FilterPlan> onChanged;

  /// The node is looping until stopped, so this row's count is ignored and a
  /// bound goal is the only thing that can end the filter short of the
  /// target's window closing.
  final bool loopMode;

  /// The dropdown's "not bound" entry. An empty id is not a legal goal id, so
  /// it cannot collide with one.
  static const String noneId = '';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goals = ref.watch(depthLockGoalsForFilterProvider(plan.filterName));
    final binding = plan.depthGoal;
    if (goals.isEmpty && binding == null) return const SizedBox.shrink();

    final DepthLockGoal? bound = binding == null
        ? null
        : goals.where((goal) => goal.id == binding.goalId).firstOrNull;
    final bool staleRevision =
        binding != null && bound != null && bound.revision != binding.revision;

    final List<String> ids = <String>[
      noneId,
      for (final goal in goals) goal.id,
      // A binding whose goal is no longer in the list still has to be
      // representable, or the dropdown would silently re-point the plan at
      // "None" the first time it is rebuilt.
      if (binding != null && bound == null) binding.goalId,
    ];

    String labelFor(String id) {
      if (id == noneId) return 'None';
      final goal = goals.where((g) => g.id == id).firstOrNull;
      if (goal == null) return 'Missing goal ($id)';
      // The list is already this plan's filter, so what tells two goals apart
      // is where each one stands — not a revision number nobody chose.
      return '${goal.definition.label} · ${depthLockStateLabel(goal.state)}';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // The one field in this form whose control goes UNDER its label, not
        // beside it: a goal is named by the operator ("NGC 7331 tidal tail")
        // and the pane is narrow, so the label-left layout the other rows use
        // folds the name onto three lines.
        Padding(
          padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceXs),
          child: Row(
            children: <Widget>[
              Text(
                'Depth goal',
                style: SkotiqTypography.bodySm.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceXs),
              Tooltip(
                message: 'Finish this filter early once the goal is reliably '
                    'achieved. Count, time, visibility and safety limits '
                    'still apply.',
                triggerMode: TooltipTriggerMode.tap,
                child: Icon(
                  LucideIcons.helpCircle,
                  size: 14,
                  color: colors.textMuted,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: FormRow.rowGap),
          child: NodeDropdown<String>(
            colors: colors,
            value: ids.contains(binding?.goalId ?? noneId)
                ? (binding?.goalId ?? noneId)
                : noneId,
            items: ids,
            labelBuilder: labelFor,
            onChanged: (id) {
              if (id == noneId) {
                onChanged(plan.copyWith(depthGoal: null));
                return;
              }
              final goal = goals.where((g) => g.id == id).firstOrNull;
              if (goal == null) return;
              onChanged(
                plan.copyWith(
                  depthGoal: DepthGoalBinding(
                    goalId: goal.id,
                    revision: goal.revision,
                  ),
                ),
              );
            },
          ),
        ),
        if (binding != null && bound == null)
          _DepthGoalNote(
            colors: colors,
            text: 'This plan is bound to a goal that is no longer on the host. '
                'It runs to its count.',
            tone: ChipTone.warning,
          ),
        if (staleRevision)
          _DepthGoalNote(
            colors: colors,
            text: 'Goal was edited; rebind. The plan is bound to revision '
                '${binding.revision} and the goal is now on '
                '${bound.revision}, so it runs to its count.',
            tone: ChipTone.warning,
            action: (
              'Rebind',
              () => onChanged(
                    plan.copyWith(
                      depthGoal: DepthGoalBinding(
                        goalId: bound.id,
                        revision: bound.revision,
                      ),
                    ),
                  ),
            ),
          ),
        if (bound != null &&
            !staleRevision &&
            !bound.definition.automaticCompletion)
          _DepthGoalNote(
            colors: colors,
            text: 'Advisory only — enable automatic completion on the goal to '
                'let this plan finish early.',
            tone: ChipTone.neutral,
          ),
        if (bound != null && !staleRevision && loopMode)
          _DepthGoalNote(
            colors: colors,
            text: 'Looping until stopped: this filter keeps going until the '
                'goal is reached or the target\'s window closes.',
            tone: ChipTone.neutral,
          ),
      ],
    );
  }
}

/// One explanatory line under the depth-goal dropdown, with an optional
/// one-tap fix.
class _DepthGoalNote extends StatelessWidget {
  const _DepthGoalNote({
    required this.colors,
    required this.text,
    required this.tone,
    this.action,
  });

  final SkotiqColors colors;
  final String text;
  final ChipTone tone;
  final (String label, VoidCallback onPressed)? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: FormRow.rowGap),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SkotiqChip(
            label: tone == ChipTone.warning ? 'Check' : 'Note',
            tone: tone,
            dot: true,
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Expanded(
            child: Text(
              text,
              style: SkotiqTypography.caption.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ),
          if (action != null) ...<Widget>[
            const SizedBox(width: SkotiqTokens.spaceSm),
            SkotiqButton(
              label: action!.$1,
              size: ButtonSize.small,
              variant: ButtonVariant.ghost,
              onPressed: action!.$2,
            ),
          ],
        ],
      ),
    );
  }
}

/// Sets each bound filter's count from what its DepthLock goal still needs.
///
/// This is the point of binding a goal to a plan: the goal knows how many more
/// exposures its own noise model expects, so the plan can be authored from
/// that rather than from a guess. It is a one-shot write, not a live binding —
/// the operator sees exactly what it set and can change any of it — because a
/// count that moved by itself between one look at the sequence and the next
/// would be a plan nobody authored.
class PlanCountsFromGoalsButton extends ConsumerStatefulWidget {
  const PlanCountsFromGoalsButton({
    super.key,
    required this.colors,
    required this.node,
    required this.onPlansChanged,
  });

  final SkotiqColors colors;
  final SmartExposureNode node;
  final ValueChanged<List<FilterPlan>> onPlansChanged;

  @override
  ConsumerState<PlanCountsFromGoalsButton> createState() =>
      _PlanCountsFromGoalsButtonState();
}

class _PlanCountsFromGoalsButtonState
    extends ConsumerState<PlanCountsFromGoalsButton> {
  /// What the last press did, in one line.
  String? _summary;

  @override
  Widget build(BuildContext context) {
    final goals = ref.watch(depthLockGoalsProvider).valueOrNull ??
        const <DepthLockGoal>[];

    DepthLockGoal? boundGoal(FilterPlan plan) {
      final binding = plan.depthGoal;
      if (binding == null) return null;
      final goal = goals.where((g) => g.id == binding.goalId).firstOrNull;
      // A plan bound to a revision the goal has moved past is not bound to
      // THIS goal's evidence, so its forecast is not this plan's to use.
      if (goal == null || goal.revision != binding.revision) return null;
      return goal;
    }

    final bool enabled = widget.node.plans.any((plan) {
      final forecast = boundGoal(plan)?.report?.forecast;
      return forecast != null && forecast.reachable;
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SkotiqButton(
          label: 'Plan counts from goals',
          icon: SkotiqIcons.target,
          size: ButtonSize.small,
          variant: ButtonVariant.secondary,
          semanticsHint: enabled
              ? 'Set each bound filter\'s count to the exposures its goal '
                  'still expects'
              : 'Needs a filter bound to a goal that has a reachable forecast',
          onPressed: enabled ? () => _apply(boundGoal) : null,
        ),
        if (_summary != null) ...<Widget>[
          const SizedBox(height: SkotiqTokens.spaceXs),
          Text(
            _summary!,
            style: SkotiqTypography.caption.copyWith(
              color: widget.colors.textSecondary,
            ),
          ),
        ],
      ],
    );
  }

  void _apply(DepthLockGoal? Function(FilterPlan) boundGoal) {
    final updated = <FilterPlan>[];
    final set = <String>[];
    final untouched = <String>[];

    for (final plan in widget.node.plans) {
      final String name = plan.filterName.isEmpty
          ? '#${(plan.filterIndex ?? 0) + 1}'
          : plan.filterName;
      final binding = plan.depthGoal;
      final goal = boundGoal(plan);
      final forecast = goal?.report?.forecast;

      if (binding == null) {
        // Unbound rows are the operator's own plan and are left alone.
        updated.add(plan);
        continue;
      }
      if (goal == null) {
        updated.add(plan);
        untouched.add('$name (rebind)');
        continue;
      }
      if (forecast == null) {
        updated.add(plan);
        untouched.add('$name (no forecast yet)');
        continue;
      }
      if (!forecast.reachable) {
        updated.add(plan);
        untouched.add('$name (floor limit)');
        continue;
      }
      if (goal.state == DepthLockState.achieved) {
        updated.add(plan.copyWith(count: 0));
        set.add('$name → 0 (reached)');
        continue;
      }
      final int count = forecast.framesRemaining;
      updated.add(plan.copyWith(count: count));
      set.add('$name → $count');
    }

    widget.onPlansChanged(updated);
    setState(() {
      final parts = <String>[
        if (set.isNotEmpty) 'Counts: ${set.join(', ')}.',
        if (untouched.isNotEmpty) 'Left alone: ${untouched.join(', ')}.',
      ];
      _summary = parts.isEmpty
          ? 'Nothing to set — no row is bound to a goal with a forecast.'
          : parts.join(' ');
    });
  }
}
