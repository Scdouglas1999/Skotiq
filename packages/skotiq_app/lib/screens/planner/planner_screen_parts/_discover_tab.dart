// "Discover" tab: a segmented Your Sky | Constellation toggle hosting the
// personal all-sky atlas and the community swarm view — the less-frequent
// discovery surfaces, nested one tap inside Plan Tonight so the rail stays for
// nightly tools.
part of '../planner_screen.dart';

class _DiscoverTab extends ConsumerStatefulWidget {
  const _DiscoverTab({this.requestedView});

  /// The view a link asked for; null keeps Your sky.
  final DiscoverView? requestedView;

  @override
  ConsumerState<_DiscoverTab> createState() => _DiscoverTabState();
}

class _DiscoverTabState extends ConsumerState<_DiscoverTab> {
  late DiscoverView _view;

  @override
  void initState() {
    super.initState();
    _view = widget.requestedView ?? DiscoverView.yourSky;
  }

  @override
  void didUpdateWidget(_DiscoverTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A link with a new `?view=` re-enters the planner already showing this
    // tab. Applied only when the request changes, so the operator's own
    // segment choice is not snapped back by an unrelated rebuild.
    final requested = widget.requestedView;
    if (requested != oldWidget.requestedView &&
        requested != null &&
        requested != _view) {
      setState(() => _view = requested);
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
          // Only the surface in view is built: each one reads host data while
          // mounted, and a hidden one must not keep doing so.
          child: switch (_view) {
            DiscoverView.yourSky => const YourSkyView(),
            DiscoverView.constellation => const ConstellationView(),
            DiscoverView.collaborative => const CollaborativeSkyView(),
          },
        ),
      ],
    );
  }
}
