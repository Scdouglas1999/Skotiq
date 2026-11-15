part of 'plan_targets_tab.dart';

typedef _SetInAutopilot = Future<void> Function(
    PlanTarget target, bool include);
typedef _RemoveFromGroup = Future<void> Function(
    Project group, PlanTarget target);

/// One target's page: what is done, its goals and limits, tonight, and the
/// ways on to framing, a sequence, its history and the Darkroom.
class _TargetDetail extends ConsumerWidget {
  const _TargetDetail({
    super.key,
    required this.row,
    required this.group,
    required this.onSetInAutopilot,
    required this.onRemoveFromGroup,
    required this.onLimitsChanged,
  });

  final _TargetRow row;
  final Project? group;
  final _SetInAutopilot onSetInAutopilot;
  final _RemoveFromGroup onRemoveFromGroup;
  final VoidCallback onLimitsChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final plan = row.target;
    final progress = plan.progress;
    final target = progress.target;
    final profile = ref.watch(activeEquipmentProfileProvider);
    final muted = SkotiqTypography.bodySm.copyWith(color: colors.textMuted);

    final facts = [
      if (target.objectType?.isNotEmpty ?? false) target.objectType!,
      if (target.constellation?.isNotEmpty ?? false) target.constellation!,
      if (target.magnitude != null)
        'mag ${target.magnitude!.toStringAsFixed(1)}',
    ].join(' · ');
    final byFilter = [...progress.filters]
      ..sort((a, b) => compareDarkroomFilters(a.filter, b.filter));
    final done = progress.integratedSecs;
    final wholeHours = done >= 3600;
    final sky = SkyTarget(
      raHours: target.ra,
      decDegrees: target.dec,
      name: target.name,
    );

