// Installed-catalog and SIMBAD search-result sections that mount under the
// candidate list once the user has typed enough characters into the planner
// search field. Both answer the same question the candidate list cannot: "the
// thing I typed is not scored for tonight — where is it?"
part of '../planner_screen.dart';

/// The two lookup sections, in one widget, so the candidate list appends ONE
/// item rather than reasoning about query lengths itself.
class _PlannerSearchResults extends ConsumerWidget {
  final String query;

  const _PlannerSearchResults({required this.query});

  /// Characters needed before the installed catalog is searched.
  static const int localQueryFloor = 2;

  /// Characters needed before SIMBAD is asked. Higher, because it is a network
  /// round trip to a shared service.
  static const int remoteQueryFloor = 3;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trimmed = query.trim();
    if (trimmed.length < localQueryFloor) return const SizedBox.shrink();
    final candidates =
        ref.watch(plannerFilteredSuggestionsProvider).valueOrNull ?? const [];

    return Padding(
      padding: const EdgeInsets.only(top: SkotiqTokens.space2xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _InstalledCatalogResultsSection(query: trimmed),
          if (trimmed.length >= remoteQueryFloor)
            _SimbadResultsSection(
              query: trimmed,
              hasLocalMatches: candidates.isNotEmpty,
            ),
        ],
      ),
    );
  }
}

/// Section that resolves a name fragment against the installed object catalog
/// and renders the matches as send-to-framing rows.
class _InstalledCatalogResultsSection extends ConsumerWidget {
  final String query;

  const _InstalledCatalogResultsSection({required this.query});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(plannerInstalledCatalogSearchProvider(query));

    return async.when(
      loading: () =>
          const _SearchProgressLine(label: 'Searching installed catalogs'),
      error: (e, _) => _SearchProblemLine(
        label: 'Installed catalog lookup failed',
        detail: '$e',
      ),
      data: (matches) {
        if (matches.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionTitle(
              icon: LucideIcons.library,
              title: 'Installed catalog',
              trailing: SkotiqChip(label: '${matches.length}'),
            ),
            SkotiqPanel(
              padding: const EdgeInsets.symmetric(
                horizontal: SkotiqTokens.spaceMd,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < matches.length; i++)
                    _CatalogResultRow(
                      match: matches[i],
                      showDivider: i < matches.length - 1,
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _CatalogResultRow extends ConsumerWidget {
  final CatalogSearchResult match;
  final bool showDivider;

  const _CatalogResultRow({required this.match, required this.showDivider});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final raHours = match.ra / 15.0;
    return ListRow(
      title: match.name,
      icon: LucideIcons.star,
      showDivider: showDivider,
      trailingWidget: _SearchResultActions(
        raHours: raHours,
        decDegrees: match.dec,
        name: match.name,
      ),
    );
  }
}

class _SimbadResultsSection extends ConsumerWidget {
  final String query;
  final bool hasLocalMatches;

  const _SimbadResultsSection({
    required this.query,
    required this.hasLocalMatches,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(plannerSimbadResultsProvider(query));

    return async.when(
      loading: () => const _SearchProgressLine(label: 'Searching SIMBAD'),
      error: (e, _) => _SearchProblemLine(
        label: 'SIMBAD lookup failed',
        detail: '$e',
      ),
      data: (matches) {
        if (matches.isEmpty) {
          if (hasLocalMatches) return const SizedBox.shrink();
          // A lookup that succeeded and returned nothing is an ANSWER, not a
          // problem: one quiet line, not a banner (02 rule 4).
          return _SearchQuietLine(text: 'SIMBAD has no object named "$query".');
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: SkotiqTokens.spaceLg),
            SectionTitle(
              icon: LucideIcons.globe2,
              title: 'From SIMBAD',
              trailing: SkotiqChip(label: '${matches.length}'),
            ),
            SkotiqPanel(
              padding: const EdgeInsets.symmetric(
                horizontal: SkotiqTokens.spaceMd,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < matches.length; i++)
                    _SimbadResultRow(
                      match: matches[i],
                      showDivider: i < matches.length - 1,
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SimbadResultRow extends ConsumerWidget {
  final SimbadNameMatch match;
  final bool showDivider;

  const _SimbadResultRow({required this.match, required this.showDivider});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListRow(
      title: match.mainId,
      icon: LucideIcons.star,
      showDivider: showDivider,
      trailingWidget: _SearchResultActions(
        raHours: match.raHours,
        decDegrees: match.decDegrees,
        name: match.mainId,
      ),
    );
  }
}

/// The two things you can do with a name the planner resolved but did not
/// score: look at it, or frame it. Both are icon buttons — the row is not the
/// page's action.
class _SearchResultActions extends ConsumerWidget {
  final double raHours;
  final double decDegrees;
  final String name;

  const _SearchResultActions({
    required this.raHours,
    required this.decDegrees,
    required this.name,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'RA ${CoordinateFormat.ra(raHours)}  '
          'Dec ${CoordinateFormat.dec(decDegrees)}',
          style: SkotiqTypography.monoCaption.copyWith(
            color: SkotiqColors.of(context).textMuted,
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceSm),
        SkotiqIconButton(
          icon: LucideIcons.globe,
          tooltip: context.l10n.text('plannerOpenPlanetarium'),
          size: IconButtonSize.sm,
          onPressed: () => showTargetInSky(
            context,
            ref,
            raHours: raHours,
            decDegrees: decDegrees,
            name: name,
          ),
        ),
        SkotiqIconButton(
          icon: LucideIcons.crop,
          tooltip: 'Send to framing',
          size: IconButtonSize.sm,
          onPressed: () {
            ref.read(framingProvider.notifier).setTargetCoordinates(
                  raHours,
                  decDegrees,
                  name: name,
                );
            final uri = Uri(
              path: '/framing',
              queryParameters: {
                'ra': raHours.toStringAsFixed(6),
                'dec': decDegrees.toStringAsFixed(6),
                'name': name,
              },
            );
            context.go(uri.toString());
          },
        ),
      ],
    );
  }
}

/// One line saying a lookup is in flight.
class _SearchProgressLine extends StatelessWidget {
  final String label;

  const _SearchProgressLine({required this.label});

  /// The spinner's edge length.
  static const double _spinner = 14;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceSm),
      child: Row(
        children: [
          SizedBox(
            width: _spinner,
            height: _spinner,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colors.primary,
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Text(
            label,
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// One muted line stating a lookup's result. Not a banner: nothing is wrong.
class _SearchQuietLine extends StatelessWidget {
  final String text;

  const _SearchQuietLine({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceSm),
      child: Text(
        text,
        style: SkotiqTypography.bodySm.copyWith(
          color: SkotiqColors.of(context).textMuted,
        ),
      ),
    );
  }
}

/// One line saying a lookup did not produce anything usable.
class _SearchProblemLine extends StatelessWidget {
  final String label;
  final String detail;

  const _SearchProblemLine({required this.label, required this.detail});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceSm),
      child: SkotiqBanner(
        title: label,
        message: detail,
        tone: BannerTone.warning,
      ),
    );
  }
}
