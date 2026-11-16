import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/darkroom_navigation.dart';
import '../../../router/darkroom_route.dart';
import 'darkroom_image.dart';
import 'darkroom_status_chip.dart';
import 'darkroom_targets_model.dart';
import 'darkroom_targets_providers.dart';
import 'framing_check.dart';
import 'target_detail.dart';
import 'target_tidy.dart';
import 'package:skotiq_core/providers.dart';

const double _listWidth = 300;
const double _listWidthNarrow = 248;

/// Below this width the list narrows.
const double _narrowWidth = 1100;

const double _thumbSize = 56;

/// The Targets tab: every imaged target, and the selected one's detail or its
/// framing check.
class DarkroomTargetsTab extends ConsumerStatefulWidget {
  const DarkroomTargetsTab({super.key});

  @override
  ConsumerState<DarkroomTargetsTab> createState() => _DarkroomTargetsTabState();
}

class _DarkroomTargetsTabState extends ConsumerState<DarkroomTargetsTab> {
  String _query = '';

  /// Whether Other captures is unfolded; until the user folds or unfolds it,
  /// open exactly when the selected target is one of them.
  bool? _othersOpen;

  @override
  Widget build(BuildContext context) {
    final route = DarkroomRouteScope.of(context);
    final targets = ref.watch(darkroomTargetsProvider);
    return targets.when(
      skipLoadingOnRefresh: true,
      skipLoadingOnReload: true,
      loading: () => const Center(
        child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36),
      ),
      error: (error, _) => Center(
        child: EmptyState(
          icon: SkotiqIcons.imageOff,
          title: 'The captured lights could not be read',
          body: userFacingError(error),
          action: SkotiqButton(
            label: 'Try again',
            icon: SkotiqIcons.refresh,
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: () => ref.invalidate(darkroomTargetsProvider),
          ),
        ),
      ),
      data: (list) => _loaded(context, route, list),
    );
  }

  Widget _loaded(
    BuildContext context,
    DarkroomRoute route,
    List<DarkroomTarget> list,
  ) {
    if (list.isEmpty) {
      return const Center(
        child: EmptyState(
          icon: SkotiqIcons.target,
          title: 'No imaged targets yet',
          body: 'A target appears here after its first night of lights. '
              'Its masters are built here too.',
        ),
      );
    }
    final wanted = route.target;
    final selected = wanted == null
        ? (list.where((t) => t.isProject).firstOrNull ?? list.first)
        : list.where((t) => t.key == wanted).firstOrNull ??
            list
                .where(
                  (t) =>
                      normalizeDarkroomTargetName(t.key) ==
                      normalizeDarkroomTargetName(wanted),
                )
                .firstOrNull;
    if (selected != null && route.view == DarkroomTargetView.framing) {
      return DarkroomFramingCheck(
        key: ValueKey('darkroom_framing_${selected.key}'),
        target: selected,
      );
    }
    final detail = selected == null
        ? Center(
            child: EmptyState(
              icon: SkotiqIcons.searchEmpty,
              title: 'No lights for $wanted',
              body: 'This host has no captured lights listed under that name.',
            ),
          )
        : DarkroomTargetDetail(
            key: ValueKey('darkroom_target_${selected.key}'),
            target: selected,
          );
    return LayoutBuilder(
      builder: (context, constraints) {
        // On a phone the list is the screen, and a target opens over it.
        if (!BreakpointTokens.isAtLeastDesktop(constraints.maxWidth)) {
          if (wanted == null) {
            return _TargetList(
              targets: list,
              selectedKey: null,
              query: _query,
              onQuery: (q) => setState(() => _query = q),
              othersOpen: _othersOpen ?? false,
              onOthersOpen: (open) => setState(() => _othersOpen = open),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _BackToTargets(),
              Expanded(child: detail),
            ],
          );
        }
        final listWidth =
            constraints.maxWidth < _narrowWidth ? _listWidthNarrow : _listWidth;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: listWidth,
              child: _TargetList(
                targets: list,
                selectedKey: selected?.key,
                query: _query,
                onQuery: (q) => setState(() => _query = q),
                othersOpen: _othersOpen ?? selected?.isProject == false,
                onOthersOpen: (open) => setState(() => _othersOpen = open),
              ),
            ),
            VerticalDivider(
              width: 1,
              thickness: 1,
              color: context.skotiqColors.border,
            ),
            Expanded(child: detail),
          ],
        );
      },
    );
  }
}

