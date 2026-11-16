// TargetScheduler properties editor.
//
// Sliders for the five scoring weights (+ a one-tap normalise button), min
// score-to-run threshold, recompute cadence, and finish-iteration-on-switch
// toggle. Includes a live preview that ranks the current children with the
// app's target scorer, as the step will, so the user can see "M42 73 / M101
// 56 / NGC 7000 42" without leaving the editor.
//
// Respects [canEditSequenceProvider]: the entire subtree
// is wrapped in `IgnorePointer` so every control reads as disabled while the
// sequence is running.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_astro/skotiq_astro.dart' show AltitudeFloorSamples;
import 'package:skotiq_core/services.dart'
    show HorizonProfile, SchedulerTarget, SchedulerTargetScore;
import 'package:skotiq_ui/skotiq_ui.dart';

import 'node_property_widgets.dart';

class TargetSchedulerProperties extends ConsumerWidget {
  final SkotiqColors colors;
  final TargetSchedulerNode node;

  const TargetSchedulerProperties({
    super.key,
    required this.colors,
    required this.node,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(canEditSequenceProvider);
    final sequence = ref.watch(currentSequenceProvider);
    // Use the canonical observer-location provider (same one the planetarium /
    // weather providers read). `null` when the user has not configured a
    // location yet — the preview will surface a polite "set your location"
    // message instead of producing junk scores.
    final location = ref.watch(appObserverLocationProvider);

    return IgnorePointer(
      ignoring: !canEdit,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Target scheduler',
            style: TextStyle(
              fontSize: Responsive.fontSize(context, 13),
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Picks the highest-scoring TargetHeader child at runtime. Add '
            'targets as direct children; they will be ranked live by '
            'altitude, moon distance, transit proximity, darkness, and '
            'airmass.',
            style: TextStyle(
              fontSize: Responsive.fontSize(context, 11),
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 16),
          const SectionHeader(title: 'Scoring weights'),
          const SizedBox(height: 8),
          _WeightSlider(
            colors: colors,
            label: 'Altitude',
            value: node.altitudeWeight,
            onChanged: (v) => _update(ref, node.copyWith(altitudeWeight: v)),
          ),
          _WeightSlider(
            colors: colors,
            label: 'Moon distance',
            value: node.moonDistanceWeight,
            onChanged: (v) =>
                _update(ref, node.copyWith(moonDistanceWeight: v)),
          ),
          _WeightSlider(
            colors: colors,
            label: 'Transit proximity',
            value: node.transitProximityWeight,
            onChanged: (v) =>
                _update(ref, node.copyWith(transitProximityWeight: v)),
          ),
          _WeightSlider(
            colors: colors,
            label: 'Darkness',
            value: node.darknessWeight,
            onChanged: (v) => _update(ref, node.copyWith(darknessWeight: v)),
          ),
          _WeightSlider(
            colors: colors,
            label: 'Airmass',
            value: node.airmassWeight,
            onChanged: (v) => _update(ref, node.copyWith(airmassWeight: v)),
          ),
          const SizedBox(height: 8),
          _WeightSumIndicator(colors: colors, node: node, ref: ref),
          const SizedBox(height: 16),
          const SectionHeader(title: 'Decision policy'),
          const SizedBox(height: 8),
          NodePropertyField(
            colors: colors,
            label: 'Minimum score to run (0–100)',
            child: NodeNumberInput(
              colors: colors,
              value: node.minScoreToRun,
              min: 0,
              max: 100,
              decimals: 1,
              onChanged: (v) => _update(ref, node.copyWith(minScoreToRun: v)),
            ),
          ),
          NodePropertyField(
            colors: colors,
            label: 'Recompute every N exposures (0 = boundary only)',
            child: NodeNumberInput(
              colors: colors,
              value: node.recomputeEveryNExposures.toDouble(),
              min: 0,
              max: 9999,
              onChanged: (v) => _update(
                  ref, node.copyWith(recomputeEveryNExposures: v.toInt())),
            ),
          ),
          NodePropertyField(
            colors: colors,
            label: 'Finish current loop iteration before switching',
            child: Row(
              children: [
                SkotiqSwitch(
                  value: node.finishIterationOnSwitch,
                  onChanged: canEdit
                      ? (v) => _update(
                          ref, node.copyWith(finishIterationOnSwitch: v))
                      : null,
                ),
                const SizedBox(width: 8),
                Text(
                  node.finishIterationOnSwitch ? 'Yes' : 'No',
                  style: TextStyle(color: colors.textSecondary),
                ),
              ],
            ),
          ),
          NodePropertyField(
            colors: colors,
            label: 'Moon avoidance (skip targets near a bright Moon)',
            child: Row(
              children: [
                SkotiqSwitch(
                  value: node.minMoonSeparationDeg != null,
                  onChanged: canEdit
                      ? (v) {
                          if (v) {
                            _update(
                                ref, node.copyWith(minMoonSeparationDeg: 30.0));
                          } else {
                            // copyWith is keep-or-replace, so clearing to null
                            // needs a fresh node. Carry every field through —
                            // including the other nullable (swap threshold).
                            _update(
                              ref,
                              TargetSchedulerNode(
                                id: node.id,
                                name: node.name,
                                isEnabled: node.isEnabled,
                                childIds: node.childIds,
                                parentId: node.parentId,
                                orderIndex: node.orderIndex,
                                comment: node.comment,
                                altitudeWeight: node.altitudeWeight,
                                moonDistanceWeight: node.moonDistanceWeight,
                                transitProximityWeight:
                                    node.transitProximityWeight,
                                darknessWeight: node.darknessWeight,
                                airmassWeight: node.airmassWeight,
                                minScoreToRun: node.minScoreToRun,
                                recomputeEveryNExposures:
                                    node.recomputeEveryNExposures,
                                finishIterationOnSwitch:
                                    node.finishIterationOnSwitch,
                                swapOnConditionsBelow:
                                    node.swapOnConditionsBelow,
                                swapHysteresisSecs: node.swapHysteresisSecs,
                                brightnessTierPreferences:
                                    node.brightnessTierPreferences,
                                maxConditionsScoreAgeSecs:
                                    node.maxConditionsScoreAgeSecs,
                              ),
                            );
                          }
                        }
                      : null,
                ),
                const SizedBox(width: 8),
                Text(
                  node.minMoonSeparationDeg != null ? 'On' : 'Off',
                  style: TextStyle(color: colors.textSecondary),
                ),
              ],
            ),
          ),
          if (node.minMoonSeparationDeg != null)
            NodePropertyField(
              colors: colors,
              label: 'Minimum Moon separation (degrees)',
              child: NodeNumberInput(
                colors: colors,
                value: node.minMoonSeparationDeg ?? 30.0,
                min: 0,
                max: 180,
                onChanged: (v) =>
                    _update(ref, node.copyWith(minMoonSeparationDeg: v)),
              ),
            ),
          const SizedBox(height: 16),
          _AdaptiveSwapSection(
            colors: colors,
            node: node,
            canEdit: canEdit,
            onUpdate: (updated) => _update(ref, updated),
          ),
          const SizedBox(height: 16),
          const SectionHeader(title: 'Live ranking preview'),
          const SizedBox(height: 8),
          if (sequence == null)
            _PreviewPlaceholder(
              colors: colors,
              message: 'No sequence loaded.',
            )
          else
            _LiveRankingPreview(
              colors: colors,
              node: node,
              sequence: sequence,
              location: location,
            ),
        ],
      ),
    );
  }

