import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The stacks Stack & Share has saved, newest first; a row opens the result.
class RecentStacksPanel extends ConsumerStatefulWidget {
  const RecentStacksPanel({super.key});

  /// Rows shown before "Show more".
  static const int collapsedRows = 5;

  @override
  ConsumerState<RecentStacksPanel> createState() => _RecentStacksPanelState();
}

class _RecentStacksPanelState extends ConsumerState<RecentStacksPanel> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final linked = ref.watch(isRemoteModeProvider);
    final stacks = ref.watch(recentStackedResultsProvider);

    final Widget body;
    if (stacks.hasError && !stacks.isLoading) {
      body = EmptyState.compact(
        icon: SkotiqIcons.warning,
        title: 'Could not load recent stacks',
        body: userFacingError(stacks.error!),
        action: SkotiqButton(
          label: 'Retry',
          icon: SkotiqIcons.refresh,
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: () => ref.invalidate(recentStackedResultsProvider),
        ),
      );
    } else if (!stacks.hasValue) {
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceSm),
        child: Row(
          children: [
            SkotiqSpinner(size: 14, color: colors.primary),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Text(
              'Loading recent stacks…',
              style: SkotiqTypography.caption.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ],
        ),
      );
    } else if (stacks.requireValue.isEmpty) {
      body = EmptyState.compact(
        icon: SkotiqIcons.layers,
        title: 'No stacks yet',
        body: linked
            ? 'Stacks made with Stack & Share on the imaging host are listed '
                  'here.'
            : 'Run Stack & Share on a finished session and the stack is kept '
                  'here.',
      );
    } else {
      final all = stacks.requireValue;
      final shown = _expanded
          ? all
          : all.take(RecentStacksPanel.collapsedRows).toList();
      final hidden = all.length - shown.length;
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < shown.length; i++)
            _RecentStackRow(
              result: shown[i],
              showDivider: i < shown.length - 1 || hidden > 0,
            ),
          if (hidden > 0)
            Align(
              alignment: Alignment.centerLeft,
              child: SkotiqButton(
                label: 'Show $hidden more',
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
                onPressed: () => setState(() => _expanded = true),
              ),
            ),
        ],
      );
    }

    return SkotiqPanel(
      head: const PanelHead(label: 'Recent stacks', icon: SkotiqIcons.history),
      child: body,
    );
  }
}

class _RecentStackRow extends StatefulWidget {
  const _RecentStackRow({required this.result, required this.showDivider});

  final StackAndShareResult result;
  final bool showDivider;

  @override
  State<_RecentStackRow> createState() => _RecentStackRowState();
}

class _RecentStackRowState extends State<_RecentStackRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final result = widget.result;
    final id = result.id;
    final title = result.targetName ?? 'Unnamed target';
    final details = [
      result.filter ?? (result.isColor ? 'Color' : null),
      '${result.framesStacked} '
          '${result.framesStacked == 1 ? 'frame' : 'frames'}',
      DurationFormat.seconds(
        result.integrationSecs,
        style: DurationStyle.short,
      ),
    ].whereType<String>().join(' · ');
    final date = ClockFormat.monthDayYear(result.createdAt.toLocal());

    final row = Container(
      padding: const EdgeInsets.symmetric(
        vertical: SkotiqTokens.spaceSm,
        horizontal: SkotiqTokens.spaceSm,
      ),
      decoration: BoxDecoration(
        color: _hovered && id != null ? colors.surfaceHover : null,
        borderRadius: SkotiqTokens.borderRadiusSm,
        border: widget.showDivider
            ? Border(bottom: BorderSide(color: colors.border))
            : null,
      ),
      child: Row(
        children: [
          _StackThumbnail(resultId: id),
          const SizedBox(width: SkotiqTokens.spaceMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SkotiqTypography.labelStrong.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  details,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  date,
                  maxLines: 1,
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    if (id == null) return row;
    return Semantics(
      button: true,
      enabled: true,
      label: 'Open stack: $title, $details, $date',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => context.push('/stack-result?id=$id'),
          child: ExcludeSemantics(child: row),
        ),
      ),
    );
  }
}

class _StackThumbnail extends ConsumerWidget {
  const _StackThumbnail({required this.resultId});

  final int? resultId;

  static const double width = 52;
  static const double height = 52;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final id = resultId;
    final path = id == null
        ? null
        : ref.watch(stackResultThumbnailPathProvider(id)).valueOrNull;
    final placeholder = Center(
      child: Icon(SkotiqIcons.layers, size: 16, color: colors.textMuted),
    );
    return ClipRRect(
      borderRadius: SkotiqTokens.borderRadiusSm,
      child: Container(
        width: width,
        height: height,
        color: colors.well,
        child: path == null
            ? placeholder
            : Image.file(
                File(path),
                // Decode at the size drawn, not the stack's full resolution.
                cacheWidth:
                    (width * MediaQuery.devicePixelRatioOf(context)).round(),
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
                errorBuilder: (context, error, stackTrace) => placeholder,
              ),
      ),
    );
  }
}
