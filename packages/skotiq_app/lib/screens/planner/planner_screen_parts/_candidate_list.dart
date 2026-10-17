// The candidate list: the eyebrow column-header row, one `Candidate` per
// scored target, and cursor-driven pagination.
part of '../planner_screen.dart';

/// The width of the Tonight tab's detail column (05 §15: "Plan detail 380").
const double _kPlannerDetailWidth = 380;

/// Minimum altitude the "imageable" readout is measured against when the
/// filter state does not name one. Mirrors the suggestion pipeline's own
/// default so the label and the number describe the same threshold.
const double _kPlannerDefaultMinAltitude = 30;

class _CandidateList extends ConsumerWidget {
  final List<TargetSuggestion> candidates;
  final SkotiqColors colors;
  final ScrollController scrollController;
  final int? selectedTargetId;
  final ValueChanged<TargetSuggestion> onSelect;

  /// What the optimizer flagged about tonight as a whole (a bright moon, a
  /// short window). One banner, joined — never one per factor.
  final List<String> riskFactors;

  const _CandidateList({
    required this.candidates,
    required this.colors,
    required this.scrollController,
    required this.selectedTargetId,
    required this.onSelect,
    required this.riskFactors,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final visibleCount =
        ref.watch(_plannerVisibleCountProvider).clamp(0, candidates.length);
    final visible = candidates.take(visibleCount).toList(growable: false);
    final filters = ref.watch(suggestionFilterProvider);
    final minAltitude =
        filters.minCurrentAltitude ?? _kPlannerDefaultMinAltitude;
    final night = ref.watch(_plannerNightWindowProvider);
    // A typed name that tonight's scorer never saw still has to be findable:
    // the installed catalog and SIMBAD answer for it under the list.
    final query = filters.searchQuery.trim();
    final hasLookups = query.length >= _PlannerSearchResults.localQueryFloor;
    final hasLoadMore = visibleCount < candidates.length;
    final hasRisks = riskFactors.isNotEmpty;
    final leading = hasRisks ? 2 : 1;

    return ListView.separated(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.space2xl,
        vertical: SkotiqTokens.spaceMd,
      ),
      itemCount: visible.length +
          leading +
          (hasLoadMore ? 1 : 0) +
          (hasLookups ? 1 : 0),
      separatorBuilder: (_, __) =>
          const SizedBox(height: SkotiqTokens.spaceSm),
      itemBuilder: (context, index) {
        if (hasRisks && index == 0) {
          return PlanningRisksBanner(riskFactors: riskFactors);
        }
        if (index == leading - 1) {
          return _CandidateColumnHeader(
            count: _candidateCountLabel(
              l10n,
              total: candidates.length,
              shown: visible.length,
            ),
          );
        }
        final rowIndex = index - leading;
        if (rowIndex >= visible.length) {
          final tailIndex = rowIndex - visible.length;
          if (hasLoadMore && tailIndex == 0) {
            return Align(
              child: Padding(
                padding: const EdgeInsets.only(top: SkotiqTokens.spaceSm),
                child: SkotiqButton(
                  label: 'Load more '
                      '(${candidates.length - visibleCount} remaining)',
                  icon: LucideIcons.chevronDown,
                  variant: ButtonVariant.secondary,
                  size: ButtonSize.small,
                  onPressed: () {
                    final next = (visibleCount + _kPlannerPageSize)
                        .clamp(0, candidates.length);
                    ref.read(_plannerVisibleCountProvider.notifier).state =
                        next;
                  },
                ),
              ),
            );
          }
          return _PlannerSearchResults(query: query);
        }

        final candidate = visible[rowIndex];
        final selected = candidate.targetId == selectedTargetId;
        return _PlannerCandidateRow(
          key: ValueKey('candidate-${candidate.targetId}'),
          suggestion: candidate,
          selected: selected,
          minAltitude: minAltitude,
          night: night,
          onSelect: () => onSelect(candidate),
        );
      },
    );
  }
}

/// "38 candidates · best 12 shown", or just "38 candidates" when the list is
/// not paged, or "1 candidate" when there is only one. Three keys rather than a
/// plural rule, which the string table does not have.
String _candidateCountLabel(
  SkotiqLocalizations l10n, {
  required int total,
  required int shown,
}) {
  if (total == 1) return l10n.text('plannerCandidateCountOne');
  if (shown >= total) {
    return l10n.text(
      'plannerCandidateCountAll',
      params: {'total': '$total'},
    );
  }
  return l10n.text(
    'plannerCandidateCount',
    params: {'total': '$total', 'shown': '$shown'},
  );
}

