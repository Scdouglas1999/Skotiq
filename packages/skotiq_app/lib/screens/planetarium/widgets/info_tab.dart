import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../../../services/mount_command_service.dart';
import '../../../utils/plan_tonight_sequencer_helper.dart';
import '../../../utils/snackbar_helper.dart';
import '../../framing/add_target_to_sequence_flow.dart';
import '../providers/sequenced_object_ids_provider.dart';
import 'fov_presets_panel.dart';
import 'sidebar_shared_widgets.dart';

class InfoTab extends ConsumerWidget {
  final SkotiqColors colors;
  final SelectedObjectState selectedObject;

  const InfoTab({
    super.key,
    required this.colors,
    required this.selectedObject,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (selectedObject.object == null && selectedObject.coordinates == null) {
      // No selection: still surface the FOV framing manager so a rig can be
      // configured and overlaid before picking a target.
      return SingleChildScrollView(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(SkotiqIcons.info, size: 48, color: colors.textMuted),
                  const SizedBox(height: 16),
                  Text(
                    'Select an object',
                    style: TextStyle(color: colors.textMuted),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Click on the sky to select',
                    style: TextStyle(
                        fontSize: SkotiqTypography.fontSize12,
                        color: colors.textMuted),
                  ),
                ],
              ),
            ),
            FovPresetsPanel(colors: colors, selectedObject: selectedObject),
          ],
        ),
      );
    }

    final obj = selectedObject.object;

    // If we have a celestial object, use the ObjectDetailsPanel + imaging history
    if (obj != null) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: ObjectDetailsPanel(
          object: obj,
          backgroundColor: colors.surfaceAlt,
          textColor: colors.textPrimary,
          accentColor: colors.accent,
          showVisibilityGraph: true,
          cloudCoverPercent:
              ref.watch(cloudCoverPercentageProvider).valueOrNull,
          extraContent: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ImagingHistorySection(
                object: obj,
                colors: colors,
              ),
              const SizedBox(height: 8),
              InSequenceBadge(colors: colors, object: obj),
              AddToTargetQueueButton(colors: colors, object: obj),
              const SizedBox(height: 8),
              FovPresetsPanel(colors: colors, selectedObject: selectedObject),
            ],
          ),
          onGoTo: () async {
            final coords = obj.coordinates;
            final result = await ref
                .read(mountCommandServiceProvider)
                .slewTo(coords.ra, coords.dec);
            if (context.mounted) {
              context.showCommandActionResult(result);
            }
          },
          onFrameTarget: () async {
            // Open the Framing screen for this object. Reuse the same handoff
            // the rest of the planetarium uses: build the rich target
            // suggestion (so Framing can round-trip into Smart Night), set it
            // on the framing provider, then route to the Framing screen.
            final coords = obj.coordinates;
            final visibility = ref.read(selectedObjectVisibilityProvider);
            final meta = celestialObjectMetadata(obj);
            final target = await catalogTargetSuggestion(
              ref: ref,
              targetName: obj.name,
              raHours: coords.ra,
              decDegrees: coords.dec,
              catalogId: meta.catalogId,
              objectType: meta.objectType,
              magnitude: obj.magnitude,
              sizeArcmin: meta.sizeArcmin,
              constellation: meta.constellation,
              visibility: visibility,
            );
            if (!context.mounted) return;
            ref.read(framingProvider.notifier).setTargetSuggestion(target);
            context.goNamed('framing');
          },
          onAddToSequence: () async {
            // Drop this object into a sequence the user picks (or a new one)
            // via the shared add-to-sequence flow — a bare target header, no
            // auto-generated instruction tree.
            final coords = obj.coordinates;
            final framingTarget = FramingTarget(
              name: obj.name,
              raHours: coords.ra,
              decDegrees: coords.dec,
            );
            final added = await addFramedTargetToExistingSequence(
              context: context,
              ref: ref,
              target: framingTarget,
            );
            if (added && context.mounted) {
              context.showSuccessSnackBar('Added ${obj.name} to sequence');
            }
          },
          onAddToTargets: () async {
            final coords = obj.coordinates;
            final visibility = ref.read(selectedObjectVisibilityProvider);
            final meta = celestialObjectMetadata(obj);
            final target = await catalogTargetSuggestion(
              ref: ref,
              targetName: obj.name,
              raHours: coords.ra,
              decDegrees: coords.dec,
              catalogId: meta.catalogId,
              objectType: meta.objectType,
              magnitude: obj.magnitude,
              sizeArcmin: meta.sizeArcmin,
              constellation: meta.constellation,
              visibility: visibility,
            );
            if (!context.mounted) return;
            final added = await addPlanTonightTargetToSequencer(
              context: context,
              ref: ref,
              target: target,
            );
            if (added && context.mounted) {
              context.showSuccessSnackBar('Added ${obj.name} to sequence');
            }
          },
        ),
      );
    }

    // Fallback for coordinates-only selection (rare case)
    final coords = selectedObject.coordinates;
    final altAz = ref.watch(selectedObjectAltAzProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Selected Coordinates',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize18,
              fontWeight: FontWeight.bold,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 16),
          InfoCard(
            title: 'Coordinates',
            icon: SkotiqIcons.compass,
            color: colors.info,
            colors: colors,
            child: Column(
              children: [
                if (coords != null) ...[
                  InfoRow(
                      label: 'RA',
                      value: coords
                          .toString()
                          .split(',')[0]
                          .replaceAll('RA: ', ''),
                      colors: colors),
                  InfoRow(
                      label: 'Dec',
                      value: coords
                          .toString()
                          .split(',')[1]
                          .replaceAll(' Dec: ', ''),
                      colors: colors),
                ],
                if (altAz != null) ...[
                  InfoRow(
                    label: 'Altitude',
                    value: '${altAz.$1.toStringAsFixed(1)}\u00b0',
                    colors: colors,
                    valueColor: altAz.$1 > 30
                        ? colors.success
                        : altAz.$1 > 0
                            ? colors.warning
                            : colors.error,
                  ),
                  InfoRow(
                      label: 'Azimuth',
                      value: '${altAz.$2.toStringAsFixed(1)}\u00b0',
                      colors: colors),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          FovPresetsPanel(colors: colors, selectedObject: selectedObject),
        ],
      ),
    );
  }
}

