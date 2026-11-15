part of '../sequence_library_tab.dart';

/// What a row's "more" menu offers.
enum _RowAction {
  preview,
  runHistory,
  versionHistory,
  editTags,
  duplicate,
  export,
  delete,
}

/// One saved sequence, from a lightweight [SequenceSummary] (no node-tree
/// hydration): the name, one line of facts and the last run.
///
/// Tapping the row opens the sequence in the Builder. The star and the "more"
/// menu are its two buttons; the menu holds the rest. Actions that need the
/// node graph (open, duplicate, export, preview) load the [Sequence] from the
/// repository on demand, so opening the library never pays the N+1 cost.
class _SequenceRow extends ConsumerStatefulWidget {
  const _SequenceRow({
    super.key,
    required this.summary,
    required this.compact,
    required this.last,
  });

  final SequenceSummary summary;

  /// Phone width: the last run joins the facts line instead of a column.
  final bool compact;

  /// The last row in the panel draws no hairline under itself.
  final bool last;

  @override
  ConsumerState<_SequenceRow> createState() => _SequenceRowState();
}

class _SequenceRowState extends ConsumerState<_SequenceRow> {
  bool _expanded = false;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;

  /// The full sequence for the preview, loaded the first time it opens.
  Sequence? _previewSequence;
  bool _previewLoading = false;
  Object? _previewError;

  SequenceSummary get _summary => widget.summary;

  SkotiqColors get _colors => SkotiqColors.of(context);