/// The column-header row above the candidates: the count on the left and the
/// three measured columns named on the right, all in `eyebrow`.
class _CandidateColumnHeader extends StatelessWidget {
  final String count;

  const _CandidateColumnHeader({required this.count});

  /// Below this the column names are dropped: a `Candidate` narrower than this
  /// has already given its measurements up to the name, so naming columns that
  /// are not there would be the header describing a row nobody can see.
  static const double _columnNamesFloor = 560;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final l10n = context.l10n;
    final style =
        SkotiqTypography.eyebrow.copyWith(color: colors.textMuted);

    return Padding(
      padding: const EdgeInsets.only(
        left: Candidate.badgeSize + Candidate.columnGap,
        bottom: SkotiqTokens.spaceXs,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            Expanded(
              child: Text(
                count.toUpperCase(),
                style: style,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (constraints.maxWidth >= _columnNamesFloor) ...[
              Text(l10n.text('plannerColTransit').toUpperCase(), style: style),
              const SizedBox(width: SkotiqTokens.space2xl),
              Text(
                l10n.text('plannerColImageable').toUpperCase(),
                style: style,
              ),
              const SizedBox(width: SkotiqTokens.space2xl),
              Text(l10n.text('plannerColWindow').toUpperCase(), style: style),
            ],
          ],
        ),
      ),
    );
  }
}

/// One scored target, rendered with the shared [Candidate] component.
class _PlannerCandidateRow extends ConsumerWidget {
  final TargetSuggestion suggestion;
  final bool selected;
  final double minAltitude;
  final _PlannerNightWindow? night;
  final VoidCallback onSelect;

  const _PlannerCandidateRow({
    super.key,
    required this.suggestion,
    required this.selected,
    required this.minAltitude,
    required this.night,
    required this.onSelect,
  });

  /// Above this score a candidate is worth imaging; below it, it is marginal.
  /// The two tones the score badge takes (05 §9).
  static const double _goodScore = 75;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final l10n = context.l10n;
    final visibility = suggestion.visibility;

    return Candidate(
      score: suggestion.totalScore.round().toString(),
      scoreTone:
          suggestion.totalScore >= _goodScore ? colors.success : colors.warning,
      name: suggestion.targetName,
      detail: _candidateDetailLine(suggestion),
      selected: selected,
      onTap: onSelect,
      readouts: [
        Readout(
          value: _transitValue(visibility),
          label: l10n.text('plannerColTransit'),
          size: ReadoutSize.sm,
        ),
        Readout(
          value: _hoursAndMinutes(visibility.hoursAboveMinAlt),
          label: l10n.text(
            'plannerAboveMin',
            params: {'value': minAltitude.round().toString()},
          ),
          size: ReadoutSize.sm,
        ),
      ],
      window: night?.windowFor(visibility),
      // 06 SS Plan: the SELECTED row carries "Image tonight" - the thing you
      // do with the target the detail column is describing - and every other
      // row parks it instead. One button per row either way, and neither is
      // the page's primary.
      action: SkotiqButton(
        label: selected
            ? l10n.text('plannerImageTonight')
            : l10n.text('plannerAddTarget'),
        variant: ButtonVariant.secondary,
        size: ButtonSize.small,
        onPressed: () => selected
            ? _imageTonight(context, ref)
            : _addToObservingList(context, ref, colors),
      ),
    );
  }

  Future<void> _imageTonight(BuildContext context, WidgetRef ref) async {
    final loaded = await addPlanTonightTargetToSequencer(
      context: context,
      ref: ref,
      target: suggestion,
      replaceSequence: true,
      includeSessionPreamble: true,
    );
    if (!loaded || !context.mounted) return;

    final colors = SkotiqColors.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Loaded ${suggestion.targetName} into the sequencer'),
        backgroundColor: colors.success,
      ),
    );
    context.go('/sequencer');
  }

  Future<void> _addToObservingList(
    BuildContext context,
    WidgetRef ref,
    SkotiqColors colors,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _CandidateObservingListDialog(
        suggestion: suggestion,
        colors: colors,
      ),
    );
  }
}