  void _update(WidgetRef ref, TargetSchedulerNode updated) {
    ref.read(currentSequenceProvider.notifier).updateNode(updated);
  }
}

// Local helpers — kept private to this file so they don't pollute the design
// system. If the same pattern shows up in a second editor we'll promote them
// to skotiq_ui.

/// Weight slider that updates its thumb locally on every drag frame but only
/// commits the value (which re-instantiates the scoring service and re-scores
/// every child in the live preview) on a short debounce and on drag-end. This
/// keeps the drag responsive without re-scoring the whole ranking on every
/// pointer move.
class _WeightSlider extends StatefulWidget {
  final SkotiqColors colors;
  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  const _WeightSlider({
    required this.colors,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  State<_WeightSlider> createState() => _WeightSliderState();
}

class _WeightSliderState extends State<_WeightSlider> {
  double? _dragValue;
  Timer? _commitDebounce;

  @override
  void didUpdateWidget(_WeightSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    // When the committed value changes from outside (e.g. Normalise button)
    // and the user isn't mid-drag, follow it.
    if (_dragValue == null && oldWidget.value != widget.value) {
      // Nothing to do — build reads widget.value directly when not dragging.
    }
  }

  @override
  void dispose() {
    _commitDebounce?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final shown = (_dragValue ?? widget.value).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 130,
            child: Text(
              widget.label,
              style: TextStyle(
                fontSize: Responsive.fontSize(context, 12),
                color: colors.textPrimary,
              ),
            ),
          ),
          Expanded(
            child: Slider(
              min: 0,
              max: 1,
              divisions: 100,
              value: shown,
              label: shown.toStringAsFixed(2),
              onChanged: (v) {
                setState(() => _dragValue = v);
                // Debounced commit while dragging so the preview rescore
                // fires at most every ~200ms, not every frame.
                _commitDebounce?.cancel();
                _commitDebounce = Timer(const Duration(milliseconds: 200), () {
                  widget.onChanged(v);
                });
              },
              onChangeEnd: (v) {
                _commitDebounce?.cancel();
                widget.onChanged(v);
                setState(() => _dragValue = null);
              },
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(
              shown.toStringAsFixed(2),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: Responsive.fontSize(context, 11),
                color: colors.textSecondary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WeightSumIndicator extends StatelessWidget {
  final SkotiqColors colors;
  final TargetSchedulerNode node;
  final WidgetRef ref;
  const _WeightSumIndicator({
    required this.colors,
    required this.node,
    required this.ref,
  });

  @override
  Widget build(BuildContext context) {
    final sum = node.weightsSum;
    final normalised = node.weightsNormalised;
    final color = normalised ? colors.success : colors.warning;
    final icon =
        normalised ? LucideIcons.checkCircle2 : LucideIcons.alertTriangle;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: SkotiqDecorations.iconChip(
        color,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              normalised
                  ? 'Weights normalized (sum ${sum.toStringAsFixed(2)})'
                  : 'Weights do not sum to ~1.0 (sum ${sum.toStringAsFixed(2)}): '
                      'the scheduler still works, but the ranking will be biased.',
              style: TextStyle(
                fontSize: Responsive.fontSize(context, 11),
                color: colors.textPrimary,
              ),
            ),
          ),
          TextButton(
            onPressed: normalised
                ? null
                : () => ref
                    .read(currentSequenceProvider.notifier)
                    .updateNode(node.normalisedWeights()),
            child: const Text('Normalize'),
          ),
        ],
      ),
    );
  }
}

class _PreviewPlaceholder extends StatelessWidget {
  final SkotiqColors colors;
  final String message;
  const _PreviewPlaceholder({required this.colors, required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border),
      ),
      child: Text(
        message,
        style: TextStyle(
          fontSize: Responsive.fontSize(context, 11),
          color: colors.textSecondary,
        ),
      ),
    );
  }
}

