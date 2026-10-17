import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../accessible_dropdown.dart';
import 'framing_assistant_inline.dart';
import 'node_property_widgets.dart';
import 'target_coordinates.dart';

part 'target_node_properties/coordinate_lookup.dart';
part 'target_node_properties/trigger_section.dart';
part 'target_node_properties/trigger_params_and_preview.dart';
part 'target_node_properties/integration_budget_section.dart';
part 'target_node_properties/budget_filter_controls.dart';
part 'target_node_properties/budget_preview.dart';

enum _BrightnessTierChoice {
  auto(null, 'Auto (infer from target)'),
  faint(BrightnessTier.faint, 'Faint (galaxies, dim nebulae)'),
  medium(BrightnessTier.medium, 'Medium (bright galaxies, dim nebulae)'),
  bright(BrightnessTier.bright, 'Bright (planetary nebulae, open clusters)');

  final BrightnessTier? tier;
  final String label;

  const _BrightnessTierChoice(this.tier, this.label);

  static _BrightnessTierChoice fromTier(BrightnessTier? tier) {
    for (final choice in values) {
      if (choice.tier == tier) return choice;
    }
    return auto;
  }
}

class TargetGroupProperties extends ConsumerWidget {
  final SkotiqColors colors;
  final TargetHeaderNode node;

