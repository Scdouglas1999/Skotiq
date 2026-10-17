// ignore_for_file: invalid_use_of_protected_member
// Save-as-snippet dialog plus icon, colour and accessibility helpers shared by
// the tree's rows.
//
// The icon / status / category lookups are FREE functions rather than methods
// on `_NodeItemState`: the ledger row is a different widget and needs the same
// three answers, and a second copy of any of them would let two rows in the
// same tree disagree about what a node looks like.
part of '../sequence_tree.dart';

/// Open the "promote this subtree to the template library" dialog for [node].
///
/// Shared by the comfortable row's kebab and the ledger row's kebab (both go
/// through [_NodeOverflowMenu]). Captures the whole multi-selection when there
/// is one, so "Save as Template" on a selected block saves the block.
void showSaveAsSnippetDialog(
  BuildContext context,
  WidgetRef ref,
  SequenceNode node,
  SkotiqColors colors,
) {
  final sequence = ref.read(currentSequenceProvider);
  if (sequence == null) return;

  final nameController = TextEditingController(text: node.name);
  final descController = TextEditingController();
  SnippetCategory selectedCategory = SnippetCategory.custom;

  showDialog(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AlertDialog(
        backgroundColor: colors.surfaceOverlay,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        ),
        title: Row(
          children: [
            Icon(LucideIcons.bookmark, size: 20, color: colors.primary),
            const SizedBox(width: 12),
            Text(
              'Save as Template',
              style: SkotiqTypography.sectionTitle.copyWith(
                color: colors.textPrimary,
              ),
            ),
          ],
        ),
        content: ConstrainedBox(
          constraints: AdaptiveDialogConstraints.hybrid(
            dialogContext,
            designMaxWidth: 360,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Name',
                  style: SkotiqTypography.labelSm
                      .copyWith(color: colors.textSecondary)),
              const SizedBox(height: 6),
              TextField(
                controller: nameController,
                autofocus: true,
                style: SkotiqTypography.body
                    .copyWith(color: colors.textPrimary),
                decoration: InputDecoration(
                  hintText: 'Template name',
                  hintStyle: SkotiqTypography.body
                      .copyWith(color: colors.textMuted),
                  filled: true,
                  fillColor: colors.surfaceAlt,
                  border: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline8),
                    borderSide: BorderSide(color: colors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline8),
                    borderSide: BorderSide(color: colors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline8),
                    borderSide: BorderSide(color: colors.primary),
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),
              const SizedBox(height: 14),
              Text('Description',
                  style: SkotiqTypography.labelSm
                      .copyWith(color: colors.textSecondary)),
              const SizedBox(height: 6),
              TextField(
                controller: descController,
                maxLines: 2,
                style: SkotiqTypography.body
                    .copyWith(color: colors.textPrimary),
                decoration: InputDecoration(
                  hintText: 'What does this template do?',
                  hintStyle: SkotiqTypography.body
                      .copyWith(color: colors.textMuted),
                  filled: true,
                  fillColor: colors.surfaceAlt,
                  border: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline8),
                    borderSide: BorderSide(color: colors.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline8),
                    borderSide: BorderSide(color: colors.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline8),
                    borderSide: BorderSide(color: colors.primary),
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),
              const SizedBox(height: 14),
              Text('Category',
                  style: SkotiqTypography.labelSm
                      .copyWith(color: colors.textSecondary)),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: colors.surfaceAlt,
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline8),
                  border: Border.all(color: colors.border),
                ),
                child: DropdownButtonHideUnderline(
                  child: AccessibleDropdown<SnippetCategory>(
                    value: selectedCategory,
                    isExpanded: true,
                    dropdownColor: colors.surfaceOverlay,
                    style: SkotiqTypography.body
                        .copyWith(color: colors.textPrimary),
                    items: SnippetCategory.values.map((cat) {
                      return DropdownMenuItem(
                        value: cat,
                        child: Text(
                            cat.name[0].toUpperCase() + cat.name.substring(1)),
                      );
                    }).toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setDialogState(() => selectedCategory = value);
                      }
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          SkotiqButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            label: 'Cancel',
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
          ),
          SkotiqButton(
            onPressed: () async {
              final name = nameController.text.trim();
              if (name.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text('Please enter a template name'),
                    backgroundColor: colors.error,
                  ),
                );
                return;
              }

              final messenger = ScaffoldMessenger.of(context);
              try {
                // Capture the full multi-selection when present, else just
                // this node. createSnippetFromSelection requires the nodes
                // share a parent / be contiguous; failures land in catch.
                final multi = ref.read(multiSelectedNodeIdsProvider);
                final nodeIds = multi.isNotEmpty ? multi.toList() : [node.id];
                final snippet = createSnippetFromSelection(
                  name: name,
                  description: descController.text.trim().isEmpty
                      ? 'Custom template from ${node.nodeType}'
                      : descController.text.trim(),
                  category: selectedCategory,
                  iconName: node.iconName,
                  nodeIds: nodeIds,
                  sequence: sequence,
                );

                await ref
                    .read(customSnippetsProvider.notifier)
                    .addSnippet(snippet);

                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }

                if (context.mounted) {
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text('Template "$name" created successfully'),
                      backgroundColor: colors.success,
                    ),
                  );
                }
              } catch (e) {
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
                if (context.mounted) {
                  messenger.showSnackBar(
                    SnackBar(
                      content: Text('Failed to create template: $e'),
                      backgroundColor: colors.error,
                    ),
                  );
                }
              }
            },
            label: 'Save',
            variant: ButtonVariant.primary,
            size: ButtonSize.small,
          ),
        ],
      ),
    ),
  );
}

