import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Modal that renders a [SequenceDiffResult] in a unified-diff layout
/// with green/red/yellow color coding.
///
/// Two factory entry points:
///   * [SequenceDiffDialog.show] for direct invocation when both
///     sequences are already in memory.
///   * [SequenceDiffDialog.showForRun] for the History tab's
///     "Diff vs previous" button, which resolves the previous and
///     current snapshots from the sequence repository before showing
///     the dialog.
///
/// Visual scheme:
///   * Added → success / green
///   * Removed → error / red
///   * Modified → warning / yellow with per-field "from → to" rows
class SequenceDiffDialog extends StatelessWidget {
  final SequenceDiffResult diff;

  const SequenceDiffDialog({super.key, required this.diff});

  static Future<void> show(BuildContext context, SequenceDiffResult diff) {
    return showDialog<void>(
      context: context,
      builder: (_) => SequenceDiffDialog(diff: diff),
    );
  }

  /// Resolve "diff vs previous run for the sequence behind [run]" and show
  /// the dialog.
  ///
  /// The comparison is between two real run snapshots:
  ///   * `current`  = this run's own captured `sequenceSnapshotJson`.
  ///   * `previous` = the snapshot of the most recent *completed* run of the
  ///     same sequence that started before this one
  ///     ([SequenceRepository.loadPreviousRunSnapshot]).
  ///
  /// When this run has no captured snapshot (legacy / resumed run) we fall
  /// back to the sequence as it stands now in the database so the operator
  /// still gets a meaningful "what changed since the previous run" view.
  /// When there is no earlier completed snapshot at all we show an honest
  /// empty state rather than diffing the sequence against itself.
  static Future<void> showForRun(
    BuildContext context,
    WidgetRef ref, {
    required SequenceRun run,
  }) async {
    final colors = SkotiqColors.of(context);
    final repo = ref.read(sequenceRepositoryProvider);
    final fileService = ref.read(sequenceFileServiceProvider);
    final diffService = ref.read(sequenceDiffServiceProvider);

    final sequenceId = run.sequenceId;
    if (sequenceId == null) {
      await _showNoComparison(
          context, colors, 'This run has no linked sequence; cannot diff.');
      return;
    }

    // Resolve both sides together so remote clients compare the exact
    // host-persisted documents instead of falling back to a controller-local
    // database or a since-edited live sequence definition.
    final SequenceRunDiffContext diffContext;
    try {
      diffContext = await repo.loadRunDiffContext(run.id);
    } on ServerError catch (error) {
      if (!context.mounted) return;
      await _showNoComparison(
        context,
        colors,
        error.code == 'sequence_run_not_found'
            ? 'This run no longer exists on the imaging host.'
            : 'Could not load the run snapshots from the imaging host. '
                'Check the connection and try again.',
      );
      return;
    } catch (e) {
      // Fallback arm for anything that is not a typed ServerError — decode
      // failures, transport errors, a repository fault. The dialog tells the
      // operator the comparison is unavailable; the log is the only place the
      // actual cause survives for a run whose snapshots will not load.
      developer.log(
        'Could not load run diff context for run ${run.id}: $e',
        name: 'SequenceDiff',
        level: 900,
      );
      if (!context.mounted) return;
      await _showNoComparison(
        context,
        colors,
        'Could not load the saved run snapshots. Try again.',
      );
      return;
    }
    if (diffContext.sequenceId != sequenceId) {
      if (!context.mounted) return;
      await _showNoComparison(
        context,
        colors,
        'This run is no longer linked to the sequence shown in history.',
      );
      return;
    }
    final previousJson = diffContext.previousSnapshotJson;
    if (previousJson == null) {
      if (!context.mounted) return;
      await _showNoComparison(
        context,
        colors,
        'No earlier completed run of this sequence has a saved snapshot to '
        'diff against. Runs recorded before snapshotting was added, or runs '
        'that never completed, are not comparable.',
      );
      return;
    }

    // The "current" side of the diff: prefer this run's own captured snapshot
    // (the exact sequence that executed), falling back to the live sequence
    // definition for runs that predate snapshot capture.
    Sequence current;
    try {
      final currentSnapshot = diffContext.currentSnapshotJson;
      if (currentSnapshot != null && currentSnapshot.isNotEmpty) {
        current = _parseSnapshot(fileService, currentSnapshot);
      } else {
        final loaded = await repo.loadSequence(sequenceId);
        if (loaded == null) {
          if (!context.mounted) return;
          await _showNoComparison(context, colors,
              'Sequence definition is no longer in the database.');
          return;
        }
        current = loaded;
      }
    } on FormatException catch (e) {
      if (!context.mounted) return;
      await _showNoComparison(
          context, colors, 'This run\'s snapshot could not be read: $e');
      return;
    }

    final Sequence previous;
    try {
      previous = _parseSnapshot(fileService, previousJson);
    } on FormatException catch (e) {
      if (!context.mounted) return;
      await _showNoComparison(context, colors,
          'The previous run\'s snapshot could not be read: $e');
      return;
    }

    final result = diffService.diff(previous: previous, current: current);
    if (!context.mounted) return;
    await show(context, result);
  }

