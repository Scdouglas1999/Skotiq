part of '../darkroom_screen.dart';

/// Which list the Darkroom landing state is showing.
///
/// The three the design contract names (06-screens, "Darkroom"): the recipes
/// there are to reopen, the nights that produced masters, and the masters
/// themselves. Ordered the way the operator arrives — a recipe is what most
/// visits want, a master is what a first visit has.
enum _DarkroomLandingTab {
  recipes,
  sessions,
  masters,
  passes;

  String get label => switch (this) {
        _DarkroomLandingTab.recipes => 'Recipes',
        _DarkroomLandingTab.sessions => 'Sessions',
        _DarkroomLandingTab.masters => 'Masters',
        _DarkroomLandingTab.passes => 'Passes',
      };
}

/// One master, with the recipes written over it.
///
/// The DAOs answer these separately — masters from [IntegratedMastersDao], the
/// recipes over a master by its FITS path — so the landing state joins them
/// once here rather than in three places that could disagree about how many
/// recipes a master has.
///
/// Joined on the master's own path, which is what `recipes.base_master_path`
/// stores. Never on list position: a master with no recipes returns an empty
/// list and would otherwise shift every later pairing by one.
class _DarkroomLandingEntry {
  final IntegratedMaster master;
  final List<DarkroomRecipe> recipes;

  const _DarkroomLandingEntry({required this.master, required this.recipes});

  /// The newest recipe over this master, or null when it has none.
  DarkroomRecipe? get newest => recipes.isEmpty ? null : recipes.first;
}

/// Everything the landing state lists, read once per visit.
class _DarkroomLandingData {
  final List<_DarkroomLandingEntry> entries;
  final List<ImagingSession> sessions;

  /// Every recorded pass, newest first: what calibrated, registered and
  /// integrated a night, live while it runs.
  final List<PassRecordSummary> passes;

  const _DarkroomLandingData({
    required this.entries,
    required this.sessions,
    this.passes = const <PassRecordSummary>[],
  });

  _DarkroomLandingData withPasses(List<PassRecordSummary> passes) =>
      _DarkroomLandingData(
          entries: entries, sessions: sessions, passes: passes);

  /// Every recipe over every master, newest first.
  List<(_DarkroomLandingEntry, DarkroomRecipe)> get recipes {
    final rows = <(_DarkroomLandingEntry, DarkroomRecipe)>[
      for (final entry in entries)
        for (final recipe in entry.recipes) (entry, recipe),
    ];
    rows.sort((a, b) => b.$2.updatedAt.compareTo(a.$2.updatedAt));
    return rows;
  }
}

/// What the landing state reads.
///
/// Read-only, and built from the DAO methods that already exist: this wave is
/// a re-skin, so it adds no query the app did not already run. `getAll` is the
/// masters list the session review's own library panel reads, and
/// `listForMaster` is what the editor calls when it resolves a master to its
/// newest recipe.
final _darkroomLandingProvider =
    FutureProvider.autoDispose<_DarkroomLandingData>((
  ref,
) async {
  final masters = await ref.watch(integratedMastersDaoProvider).getAll();
  final recipesDao = ref.watch(recipesDaoProvider);
  final entries = <_DarkroomLandingEntry>[];
  for (final master in masters) {
    final path = master.masterFitsPath;
    // A master whose integration never wrote a file has no pixels to interpret
    // and therefore no recipe path to look up. It still belongs on the Masters
    // list — with no recipe count — rather than being silently dropped.
    final recipes = path == null || path.isEmpty
        ? const <DarkroomRecipe>[]
        : await recipesDao.listForMaster(path);
    entries.add(_DarkroomLandingEntry(master: master, recipes: recipes));
  }
  final sessions = await ref.watch(sessionsDaoProvider).getAllSessions();
  return _DarkroomLandingData(entries: entries, sessions: sessions);
});

/// The Darkroom with no master and no recipe named: what there is to open.
///
/// Until the rail carried a Darkroom destination this route was only ever
/// reached with a query parameter, so a bare `/darkroom` was a dead end whose
/// empty state told the operator to go and find a master somewhere else. The
/// rail now points here, and a destination that answers "there is nothing to
/// open" while the database holds nine masters is the cry-wolf defect class.
///
/// The controller is deliberately NOT watched on this branch. Its load fails
/// by design when the scope names neither a recipe nor a master, and watching
/// it would put that refusal back on screen underneath the list.
class _DarkroomLandingView extends ConsumerStatefulWidget {
  const _DarkroomLandingView();

