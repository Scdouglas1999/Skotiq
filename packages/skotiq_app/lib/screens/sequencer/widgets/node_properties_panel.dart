import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

import '../../accessible_dropdown.dart';
import '../../equipment/dialogs/profile_editor_dialog.dart';
import '../filter_source.dart';
import 'delete_node_confirmation.dart';
import 'live_stacking_properties.dart';
import 'meridian_flip_edit_helper.dart';
import 'node_activity_tab.dart';
import 'node_notes_tab.dart';
import 'node_progress_panels.dart';
import 'node_property_widgets.dart';
import 'node_timing_section.dart';
import 'science_photometry_properties.dart';
import 'smart_exposure_properties.dart';
import 'target_coordinates.dart';
import 'target_node_properties.dart';
import 'target_scheduler_properties.dart';

// File split: the per-node property widgets, input primitives, dispatcher,
// and timing section live in `node_properties_panel_parts/`. The public
// `NodePropertiesPanel` widget stays in this file. Parts share the same
// library scope so private symbols (_NodeEditor, _TextInput, etc.) cross
// files without needing to be promoted.

part 'node_properties_panel_parts/_input_primitives.dart';
part 'node_properties_panel_parts/_node_editor.dart';
part 'node_properties_panel_parts/_exposure_rich.dart';
part 'node_properties_panel_parts/_adaptive_exposure_section.dart';
part 'node_properties_panel_parts/_capture_properties.dart';
part 'node_properties_panel_parts/_capture_rich.dart';
part 'node_properties_panel_parts/_guiding_properties.dart';
part 'node_properties_panel_parts/_motion_rich.dart';
part 'node_properties_panel_parts/_flow_properties.dart';
part 'node_properties_panel_parts/_misc_properties.dart';
part 'node_properties_panel_parts/_plugin_properties.dart';
part 'node_properties_panel_parts/_motion_flip_and_polar.dart';

/// The inspector tab remembered per node CATEGORY for this session
/// (`Map<NodeCategory, int>`, in memory only — spec §8: "the active tab
/// persists per node type"). Selecting another node of the same category
/// restores the tab it last had; a category never visited falls back to
/// Settings. Nothing is written to storage.
final inspectorTabProvider =
    StateProvider<Map<NodeCategory, int>>((ref) => const {});

const int _inspectorTabSettings = 0;
const int _inspectorTabActivity = 1;
const int _inspectorTabNotes = 2;

class NodePropertiesPanel extends ConsumerWidget {
  final SkotiqColors colors;
  final ScrollController? scrollController;
  final bool isMobileSheet;
  final VoidCallback? onClose;
  final VoidCallback? onCollapse;