// Adaptive Swap editor section.
//
// Surfaces the four `swap_on_conditions_below`-family fields on
// [TargetSchedulerNode]. The feature is opt-in: when
// `swapOnConditionsBelow == null` the scheduler runs the ordinary ranking
// only and we hide the sub-controls behind a master enable switch (matches
// how the Rust side treats `None` as "feature off").

/// Default value the master toggle restores when the user re-enables
/// adaptive swap after a previous "off" (so the field doesn't come back as
/// 0, which would mean "swap on a perfect sky"). Matches the brief's
/// recommended starting point — a conditions score of 50 sits at the
/// boundary between the `medium` and `bright` tier floors.
const double _defaultSwapThreshold = 50.0;

class _AdaptiveSwapSection extends StatelessWidget {
  final SkotiqColors colors;
  final TargetSchedulerNode node;
  final bool canEdit;
  final ValueChanged<TargetSchedulerNode> onUpdate;

  const _AdaptiveSwapSection({
    required this.colors,
    required this.node,
    required this.canEdit,
    required this.onUpdate,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = node.swapOnConditionsBelow != null;
    final prefs = node.brightnessTierPreferences;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: 'Adaptive swap',
          subtitle: 'When live sky-conditions deteriorate, swap from the faint '
              'target to a brighter backup that still accepts the score.',
        ),
        const SizedBox(height: 8),

        // Master enable toggle. Flipping it on seeds a sensible default
        // threshold (50) so the scheduler doesn't immediately interpret a
        // freshly-enabled-but-zero threshold as "never swap" (which would
        // be confusing) or as "swap on a perfect sky" (which would be
        // worse). Flipping off passes `null` through copyWith via the
        // sentinel-aware overload — see TargetSchedulerNode.copyWith.
        NodePropertyField(
          colors: colors,
          label: 'Enable adaptive swap on degraded conditions',
          child: Row(
            children: [
              SkotiqSwitch(
                value: enabled,
                onChanged: canEdit
                    ? (v) {
                        if (v) {
                          onUpdate(node.copyWith(
                            swapOnConditionsBelow: _defaultSwapThreshold,
                          ));
                        } else {
                          // TargetSchedulerNode.copyWith uses plain
                          // `?? this.swapOnConditionsBelow`, so clearing back
                          // to null requires a fresh node.
                          onUpdate(TargetSchedulerNode(
                            id: node.id,
                            name: node.name,
                            isEnabled: node.isEnabled,
                            childIds: node.childIds,
                            parentId: node.parentId,
                            orderIndex: node.orderIndex,
                            comment: node.comment,
                            altitudeWeight: node.altitudeWeight,
                            moonDistanceWeight: node.moonDistanceWeight,
                            transitProximityWeight: node.transitProximityWeight,
                            darknessWeight: node.darknessWeight,
                            airmassWeight: node.airmassWeight,
                            minScoreToRun: node.minScoreToRun,
                            recomputeEveryNExposures:
                                node.recomputeEveryNExposures,
                            finishIterationOnSwitch:
                                node.finishIterationOnSwitch,
                            swapHysteresisSecs: node.swapHysteresisSecs,
                            brightnessTierPreferences:
                                node.brightnessTierPreferences,
                            maxConditionsScoreAgeSecs:
                                node.maxConditionsScoreAgeSecs,
                            // Carry the OTHER nullable through the explicit
                            // rebuild so toggling swap off doesn't wipe the
                            // moon gate.
                            minMoonSeparationDeg: node.minMoonSeparationDeg,
                          ));
                        }
                      }
                    : null,
              ),
              const SizedBox(width: 8),
              Text(
                enabled ? 'On' : 'Off',
                style: TextStyle(color: colors.textSecondary),
              ),
            ],
          ),
        ),

        // The four sub-controls are hidden when the feature is off — both
        // because they would be meaningless (the Rust executor ignores
        // them when `swap_on_conditions_below` is None) and because
        // showing four greyed-out inputs creates a wall of noise users
        // have to mentally filter past.
        if (enabled) ...[
          NodePropertyField(
            colors: colors,
            label: 'Conditions score below which swap engages (0–100)',
            child: NodeNumberInput(
              colors: colors,
              value: node.swapOnConditionsBelow ?? _defaultSwapThreshold,
              min: 0,
              max: 100,
              decimals: 1,
              onChanged: (v) =>
                  onUpdate(node.copyWith(swapOnConditionsBelow: v)),
            ),
          ),
          NodePropertyField(
            colors: colors,
            label: 'Minimum seconds between swaps (hysteresis)',
            child: NodeNumberInput(
              colors: colors,
              value: node.swapHysteresisSecs,
              min: 0,
              // 24 h cap — stops a fat-fingered keypress from disabling
              // the feature in practice. Real-world values sit in the
              // 60–600 s band.
              max: 86400,
              decimals: 0,
              suffix: 's',
              onChanged: (v) => onUpdate(node.copyWith(swapHysteresisSecs: v)),
            ),
          ),
          NodePropertyField(
            colors: colors,
            label: 'Maximum age of conditions score before fallback',
            child: NodeNumberInput(
              colors: colors,
              value: node.maxConditionsScoreAgeSecs.toDouble(),
              min: 0,
              // Same 24 h ceiling as hysteresis — anything older than a
              // night is functionally "no telemetry" anyway.
              max: 86400,
              decimals: 0,
              suffix: 's',
              onChanged: (v) =>
                  onUpdate(node.copyWith(maxConditionsScoreAgeSecs: v.toInt())),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Per-tier acceptance floors',
            style: TextStyle(
              fontSize: Responsive.fontSize(context, 12),
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'A tier accepts the current sky when the conditions score is '
            'at or above its floor. Defaults: faint 70 / medium 50 / '
            'bright 30.',
            style: TextStyle(
              fontSize: Responsive.fontSize(context, 11),
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          NodePropertyField(
            colors: colors,
            label: 'Faint (galaxies, dim nebulae): min score',
            child: NodeNumberInput(
              colors: colors,
              value: prefs.faintMinScore,
              min: 0,
              max: 100,
              decimals: 1,
              onChanged: (v) => onUpdate(node.copyWith(
                brightnessTierPreferences: prefs.copyWith(faintMinScore: v),
              )),
            ),
          ),
          NodePropertyField(
            colors: colors,
            label: 'Medium (bright galaxies, dim nebulae). Min score',
            child: NodeNumberInput(
              colors: colors,
              value: prefs.mediumMinScore,
              min: 0,
              max: 100,
              decimals: 1,
              onChanged: (v) => onUpdate(node.copyWith(
                brightnessTierPreferences: prefs.copyWith(mediumMinScore: v),
              )),
            ),
          ),
          NodePropertyField(
            colors: colors,
            label: 'Bright (planetaries, open clusters): min score',
            child: NodeNumberInput(
              colors: colors,
              value: prefs.brightMinScore,
              min: 0,
              max: 100,
              decimals: 1,
              onChanged: (v) => onUpdate(node.copyWith(
                brightnessTierPreferences: prefs.copyWith(brightMinScore: v),
              )),
            ),
          ),
          const SizedBox(height: 6),
          _TierOrderIndicator(colors: colors, prefs: prefs),
        ],
      ],
    );
  }
}

/// Surface a friendly warning when the user inverts the canonical tier
/// ordering (faint ≥ medium ≥ bright). The Rust executor still runs in
/// that case — it just uses whatever the user typed — but the resulting
/// behaviour is rarely what people intend, so we flag it loudly.
class _TierOrderIndicator extends StatelessWidget {
  final SkotiqColors colors;
  final BrightnessTierPreferences prefs;

  const _TierOrderIndicator({required this.colors, required this.prefs});

  @override
  Widget build(BuildContext context) {
    final ordered = prefs.faintMinScore >= prefs.mediumMinScore &&
        prefs.mediumMinScore >= prefs.brightMinScore;
    if (ordered) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: SkotiqDecorations.iconChip(
        colors.warning,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.alertTriangle, size: 16, color: colors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Tier floors are out of order. Expected faint ≥ medium ≥ '
              'bright; faint targets normally need the cleanest sky.',
              style: TextStyle(
                fontSize: Responsive.fontSize(context, 11),
                color: colors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The step's TargetHeader children ranked now by the app's one target
/// scorer, with the step's weights and floor (its own horizon when it has
/// one, else the site's): the same ranking the step makes when it decides,
/// refreshed as the sky moves.
class _LiveRankingPreview extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final TargetSchedulerNode node;
  final Sequence sequence;
  final LocationSettings? location;

  const _LiveRankingPreview({
    required this.colors,
    required this.node,
    required this.sequence,
    required this.location,
  });

  @override
  ConsumerState<_LiveRankingPreview> createState() =>
      _LiveRankingPreviewState();
}

class _LiveRankingPreviewState extends ConsumerState<_LiveRankingPreview> {
  int? _inputs;
  Future<List<SchedulerTargetScore>>? _ranking;

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final node = widget.node;
    final location = widget.location;
    final children = node.childIds
        .map((id) => widget.sequence.nodes[id])
        .whereType<TargetHeaderNode>()
        .toList();

    if (children.isEmpty) {
      return _PreviewPlaceholder(
        colors: colors,
        message: 'Add TargetHeader children to see live rankings.',
      );
    }
    if (location == null) {
      return _PreviewPlaceholder(
        colors: colors,
        message: 'Set your observer location in Settings to enable scoring.',
      );
    }

    final tick = ref.watch(tickerProvider(TickerCadence.thirtySeconds));
    final now = (tick.valueOrNull ?? DateTime.now()).toUtc();
    final ownHorizon = node.horizonProfile;
    final siteFloor = ref.watch(altitudeFloorProvider);
    final scorer = ref.watch(targetScorerProvider);
    // Ranked again only when something it is ranked from changed.
    final inputs = Object.hashAll([
      node,
      ...children,
      now,
      location.latitude,
      location.longitude,
      ownHorizon ?? siteFloor,
      scorer,
    ]);
    if (_inputs != inputs) {
      _inputs = inputs;
      final floor =
          ownHorizon == null ? siteFloor.asSamples() : _samplesOf(ownHorizon);
      _ranking = scorer.rankSchedulerTargets(
        latitudeDeg: location.latitude,
        longitudeDeg: location.longitude,
        now: now,
        targets: [
          for (final header in children)
            SchedulerTarget(
              id: header.id,
              name: header.targetName,
              raHours: header.raHours,
              decDegrees: header.decDegrees,
              minAltitudeDeg: header.minAltitude,
              startAfter: header.startAfter,
              endBefore: header.endBefore,
              priority: header.priority,
            ),
        ],
        weights: node.scoringWeights,
        minMoonSeparationDeg: node.minMoonSeparationDeg,
        floor: floor,
      );
    }

    return FutureBuilder<List<SchedulerTargetScore>>(
      future: _ranking,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _PreviewPlaceholder(
            colors: colors,
            message: 'Could not rank the targets: ${snapshot.error}',
          );
        }
        final scores = snapshot.data;
        if (scores == null) {
          return _PreviewPlaceholder(colors: colors, message: 'Ranking...');
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final s in scores)
              _ScoreRow(
                colors: colors,
                score: s,
                threshold: node.minScoreToRun,
              ),
          ],
        );
      },
    );
  }
}