/// "In tonight's sequence" marker for the selected sky object.
///
/// The sky itself is still blind to the sequence — drawing a third per-DSO
/// marker on the canvas needs a renderer change (a `sequencedObjectIds` set on
/// `SkyCanvasPainter`, see [sequencedObjectIdsProvider]) — but the object panel
/// can answer "am I already imaging this?" today, which is the question that
/// otherwise sends the user to the sequencer to check.
///
/// Renders nothing when the object is not planned, so it costs no space in the
/// common case.
class InSequenceBadge extends ConsumerWidget {
  final SkotiqColors colors;
  final CelestialObject object;

  const InSequenceBadge({
    super.key,
    required this.colors,
    required this.object,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final planned = ref.watch(
      sequencedObjectIdsProvider.select(
        (ids) => _matches(ids, object),
      ),
    );
    if (!planned) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(LucideIcons.listOrdered, size: 13, color: colors.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              "In tonight's sequence",
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize11,
                fontWeight: FontWeight.w600,
                color: colors.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Mirrors the renderer's lenient DSO matching (id, name, Messier number,
  /// NGC/IC designation) so this badge and a future canvas marker agree.
  static bool _matches(Set<String> ids, CelestialObject object) {
    if (ids.isEmpty) return false;
    if (ids.contains(object.id) || ids.contains(object.name)) return true;
    if (object is DeepSkyObject) {
      final messier = object.isMessier ? object.messierNumber : null;
      if (messier != null && ids.contains(messier)) return true;
      final ngcIc = object.ngcIcDesignation;
      if (ngcIc != null && ids.contains(ngcIc)) return true;
    }
    return false;
  }
}

/// "Add to target queue" action for the selected sky object.
///
/// The target queue ([targetQueueProvider]) is the shortlist the sequencer
/// Builder's Target Queue panel renders and drags onto the instruction tree, so
/// this is the light-weight counterpart to "Add to sequence": it records the
/// intent without authoring any nodes.
///
/// Reflects membership rather than blindly appending — a wishlist that silently
/// grows a second M31 every time the user re-taps a bright object is worse than
/// no button.
class AddToTargetQueueButton extends ConsumerWidget {
  final SkotiqColors colors;
  final CelestialObject object;

  const AddToTargetQueueButton({
    super.key,
    required this.colors,
    required this.object,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = object.name.isNotEmpty ? object.name : object.id;
    final queued = ref.watch(
      targetQueueProvider.select(
        (queue) => queue.targets.any(
          (t) => t.displayName.toLowerCase() == name.toLowerCase(),
        ),
      ),
    );

    return SkotiqButton(
      key: const ValueKey('info_tab_add_to_target_queue'),
      label: queued ? 'In target queue' : 'Add to target queue',
      icon: queued ? SkotiqIcons.check : LucideIcons.listChecks,
      variant: ButtonVariant.outline,
      size: ButtonSize.small,
      onPressed: queued
          ? null
          : () {
              ref.read(targetQueueProvider.notifier).addTarget(object);
              context.showSuccessSnackBar('Added $name to the target queue');
            },
    );
  }
}

/// Shows imaging history for a celestial object, queried from the local database.
class ImagingHistorySection extends ConsumerWidget {
  final CelestialObject object;
  final SkotiqColors colors;

  const ImagingHistorySection({
    super.key,
    required this.object,
    required this.colors,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = ImagingHistoryQuery(
      objectName: object.name,
      raHours: object.coordinates.ra,
      decDegrees: object.coordinates.dec,
    );

    final historyAsync = ref.watch(imagingHistoryProvider(query));

    return historyAsync.when(
      loading: () => Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colors.primary,
            ),
          ),
        ),
      ),
      error: (error, _) => Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'Failed to load imaging history: $error',
          style: TextStyle(
              color: colors.error, fontSize: SkotiqTypography.fontSize12),
        ),
      ),
      data: (history) {
        if (!history.hasData) {
          return _buildNoDataSection();
        }
        return _buildHistorySection(history);
      },
    );
  }

  Widget _buildNoDataSection() {
    return SkotiqCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: colors.textMuted.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
            ),
            child:
                Icon(SkotiqIcons.camera, size: 14, color: colors.textMuted),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'No imaging data',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize12,
                color: colors.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistorySection(ImagingHistory history) {
    final totalHours = history.totalIntegrationSecs / 3600.0;
    final totalMinutes = (history.totalIntegrationSecs / 60.0).round();

    // Format total integration nicely. Rounded minutes can reach 60, and
    // without the carry 3.99h printed "3h 60m".
    String integrationStr;
    if (totalHours >= 1.0) {
      var h = totalHours.floor();
      var m = ((totalHours - h) * 60).round();
      if (m == 60) {
        h += 1;
        m = 0;
      }
      integrationStr = m == 0 ? '${h}h' : '${h}h ${m}m';
    } else if (totalMinutes == 60) {
      integrationStr = '1h';
    } else {
      integrationStr = '${totalMinutes}m';
    }

    return SkotiqCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: colors.primary.withValues(alpha: 0.15),
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusMd),
                ),
                child: Icon(SkotiqIcons.camera,
                    size: 14, color: colors.primary),
              ),
              const SizedBox(width: 10),
              Text(
                'Imaging History',
                style: SkotiqTypography.labelStrong
                    .copyWith(color: colors.textPrimary),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Summary stats row
          Row(
            children: [
              _buildStatChip(
                label: 'Integration',
                value: integrationStr,
                icon: SkotiqIcons.clock,
              ),
              const SizedBox(width: 8),
              _buildStatChip(
                label: 'Sessions',
                value: history.sessionCount.toString(),
                icon: SkotiqIcons.calendar,
              ),
            ],
          ),

          // Completion bar (if goal is set)
          if (history.hasGoal) ...[
            const SizedBox(height: 12),
            _buildCompletionBar(history),
          ],

          // Last imaged
          if (history.lastImaged != null) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(LucideIcons.clock3, size: 12, color: colors.textMuted),
                const SizedBox(width: 6),
                Text(
                  'Last imaged: ${DateFormat('MMM d, yyyy').format(history.lastImaged!.toLocal())}',
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize11,
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ],

          // Per-filter breakdown
          if (history.filterCounts.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'Per-Filter Breakdown',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize10,
                fontWeight: FontWeight.w600,
                color: colors.textMuted,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 8),
            ...history.filterCounts.entries.map((entry) {
              final filterSecs =
                  history.filterIntegrationSecs[entry.key] ?? 0.0;
              return _buildFilterRow(
                filterName: entry.key,
                frameCount: entry.value,
                integrationSecs: filterSecs,
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _buildStatChip({
    required String label,
    required String value,
    required IconData icon,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: colors.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          border: Border.all(
            color: colors.primary.withValues(alpha: 0.15),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: colors.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize9,
                      color: colors.textMuted,
                    ),
                  ),
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize13,
                      fontWeight: FontWeight.w600,
                      color: colors.textPrimary,
                      fontFeatures: const [ui.FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompletionBar(ImagingHistory history) {
    final pct = (history.completionFraction * 100).round();
    final goalHours = history.goalIntegrationSecs / 3600.0;

    Color barColor;
    if (history.completionFraction >= 1.0) {
      barColor = colors.success;
    } else if (history.completionFraction > 0.5) {
      barColor = colors.primary;
    } else {
      barColor = colors.warning;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Completion',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize11,
                color: colors.textSecondary,
              ),
            ),
            Text(
              '$pct% of ${goalHours.toStringAsFixed(1)}h goal',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize11,
                fontWeight: FontWeight.w500,
                color: barColor,
                fontFeatures: const [ui.FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
          child: SizedBox(
            height: 6,
            child: LinearProgressIndicator(
              value: history.completionFraction,
              backgroundColor: colors.surfaceAlt,
              valueColor: AlwaysStoppedAnimation<Color>(barColor),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFilterRow({
    required String filterName,
    required int frameCount,
    required double integrationSecs,
  }) {
    String integStr;
    if (integrationSecs >= 3600) {
      final h = (integrationSecs / 3600).floor();
      final m = ((integrationSecs % 3600) / 60).round();
      integStr = '${h}h ${m}m';
    } else {
      integStr = '${(integrationSecs / 60).round()}m';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: _filterColor(filterName),
              borderRadius:
                  BorderRadius.circular(SkotiqTokens.radiusInline2),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              filterName,
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize11,
                color: colors.textPrimary,
              ),
            ),
          ),
          Text(
            '$frameCount subs',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize11,
              color: colors.textSecondary,
              fontFeatures: const [ui.FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 48,
            child: Text(
              integStr,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize11,
                fontWeight: FontWeight.w500,
                color: colors.textPrimary,
                fontFeatures: const [ui.FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Swatch color for common astrophotography filter names.
  ///
  /// These are fixed data-series (legend) colors that encode the filter's
  /// optical wavelength, so they intentionally use literal hues rather than
  /// the theme's semantic palette. They mirror the desaturated, palette-aligned
  /// values used by the project-tracking filter chips for visual consistency.
  /// The neutral L/default cases resolve from theme semantics so they still
  /// re-tint under red-night mode.
  Color _filterColor(String name) {
    final lower = name.toLowerCase();
    if (lower == 'l' || lower == 'luminance' || lower == 'lum') {
      return colors.textSecondary;
    } else if (lower == 'r' || lower == 'red') {
      return const Color(0xFFF87171);
    } else if (lower == 'g' || lower == 'green') {
      return const Color(0xFF4ADE80);
    } else if (lower == 'b' || lower == 'blue') {
      return const Color(0xFF60A5FA);
    } else if (lower == 'ha' || lower.contains('alpha')) {
      return const Color(0xFFB91C1C);
    } else if (lower == 'oiii' || lower.contains('oxygen')) {
      return const Color(0xFF2DD4BF);
    } else if (lower == 'sii' ||
        lower.contains('sulphur') ||
        lower.contains('sulfur')) {
      return const Color(0xFFFB923C);
    } else {
      return colors.textSecondary;
    }
  }
}