  @override
  ConsumerState<_DarkroomLandingView> createState() =>
      _DarkroomLandingViewState();
}

class _DarkroomLandingViewState extends ConsumerState<_DarkroomLandingView> {
  /// The tab the operator picked on this visit, or null until they pick one.
  _DarkroomLandingTab? _chosen;

  /// The picked tab, otherwise the first one with something in it.
  ///
  /// Opening on "Recipes 0" beside "Sessions 66" put an empty state in front
  /// of the content; the empty Recipes tab is still the answer when nothing
  /// has anything in it, because it explains where recipes come from.
  _DarkroomLandingTab _tabFor(_DarkroomLandingData? data) {
    final chosen = _chosen;
    if (chosen != null) return chosen;
    if (data == null) return _DarkroomLandingTab.recipes;
    // A pass running now is what a visit is most likely here to watch.
    if (data.passes.any((pass) => !pass.ended)) {
      return _DarkroomLandingTab.passes;
    }
    return _DarkroomLandingTab.values.firstWhere(
      (tab) => _countOf(tab, data) > 0,
      orElse: () => _DarkroomLandingTab.recipes,
    );
  }

  void _choose(_DarkroomLandingTab tab) => setState(() => _chosen = tab);

  @override
  Widget build(BuildContext context) {
    // The pass records are read on their own, so a slow read of the record
    // folder never holds up the lists.
    final passes = ref.watch(darkroomPassRecordsProvider).valueOrNull ??
        const <PassRecordSummary>[];
    final data = ref
        .watch(_darkroomLandingProvider)
        .whenData((value) => value.withPasses(passes));
    final tab = _tabFor(data.valueOrNull);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Darkroom',
          icon: SkotiqIcons.aperture,
          tabs: AdaptiveTabBar(
            tabs: [
              for (final tab in _DarkroomLandingTab.values)
                AdaptiveTab(
                  label: tab.label,
                  count: _countFor(tab, data),
                  buttonKey: ValueKey('darkroom_landing_tab_${tab.name}'),
                ),
            ],
            selectedIndex: tab.index,
            onSelected: (index) => _choose(_DarkroomLandingTab.values[index]),
          ),
          actions: [
            SkotiqButton(
              label: 'Build masters',
              onPressed: () async {
                await showDialog<void>(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) => const BuildMastersDialog());
                if (mounted) ref.invalidate(_darkroomLandingProvider);
              },
            ),
            SkotiqIconButton(
              icon: SkotiqIcons.refresh,
              tooltip: 'Reload the masters, recipes and sessions on this host',
              onPressed: () => ref.invalidate(_darkroomLandingProvider),
            ),
          ],
        ),
        Expanded(child: _body(data, tab)),
      ],
    );
  }

  /// The count chip on a tab, or null before the read answers.
  ///
  /// Null rather than `0`: a zero on the tab while the query is still running
  /// states a fact the screen does not know yet, and the chip is the only
  /// place the operator can read how much there is.
  String? _countFor(
    _DarkroomLandingTab tab,
    AsyncValue<_DarkroomLandingData> data,
  ) {
    final value = data.valueOrNull;
    if (value == null) return null;
    return '${_countOf(tab, value)}';
  }

  static int _countOf(_DarkroomLandingTab tab, _DarkroomLandingData data) =>
      switch (tab) {
        _DarkroomLandingTab.recipes => data.recipes.length,
        _DarkroomLandingTab.sessions => data.sessions.length,
        _DarkroomLandingTab.masters => data.entries.length,
        _DarkroomLandingTab.passes => data.passes.length,
      };

  Widget _body(
    AsyncValue<_DarkroomLandingData> data,
    _DarkroomLandingTab tab,
  ) {
    // The one loading, error and empty pattern (07, wave 3 checklist): a
    // centred spinner, ONE EmptyState with one button, never a stack of cards.
    return data.when(
      loading: () => const Center(
          child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36)),
      error: (error, _) => Center(
        child: EmptyState(
          icon: SkotiqIcons.imageOff,
          title: 'The Darkroom could not read this host',
          body: '$error',
          action: SkotiqButton(
            label: 'Try again',
            icon: SkotiqIcons.refresh,
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: () => ref.invalidate(_darkroomLandingProvider),
          ),
        ),
      ),
      data: (value) => switch (tab) {
        _DarkroomLandingTab.recipes => _recipes(value),
        _DarkroomLandingTab.sessions => _sessions(value),
        _DarkroomLandingTab.masters => _masters(value),
        _DarkroomLandingTab.passes => _passes(value),
      },
    );
  }

  /// The list body every tab shares: 24 px gutter, 8 px between rows.
  Widget _list({required List<Widget> children, required Key key}) {
    return ListView.separated(
      key: key,
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.space2xl,
        vertical: SkotiqTokens.spaceLg,
      ),
      itemCount: children.length,
      separatorBuilder: (_, __) => const SizedBox(height: SkotiqTokens.spaceSm),
      itemBuilder: (_, index) => children[index],
    );
  }

  Widget _recipes(_DarkroomLandingData data) {
    final rows = data.recipes;
    if (rows.isEmpty) {
      return Center(
        child: EmptyState(
          icon: SkotiqIcons.palette,
          title: 'No recipes yet',
          body: 'A recipe is one interpretation of a linear master. Open a '
              'master to write its first.',
          action: SkotiqButton(
            label: 'Browse masters',
            icon: SkotiqIcons.layers,
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: () => _choose(_DarkroomLandingTab.masters),
          ),
        ),
      );
    }
    return _list(
      key: const ValueKey('darkroom_landing_recipes'),
      children: [
        for (final (entry, recipe) in rows)
          Candidate(
            key: ValueKey('darkroom_landing_recipe_${recipe.id}'),
            score: '${_stepCount(recipe)}',
            scoreTone: recipe.createdBy == RecipeAuthor.autopilot
                ? SkotiqColors.of(context).primary
                : SkotiqColors.of(context).success,
            name: recipe.name.isEmpty ? 'Recipe ${recipe.id}' : recipe.name,
            detail: '${entry.master.name} · '
                '${recipe.createdBy == RecipeAuthor.autopilot ? 'Drafted for you' : 'Yours'}',
            readouts: [
              Readout(
                value: _relative(recipe.updatedAt),
                label: 'Edited',
                size: ReadoutSize.sm,
              ),
              Readout(
                value: '${entry.master.frameCount}',
                label: 'Frames',
                size: ReadoutSize.sm,
              ),
            ],
            action: SkotiqButton(
              label: 'Open',
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: recipe.id == null
                  ? null
                  : () => context.go(darkroomRecipeLocation(recipe.id!)),
            ),
            onTap: recipe.id == null
                ? null
                : () => context.go(darkroomRecipeLocation(recipe.id!)),
          ),
      ],
    );
  }

  Widget _masters(_DarkroomLandingData data) {
    if (data.entries.isEmpty) {
      return const Center(
        child: EmptyState(
          icon: SkotiqIcons.layers,
          title: 'No integrated masters on this host',
          body: 'Masters are written when a night is integrated. Finish a '
              'session, and its masters appear here.',
        ),
      );
    }
    final colors = SkotiqColors.of(context);
    return _list(
      key: const ValueKey('darkroom_landing_masters'),
      children: [
        for (final entry in data.entries)
          Candidate(
            key: ValueKey('darkroom_landing_master_${entry.master.id}'),
            score: '${entry.recipes.length}',
            scoreTone: entry.recipes.isEmpty ? colors.warning : colors.success,
            name: entry.master.name,
            detail: [
              '${entry.master.width} × ${entry.master.height}',
              '${entry.master.channels} '
                  'channel${entry.master.channels == 1 ? '' : 's'}',
              if (entry.master.filter != null) entry.master.filter!,
            ].join(' · '),
            readouts: [
              Readout(
                value: '${entry.master.frameCount}',
                label: 'Frames',
                size: ReadoutSize.sm,
              ),
              Readout(
                value: _hours(entry.master.totalIntegrationSeconds),
                label: 'Integrated',
                unit: 'h',
                size: ReadoutSize.sm,
              ),
              Readout(
                value: _relative(entry.master.createdAt),
                label: 'Stacked',
                size: ReadoutSize.sm,
              ),
            ],
            action: SkotiqButton(
              // The label states which of the two things pressing it does,
              // because the master decides: a master with a recipe reopens the
              // newest one, a master with none is offered its first.
              label: entry.newest == null ? 'Start a recipe' : 'Open',
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: () =>
                  context.go(darkroomMasterLocation(entry.master.id)),
            ),
            onTap: () => context.go(darkroomMasterLocation(entry.master.id)),
          ),
      ],
    );
  }

  Widget _sessions(_DarkroomLandingData data) {
    if (data.sessions.isEmpty) {
      return const Center(
        child: EmptyState(
          icon: SkotiqIcons.history,
          title: 'No sessions recorded yet',
          body: 'A session is one night of capture. The Darkroom lists them '
              'so a master can be found by the night it came from.',
        ),
      );
    }
    final sessions = [...data.sessions]
      ..sort((a, b) => b.startTime.compareTo(a.startTime));
    final colors = SkotiqColors.of(context);
    return _list(
      key: const ValueKey('darkroom_landing_sessions'),
      children: [
        for (final session in sessions)
          Candidate(
            key: ValueKey('darkroom_landing_session_${session.id}'),
            score: '${session.successfulExposures}',
            scoreTone: session.successfulExposures == 0
                ? colors.warning
                : colors.success,
            name: session.name?.trim().isNotEmpty ?? false
                ? session.name!.trim()
                : 'Session ${session.id}',
            detail: _night(session.startTime),
            readouts: [
              Readout(
                value: _hours(session.totalIntegrationSecs),
                label: 'Integrated',
                unit: 'h',
                size: ReadoutSize.sm,
              ),
              Readout(
                value: session.avgHfr?.toStringAsFixed(2),
                label: 'Mean HFR',
                unit: 'px',
                size: ReadoutSize.sm,
              ),
              Readout(
                value: '${session.failedExposures}',
                label: 'Failed',
                size: ReadoutSize.sm,
              ),
            ],
            action: SkotiqButton(
              label: 'Review',
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: () => context.go(sessionReviewLocation(session.id)),
            ),
            onTap: () => context.go(sessionReviewLocation(session.id)),
          ),
      ],
    );
  }

  Widget _passes(_DarkroomLandingData data) {
    final passes = data.passes;
    if (passes.isEmpty) {
      return const Center(
        child: EmptyState(
          icon: SkotiqIcons.history,
          title: 'No passes recorded yet',
          body: 'A pass is the Darkroom calibrating, registering and '
              'integrating a night into masters. Each one is recorded here '
              'as it runs.',
        ),
      );
    }
    final colors = SkotiqColors.of(context);
    return _list(
      key: const ValueKey('darkroom_landing_passes'),
      children: [
        for (final pass in passes)
          Candidate(
            key: ValueKey('darkroom_landing_pass_${pass.runId}'),
            score: pass.ended
                ? (pass.failure == null ? 'Done' : 'Stopped')
                : 'Live',
            scoreTone: !pass.ended
                ? colors.primary
                : (pass.failure == null ? colors.success : colors.error),
            name: pass.target ??
                'Pass of ${_night(pass.startedAt)} '
                    '${pass.startedAt.hour.toString().padLeft(2, '0')}:'
                    '${pass.startedAt.minute.toString().padLeft(2, '0')}',
            detail: [
              if (pass.sessionId != null) 'session ${pass.sessionId}',
              if (!pass.ended) 'running now',
              if (pass.failure != null) pass.failure!,
            ].join(' · '),
            readouts: [
              Readout(
                value: _relative(pass.startedAt),
                label: 'Started',
                size: ReadoutSize.sm,
              ),
            ],
            action: SkotiqButton(
              label: pass.ended ? 'Open' : 'Watch',
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: () => context.go(darkroomPassLocation(pass.runId)),
            ),
            onTap: () => context.go(darkroomPassLocation(pass.runId)),
          ),
      ],
    );
  }

  /// How many steps a stored recipe carries, or `0` when its envelope will not
  /// parse — the badge is a count, not a place to surface a decode failure.
  static int _stepCount(DarkroomRecipe recipe) {
    try {
      final decoded = jsonDecode(recipe.stepsJson);
      return decoded is List ? decoded.length : 0;
    } catch (_) {
      return 0;
    }
  }

  /// Seconds as hours to one decimal. The unit is carried by the readout, so
  /// this returns the figure alone.
  static String _hours(double seconds) => (seconds / 3600).toStringAsFixed(1);

  /// A coarse age. Coarse on purpose: the exact stamp belongs in the review,
  /// and a readout that changes every second is noise on a list.
  static String _relative(DateTime when) {
    final age = DateTime.now().difference(when);
    if (age.inDays >= 365) return '${age.inDays ~/ 365} y';
    if (age.inDays >= 1) return '${age.inDays} d';
    if (age.inHours >= 1) return '${age.inHours} h';
    if (age.inMinutes >= 1) return '${age.inMinutes} min';
    return 'now';
  }

  /// The night a session belongs to, as a bare ISO date.
  static String _night(DateTime start) =>
      '${start.year}-${start.month.toString().padLeft(2, '0')}-'
      '${start.day.toString().padLeft(2, '0')}';
}
