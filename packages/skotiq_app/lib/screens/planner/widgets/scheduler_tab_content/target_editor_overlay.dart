part of '../scheduler_tab_content.dart';

class _TargetEditorOverlay extends ConsumerWidget {
  final int targetId;
  final SchedulerDecision? decision;
  final VoidCallback onClose;

  const _TargetEditorOverlay({
    required this.targetId,
    required this.decision,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final score = decision?.scoredCandidates
        .where((s) => s.targetId == targetId)
        .toList();
    final name = (score != null && score.isNotEmpty)
        ? score.first.targetName
        : 'Target $targetId';
    final profile = ref.watch(activeEquipmentProfileProvider);
    final availableFilters =
        profile != null ? List<String>.from(profile.filterNames) : <String>[];

    return Positioned.fill(
      child: GestureDetector(
        onTap: onClose,
        child: Container(
          // absolute: modal barrier scrim dimming the screen behind the dialog
          color: Colors.black.withValues(alpha: 0.55),
          alignment: Alignment.center,
          child: GestureDetector(
            onTap: () => FocusScope.of(context).unfocus(),
            child: Material(
              color: Colors.transparent,
              child: ConstrainedBox(
                constraints: Responsive.dialogConstraints(
                  context,
                  preferredWidth: dialogMaxWidth(context, 720),
                  preferredHeight: 720,
                  minWidth: 400,
                  minHeight: 320,
                  maxHeightPercent: 0.9,
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return SizedBox(
                      width: constraints.maxWidth,
                      height: constraints.maxHeight,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: colors.surface,
                          borderRadius:
                              BorderRadius.circular(SkotiqTokens.radiusLg),
                          border: Border.all(color: colors.border),
                          boxShadow: [
                            BoxShadow(
                              // absolute: dialog drop shadow cast on the canvas
                              color: Colors.black.withValues(alpha: 0.35),
                              blurRadius: 24,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Padding(
                          padding:
                              const EdgeInsets.all(SkotiqTokens.spaceLg),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Text(
                                    name,
                                    style: SkotiqTypography.pageTitle
                                        .copyWith(color: colors.textPrimary),
                                  ),
                                  const Spacer(),
                                  SkotiqIconButton(
                                    icon: LucideIcons.x,
                                    tooltip: 'Close',
                                    onPressed: onClose,
                                  ),
                                ],
                              ),
                              const SizedBox(height: SkotiqTokens.spaceMd),
                              Expanded(
                                child: SingleChildScrollView(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      IntegrationGoalsEditor(
                                        targetId: targetId,
                                        targetName: name,
                                        availableFilters: availableFilters,
                                      ),
                                      const SizedBox(
                                        height: SkotiqTokens.space2xl,
                                      ),
                                      TargetConstraintsEditor(
                                        targetId: targetId,
                                        targetName: name,
                                        onChanged: () {
                                          final backend =
                                              ref.read(backendProvider);
                                          if (backend is NetworkBackend) {
                                            unawaited(() async {
                                              try {
                                                await backend.controlScheduler(
                                                  'evaluate',
                                                );
                                                if (!context.mounted) return;
                                                ref.invalidate(
                                                  schedulerRemoteSnapshotProvider,
                                                );
                                                ref.invalidate(
                                                  schedulerPreviewDecisionProvider,
                                                );
                                              } catch (error) {
                                                if (!context.mounted) return;
                                                ScaffoldMessenger.of(context)
                                                    .showSnackBar(
                                                  SnackBar(
                                                    content: Text(
                                                      'Could not re-evaluate scheduler: $error',
                                                    ),
                                                  ),
                                                );
                                              }
                                            }());
                                          } else {
                                            ref
                                                .read(schedulerEngineProvider)
                                                .evaluateNow(
                                                  reason: 'constraint edit',
                                                );
                                          }
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Empty-state placeholder shown in the queue table when the scheduler has
/// no candidate targets to score (either because the database is empty or
/// because the engine has not produced a first decision yet).
///
/// Tells the user what the scheduler does, points at the next concrete
/// action (open the planner / target catalog), and exposes an inline
/// "Learn more" expander explaining the scoring inputs.