/// The glyph for a node, resolved from the node's own [SequenceNode.iconName]
/// so the tree row, the palette entry and the drag feedback all show the same
/// picture of the same instruction.
IconData sequenceNodeIcon(String iconName) {
  switch (iconName) {
    case 'target':
      return LucideIcons.target;
    case 'camera':
      return LucideIcons.camera;
    case 'circle':
      return LucideIcons.circle;
    case 'shuffle':
      return LucideIcons.shuffle;
    case 'compass':
      return LucideIcons.compass;
    case 'crosshair':
      return LucideIcons.crosshair;
    case 'parking-circle':
      return LucideIcons.parkingCircle;
    case 'unlock':
      return LucideIcons.unlock;
    case 'focus':
      return LucideIcons.focus;
    case 'snowflake':
      return LucideIcons.snowflake;
    case 'flame':
      return LucideIcons.flame;
    case 'rotate-cw':
      return LucideIcons.rotateCw;
    case 'repeat':
      return LucideIcons.repeat;
    case 'git-merge':
      return LucideIcons.gitMerge;
    case 'git-branch':
      return LucideIcons.gitBranch;
    case 'shield-check':
      return LucideIcons.shieldCheck;
    case 'clock':
      return LucideIcons.clock;
    case 'timer':
      return LucideIcons.timer;
    case 'bell':
      return LucideIcons.bell;
    case 'code':
      return LucideIcons.code;
    case 'list':
      return LucideIcons.list;
    // SmartExposure uses the layered-stack glyph.
    case 'layers':
      return LucideIcons.layers;
    default:
      return LucideIcons.box;
  }
}

/// The one colour a run STATUS is allowed to paint on a row.
///
/// Transparent for pending / unknown: a step that has not run has no status to
/// report, and the row must not imply one.
Color nodeStatusColor(NodeStatus? status, SkotiqColors colors) {
  switch (status) {
    case NodeStatus.running:
      return colors.info;
    case NodeStatus.success:
      return colors.success;
    case NodeStatus.failure:
      return colors.error;
    case NodeStatus.skipped:
      return colors.textMuted;
    case NodeStatus.cancelled:
      return colors.warning;
    default:
      return const Color(0x00000000);
  }
}

/// Whether [node] is a container — one of the node types the tree lets hold
/// children, and therefore the types that get a chevron, a children drop area
/// and a subtree rollup even while they are empty.
///
/// A type test, not `childIds.isNotEmpty`: an empty Loop is still a Loop, and
/// the tree has to offer somewhere to drop the first child into.
bool isSequenceContainer(SequenceNode node) =>
    node is TargetHeaderNode ||
    node is LoopNode ||
    node is InstructionSetNode ||
    node is ParallelNode ||
    node is ConditionalNode ||
    node is RecoveryNode;

/// A node's category tint, mirroring `NodeSummaryLine`'s `_categoryColor`
/// exactly so a ledger row's glyph belongs to the same colour family as the
/// summary chips of the same node.
///
/// A category is NOT a status: this tint only ever colours the node's own
/// glyph, never the row's chrome (02 rule 2 — the row has one line, the
/// selected ring, and one status colour).
Color nodeCategoryTint(NodeCategory category, SkotiqColors colors) {
  switch (category) {
    case NodeCategory.instruction:
      return colors.primary;
    case NodeCategory.trigger:
      return colors.warning;
    case NodeCategory.logic:
      return colors.accent;
    case NodeCategory.target:
      return colors.warning;
  }
}

extension _NodeItemHelpers on _NodeItemState {
  IconData _getIcon() => sequenceNodeIcon(widget.node.iconName);

  // _getCategoryColor is gone: a step's CATEGORY is not a status, and the
  // four-colour scheme it drove painted chrome in four hues that meant
  // nothing to the operator (02: "Not a colour-coded rainbow"). Colour on a
  // step row now means exactly one of: selected (primary), succeeded
  // (success), failed (error), skipped (muted).

  Color _getStatusColor() => nodeStatusColor(widget.nodeStatus, widget.colors);

  /// Build the plain-text accessibility string for the at-a-glance summary by
  /// joining each fragment's user-visible value. [EditableFragment]s expose
  /// their current [EditableFragment.displayValue]; [StaticFragment]s expose
  /// their text. Fragments are separated by a middle dot so screen readers
  /// announce a single, scannable phrase (e.g. "10 · × · 120s · Ha").
  String _summaryA11yText(List<SummaryFragment> fragments) {
    return fragments
        .map((f) => switch (f) {
              StaticFragment(text: final t) => t.trim(),
              EditableFragment(displayValue: final v) => v.trim(),
            })
        .where((s) => s.isNotEmpty)
        .join(' · ');
  }
}
