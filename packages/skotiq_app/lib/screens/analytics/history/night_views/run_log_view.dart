import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../sequencer/widgets/notes_panel.dart';
import '../night_entry.dart';
import 'run_decisions.dart';
import 'run_timeline.dart';

/// The Run log of a night: the timeline of the run, the notes written about
/// it and every decision the sequencer logged.
class NightRunLogView extends ConsumerWidget {
  const NightRunLogView({
    super.key,
    required this.entry,
    required this.targetName,
    required this.padding,
  });

  final NightEntry entry;

  /// The night's target, used to file new notes under it.
  final String? targetName;
  final EdgeInsets padding;

  /// From this width the notes sit in a side panel.
  static const double _sidePanelAbove = 1024;
  static const double _sidePanelWidth = 340;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final run = entry.run;
    if (run == null) {
      return const EmptyState(
        icon: LucideIcons.history,
        title: 'No run log for this night',
        body: 'This session has no sequence run on record, so there are no '
            'decisions, timeline or run notes to show.',
      );
    }
    final colors = SkotiqColors.of(context);
    final notes = SkotiqPanel(
      child: RunNotesSection(
        sequenceRunId: run.id,
        targetId: targetName ?? entry.runTargets.firstOrNull ?? run.sequenceName,
        colors: colors,
        embedded: true,
      ),
    );
    final timeline = RunTimeline(
      run: run,
      sessionId: entry.session?.id,
      targetName: targetName ?? entry.runTargets.firstOrNull,
    );
    final decisions = RunDecisionsSliver(
      runId: run.id,
      startedAt: run.startedAt,
      endedAt: run.endedAt,
    );
    const gap = SliverToBoxAdapter(
      child: SizedBox(height: SkotiqTokens.spaceLg),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < _sidePanelAbove) {
          return CustomScrollView(
            slivers: [
              SliverPadding(
                padding: padding,
                sliver: SliverMainAxisGroup(
                  slivers: [
                    SliverToBoxAdapter(child: timeline),
                    gap,
                    SliverToBoxAdapter(child: notes),
                    gap,
                    decisions,
                  ],
                ),
              ),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: CustomScrollView(
                slivers: [
                  SliverPadding(
                    padding: padding.copyWith(right: 0),
                    sliver: SliverMainAxisGroup(
                      slivers: [
                        SliverToBoxAdapter(child: timeline),
                        gap,
                        decisions,
                      ],
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              width: _sidePanelWidth + padding.right + SkotiqTokens.spaceLg,
              child: SingleChildScrollView(
                padding: padding.copyWith(left: SkotiqTokens.spaceLg),
                child: notes,
              ),
            ),
          ],
        );
      },
    );
  }
}
