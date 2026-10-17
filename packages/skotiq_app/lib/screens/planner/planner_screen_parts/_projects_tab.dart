// "Projects" tab: the multi-night project workspace. The former "Projects" and
// "Progress" tabs are unified here behind one clearly-labelled scope switch —
// the active project's goal tracking vs. the global all-targets roll-up — so a
// user reaches both from a single tab instead of two siblings that read the
// same captured-frames / integration-goal data at different scopes.
//
// Terminology: this surface says "project" everywhere, because Project is what
// the schema calls it. `Campaign` is a DIFFERENT entity in
// skotiq_core/lib/src/models/campaign.dart (the durable per-(target,filter)
// accepted-frame counter), so using "campaign" here for a Project would collide
// head-on once that UI lands.
part of '../planner_screen.dart';

/// Which progress scope the consolidated "Projects" tab shows.
enum _ProjectsScope { thisProject, allTargets }

class _ProjectsTab extends StatefulWidget {
  const _ProjectsTab();

  @override
  State<_ProjectsTab> createState() => _ProjectsTabState();
}

class _ProjectsTabState extends State<_ProjectsTab> {
  _ProjectsScope _scope = _ProjectsScope.thisProject;

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
          // Scrolls rather than overflows at a phone width.
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedControl(
              segments: const ['This project', 'All targets'],
              selectedIndex: _scope.index,
              onSelected: (index) => setState(
                () => _scope = _ProjectsScope.values[index],
              ),
            ),
          ),
        ),
        Expanded(
          child: _scope == _ProjectsScope.thisProject
              ? const ProjectsTabContent()
              : const ProgressTabContent(),
        ),
      ],
    );
  }
}