  const NodePropertiesPanel({
    super.key,
    required this.colors,
    this.scrollController,
    this.isMobileSheet = false,
    this.onClose,
    this.onCollapse,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedNode = ref.watch(selectedNodeProvider);

    // Keep the session's last-known progress fold alive while the inspector
    // exists: the Activity tab only watches it when it is built, and a
    // lazily-created notifier would see only the post-reset empty maps.
    ref.watch(lastKnownNodeActivityProvider);

    if (isMobileSheet) {
      return _buildMobileSheetContent(context, ref, selectedNode);
    }
    return _buildDesktopSidebarContent(context, ref, selectedNode);
  }

  Widget _buildMobileSheetContent(
      BuildContext context, WidgetRef ref, SequenceNode? selectedNode) {
    return Column(
      children: [
        // Handle bar
        Center(
          child: Container(
            margin: const EdgeInsets.only(top: 12, bottom: 8),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: colors.border,
              borderRadius:
                  BorderRadius.circular(SkotiqTokens.radiusInline2),
            ),
          ),
        ),

        // Header with close button
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: SkotiqTokens.spaceLg,
            vertical: SkotiqTokens.spaceSm,
          ),
          child: SectionTitle(
            icon: LucideIcons.sliders,
            title: selectedNode?.name ?? 'Properties',
            trailing: onClose == null
                ? null
                : SkotiqIconButton(
                    icon: LucideIcons.x,
                    tooltip: 'Close',
                    onPressed: onClose,
                  ),
          ),
        ),

        Divider(color: colors.border, height: 1),

        if (selectedNode != null) ...[
          _buildInspectorTabBar(selectedNode),
          Divider(color: colors.border, height: 1),
        ],

        // Content
        Expanded(
          child: selectedNode == null
              ? _EmptySelection(colors: colors, isMobile: true)
              : _buildTabBody(selectedNode),
        ),
        if (selectedNode != null) _SelectedNodeBanner(nodeId: selectedNode.id),
      ],
    );
  }

  Widget _buildDesktopSidebarContent(
      BuildContext context, WidgetRef ref, SequenceNode? selectedNode) {
    // A side panel with no strip: 300 px of content, 16 px padding, each
    // section opening with a SectionTitle (05 §15). The old 48 px "Properties"
    // header bar is gone — a panel that only ever holds one thing does not
    // need a row to say what that thing is, and the SectionTitle already names
    // the node.
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(left: BorderSide(color: colors.border)),
      ),
      child: selectedNode == null
          ? _EmptySelection(colors: colors)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    SkotiqTokens.spaceLg,
                    SkotiqTokens.spaceLg,
                    SkotiqTokens.spaceLg,
                    0,
                  ),
                  child: SectionTitle(
                    icon: LucideIcons.sliders,
                    title: selectedNode.name,
                    trailing: onCollapse == null
                        ? null
                        : SkotiqIconButton(
                            icon: LucideIcons.panelRightClose,
                            tooltip: 'Collapse panel',
                            size: IconButtonSize.sm,
                            onPressed: onCollapse,
                          ),
                  ),
                ),
                _buildInspectorTabBar(selectedNode),
                Divider(color: colors.border, height: 1),
                Expanded(
                  child: _buildTabBody(selectedNode),
                ),
                _SelectedNodeBanner(nodeId: selectedNode.id),
              ],
            ),
    );
  }

  /// The Settings / Activity / Notes strip under the section title. The
  /// selection is keyed by node CATEGORY (spec §8): two exposure nodes share
  /// the instruction slot, so moving between siblings keeps the tab the
  /// operator was working in.
  Widget _buildInspectorTabBar(SequenceNode node) {
    return Consumer(
      builder: (context, ref, _) {
        final tabIndex = ref.watch(inspectorTabProvider)[node.category] ??
            _inspectorTabSettings;
        final hasComment = node.comment?.trim().isNotEmpty ?? false;
        return AdaptiveTabBar(
          // The bar's default squeezes labelled tabs down to icons below
          // 480px — tuned for the 4-tab page header. The inspector is a
          // 300px sidebar where icon-only Settings/Activity/Notes would be
          // cryptic. Text-only tabs keep the full labels inside that width
          // (the bar still scrolls if a narrower host ever clips them).
          collapseLabelsWhenTight: false,
          horizontalPadding: SkotiqTokens.spaceSm,
          tabs: [
            const AdaptiveTab(label: 'Settings'),
            const AdaptiveTab(label: 'Activity'),
            // `AdaptiveTab` has no dot slot; the bullet rides in the label.
            AdaptiveTab(
              label: hasComment ? 'Notes •' : 'Notes',
              semanticLabel: hasComment ? 'Notes, has comment' : 'Notes',
            ),
          ],
          selectedIndex: tabIndex,
          onSelected: (index) => ref
              .read(inspectorTabProvider.notifier)
              .update((memory) => {...memory, node.category: index}),
        );
      },
    );
  }

  Widget _buildTabBody(SequenceNode node) {
    return Consumer(
      builder: (context, ref, _) {
        final tabIndex = ref.watch(inspectorTabProvider)[node.category] ??
            _inspectorTabSettings;
        return switch (tabIndex) {
          _inspectorTabActivity => NodeActivityTab(
              colors: colors,
              node: node,
              scrollController: scrollController,
              isMobile: isMobileSheet,
            ),
          _inspectorTabNotes => NodeNotesTab(
              colors: colors,
              node: node,
              scrollController: scrollController,
              isMobile: isMobileSheet,
            ),
          _ => _NodeEditor(
              colors: colors,
              node: node,
              scrollController: scrollController,
              isMobile: isMobileSheet,
            ),
        };
      },
    );
  }
}

/// The ONE banner the properties column may show: the worst live-validation
/// issue for the selected node, pinned to the bottom (06 §Sequencer).
///
/// The mockup's banner is an "ends after astro dawn" warning. Nothing in the
/// app computes that today, and inventing the calculation would be a new
/// feature in a re-skin — so the slot carries the real per-node problem the
/// validator already found instead of a fabricated one. See
/// reports/observatory/w3-sequencer/notes.md.
class _SelectedNodeBanner extends ConsumerWidget {
  const _SelectedNodeBanner({required this.nodeId});

  final String nodeId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final issues = ref.watch(liveValidationProvider).issuesByNodeId[nodeId];
    if (issues == null || issues.isEmpty) return const SizedBox.shrink();

    // One banner per problem: the worst issue speaks for the node, and the
    // Preflight dialog in the page header lists the rest.
    final worst = issues.reduce(
      (a, b) => a.severity.index >= b.severity.index ? a : b,
    );
    final tone = switch (worst.severity) {
      ValidationSeverity.error => BannerTone.error,
      ValidationSeverity.warning => BannerTone.warning,
      ValidationSeverity.info => BannerTone.info,
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SkotiqTokens.spaceLg,
        0,
        SkotiqTokens.spaceLg,
        SkotiqTokens.spaceLg,
      ),
      child: SkotiqBanner(
        title: worst.title,
        message: worst.resolutionHint ?? worst.description,
        tone: tone,
      ),
    );
  }
}
