import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/darkroom_navigation.dart';
import '../darkroom_route.dart';
import 'darkroom_image.dart';
import 'darkroom_status_chip.dart';
import 'darkroom_targets_model.dart';
import 'darkroom_targets_providers.dart';
import 'framing_check.dart';
import 'target_detail.dart';

/// Width of the target list beside the detail.
const double _listWidth = 300;
const double _listWidthNarrow = 248;

/// Below this width the list narrows.
const double _narrowWidth = 1100;

/// Thumbnail edge in the target list.
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
          body: '$error',
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
        ? list.first
        : list.where((t) => t.key == wanted).firstOrNull;
    if (selected != null && route.view == DarkroomTargetView.framing) {
      return DarkroomFramingCheck(
        key: ValueKey('darkroom_framing_${selected.key}'),
        target: selected,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
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
              ),
            ),
            VerticalDivider(
              width: 1,
              thickness: 1,
              color: context.skotiqColors.border,
            ),
            Expanded(
              child: selected == null
                  ? Center(
                      child: EmptyState(
                        icon: SkotiqIcons.searchEmpty,
                        title: 'No lights for $wanted',
                        body: 'This host has no captured lights listed under '
                            'that name.',
                      ),
                    )
                  : DarkroomTargetDetail(
                      key: ValueKey('darkroom_target_${selected.key}'),
                      target: selected,
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _TargetList extends ConsumerWidget {
  const _TargetList({
    required this.targets,
    required this.selectedKey,
    required this.query,
    required this.onQuery,
  });

  final List<DarkroomTarget> targets;
  final String? selectedKey;
  final String query;
  final ValueChanged<String> onQuery;

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
          child: SkotiqTextField(
            hint: 'Search targets',
            prefixIcon: SkotiqIcons.search,
            dense: true,
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
            '${shown.length} TARGET${shown.length == 1 ? '' : 'S'} · '
            'LAST IMAGED',
            style: SkotiqTypography.monoXs.copyWith(
              color: colors.textSecondary,
              letterSpacing: 1.1,
            ),
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
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(
                    SkotiqTokens.spaceSm,
                    0,
                    SkotiqTokens.spaceSm,
                    SkotiqTokens.spaceLg,
                  ),
                  itemCount: shown.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(height: SkotiqTokens.spaceXs),
                  itemBuilder: (context, i) => _TargetRow(
                    target: shown[i],
                    selected: shown[i].key == selectedKey,
                    job: job,
                  ),
                ),
        ),
      ],
    );
  }
}

class _TargetRow extends StatefulWidget {
  const _TargetRow({
    required this.target,
    required this.selected,
    required this.job,
  });

  final DarkroomTarget target;
  final bool selected;
  final DarkroomBuildJob? job;

  @override
  State<_TargetRow> createState() => _TargetRowState();
}

class _TargetRowState extends State<_TargetRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final t = widget.target;
    final (status, tone) = darkroomTargetStatus(t, widget.job, colors);
    final nights = t.nights.length;
    final meta = [
      '$nights night${nights == 1 ? '' : 's'}',
      if (t.filters.isNotEmpty) darkroomFilterSummary(t.filters),
      if (t.keptSeconds > 0) describeIntegration(t.keptSeconds),
    ].join(' · ');
    final hero = t.heroMaster;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: '${t.key}. $meta. $status.',
      excludeSemantics: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          key: ValueKey('darkroom_target_row_${t.key}'),
          behavior: HitTestBehavior.opaque,
          onTap: () => context.go(darkroomTargetLocation(t.key)),
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
                      path: hero?.previewPngPath,
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