    return SkotiqPanel(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        target.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: SkotiqTypography.pageTitle
                            .copyWith(color: colors.textPrimary),
                      ),
                    ),
                    _more(context),
                  ],
                ),
                if (facts.isNotEmpty) Text(facts, style: muted),
                const SizedBox(height: SkotiqTokens.spaceLg),
                ReadoutRow(
                  children: [
                    Readout(
                      value: done <= 0
                          ? null
                          : wholeHours
                              ? (done / 3600).toStringAsFixed(1)
                              : (done / 60).round().toString(),
                      unit: wholeHours ? 'h' : 'min',
                      label: 'Done',
                    ),
                    if (progress.goal.isSet)
                      Readout(
                        value:
                            (progress.goal.goalSecs / 3600).toStringAsFixed(1),
                        unit: 'h',
                        label: progress.goal.allFilters
                            ? 'Goal, all filters'
                            : 'Goal',
                      ),
                    Readout(
                      value: '${progress.sessionCount}',
                      label:
                          progress.sessionCount == 1 ? 'Session' : 'Sessions',
                    ),
                    Readout(
                      value: '${progress.acceptedFrames}',
                      label: 'Frames kept',
                    ),
                  ],
                ),
                if (progress.lastImagedAt != null) ...[
                  const SizedBox(height: SkotiqTokens.spaceSm),
                  Text(
                    'Last imaged '
                    '${ClockFormat.monthDayYear(progress.lastImagedAt!.toLocal())}'
                    '${plan.inAutopilot ? '' : ' · off the autopilot\'s list'}',
                    style: muted,
                  ),
                ] else if (!plan.inAutopilot) ...[
                  const SizedBox(height: SkotiqTokens.spaceSm),
                  Text('Off the autopilot\'s list', style: muted),
                ],
                if (progress.goal.isSet && !progress.isCompleted)
                  _NightsToGo(targetId: target.id),
                if (byFilter.isNotEmpty) ...[
                  const SizedBox(height: SkotiqTokens.spaceMd),
                  KeyValueList(
                    rows: [
                      for (final f in byFilter)
                        (
                          f.filter,
                          '${_hours(f.seconds)} · ${f.frames} '
                              '${f.frames == 1 ? 'frame' : 'frames'}',
                        ),
                    ],
                  ),
                ],
                const _SectionGap(),
                IntegrationGoalsEditor(
                  targetId: target.id,
                  targetName: target.name,
                  availableFilters: profile == null
                      ? const <String>[]
                      : List<String>.from(profile.filterNames),
                ),
                const _SectionGap(),
                TargetConstraintsEditor(
                  targetId: target.id,
                  targetName: target.name,
                  onChanged: onLimitsChanged,
                ),
                const _SectionGap(),
                _TonightSection(window: row.window),
              ],
            ),
          ),
          Divider(height: 1, color: colors.border),
          Padding(
            padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
            child: Wrap(
              spacing: SkotiqTokens.spaceSm,
              runSpacing: SkotiqTokens.spaceSm,
              children: [
                SkotiqButton(
                  key: const ValueKey('plan-target-frame'),
                  label: 'Frame it',
                  icon: LucideIcons.crop,
                  size: ButtonSize.small,
                  variant: ButtonVariant.secondary,
                  onPressed: () => context.go(AppRoutes.framingAt(sky)),
                ),
                SkotiqButton(
                  key: const ValueKey('plan-target-sequence'),
                  label: 'Build sequence',
                  icon: LucideIcons.listPlus,
                  size: ButtonSize.small,
                  variant: ButtonVariant.secondary,
                  onPressed: () => _buildSequence(context, ref, target),
                ),
                SkotiqButton(
                  key: const ValueKey('plan-target-history'),
                  label: 'History',
                  size: ButtonSize.small,
                  variant: ButtonVariant.ghost,
                  onPressed: () =>
                      CampaignRollupDialog.show(context, target.id),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _more(BuildContext context) {
    final plan = row.target;
    final current = group;
    return Builder(
      builder: (context) => SkotiqIconButton(
        key: const ValueKey('plan-target-more'),
        icon: LucideIcons.moreHorizontal,
        tooltip: 'More for ${plan.name}',
        size: IconButtonSize.sm,
        onPressed: () async {
          final choice = await _menuUnder<int>(context, [
            _menuItem(
              context,
              0,
              plan.inAutopilot
                  ? 'Take off the autopilot\'s list'
                  : 'Put back on the autopilot\'s list',
            ),
            if (current != null)
              _menuItem(context, 1, 'Take out of "${current.name}"'),
            if (plan.progress.hasAnyProgress)
              _menuItem(context, 2, 'Open in Darkroom'),
          ]);
          if (!context.mounted) return;
          if (choice == 0) await onSetInAutopilot(plan, !plan.inAutopilot);
          if (choice == 1) await onRemoveFromGroup(current!, plan);
          if (choice == 2) {
            context.go(
              darkroomTargetLocation(normalizeDarkroomTargetName(plan.name)),
            );
          }
        },
      ),
    );
  }

  Future<void> _buildSequence(
    BuildContext context,
    WidgetRef ref,
    DbTarget target,
  ) async {
    try {
      final suggestion = await catalogTargetSuggestion(
        ref: ref,
        targetName: target.name,
        raHours: target.ra,
        decDegrees: target.dec,
        catalogId: target.catalogId,
        objectType: target.objectType,
        magnitude: target.magnitude,
        sizeArcmin: target.sizeArcmin,
        constellation: target.constellation,
      );
      if (!context.mounted) return;
      final added = await addPlanTonightTargetToSequencer(
        context: context,
        ref: ref,
        target: suggestion,
      );
      if (added && context.mounted) context.go(AppRoute.sequencer.path);
    } catch (error) {
      if (!context.mounted) return;
      context.showErrorSnackBar(
        'Could not build the sequence: ${userFacingError(error)}',
      );
    }
  }
}

/// How many more nights the goal needs at the pace of the nights so far;
/// nothing until there is a pace to project from.
class _NightsToGo extends ConsumerWidget {
  const _NightsToGo({required this.targetId});

  final int targetId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nights = ref
        .watch(targetProgressProvider(targetId))
        .valueOrNull
        ?.estimatedNightsRemaining;
    if (nights == null || nights <= 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: SkotiqTokens.spaceXs),
      child: Text(
        'About $nights more ${nights == 1 ? 'night' : 'nights'} at your pace',
        style: SkotiqTypography.bodySm.copyWith(
          color: SkotiqColors.of(context).textMuted,
        ),
      ),
    );
  }
}

class _SectionGap extends StatelessWidget {
  const _SectionGap();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceLg),
        child: Divider(height: 1, color: SkotiqColors.of(context).border),
      );
}