  /// Decode a persisted run snapshot (JSON string) into an editable
  /// [Sequence] through the same parser the importer uses. Throws
  /// [FormatException] for a malformed payload so callers can surface an
  /// honest error rather than a stack trace.
  static Sequence _parseSnapshot(
    SequenceFileService fileService,
    String snapshotJson,
  ) {
    final decoded = jsonDecode(snapshotJson);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException(
        'Expected a JSON object, got ${decoded.runtimeType}.',
      );
    }
    return fileService.parseFromMap(decoded);
  }

  static Future<void> _showNoComparison(
    BuildContext context,
    SkotiqColors colors,
    String message,
  ) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: const Text('Sequence diff unavailable'),
        content: ConstrainedBox(
          constraints: AdaptiveDialogConstraints.hybrid(
            ctx,
            designMaxWidth: 400,
          ),
          child: Text(message),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Dialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        side: BorderSide(color: colors.border),
      ),
      child: ConstrainedBox(
        constraints: AdaptiveDialogConstraints.hybrid(
          context,
          designMaxWidth: 760,
          designMaxHeight: 720,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(context, colors),
            Expanded(child: _buildBody(colors)),
            _buildFooter(context, colors),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, SkotiqColors colors) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.gitCompare, size: 22, color: colors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Sequence Diff',
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize18,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
                Text(
                  '${diff.previousName} → ${diff.currentName}',
                  style: TextStyle(
                      fontSize: SkotiqTypography.fontSize12,
                      color: colors.textMuted),
                ),
              ],
            ),
          ),
          _SummaryChip(colors: colors, diff: diff),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: Icon(LucideIcons.x, color: colors.textMuted),
            tooltip: 'Close',
          ),
        ],
      ),
    );
  }

  Widget _buildBody(SkotiqColors colors) {
    if (diff.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.checkCircle2, size: 32, color: colors.success),
              const SizedBox(height: 8),
              Text(
                'No structural changes between these runs.',
                style: TextStyle(
                    fontSize: SkotiqTypography.fontSize13,
                    color: colors.textSecondary),
              ),
            ],
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (diff.added.isNotEmpty)
          _DiffSection(
            title: 'Added (${diff.added.length})',
            iconColor: colors.success,
            icon: LucideIcons.plusCircle,
            colors: colors,
            entries: diff.added,
            entryColor: colors.success,
            symbol: '+',
          ),
        if (diff.removed.isNotEmpty)
          _DiffSection(
            title: 'Removed (${diff.removed.length})',
            iconColor: colors.error,
            icon: LucideIcons.minusCircle,
            colors: colors,
            entries: diff.removed,
            entryColor: colors.error,
            symbol: '-',
          ),
        if (diff.modified.isNotEmpty)
          _DiffSection(
            title: 'Modified (${diff.modified.length})',
            iconColor: colors.warning,
            icon: LucideIcons.fileEdit,
            colors: colors,
            entries: diff.modified,
            entryColor: colors.warning,
            symbol: '~',
            showFieldChanges: true,
          ),
      ],
    );
  }

  Widget _buildFooter(BuildContext context, SkotiqColors colors) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          Text(
            diff.summary,
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize12,
              color: colors.textMuted,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const Spacer(),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

class _SummaryChip extends StatelessWidget {
  final SkotiqColors colors;
  final SequenceDiffResult diff;

  const _SummaryChip({required this.colors, required this.diff});

  @override
  Widget build(BuildContext context) {
    final color = diff.isEmpty ? colors.textMuted : colors.primary;
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: SkotiqDecorations.iconChip(
        color,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        borderAlpha: 0.4,
      ),
      child: Text(
        diff.summary,
        style: TextStyle(
          fontSize: SkotiqTypography.fontSize12,
          fontWeight: FontWeight.w600,
          color: color,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _DiffSection extends StatelessWidget {
  final String title;
  final Color iconColor;
  final IconData icon;
  final SkotiqColors colors;
  final List<NodeDiffEntry> entries;
  final Color entryColor;
  final String symbol;
  final bool showFieldChanges;

  const _DiffSection({
    required this.title,
    required this.iconColor,
    required this.icon,
    required this.colors,
    required this.entries,
    required this.entryColor,
    required this.symbol,
    this.showFieldChanges = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: iconColor),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize13,
                  fontWeight: FontWeight.w700,
                  color: colors.textPrimary,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final e in entries)
            _DiffNodeRow(
              entry: e,
              symbol: symbol,
              entryColor: entryColor,
              colors: colors,
              showFieldChanges: showFieldChanges,
            ),
        ],
      ),
    );
  }
}

class _DiffNodeRow extends StatelessWidget {
  final NodeDiffEntry entry;
  final String symbol;
  final Color entryColor;
  final SkotiqColors colors;
  final bool showFieldChanges;

  const _DiffNodeRow({
    required this.entry,
    required this.symbol,
    required this.entryColor,
    required this.colors,
    required this.showFieldChanges,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: entryColor.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        border: Border.all(color: entryColor.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 18,
                alignment: Alignment.center,
                child: Text(
                  symbol,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: SkotiqTypography.fontSize14,
                    color: entryColor,
                    fontFamily: SkotiqTypography.fontFamilyMono,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: colors.surfaceAlt,
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline4),
                ),
                child: Text(
                  entry.nodeKind,
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize10,
                    fontWeight: FontWeight.w600,
                    color: colors.textMuted,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  entry.label,
                  style: SkotiqTypography.labelStrong
                      .copyWith(color: colors.textPrimary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (showFieldChanges && entry.changes.isNotEmpty) ...[
            const SizedBox(height: 6),
            for (final fc in entry.changes)
              Padding(
                padding: const EdgeInsets.only(left: 26, top: 2, bottom: 2),
                child: _FieldChangeRow(
                  change: fc,
                  colors: colors,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _FieldChangeRow extends StatelessWidget {
  final FieldChange change;
  final SkotiqColors colors;

  const _FieldChangeRow({required this.change, required this.colors});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(
            color: colors.surfaceAlt,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
          ),
          child: Text(
            change.field,
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize10,
              fontWeight: FontWeight.w600,
              color: colors.textSecondary,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _ValueChip(
                  value: change.oldValue?.toString() ?? '(none)',
                  color: colors.error,
                  colors: colors),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Icon(LucideIcons.arrowRight,
                    size: 12, color: colors.textMuted),
              ),
              _ValueChip(
                  value: change.newValue?.toString() ?? '(none)',
                  color: colors.success,
                  colors: colors),
            ],
          ),
        ),
      ],
    );
  }
}

class _ValueChip extends StatelessWidget {
  final String value;
  final Color color;
  final SkotiqColors colors;

  const _ValueChip({
    required this.value,
    required this.color,
    required this.colors,
  });

  /// Max characters shown inline before the value is clamped with an
  /// ellipsis. Large opaque values (e.g. plugin config JSON) would
  /// otherwise blow out the chip width and overflow the row.
  static const int _maxInlineChars = 60;

  @override
  Widget build(BuildContext context) {
    final isTruncated = value.length > _maxInlineChars;
    final displayValue =
        isTruncated ? '${value.substring(0, _maxInlineChars)}…' : value;
    final chip = Container(
      constraints: const BoxConstraints(maxWidth: 240),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: SkotiqDecorations.tintedBadge(
        color,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
      ),
      child: Text(
        displayValue,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: SkotiqTypography.fontSize11,
          color: color,
          fontFamily: SkotiqTypography.fontFamilyMono,
        ),
      ),
    );
    if (!isTruncated) return chip;
    return Tooltip(message: value, child: chip);
  }
}
