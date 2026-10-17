import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'sequence_tree.dart';
import 'sequence_tree_shortcuts.dart';

/// "Find a step" — type a name, pick a match, land on it in the canvas.
///
/// This is the in-tree search that used to be a 160 px field wedged into the
/// tree's own header row. The header is gone (the canvas bar names the
/// sequence now), so the search moved into the canvas bar's overflow menu and
/// became a proper dialog: the same
/// [visibleNodeOrderProvider] filter, the same "select then
/// [revealSequenceRow] through [treeNodeKeyRegistryProvider]" jump the
/// run's auto-follow uses, and no bespoke overlay portal.
Future<void> showSequenceStepFinder(BuildContext context) {
  return showAdaptiveModal<void>(
    context: context,
    designWidth: 420,
    builder: (sheetContext) => const _StepFinder(),
  );
}

class _StepFinder extends ConsumerStatefulWidget {
  const _StepFinder();

  @override
  ConsumerState<_StepFinder> createState() => _StepFinderState();
}

class _StepFinderState extends ConsumerState<_StepFinder> {
  final _controller = TextEditingController();
  String _query = '';

  /// How tall the result list may grow before it scrolls.
  static const double _maxResultsHeight = 280;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _jumpTo(String nodeId) {
    ref.read(multiSelectedNodeIdsProvider.notifier).clear();
    ref.read(selectedNodeIdProvider.notifier).state = nodeId;

    final key = ref.read(treeNodeKeyRegistryProvider)?[nodeId];
    final target = key?.currentContext;
    if (target != null) {
      revealSequenceRow(
        target,
        duration: SkotiqTokens.durationSmooth,
        alignment: 0.3,
      );
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final sequence = ref.watch(currentSequenceProvider);
    final visible = ref.watch(visibleNodeOrderProvider);
    final query = _query.toLowerCase();

    final matches = <SequenceNode>[
      if (sequence != null)
        for (final entry in visible)
          if (sequence.nodes[entry.id] case final node?)
            if (query.isEmpty || node.name.toLowerCase().contains(query)) node,
    ];

    return Padding(
      padding: const EdgeInsets.all(SkotiqTokens.space2xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionTitle(icon: LucideIcons.search, title: 'Find a step'),
          SkotiqTextField(
            controller: _controller,
            autofocus: true,
            hint: 'Step name',
            prefixIcon: LucideIcons.search,
            onChanged: (value) => setState(() => _query = value),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          if (matches.isEmpty)
            EmptyState.compact(
              icon: LucideIcons.searchX,
              title: 'No matching step',
              body: 'Nothing in this sequence is called "$_query".',
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: _maxResultsHeight),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final node in matches)
                    ListRow(
                      icon: LucideIcons.chevronRight,
                      title: node.name,
                      onTap: () => _jumpTo(node.id),
                    ),
                ],
              ),
            ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          Align(
            alignment: Alignment.centerRight,
            child: SkotiqButton(
              label: 'Close',
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    );
  }
}