  const TargetGroupProperties(
      {super.key, required this.colors, required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Belt-and-suspenders gate. The parent `_NodeEditor`
    // already wraps the editor body in IgnorePointer when
    // [canEditSequenceProvider] is false, but we also wrap our own subtree
    // in IgnorePointer here. This guarantees that any future refactor that
    // extracts this widget out of the panel can't lose the gate silently —
    // the safety reads as intentional in the code, not implicit through
    // ancestor wrapping.
    final canEdit = ref.watch(canEditSequenceProvider);
    return IgnorePointer(
      ignoring: !canEdit,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Target Settings',
            style: TextStyle(
              fontSize: Responsive.fontSize(context, 13),
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          NodePropertyField(
            colors: colors,
            label: 'Target name',
            child: NodeTextInput(
              colors: colors,
              value: node.targetName,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(targetName: value),
                    );
              },
            ),
          ),
          Row(
            children: [
              Expanded(
                child: NodePropertyField(
                  colors: colors,
                  label: 'RA (hours)',
                  child: NodeNumberInput(
                    colors: colors,
                    value: node.raHours,
                    suffix: 'h',
                    min: 0,
                    max: 24,
                    decimals: 4,
                    onChanged: (value) {
                      ref.read(currentSequenceProvider.notifier).updateNode(
                            node.copyWith(raHours: value),
                          );
                    },
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: NodePropertyField(
                  colors: colors,
                  label: 'Dec (degrees)',
                  child: NodeNumberInput(
                    colors: colors,
                    value: node.decDegrees,
                    suffix: '\u00B0',
                    min: -90,
                    max: 90,
                    decimals: 4,
                    onChanged: (value) {
                      ref.read(currentSequenceProvider.notifier).updateNode(
                            node.copyWith(decDegrees: value),
                          );
                    },
                  ),
                ),
              ),
            ],
          ),
          // Name resolution: a named target must resolve to coordinates.
          // Otherwise "M31" sitting at the 0h/+0° default is a runnable state
          // that every downstream surface reports as a real pointing.
          _CoordinateLookupSection(colors: colors, node: node),
          NodePropertyField(
            colors: colors,
            label: 'Rotation (optional)',
            child: NodeNumberInput(
              colors: colors,
              value: node.rotation ?? 0,
              suffix: '\u00B0',
              min: 0,
              max: 360,
              decimals: 1,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(rotation: value),
                    );
              },
            ),
          ),
          // Frame target affordance. Opens the
          // planetarium framing assistant in a full-screen modal so the
          // user can drag the FOV outline to align rotation against the
          // sky. Disabled while the sequencer is running (the wrapping
          // IgnorePointer above the whole TargetGroupProperties handles
          // that case for us), and disabled while the coordinates are the
          // 0h/+0° default — framing a target the app cannot locate showed
          // an unrelated patch of Pisces under the target's name.
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: SizedBox(
              width: double.infinity,
              child: SkotiqButton(
                onPressed: targetCoordinatesUnset(node)
                    ? null
                    : () async {
                        final newRotation = await showFramingAssistantDialog(
                          context: context,
                          ref: ref,
                          target: node,
                        );
                        if (newRotation != null) {
                          ref.read(currentSequenceProvider.notifier).updateNode(
                                node.copyWith(rotation: newRotation),
                              );
                        }
                      },
                icon: LucideIcons.scanLine,
                label: 'Frame target',
                variant: ButtonVariant.outline,
                size: ButtonSize.small,
              ),
            ),
          ),
          NodePropertyField(
            colors: colors,
            label: 'Priority',
            child: NodeNumberInput(
              colors: colors,
              value: node.priority.toDouble(),
              min: 0,
              max: 100,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(priority: value.toInt()),
                    );
              },
            ),
          ),
          NodePropertyField(
            colors: colors,
            label: 'Adaptive Brightness Tier',
            child: NodeDropdown<_BrightnessTierChoice>(
              colors: colors,
              value: _BrightnessTierChoice.fromTier(node.brightnessTierHint),
              items: _BrightnessTierChoice.values,
              labelBuilder: (choice) => choice.label,
              onChanged: (choice) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(brightnessTierHint: choice.tier),
                    );
              },
            ),
          ),
          Row(
            children: [
              Expanded(
                child: NodePropertyField(
                  colors: colors,
                  label: 'Min altitude',
                  child: NodeNumberInput(
                    colors: colors,
                    value: node.minAltitude ?? 30,
                    suffix: '\u00B0',
                    min: 0,
                    max: 90,
                    decimals: 0,
                    onChanged: (value) {
                      ref.read(currentSequenceProvider.notifier).updateNode(
                            node.copyWith(minAltitude: value),
                          );
                    },
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: NodePropertyField(
                  colors: colors,
                  label: 'Max altitude',
                  child: NodeNumberInput(
                    colors: colors,
                    value: node.maxAltitude ?? 90,
                    suffix: '\u00B0',
                    min: 0,
                    max: 90,
                    decimals: 0,
                    onChanged: (value) {
                      ref.read(currentSequenceProvider.notifier).updateNode(
                            node.copyWith(maxAltitude: value),
                          );
                    },
                  ),
                ),
              ),
            ],
          ),
          NodePropertyField(
            colors: colors,
            label: 'Start After (optional)',
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () async {
                      final time = await showTimePicker(
                        context: context,
                        initialTime: TimeOfDay.fromDateTime(
                            node.startAfter ?? DateTime.now()),
                      );
                      if (time != null) {
                        final now = DateTime.now();
                        var targetDate = DateTime(now.year, now.month, now.day,
                            time.hour, time.minute);
                        if (targetDate.isBefore(now)) {
                          targetDate = targetDate.add(const Duration(days: 1));
                        }
                        ref.read(currentSequenceProvider.notifier).updateNode(
                              node.copyWith(startAfter: targetDate),
                            );
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: colors.surfaceAlt,
                        borderRadius: BorderRadius.circular(
                            SkotiqTokens.radiusInline8),
                        border: Border.all(color: colors.border),
                      ),
                      child: Row(
                        children: [
                          Icon(LucideIcons.clock,
                              size: 14, color: colors.textMuted),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              node.startAfter != null
                                  ? '${node.startAfter!.hour.toString().padLeft(2, '0')}:${node.startAfter!.minute.toString().padLeft(2, '0')}'
                                  : 'Not set',
                              style: TextStyle(
                                fontSize: SkotiqTypography.fontSize13,
                                color: node.startAfter != null
                                    ? colors.textPrimary
                                    : colors.textMuted,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (node.startAfter != null)
                  IconButton(
                    onPressed: () =>
                        _clearTimeConstraint(ref, clearStart: true),
                    icon:
                        Icon(LucideIcons.x, size: 14, color: colors.textMuted),
                    tooltip: 'Clear',
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
          NodePropertyField(
            colors: colors,
            label: 'End Before (optional)',
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () async {
                      final time = await showTimePicker(
                        context: context,
                        initialTime: TimeOfDay.fromDateTime(
                            node.endBefore ?? DateTime.now()),
                      );
                      if (time != null) {
                        final now = DateTime.now();
                        var targetDate = DateTime(now.year, now.month, now.day,
                            time.hour, time.minute);
                        if (targetDate.isBefore(now)) {
                          targetDate = targetDate.add(const Duration(days: 1));
                        }
                        ref.read(currentSequenceProvider.notifier).updateNode(
                              node.copyWith(endBefore: targetDate),
                            );
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: colors.surfaceAlt,
                        borderRadius: BorderRadius.circular(
                            SkotiqTokens.radiusInline8),
                        border: Border.all(color: colors.border),
                      ),
                      child: Row(
                        children: [
                          Icon(LucideIcons.clock,
                              size: 14, color: colors.textMuted),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              node.endBefore != null
                                  ? '${node.endBefore!.hour.toString().padLeft(2, '0')}:${node.endBefore!.minute.toString().padLeft(2, '0')}'
                                  : 'Not set',
                              style: TextStyle(
                                fontSize: SkotiqTypography.fontSize13,
                                color: node.endBefore != null
                                    ? colors.textPrimary
                                    : colors.textMuted,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (node.endBefore != null)
                  IconButton(
                    onPressed: () =>
                        _clearTimeConstraint(ref, clearStart: false),
                    icon:
                        Icon(LucideIcons.x, size: 14, color: colors.textMuted),
                    tooltip: 'Clear',
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
          // start_when / end_when crossings editor.
          const SizedBox(height: 16),
          _TriggerSection(
            colors: colors,
            node: node,
            isStart: true,
          ),
          const SizedBox(height: 8),
          _TriggerSection(
            colors: colors,
            node: node,
            isStart: false,
          ),
          // Trigger poll cadence. Only meaningful when a
          // start/end crossing is configured (the runtime polls these
          // on the interval); hidden otherwise to keep the panel quiet
          // for the common no-window case.
          if (node.hasCrossingTriggers) ...[
            const SizedBox(height: 8),
            NodePropertyField(
              colors: colors,
              label: 'Trigger Poll Interval',
              child: NodeNumberInput(
                colors: colors,
                value: node.triggerPollIntervalSecs.toDouble(),
                suffix: 's',
                min: 5,
                max: 600,
                onChanged: (value) {
                  ref.read(currentSequenceProvider.notifier).updateNode(
                        node.copyWith(
                          triggerPollIntervalSecs: value.round(),
                        ),
                      );
                },
              ),
            ),
          ],
          // Per-target integration budget editor.
          const SizedBox(height: 16),
          _IntegrationBudgetSection(colors: colors, node: node),
        ],
      ),
    );
  }

  /// Clear a legacy Start After / End Before wall-clock constraint back to
  /// unset. These fields use plain `?? this.startAfter` copyWith semantics, so
  /// `copyWith(startAfter: null)` keeps the old value — clearing is
  /// rebuild-explicit, mirroring the integration-budget toggle recipe.
  void _clearTimeConstraint(WidgetRef ref, {required bool clearStart}) {
    ref.read(currentSequenceProvider.notifier).updateNode(
          TargetHeaderNode(
            id: node.id,
            name: node.name,
            isEnabled: node.isEnabled,
            childIds: node.childIds,
            parentId: node.parentId,
            orderIndex: node.orderIndex,
            comment: node.comment,
            targetName: node.targetName,
            raHours: node.raHours,
            decDegrees: node.decDegrees,
            rotation: node.rotation,
            priority: node.priority,
            minAltitude: node.minAltitude,
            maxAltitude: node.maxAltitude,
            startAfter: clearStart ? null : node.startAfter,
            endBefore: clearStart ? node.endBefore : null,
            mosaicPanel: node.mosaicPanel,
            integrationBudget: node.integrationBudget,
            startWhen: node.startWhen,
            endWhen: node.endWhen,
            triggerPollIntervalSecs: node.triggerPollIntervalSecs,
            brightnessTierHint: node.brightnessTierHint,
            catalogTargetId: node.catalogTargetId,
          ),
        );
  }
}

// Start-when / End-when trigger editor.
//
// One section per direction (start vs end). Each section is toggle-gated:
// when off, the trigger is null (no gate). When on, the user picks a kind
// from a dropdown and edits the parameters inline. Compound triggers
// (And/Or) get a nested row of sub-triggers.