/// Tonight for one target: its altitude over the night and when it stands
/// above the site's floor in darkness.
class _TonightSection extends ConsumerWidget {
  const _TonightSection({required this.window});

  final _TonightWindow? window;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    // The floor in force, in the site rule's own words: "your horizon" or
    // the minimum altitude.
    final floor = ref.watch(altitudeFloorProvider).asSamples().phrase;
    final w = window;
    final head = Text(
      'Tonight',
      style: SkotiqTypography.sectionTitle.copyWith(color: colors.textPrimary),
    );
    final muted = SkotiqTypography.bodySm.copyWith(color: colors.textSecondary);
    if (w == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          head,
          const SizedBox(height: SkotiqTokens.spaceSm),
          Text(
            'Set your observing site in Settings > Location to see when this '
            'target is up.',
            style: muted,
          ),
        ],
      );
    }
    final peak = w.altitudes.fold<double>(0, (m, a) => a > m ? a : m);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        head,
        const SizedBox(height: SkotiqTokens.spaceXs),
        Text(
          w.isUp
              ? 'Clears $floor from '
                  '${ClockFormat.hm(w.start!.toLocal())} to '
                  '${ClockFormat.hm(w.end!.toLocal())}, peaking at '
                  '${peak.round()}°'
              : 'Does not clear $floor in darkness tonight',
          key: const Key('target-detail-tonight-window'),
          style: muted,
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        NightBand(
          sunset: w.sunset,
          astroDark: w.dusk,
          astroDawn: w.dawn,
          sunrise: w.sunrise,
          now: DateTime.now(),
          targetAltitudeCurve: [
            for (final a in w.altitudes) (a / 90).clamp(0.0, 1.0),
          ],
          imageableWindow:
              w.isUp ? NightBandWindow(start: w.start!, end: w.end!) : null,
        ),
      ],
    );
  }
}

/// The target's page over the list, for widths with no room beside it. It
/// reads the target afresh so edits made on it show at once.
class _TargetDetailPage extends ConsumerWidget {
  const _TargetDetailPage({
    required this.targetId,
    required this.onSetInAutopilot,
    required this.onRemoveFromGroup,
    required this.onLimitsChanged,
  });

  final int targetId;
  final _SetInAutopilot onSetInAutopilot;
  final _RemoveFromGroup onRemoveFromGroup;
  final VoidCallback onLimitsChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final targets = ref.watch(planTargetsProvider).valueOrNull ?? const [];
    final target = targets.where((t) => t.id == targetId).firstOrNull;
    final groups = ref.watch(projectListProvider).valueOrNull ?? const [];
    final activeId = ref.watch(activeProjectIdProvider);
    final windows = ref.watch(_tonightWindowsProvider);
    final phone = Responsive.isPhone(context);

    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                phone ? SkotiqTokens.spaceSm : SkotiqTokens.spaceLg,
                SkotiqTokens.spaceSm,
                SkotiqTokens.spaceLg,
                0,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: SkotiqButton(
                  key: const ValueKey('plan-target-back'),
                  label: 'Targets',
                  icon: LucideIcons.arrowLeft,
                  variant: ButtonVariant.ghost,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
            ),
            Expanded(
              child: target == null
                  ? const EmptyState(
                      icon: LucideIcons.target,
                      title: 'This target is no longer in your list',
                    )
                  : Padding(
                      padding: phone
                          ? SkotiqTokens.screenPaddingCompact
                          : SkotiqTokens.screenPadding,
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 640),
                          child: _TargetDetail(
                            row: _TargetRow(
                              target: target,
                              window: windows[target.id],
                              status: '',
                              tone: _StatusTone.quiet,
                              rank: 0,
                            ),
                            group: groups
                                .where((g) => g.id == activeId)
                                .firstOrNull,
                            onSetInAutopilot: onSetInAutopilot,
                            onRemoveFromGroup: onRemoveFromGroup,
                            onLimitsChanged: onLimitsChanged,
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