/// The one muted line under a candidate's name: catalogue, type and size, in
/// the order the mockup reads them. Parts that are not known are left out
/// rather than filled with a placeholder.
String _candidateDetailLine(TargetSuggestion suggestion) {
  final parts = <String>[
    if (suggestion.catalogId != null &&
        suggestion.catalogId != suggestion.targetName)
      suggestion.catalogId!,
    if (suggestion.objectType != null) suggestion.objectType!,
    if (suggestion.sizeArcmin != null && suggestion.sizeArcmin! > 0)
      _formatSizeLabel(suggestion.sizeArcmin),
    if (suggestion.magnitude != null)
      'mag ${suggestion.magnitude!.toStringAsFixed(1)}',
    if (suggestion.constellation != null) suggestion.constellation!,
  ];
  return parts.join(' · ');
}

/// "01:08 · 85°" — the transit time and the altitude it transits at, or null
/// when the target has no transit tonight.
String? _transitValue(TargetVisibilityInfo visibility) {
  final time = visibility.transitTime;
  final altitude = visibility.transitAltitude;
  if (time == null && altitude == null) return null;
  final clock = time == null ? null : _clock(time);
  final alt = altitude == null ? null : '${altitude.round()}°';
  if (clock == null) return alt;
  if (alt == null) return clock;
  return '$clock · $alt';
}

/// "6h 40m", with the minutes CARRIED into the hour so a rounded 60 never
/// shows. Null in, null out — the readout renders an em dash for it.
String? _hoursAndMinutes(double? hours) {
  if (hours == null) return null;
  var h = hours.floor();
  var m = ((hours - h) * 60).round();
  if (m == 60) {
    h += 1;
    m = 0;
  }
  if (h == 0) return '${m}m';
  if (m == 0) return '${h}h';
  return '${h}h ${m}m';
}

/// 24-hour clock, zero-padded.
String _clock(DateTime t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Tonight's astronomical-dark window, and where a target's own rise/set span
/// falls inside it.
///
/// The window bar is a fraction of THE NIGHT, so it needs the night before it
/// can place anything. Held as a provider so every candidate row reads one
/// computation rather than recomputing twilight per row.
@immutable
class _PlannerNightWindow {
  final DateTime start;
  final DateTime end;

  const _PlannerNightWindow({required this.start, required this.end});

  /// Where [visibility]'s above-horizon span sits on this night, or null when
  /// the target has no span to draw (never rises, or its rise/set are not
  /// known and it is not circumpolar).
  CandidateWindow? windowFor(TargetVisibilityInfo visibility) {
    if (visibility.neverRises) return null;
    final span = end.difference(start).inSeconds;
    if (span <= 0) return null;

    double fraction(DateTime t) =>
        (t.difference(start).inSeconds / span).clamp(0.0, 1.0);

    final double from;
    final double to;
    if (visibility.isCircumpolar) {
      from = 0;
      to = 1;
    } else {
      final rise = visibility.riseTime;
      final set = visibility.setTime;
      if (rise == null && set == null) return null;
      from = rise == null ? 0 : fraction(rise);
      to = set == null ? 1 : fraction(set);
    }
    if (to <= from) return null;

    return CandidateWindow(
      start: from,
      end: to,
      now: fraction(DateTime.now()),
    );
  }
}

/// Tonight's astronomical-dark window for the configured site, or null when
/// there is no site or the sun never sets far enough for one.
final _plannerNightWindowProvider = Provider.autoDispose<_PlannerNightWindow?>(
  (ref) {
    final location = ref.watch(appObserverLocationProvider);
    if (plannerSiteUnset(location)) return null;
    final twilight = AstronomyCalculations.calculateTwilightTimes(
      date: DateTime.now(),
      latitudeDeg: location!.latitude,
      longitudeDeg: location.longitude,
    );
    final dusk = twilight.astronomicalDusk;
    final dawn = twilight.astronomicalDawn;
    if (dusk == null || dawn == null) return null;
    // Dusk and dawn come back for the same calendar date, so dawn precedes
    // dusk by a day; carry it forward or every window measures negative.
    final end = dawn.isAfter(dusk) ? dawn : dawn.add(const Duration(days: 1));
    return _PlannerNightWindow(start: dusk, end: end);
  },
);
