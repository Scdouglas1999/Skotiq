import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../widgets/narrator/narrator_card.dart';
import '../../widgets/narrator/narrator_feed.dart'
    show formatNarratorRelativeTime;
import 'first_light_format.dart';
import 'widgets/transient_candidate_card.dart';

/// Filters for the First Light candidate list.
enum FirstLightFilter {
  all('All'),
  unnamed('Unnamed'),
  confirmed('Confirmed'),
  dismissed('Dismissed');

  const FirstLightFilter(this.label);
  final String label;
}

final _firstLightFilterProvider = StateProvider<FirstLightFilter>((ref) {
  return FirstLightFilter.all;
});

/// Pillar B ("First Light") — the discovery surface.
///
/// Difference-imaging compares each fresh, plate-solved frame against the deep
/// personal-atlas template for the patch it covers; whatever changed surfaces
/// here as a [TransientDetectionRow]. This view leads with the most exciting
/// thing the Night Narrator celebrated tonight, then lists every candidate with
/// its side-by-side template / frame / residual cutouts, its measured metrics
/// and catalog verdict, and the one-tap path to submit it to AAVSO, the MPC, or
/// the TNS.
///
/// Backend-aware: the candidate feed and triage both go through providers that
/// read the local DB on desktop and the appliance's `/api/firstlight/*`
/// endpoints over [NetworkBackend] on a companion tablet, so the surface is
/// identical on desktop and mobile.
class FirstLightView extends ConsumerWidget {
  const FirstLightView({super.key, this.showHeader = true});

  /// Whether to render the [ScreenHeader]. Off when embedded as a Science tab.
  final bool showHeader;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final candidatesAsync = ref.watch(firstLightCandidatesProvider);
    final filter = ref.watch(_firstLightFilterProvider);

    return Column(
      children: [
        if (showHeader)
          const ScreenHeader(
            title: 'First light',
            icon: SkotiqIcons.sparkle,
          ),
        const _IntroStrip(),
        _CelebrateBanner(colors: colors),
        _FilterBar(
          colors: colors,
          current: filter,
          onChanged: (f) =>
              ref.read(_firstLightFilterProvider.notifier).state = f,
        ),
        Expanded(
          child: candidatesAsync.when(
            data: (rows) => _List(rows: rows, filter: filter),
            loading: () => const Center(
              child: SkotiqCircularProgress(value: 0, indeterminate: true),
            ),
            error: (error, _) => _ErrorState(ref: ref, error: error),
          ),
        ),
      ],
    );
  }
}

/// What-this-is explainer strip. Mirrors the transient-alert citizen-science
/// strip so the two Science discovery surfaces read as siblings. Explains the
/// differencing AND the template-depth gate (a region produces nothing until its
/// tiles are deep enough), and — when the last scan reported a thin atlas —
/// surfaces a live "atlas not deep enough here yet" readout so a quiet sparse
/// region is explainable instead of reading as broken.
class _IntroStrip extends ConsumerWidget {
  const _IntroStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final coverage = ref.watch(firstLightCoverageProvider);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceLg,
        vertical: SkotiqTokens.spaceMd,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
                decoration: SkotiqDecorations.tintedBadge(colors.accent),
                child: Icon(
                  LucideIcons.radar,
                  size: SkotiqTokens.iconSm,
                  color: colors.accent,
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceMd),
              Expanded(
                child: Text(
                  'Every solved frame is differenced against your deep sky '
                  'atlas — but only where the atlas is at least 5 frames deep, '
                  'so a fresh patch of sky stays quiet until it builds up. '
                  'Anything that appeared, moved, or brightened on a deep patch '
                  'lands here to review, then submit to the TNS or export an '
                  'AAVSO / MPC report.',
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textSecondary,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
          if (coverage != null) ...[
            const SizedBox(height: SkotiqTokens.spaceSm),
            _CoverageReadout(coverage: coverage, colors: colors),
          ],
        ],
      ),
    );
  }
}

/// Live deep-tile readout from the most-recent scan's coverage envelope. Tells
/// the user, in plain terms, whether tonight's field was deep enough to search —
/// the "atlas not deep enough here yet" feedback that turns a silent thin-atlas
/// no-op into an explained quiet night.
class _CoverageReadout extends StatelessWidget {
  const _CoverageReadout({required this.coverage, required this.colors});

