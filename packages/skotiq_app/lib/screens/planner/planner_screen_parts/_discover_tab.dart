// "Discover" tab: a segmented Your Sky | Constellation toggle hosting the
// personal all-sky atlas and the community swarm view — the less-frequent
// discovery surfaces, nested one tap inside Plan Tonight so the rail stays for
// nightly tools.
part of '../planner_screen.dart';

/// Which view the "Discover" tab's inner segmented control shows.
enum DiscoverView { yourSky, constellation, collaborative }

/// Maps a router `?view=` query value to a [DiscoverView]. Returns null for an
/// unrecognised value so the caller can fall back to [DiscoverView.yourSky].
/// Public so the `/your-sky`, `/constellation`, and `/collaborative-sky`
/// redirects (and tests) share the same mapping.
DiscoverView? plannerDiscoverViewFromQuery(String? value) {
  if (value == null) return null;
  switch (value.toLowerCase()) {
    case 'yoursky':
    case 'your-sky':
    case 'atlas':
      return DiscoverView.yourSky;
    case 'constellation':
    case 'swarm':
      return DiscoverView.constellation;
    case 'collaborative':
    case 'collaborative-sky':
    case 'collab':
      return DiscoverView.collaborative;
  }
  return null;
}

class _DiscoverTab extends ConsumerStatefulWidget {
  const _DiscoverTab();

  @override
  ConsumerState<_DiscoverTab> createState() => _DiscoverTabState();
}

class _DiscoverTabState extends ConsumerState<_DiscoverTab> {
  late DiscoverView _view;
  String? _lastViewQuery;

  @override
  void initState() {
    super.initState();
    _lastViewQuery = _viewQuery();
    _view =
        plannerDiscoverViewFromQuery(_lastViewQuery) ?? DiscoverView.yourSky;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // The Discover tab lives in an always-built IndexedStack, so initState ran
    // once at first planner build. When a `/your-sky` or `/constellation`
    // deep-link re-enters the already-mounted planner with a new `?view=`,
    // re-apply it here (GoRouterState is an inherited dependency). Guarded on the
    // query changing so a user's manual segment toggle isn't snapped back.
    final viewQuery = _viewQuery();
    if (viewQuery != _lastViewQuery) {
      _lastViewQuery = viewQuery;
      final resolved = plannerDiscoverViewFromQuery(viewQuery);
      if (resolved != null && resolved != _view) {
        setState(() => _view = resolved);
      }
    }
  }

  /// Reads the `?view=` query from the current GoRouter location. Returns null
  /// outside the GoRouter tree (tests mount the screen standalone).
  String? _viewQuery() {
    try {
      return GoRouterState.of(context).uri.queryParameters['view'];
    } catch (_) {
      return null;
    }
  }

  /// Re-reads whichever discovery surface is on screen.
  void _refreshCurrentView(WidgetRef ref) {
    switch (_view) {
      case DiscoverView.yourSky:
        YourSkyView.refreshYourSky(ref);
      case DiscoverView.constellation:
        ConstellationView.refreshConstellation(ref);
      case DiscoverView.collaborative:
        CollaborativeSkyView.refreshCollaborativeSky(ref);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: SkotiqTokens.space2xl,
            vertical: SkotiqTokens.spaceSm,
          ),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: colors.border)),
          ),
          child: Row(
            children: [
              // Scrolls rather than overflows: three segment labels plus the
              // refresh button need ~330px, which a 360px phone does not have
              // once the row is padded.
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SegmentedControl(
                    segments: const [
                      'Your sky',
                      'Constellation',
                      'Collaborate',
                    ],
                    selectedIndex: _view.index,
                    onSelected: (index) => setState(
                      () => _view = DiscoverView.values[index],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              // The ONE refresh for all three surfaces. Each used to carry its
              // own header with its own button; 06 §Plan leaves the page one
              // header, so the action moves out here and dispatches on the
              // segment in view.
              SkotiqIconButton(
                icon: SkotiqIcons.refresh,
                tooltip: 'Refresh',
                onPressed: () => _refreshCurrentView(ref),
              ),
            ],
          ),
        ),
        Expanded(
          child: IndexedStack(
            index: _view.index,
            children: const [
              YourSkyView(),
              ConstellationView(),
              CollaborativeSkyView(),
            ],
          ),
        ),
      ],
    );
  }
}
