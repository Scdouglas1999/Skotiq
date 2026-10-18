// The 'no node selected' placeholder and the central _NodeEditor dispatcher widget that picks the right per-node properties widget based on the selected node's runtime type.
part of '../node_properties_panel.dart';

/// The properties column with nothing selected: the app's ONE empty-state
/// pattern, and no button — the action is to click a step, which is already
/// on screen beside it (06 §Sequencer).
class _EmptySelection extends StatelessWidget {
  final SkotiqColors colors;
  final bool isMobile;

  const _EmptySelection({required this.colors, this.isMobile = false});

  @override
  Widget build(BuildContext context) {
    return const EmptyState(
      icon: LucideIcons.mousePointerClick,
      title: 'Select a node',
      body: 'Its settings appear here.',
    );
  }
}

class _NodeEditor extends ConsumerWidget {
  final SkotiqColors colors;
  final SequenceNode node;
  final ScrollController? scrollController;
  final bool isMobile;

  const _NodeEditor({
    required this.colors,
    required this.node,
    this.scrollController,
    this.isMobile = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // While the executor owns the tree (Running / Paused / Stopping) the
    // notifier throws SequenceLockedException from every mutation, so the
    // Name/Enabled/type/Delete controls must be inert rather than looking
    // live and silently discarding edits.
    final canEdit = ref.watch(canEditSequenceProvider);

    // The properties panel's outer surface is a DecoratedBox with a background
    // color. Some editors render ListTile/SwitchListTile, which (Flutter 3.44)
    // assert when their nearest Material ancestor is hidden behind such a
    // DecoratedBox. A transparent Material gives every ListTile descendant a
    // Material to paint on without altering the visuals.
    // The edit lock must sit INSIDE the scroll view, not around it. With
    // IgnorePointer wrapping SingleChildScrollView, `!canEdit` (i.e. any time a
    // sequence is running/paused/stopping — all night) also swallowed drag and
    // wheel scrolling, so everything below the fold became unreadable: the
    // operator could not even inspect the settings of the node currently
    // executing. On mobile it also froze the DraggableScrollableSheet that
    // hands this panel its controller. Dimming stays outside (it is purely
    // visual); only pointer-blocking moved in, so the form is still read-only.
    return Material(
      type: MaterialType.transparency,
      child: Opacity(
        opacity: canEdit ? 1.0 : SkotiqTokens.opacityDisabled,
        child: SingleChildScrollView(
          controller: scrollController,
          padding: EdgeInsets.all(isMobile ? 20 : 16),
          child: IgnorePointer(
            ignoring: !canEdit,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Name field
                NodePropertyField(
                  colors: colors,
                  label: 'Name',
                  child: NodeTextInput(
                    colors: colors,
                    value: node.name,
                    onChanged: (value) {
                      ref.read(currentSequenceProvider.notifier).updateNode(
                            node.copyWith(name: value),
                          );
                    },
                  ),
                ),

                // Enabled toggle
                NodePropertyField(
                  colors: colors,
                  label: 'Enabled',
                  child: NodeToggleSwitch(
                    colors: colors,
                    value: node.isEnabled,
                    onChanged: (value) {
                      ref.read(currentSequenceProvider.notifier).updateNode(
                            node.copyWith(isEnabled: value),
                          );
                    },
                  ),
                ),

                const Divider(height: 32),

                // Type-specific properties
                _buildTypeSpecificProperties(ref),

                const SizedBox(height: 24),

                // Delete button — routes through the canonical confirmation
                // helper so a stray click on the Properties-panel button can't
                // silently nuke a container holding many descendants. The
                // helper handles both the prompt and the selection cleanup.
                SizedBox(
                  width: double.infinity,
                  child: NodeDangerButton(
                    colors: colors,
                    label: 'Delete node',
                    icon: LucideIcons.trash2,
                    onPressed: () async {
                      await confirmAndDeleteSequenceNode(
                        context: context,
                        ref: ref,
                        nodeId: node.id,
                        colors: colors,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTypeSpecificProperties(WidgetRef ref) {
    // Dispatch is a Dart-3 switch expression: every branch is in one visual
    // scan, the typed node binds directly (no `as ExposureNode` cast per arm),
    // and a missing node type is a compile-time gap rather than a silent
    // fall-through.
    final Widget propertiesWidget = switch (node) {
      ExposureNode n => _ExposureProperties(colors: colors, node: n),
      TargetHeaderNode n => TargetGroupProperties(colors: colors, node: n),
      LoopNode n => _LoopProperties(colors: colors, node: n),
      TargetSchedulerNode n =>
        TargetSchedulerProperties(colors: colors, node: n),
      SmartExposureNode n => SmartExposureProperties(colors: colors, node: n),
      CenterNode n => _CenterProperties(colors: colors, node: n),
      AutofocusNode n => _AutofocusProperties(colors: colors, node: n),
      CoolCameraNode n => _CoolCameraProperties(colors: colors, node: n),
      FilterChangeNode n => _FilterChangeProperties(colors: colors, node: n),
      DelayNode n => _DelayProperties(colors: colors, node: n),
      DitherNode n => _DitherProperties(colors: colors, node: n),
      StartGuidingNode n => _StartGuidingProperties(colors: colors, node: n),
      StopGuidingNode n => _StopGuidingProperties(colors: colors, node: n),
      LiveStackingNode n => LiveStackingProperties(colors: colors, node: n),
      SciencePhotometryNode n =>
        SciencePhotometryProperties(colors: colors, node: n),
      PluginInstructionNode n =>
        _PluginInstructionProperties(colors: colors, node: n),
      WarmCameraNode n => _WarmCameraProperties(colors: colors, node: n),
      RotatorNode n => _RotatorProperties(colors: colors, node: n),
      SlewNode n => _SlewProperties(colors: colors, node: n),
      WaitTimeNode n => _WaitTimeProperties(colors: colors, node: n),
      ConditionalNode n => _ConditionalProperties(colors: colors, node: n),
      ParallelNode n => _ParallelProperties(colors: colors, node: n),
      RecoveryNode n => _RecoveryProperties(colors: colors, node: n),
      NotificationNode n => _NotificationProperties(colors: colors, node: n),
      ScriptNode n => _ScriptProperties(colors: colors, node: n),
      ParkNode() ||
      UnparkNode() ||
      HomeMountNode() =>
        _SimpleInstructionInfo(colors: colors, node: node),
      MeridianFlipNode n => _MeridianFlipProperties(colors: colors, node: n),
      OpenDomeNode() ||
      CloseDomeNode() ||
      ParkDomeNode() =>
        _DomeProperties(colors: colors, node: node),
      OpenCoverNode n => _OpenCoverProperties(colors: colors, node: n),
      CloseCoverNode n => _CloseCoverProperties(colors: colors, node: n),
      CalibratorOnNode n => _CalibratorOnProperties(colors: colors, node: n),
      CalibratorOffNode n => _CalibratorOffProperties(colors: colors, node: n),
      PolarAlignmentNode n =>
        _PolarAlignmentProperties(colors: colors, node: n),
      InstructionSetNode n => _InstructionSetInfo(colors: colors, node: n),
    };

    // Add timing section for nodes with meaningful duration, through the public
    // NodeTimingSection so there is one source of truth.
    if (hasMeaningfulDuration(node)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          propertiesWidget,
          const SizedBox(height: 16),
          NodeTimingSection(colors: colors, node: node),
        ],
      );
    }

    return propertiesWidget;
  }
}