  final FirstLightCoverage coverage;
  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    final thin = coverage.isAtlasTooThin;
    final color = thin ? colors.warning : colors.success;
    final icon = thin ? LucideIcons.layers : SkotiqIcons.check;
    final text = thin
        ? 'Atlas not deep enough here yet — '
            '${coverage.tilesSkippedThin + coverage.tilesNoTemplate} of '
            '${coverage.tilesCovered} covered tiles still need more frames '
            'before differencing can run.'
        : '${coverage.tilesChecked} of ${coverage.tilesCovered} covered tiles '
            'were deep enough to search this scan.';
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceMd,
        vertical: SkotiqTokens.spaceSm,
      ),
      decoration: SkotiqDecorations.tintedBadge(
        color,
        borderRadius: SkotiqTokens.borderRadiusSm,
      ),
      child: Row(
        children: [
          Icon(icon, size: SkotiqTokens.iconXs, color: color),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Expanded(
            child: Text(
              text,
              style: SkotiqTypography.labelSm.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// The headline: the most recent celebrate-severity First Light Narrator event,
/// rendered prominently above the list. Quiet (renders nothing) until a
/// discovery is actually announced, so a clean-sky night shows no empty chrome.
class _CelebrateBanner extends ConsumerWidget {
  const _CelebrateBanner({required this.colors});

  final SkotiqColors colors;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(recentNarratorFeedProvider).valueOrNull;
    if (feed == null || feed.isEmpty) return const SizedBox.shrink();

    // The Narrator's First Light detectors pin the discovery events
    // (`first_light.transient` / `.brightening` / `.mover`); surface the most
    // recent one. Prefer celebrate severity (transient / brightening) over the
    // success-severity mover.
    NarratorEvent? best;
    for (final e in feed) {
      if (!e.eventType.startsWith('first_light.')) continue;
      if (best == null) {
        best = e;
      } else if (e.severity == NarratorSeverity.celebrate &&
          best.severity != NarratorSeverity.celebrate) {
        best = e;
      }
    }
    if (best == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SkotiqTokens.spaceLg,
        SkotiqTokens.spaceMd,
        SkotiqTokens.spaceLg,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                LucideIcons.sparkles,
                size: SkotiqTokens.iconSm,
                color: colors.accent,
              ),
              const SizedBox(width: SkotiqTokens.spaceXs),
              Text(
                'Tonight\'s highlight',
                style: SkotiqTypography.labelStrongSm.copyWith(
                  color: colors.accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          NarratorCard(
            event: best,
            relativeTime: formatNarratorRelativeTime(best.timestamp),
          ),
        ],
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.colors,
    required this.current,
    required this.onChanged,
  });

  final SkotiqColors colors;
  final FirstLightFilter current;
  final ValueChanged<FirstLightFilter> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceLg,
        vertical: SkotiqTokens.spaceSm,
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: FirstLightFilter.values.map((f) {
            return Padding(
              padding: const EdgeInsets.only(right: SkotiqTokens.spaceSm),
              child: SkotiqChip(
                label: f.label,
                selected: f == current,
                onTap: () => onChanged(f),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}

class _List extends StatelessWidget {
  const _List({required this.rows, required this.filter});

  final List<TransientDetectionRow> rows;
  final FirstLightFilter filter;

  List<TransientDetectionRow> get _filtered {
    switch (filter) {
      case FirstLightFilter.all:
        return rows.where((r) => !r.dismissed).toList(growable: false);
      case FirstLightFilter.unnamed:
        return rows
            .where((r) => r.catalogMatch == null && !r.dismissed)
            .toList(growable: false);
      case FirstLightFilter.confirmed:
        // Confirmed = reviewed AND not dismissed. A dismissed detection is also
        // marked reviewed (markReviewed sets reviewed=true, dismissed=true), so
        // without the !dismissed guard every dismissed artefact would pollute
        // the curated submit list the instant anything is dismissed.
        return rows
            .where((r) => r.reviewed && !r.dismissed)
            .toList(growable: false);
      case FirstLightFilter.dismissed:
        return rows.where((r) => r.dismissed).toList(growable: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    if (filtered.isEmpty) return _EmptyState(filter: filter);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile =
            constraints.maxWidth < SkotiqTokens.breakpointTablet;
        return ListView.builder(
          padding: isMobile
              ? SkotiqTokens.screenPaddingCompact
              : SkotiqTokens.screenPadding,
          itemCount: filtered.length,
          itemBuilder: (context, index) {
            return Padding(
              padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceMd),
              child: TransientCandidateCard(detection: filtered[index]),
            );
          },
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.filter});

  final FirstLightFilter filter;

  @override
  Widget build(BuildContext context) {
    final (title, body, icon) = _copy();
    return EmptyState(icon: icon, title: title, body: body);
  }

  (String, String, IconData) _copy() {
    switch (filter) {
      case FirstLightFilter.all:
        return (
          'No transients yet',
          'Keep imaging. Once a solved frame differs from your atlas template, '
              'the candidate appears here.',
          SkotiqIcons.sparkle,
        );
      case FirstLightFilter.unnamed:
        return (
          'No unnamed candidates',
          'An unnamed clean point source — one with no catalog match — is the '
              'headline possible-transient. None are flagged right now.',
          LucideIcons.radar,
        );
      case FirstLightFilter.confirmed:
        return (
          'Nothing confirmed yet',
          'Candidates you confirm with the Confirm action collect here, ready '
              'to submit.',
          SkotiqIcons.check,
        );
      case FirstLightFilter.dismissed:
        return (
          'No dismissed candidates',
          'Artefacts you dismiss are kept here so the difference pipeline never '
              're-announces them.',
          SkotiqIcons.close,
        );
    }
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.ref, required this.error});

  final WidgetRef ref;
  final Object error;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: LucideIcons.alertCircle,
      title: 'Could not load candidates',
      body: firstLightErrorBody(error),
      action: SkotiqButton(
        label: 'Retry',
        icon: SkotiqIcons.refresh,
        onPressed: () => ref.invalidate(firstLightCandidatesProvider),
      ),
    );
  }
}