/// The phone detail's way back to the list.
class _BackToTargets extends StatelessWidget {
  const _BackToTargets();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SkotiqTokens.spaceSm,
        SkotiqTokens.spaceSm,
        SkotiqTokens.spaceSm,
        0,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SkotiqButton(
          key: const ValueKey('darkroom_back_to_targets'),
          label: 'All targets',
          icon: SkotiqIcons.arrowLeft,
          variant: ButtonVariant.ghost,
          onPressed: () => context.go(darkroomTabLocation(DarkroomTab.targets)),
        ),
      ),
    );
  }
}

/// The projects, then everything else under one folded "Other captures".
class _TargetList extends ConsumerWidget {
  const _TargetList({
    required this.targets,
    required this.selectedKey,
    required this.query,
    required this.onQuery,
    required this.othersOpen,
    required this.onOthersOpen,
  });

  final List<DarkroomTarget> targets;
  final String? selectedKey;
  final String query;
  final ValueChanged<String> onQuery;
  final bool othersOpen;
  final ValueChanged<bool> onOthersOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.skotiqColors;
    final job = ref.watch(darkroomBuildJobsProvider);
    final needle = normalizeDarkroomTargetName(query);
    final shown = needle.isEmpty
        ? targets
        : [
            for (final t in targets)
              if (normalizeDarkroomTargetName(t.key).contains(needle)) t,
          ];
    final projects = [
      for (final t in shown)
        if (t.isProject) t,
    ];
    final others = [
      for (final t in shown)
        if (!t.isProject) t,
    ];
    // A search that finds only other captures shows them.
    final open = othersOpen || (needle.isNotEmpty && projects.isEmpty);
    final eyebrow = SkotiqTypography.monoXs.copyWith(
      color: colors.textSecondary,
      letterSpacing: 1.1,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            SkotiqTokens.spaceLg,
            SkotiqTokens.spaceLg,
            SkotiqTokens.spaceLg,
            SkotiqTokens.spaceSm,
          ),
          child: SkotiqSearchField(
            hint: 'Search targets',
            onChanged: onQuery,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            SkotiqTokens.spaceLg,
            SkotiqTokens.spaceXs,
            SkotiqTokens.spaceLg,
            SkotiqTokens.spaceSm,
          ),
          child: Text(
            '${projects.length} PROJECT${projects.length == 1 ? '' : 'S'} · '
            'LAST IMAGED',
            style: eyebrow,
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
                  child: Text(
                    'No target matches "$query".',
                    style: SkotiqTypography.bodySm.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(
                    SkotiqTokens.spaceSm,
                    0,
                    SkotiqTokens.spaceSm,
                    SkotiqTokens.spaceLg,
                  ),
                  children: [
                    if (projects.isEmpty && needle.isEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          SkotiqTokens.spaceSm,
                          0,
                          SkotiqTokens.spaceSm,
                          SkotiqTokens.spaceMd,
                        ),
                        child: Text(
                          'A target becomes a project once it has enough '
                          'kept light. Until then it is under Other captures.',
                          style: SkotiqTypography.bodySm.copyWith(
                            color: colors.textSecondary,
                          ),
                        ),
                      ),
                    for (final (i, t) in projects.indexed) ...[
                      if (i > 0) const SizedBox(height: SkotiqTokens.spaceXs),
                      _TargetRow(
                        target: t,
                        selected: t.key == selectedKey,
                        job: job,
                      ),
                    ],
                    if (others.isNotEmpty) ...[
                      const SizedBox(height: SkotiqTokens.spaceMd),
                      _OthersHeader(
                        others: others,
                        open: open,
                        onToggle: () => onOthersOpen(!open),
                      ),
                      if (open)
                        for (final t in others) ...[
                          const SizedBox(height: SkotiqTokens.spaceXs),
                          _TargetRow(
                            target: t,
                            selected: t.key == selectedKey,
                            job: job,
                            compact: true,
                          ),
                        ],
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

/// The fold over everything that is not a project, with how much is in it.
class _OthersHeader extends StatelessWidget {
  const _OthersHeader({
    required this.others,
    required this.open,
    required this.onToggle,
  });

  final List<DarkroomTarget> others;
  final bool open;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final subs = others.fold<int>(0, (n, t) => n + t.frames.length);
    final count = '${others.length} · $subs sub${subs == 1 ? '' : 's'}';
    return Row(
      children: [
        Expanded(
          child: Semantics(
            button: true,
            enabled: true,
            expanded: open,
            label: 'Other captures, $count',
            onTap: onToggle,
            excludeSemantics: true,
            child: InkWell(
              key: const ValueKey('darkroom_other_captures'),
              borderRadius: SkotiqTokens.borderRadiusMd,
              onTap: onToggle,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: SkotiqTokens.minTouchTarget,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: SkotiqTokens.spaceSm,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        open ? SkotiqIcons.chevronDown : SkotiqIcons.chevronRight,
                        size: SkotiqTokens.iconSm,
                        color: colors.textSecondary,
                      ),
                      const SizedBox(width: SkotiqTokens.spaceSm),
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(
                                text: 'OTHER CAPTURES',
                                style: SkotiqTypography.monoXs.copyWith(
                                  color: colors.textSecondary,
                                  letterSpacing: 1.1,
                                ),
                              ),
                              TextSpan(
                                text: '  ${count.toUpperCase()}',
                                style: SkotiqTypography.monoXs.copyWith(
                                  color: colors.textMuted,
                                  letterSpacing: 1.1,
                                ),
                              ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const DarkroomProjectRuleButton(),
      ],
    );
  }
}

class _TargetRow extends StatefulWidget {
  const _TargetRow({
    required this.target,
    required this.selected,
    required this.job,
    this.compact = false,
  });

  final DarkroomTarget target;
  final bool selected;
  final DarkroomBuildJob? job;

  /// An other capture: its sub count, and why it is not a project in place
  /// of its build status.
  final bool compact;

  @override
  State<_TargetRow> createState() => _TargetRowState();
}

class _TargetRowState extends State<_TargetRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final t = widget.target;
    var (status, tone) = darkroomTargetStatus(t, widget.job, colors);
    if (widget.compact) (status, tone) = (t.otherReason, colors.textMuted);
    final nights = t.nights.length;
    final subs = t.frames.length;
    final meta = [
      if (widget.compact) '$subs sub${subs == 1 ? '' : 's'}',
      '$nights night${nights == 1 ? '' : 's'}',
      if (t.filters.isNotEmpty) darkroomFilterSummary(t.filters),
      if (t.keptSeconds > 0) describeIntegration(t.keptSeconds),
    ].join(' · ');
    void open() => context.go(darkroomTargetLocation(t.key));
    return Semantics(
      button: true,
      enabled: true,
      selected: widget.selected,
      label: '${t.key}. $meta. $status.',
      onTap: open,
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          key: ValueKey('darkroom_target_row_${t.key}'),
          behavior: HitTestBehavior.opaque,
          onTap: open,
          child: AnimatedContainer(
            duration: SkotiqTokens.durationFast,
            padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
            decoration: BoxDecoration(
              color: widget.selected || _hover
                  ? colors.surfaceHover
                  : Colors.transparent,
              borderRadius: SkotiqTokens.borderRadiusLg,
              border: Border.all(
                color: widget.selected
                    ? colors.primary.withValues(alpha: .4)
                    : Colors.transparent,
              ),
            ),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: SkotiqTokens.borderRadiusSm,
                  child: SizedBox.square(
                    dimension: _thumbSize,
                    child: DarkroomPreviewImage(
                      path: t.heroImagePath,
                      alignment: const Alignment(.4, 0),
                      decodeWidth: 240,
                      placeholderIcon: SkotiqIcons.star,
                    ),
                  ),
                ),
                const SizedBox(width: SkotiqTokens.spaceMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.key,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: SkotiqTypography.sectionTitle.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: SkotiqTypography.caption.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        status,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: SkotiqTypography.caption.copyWith(color: tone),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// `LRGB` when every filter is one letter, else the names joined.
String darkroomFilterSummary(List<String> filters) =>
    filters.every((f) => f.length == 1) ? filters.join() : filters.join(' ');