  @override
  void initState() {
    super.initState();
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (previous == null || identical(previous, next) || !mounted) return;
        setState(() {
          _expanded = false;
          _previewSequence = null;
          _previewLoading = false;
          _previewError = null;
        });
      },
    );
  }

  @override
  void dispose() {
    _backendSubscription?.close();
    super.dispose();
  }

  String? _durationLabel() {
    final totalSecs = _summary.totalIntegrationSecs;
    if (totalSecs <= 0) return null;
    return DurationFormat.seconds(
      totalSecs,
      style: DurationStyle.coarse,
      rounding: DurationRounding.truncate,
    );
  }

  String get _lastRunLabel {
    final lastRun = _summary.lastRunAt;
    return lastRun == null ? 'Never run' : _formatDate(lastRun);
  }

  /// The facts line. The capture count is capture STEPS: the summary query
  /// counts exposure nodes, so a "10 x 60s" step is one, not ten frames.
  String get _facts {
    final target = _summary.primaryTargetName;
    final duration = _durationLabel();
    return <String>[
      if (target != null && target.isNotEmpty) target,
      if (_summary.targetCount != 1 || target == null || target.isEmpty)
        countLabel(_summary.targetCount, 'target'),
      countLabel(_summary.exposureCount, 'capture step'),
      if (duration != null) duration,
      if (_summary.runCount > 0) countLabel(_summary.runCount, 'run'),
      if (widget.compact)
        _summary.lastRunAt == null
            ? 'never run'
            : 'last run ${_formatDate(_summary.lastRunAt!)}',
      'edited ${_formatDate(_summary.modifiedAt)}',
      if (_summary.tags.isNotEmpty) _summary.tags.join(', '),
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final favorite = _summary.isFavorite;
    final row = ListRow(
      title: _summary.name,
      subtitle: _facts,
      trailing: widget.compact ? null : _lastRunLabel,
      showDivider: !widget.last || _expanded,
      onTap: () => _loadSequence(context),
      actions: [
        SkotiqIconButton(
          icon: LucideIcons.star,
          tooltip: favorite ? 'Remove from favorites' : 'Add to favorites',
          color: favorite ? colors.warning : null,
          onPressed: _toggleFavorite,
        ),
        _moreMenu(),
      ],
    );
    if (!_expanded) return row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [row, _buildPreview(colors)],
    );
  }

  Widget _moreMenu() {
    return SkotiqMenuButton<_RowAction>(
      tooltip: 'More actions for ${_summary.name}',
      entries: [
        SkotiqMenuChoice(
            _RowAction.preview, _expanded ? 'Hide preview' : 'Preview'),
        const SkotiqMenuChoice(_RowAction.runHistory, 'View run history'),
        const SkotiqMenuChoice(_RowAction.versionHistory, 'Version history'),
        const SkotiqMenuChoice(_RowAction.editTags, 'Edit tags'),
        const SkotiqMenuChoice(_RowAction.duplicate, 'Duplicate'),
        const SkotiqMenuChoice(_RowAction.export, 'Export'),
        const SkotiqMenuChoice(_RowAction.delete, 'Delete', destructive: true),
      ],
      onSelected: (action) => switch (action) {
        _RowAction.preview => _togglePreview(),
        _RowAction.runHistory => _openHistory(context),
        _RowAction.versionHistory => _openVersionHistory(context),
        _RowAction.editTags => _editTags(context),
        _RowAction.duplicate => _duplicateSequence(context),
        _RowAction.export => _exportSequence(context),
        _RowAction.delete => _deleteSequence(context),
      },
    );
  }

  /// The planned capture per target, loaded on demand, in a well under the
  /// row.
  Widget _buildPreview(SkotiqColors colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SkotiqTokens.spaceSm,
        SkotiqTokens.spaceSm,
        SkotiqTokens.spaceSm,
        SkotiqTokens.spaceMd,
      ),
      child: DecoratedBox(
        decoration: SkotiqDecorations.well(colors),
        child: Padding(
          padding: SkotiqTokens.paddingMd,
          child: _buildPreviewBody(),
        ),
      ),
    );
  }

  Widget _buildPreviewBody() {
    final muted = SkotiqTypography.bodySm.copyWith(color: _colors.textMuted);
    if (_previewLoading) {
      return Row(
        children: [
          SkotiqSpinner(
              size: SkotiqTokens.iconGlyphRow, color: _colors.primary),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Text('Loading the preview', style: muted),
        ],
      );
    }

    if (_previewError != null) {
      return Text(
        'Could not load the preview: ${userFacingError(_previewError!)}',
        style: SkotiqTypography.bodySm.copyWith(color: _colors.error),
      );
    }

    final sequence = _previewSequence;
    if (sequence == null) {
      return Text('Preview unavailable', style: muted);
    }

    final headers =
        sequence.nodes.values.whereType<TargetHeaderNode>().toList();

    if (headers.isEmpty) {
      // Frames, not nodes: the shared walk applies loop multipliers and
      // counts SmartExposure plans, so a target-less calibration or
      // Plan-Tonight sequence reports what it will actually capture.
      final planned = plannedCaptureForSequence(sequence);
      return Text('No targets: ${_plannedSummary(planned)}', style: muted);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < headers.length; i++) ...[
          if (i > 0) const SizedBox(height: SkotiqTokens.spaceSm),
          _buildTargetPreviewRow(sequence, headers[i]),
        ],
      ],
    );
  }

  /// One-line "what this will capture" phrase for a [PlannedCapture].
  ///
  /// Never says "no exposures" for a plan that captures something: an
  /// open-ended (loop-until-stopped) Smart Exposure has no fixed count but is
  /// very much imaging, and a non-`count` loop makes the counted figure a
  /// per-pass floor.
  String _plannedSummary(PlannedCapture planned) {
    if (planned.isEmpty) return 'no exposures';

    final parts = <String>[];
    if (planned.frames > 0) {
      parts.add(
        '${countLabel(planned.frames, 'frame')} • '
        '${DurationFormat.seconds(planned.integrationSecs, style: DurationStyle.coarse, roundToMinute: true)}'
        '${planned.hasUnboundedRepeat ? ' per pass' : ''}',
      );
    }
    if (planned.hasOpenEndedLoop) {
      parts.add(
        planned.openEndedBudgetSecs > 0
            ? 'looping up to ${DurationFormat.seconds(planned.openEndedBudgetSecs, style: DurationStyle.coarse, roundToMinute: true)}'
            : 'looping until the window closes',
      );
    }
    if (planned.hasUnboundedRepeat && planned.frames > 0) {
      parts.add('loop repeats until its stop condition');
    }
    return parts.join(' + ');
  }

  Widget _buildTargetPreviewRow(Sequence sequence, TargetHeaderNode header) {
    // The shared plan walk: loop multipliers applied, SmartExposure plans
    // counted, so a target whose only imager is a Smart Exposure or a
    // `Capture Loop x10` reports what it really captures.
    final planned = plannedCaptureUnder(sequence, header.id);
    final byFilter = planned.integrationSecsByFilter;
    final secondary =
        SkotiqTypography.bodySm.copyWith(color: _colors.textSecondary);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          header.targetName.isEmpty ? 'Target' : header.targetName,
          style: SkotiqTypography.bodySm.copyWith(
            fontWeight: FontWeight.w600,
            color: _colors.textPrimary,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          _plannedSummary(planned),
          style: planned.isEmpty
              ? secondary.copyWith(color: _colors.textMuted)
              : secondary,
        ),
        for (final entry in byFilter.entries)
          Text(
            '${entry.key}: ${DurationFormat.seconds(entry.value, style: DurationStyle.coarse, roundToMinute: true)}',
            style: secondary,
          ),
      ],
    );
  }

  /// Load the full sequence from the repository, used by every tree-requiring
  /// action. Returns null and surfaces an error snackbar on failure.
  Future<Sequence?> _loadFullSequence(
    BuildContext context, {
    required AsyncScope<SkotiqBackend> host,
    required SequenceRepository repository,
  }) async {
    try {
      final sequence = await repository.loadSequence(_summary.id);
      if (host.isStale) return null;
      if (sequence == null && context.mounted) {
        context.showErrorSnackBar('Sequence is no longer available');
      }
      return sequence;
    } catch (e) {
      if (context.mounted && host.isCurrent) {
        context.showErrorSnackBar(
            'Failed to load sequence: ${userFacingError(e)}');
      }
      return null;
    }
  }

  void _togglePreview() {
    final willExpand = !_expanded;
    setState(() => _expanded = willExpand);
    if (willExpand && _previewSequence == null && !_previewLoading) {
      _loadPreview();
    }
  }

  Future<void> _loadPreview() async {
    final host = ref.backendScope();
    final repository = ref.read(sequenceRepositoryProvider);
    setState(() {
      _previewLoading = true;
      _previewError = null;
    });
    try {
      final sequence = await repository.loadSequence(_summary.id);
      if (!mounted || host.isStale) return;
      setState(() {
        _previewSequence = sequence;
        _previewLoading = false;
        if (sequence == null) {
          _previewError = 'Sequence is no longer available';
        }
      });
    } catch (e) {
      if (!mounted || host.isStale) return;
      setState(() {
        _previewLoading = false;
        _previewError = e;
      });
    }
  }

  Future<void> _toggleFavorite() async {
    final host = ref.backendScope();
    final repository = ref.read(sequenceRepositoryProvider);
    try {
      await repository.toggleFavorite(_summary.id);
      if (host.isStale) return;
      ref.invalidate(savedSequenceSummariesProvider);
    } catch (e) {
      if (mounted && host.isCurrent) {
        context.showErrorSnackBar(
            'Failed to update favorite: ${userFacingError(e)}');
      }
    }
  }

  /// Opens Analytics > History narrowed to this sequence's runs.
  void _openHistory(BuildContext context) =>
      context.go(AppRoutes.history(sequenceId: _summary.id));

  void _openVersionHistory(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => _VersionHistoryDialog(
        colors: _colors,
        sequenceId: _summary.id,
        sequenceName: _summary.name,
      ),
    );
  }

  void _editTags(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => _TagEditorDialog(
        colors: _colors,
        sequenceId: _summary.id,
        sequenceName: _summary.name,
        initialTags: _summary.tags,
      ),
    );
  }

  String _formatDate(DateTime date) =>
      sequenceRowDateLabel(date, DateTime.now());

  Future<void> _loadSequence(BuildContext context) async {
    final host = ref.backendScope();
    final repository = ref.read(sequenceRepositoryProvider);
    final source = await _loadFullSequence(
      context,
      host: host,
      repository: repository,
    );
    if (source == null || !context.mounted || host.isStale) {
      return;
    }

    // The editor keeps the saved node ids: runs, captured frames and the
    // pre-flight "changed since the last run" check all match nodes by id.
    final loadedSequence = source.copyWith(isTemplate: false);

    final editor = ref.read(currentSequenceProvider.notifier);
    try {
      editor.loadSequence(loadedSequence);
    } on UnsavedChangesException catch (e) {
      // Opening a row is a deliberate switch, but unsaved work still gets
      // the chance to be kept.
      if (!context.mounted) return;
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Discard unsaved changes?'),
          content: ConstrainedBox(
            constraints: AdaptiveDialogConstraints.hybrid(
              ctx,
              designMaxWidth: 440,
            ),
            child: Text('"${e.currentSequenceName}" has unsaved changes. '
                'Opening "${_summary.name}" will discard them.'),
          ),
          actions: [
            SkotiqButton(
              label: 'Cancel',
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: () => Navigator.of(ctx).pop(false),
            ),
            SkotiqButton(
              label: 'Discard and open',
              variant: ButtonVariant.destructive,
              size: ButtonSize.small,
              onPressed: () => Navigator.of(ctx).pop(true),
            ),
          ],
        ),
      );
      if (discard != true || host.isStale) return;
      editor.loadSequence(loadedSequence, discardUnsaved: true);
    }

    if (host.isStale) return;

    ref.read(sequencerTabProvider.notifier).state = 0;

    if (context.mounted) {
      context.showSuccessSnackBar('Opened "${_summary.name}"');
    }
  }

  Future<void> _duplicateSequence(BuildContext context) async {
    final host = ref.backendScope();
    final repository = ref.read(sequenceRepositoryProvider);
    try {
      final duplicated = await repository.duplicateSequence(
          _summary.id, '${_summary.name} (Copy)');

      if (host.isStale) return;

      if (duplicated?.databaseId != null) {
        notifySequenceCatalogChanged(
          ref,
          sequenceId: duplicated!.databaseId!,
          action: 'duplicated',
          name: duplicated.name,
        );
      } else {
        ref.invalidate(savedSequenceSummariesProvider);
      }

      if (context.mounted && host.isCurrent) {
        context.showSuccessSnackBar('Duplicated "${_summary.name}"');
      }
    } catch (e) {
      if (context.mounted && host.isCurrent) {
        context.showErrorSnackBar('Failed to duplicate: ${userFacingError(e)}');
      }
    }
  }

  /// Export the saved sequence to a JSON file. Mirrors the toolbar's
  /// export path: on a blocking validation failure, surface the structured
  /// issue dialog with a "force export anyway" escape hatch.
  Future<void> _exportSequence(BuildContext context) async {
    final host = ref.backendScope();
    final repository = ref.read(sequenceRepositoryProvider);
    final sequence = await _loadFullSequence(
      context,
      host: host,
      repository: repository,
    );
    if (sequence == null || !context.mounted || host.isStale) {
      return;
    }
    final fileService = ref.read(sequenceFileServiceProvider);
    try {
      final exportedPath = await fileService.exportSequence(sequence);
      if (exportedPath != null && context.mounted && host.isCurrent) {
        // On a phone the file landed in the app sandbox, so a snackbar naming
        // it would be a file the user can never open — hand it to the share
        // sheet instead. Live before this: "Failed to export:
        // UnimplementedError: getSavePath() has not been implemented."
        await revealExportedFile(
          context,
          exportedPath,
          subject: 'Skotiq sequence: ${sequence.name}',
          desktopMessage: 'Exported "${sequence.name}"',
        );
      }
    } on SequenceValidationFailedException catch (e) {
      if (!context.mounted || host.isStale) return;
      final force = await showValidationIssueDialog(
        context,
        issues: e.issues,
        operationName: 'export sequence',
        forceLabel: 'Force export anyway',
      );
      if (!force || !context.mounted || host.isStale) {
        return;
      }
      try {
        final exportedPath = await fileService.exportSequence(
          sequence,
          forceExport: true,
        );
        if (exportedPath != null && context.mounted && host.isCurrent) {
          await revealExportedFile(
            context,
            exportedPath,
            subject: 'Skotiq sequence: ${sequence.name}',
            desktopMessage: 'Exported "${sequence.name}" (forced)',
          );
        }
      } catch (err) {
        if (context.mounted && host.isCurrent) {
          context
              .showErrorSnackBar('Failed to export: ${userFacingError(err)}');
        }
      }
    } catch (e) {
      if (context.mounted && host.isCurrent) {
        context.showErrorSnackBar('Failed to export: ${userFacingError(e)}');
      }
    }
  }

  void _deleteSequence(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => _DeleteSequenceDialog(
        colors: _colors,
        sequenceId: _summary.id,
        sequenceName: _summary.name,
      ),
    );
  }
}

/// "Today" and "Yesterday" are calendar days in local time, not 24-hour
/// windows: a run that ended at 22:37 is "Yesterday" at 08:00.
@visibleForTesting
String sequenceRowDateLabel(DateTime date, DateTime now) {
  final local = date.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final days = today.difference(day).inHours ~/ 24;
  if (days <= 0) return 'Today ${ClockFormat.hm(local)}';
  if (days == 1) return 'Yesterday ${ClockFormat.hm(local)}';
  if (days < 7) return '$days days ago';
  return ClockFormat.monthDayYear(local);
}