/// A step's own horizon as the floor by azimuth, samples in compass order.
AltitudeFloorSamples _samplesOf(HorizonProfile horizon) {
  final samples = [...horizon.samples]
    ..sort((a, b) => a.azimuthDegrees.compareTo(b.azimuthDegrees));
  return AltitudeFloorSamples(
    [for (final s in samples) s.azimuthDegrees],
    [for (final s in samples) s.altitudeDegrees],
  );
}

class _ScoreRow extends StatelessWidget {
  final SkotiqColors colors;
  final SchedulerTargetScore score;
  final double threshold;
  const _ScoreRow({
    required this.colors,
    required this.score,
    required this.threshold,
  });

  @override
  Widget build(BuildContext context) {
    final passes = score.runnable && score.totalScore >= threshold;
    final fillColor = passes ? colors.success : colors.warning;
    final airmass = score.airmass;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 28,
            decoration: BoxDecoration(
              color: fillColor,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  score.target.name,
                  style: TextStyle(
                    fontSize: Responsive.fontSize(context, 12),
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
                Text(
                  'alt ${score.altitudeDeg.toStringAsFixed(0)}° • '
                  'airmass ${airmass == null ? '∞' : airmass.toStringAsFixed(2)} • '
                  'moon ${score.moonDistanceDeg.toStringAsFixed(0)}°',
                  style: TextStyle(
                    fontSize: Responsive.fontSize(context, 10),
                    color: colors.textSecondary,
                  ),
                ),
                if (score.skipReason case final reason?)
                  Text(
                    'Will not run now: $reason',
                    style: TextStyle(
                      fontSize: Responsive.fontSize(context, 10),
                      color: colors.warning,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            score.totalScore.toStringAsFixed(0),
            style: TextStyle(
              fontSize: Responsive.fontSize(context, 14),
              fontWeight: FontWeight.w700,
              color: fillColor,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          Text(
            ' / 100',
            style: TextStyle(
              fontSize: Responsive.fontSize(context, 10),
              color: colors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
