part of '../sequence_library_tab.dart';

/// One row in the sequence library, rendered from a lightweight
/// [SequenceSummary] (no node-tree hydration).
///
/// The summary carries everything the collapsed card shows — name, primary
/// target, node/target/exposure counts, estimated duration, run roll-up, tags
/// and the favorite flag. Actions that genuinely need the full node graph
/// (Load, Duplicate, Export, Preview) lazily load the [Sequence] from the
/// repository on demand, so opening the library never pays the N+1 full-load
/// cost.
class _SequenceCard extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final SequenceSummary summary;

  const _SequenceCard({
    required this.colors,
    required this.summary,
  });

  @override
  ConsumerState<_SequenceCard> createState() => _SequenceCardState();
}

class _SequenceCardState extends ConsumerState<_SequenceCard> {
  bool _isHovered = false;
  bool _expanded = false;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;

  /// Lazily-loaded full sequence for the expandable preview. Loaded the first
  /// time the user expands the card and reused afterwards.
  Sequence? _previewSequence;
  bool _previewLoading = false;
  Object? _previewError;

  SequenceSummary get _summary => widget.summary;

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

  bool _isCurrentAuthority(SkotiqBackend authority) =>
      identical(ref.read(backendProvider), authority);

  String _formatDuration() {
    final totalSecs = _summary.totalIntegrationSecs;
    if (totalSecs <= 0) return kReadoutUnknown;
    return DurationFormat.seconds(
      totalSecs,
      style: DurationStyle.compact,
      rounding: DurationRounding.truncate,
    );
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: widget.colors.surface,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          border: Border.all(
            color: _isHovered
                ? widget.colors.primary.withValues(alpha: 0.4)
                : widget.colors.border,
            width: _isHovered ? 2 : 1,
          ),
          boxShadow: null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildMainRow(),
            if (_expanded) _buildPreview(),
          ],
        ),
      ),
    );
  }

  Widget _buildMainRow() {
    final primaryTarget = _summary.primaryTargetName;
    final info = _buildInfo(primaryTarget);
    final actions = _buildActions();

    if (Responsive.isMobile(context)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _FavoriteToggle(
                colors: widget.colors,
                isFavorite: _summary.isFavorite,
                onPressed: _toggleFavorite,
              ),
              const SizedBox(width: 8),
              _buildSequenceIcon(size: 40),
              const SizedBox(width: 12),
              Expanded(child: info),
            ],
          ),
          const SizedBox(height: 12),
          AnimatedOpacity(
            opacity: 1,
            duration: const Duration(milliseconds: 150),
            child: Wrap(
              spacing: 4,
              runSpacing: 4,
              children: actions,
            ),
          ),
        ],
      );
    }

    return Row(
      children: [
        // Favorite star (also acts as the favorite toggle).
        _FavoriteToggle(
          colors: widget.colors,
          isFavorite: _summary.isFavorite,
          onPressed: _toggleFavorite,
        ),

        const SizedBox(width: 8),

        // Icon
        _buildSequenceIcon(),

        const SizedBox(width: 16),

        // Info
        Expanded(child: info),

        // Actions
        AnimatedOpacity(
          opacity: _isHovered ? 1.0 : 0.5,
          duration: const Duration(milliseconds: 150),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < actions.length; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                actions[i],
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSequenceIcon({double size = 48}) {
    return Container(
      width: size,
      height: size,
      decoration: SkotiqDecorations.tintedBadge(
        widget.colors.primary,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
      ),
      child: Icon(
        LucideIcons.workflow,
        size: size / 2,
        color: widget.colors.primary,
      ),
    );
  }

  Widget _buildInfo(String? primaryTarget) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                _summary.name,
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize15,
                  fontWeight: FontWeight.w600,
                  color: widget.colors.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              _formatDate(_summary.modifiedAt),
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize11,
                color: widget.colors.textMuted,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 12,
          runSpacing: 6,
          children: [
            if (primaryTarget != null && primaryTarget.isNotEmpty)
              _StatChip(
                colors: widget.colors,
                icon: LucideIcons.star,
                label: primaryTarget,
              ),
            _StatChip(
              colors: widget.colors,
              icon: LucideIcons.layers,
              label: countLabel(_summary.nodeCount, 'node'),
            ),
            _StatChip(
              colors: widget.colors,
              icon: LucideIcons.target,
              label: countLabel(_summary.targetCount, 'target'),
            ),
            // NOT a frame count: the library roll-up query counts capture
            // NODES (`TakeExposure` / `SmartExposure` rows), so a "10 × 60s"
            // exposure node is 1. Labelling it "exposures" read as frames and
            // contradicted both the Builder toolbar's frame counter and this
            // card's own preview. The true frame total needs the node tree,
            // which the preview below loads on demand.
            _StatChip(
              colors: widget.colors,
              icon: LucideIcons.camera,
              label: countLabel(_summary.exposureCount, 'capture step'),
            ),
            _StatChip(
              colors: widget.colors,
              icon: LucideIcons.timer,
              label: _formatDuration(),
            ),
          ],
        ),
        _buildRunRollup(),
        _buildTagRow(),
      ],
    );
  }

  List<Widget> _buildActions() {
    return [
      _IconButton(
        colors: widget.colors,
        icon: _expanded ? LucideIcons.chevronUp : LucideIcons.chevronDown,
        tooltip: _expanded ? 'Hide preview' : 'Preview',
        onPressed: _togglePreview,
      ),
      _IconButton(
        colors: widget.colors,
        icon: LucideIcons.history,
        tooltip: 'View run history',
        onPressed: () => _openHistory(context),
      ),
      _IconButton(
        colors: widget.colors,
        icon: LucideIcons.gitBranch,
        tooltip: 'Version history',
        onPressed: () => _openVersionHistory(context),
      ),
      _IconButton(
        colors: widget.colors,
        icon: LucideIcons.tags,
        tooltip: 'Edit tags',
        onPressed: () => _editTags(context),
      ),
      _IconButton(
        colors: widget.colors,
        icon: LucideIcons.folderOpen,
        tooltip: 'Load',
        onPressed: () => _loadSequence(context),
      ),
      _IconButton(
        colors: widget.colors,
        icon: LucideIcons.copy,
        tooltip: 'Duplicate',
        onPressed: () => _duplicateSequence(context),
      ),
      _IconButton(
        colors: widget.colors,
        icon: LucideIcons.upload,
        tooltip: 'Export',
        onPressed: () => _exportSequence(context),
      ),
      _IconButton(
        colors: widget.colors,
        icon: LucideIcons.trash2,
        tooltip: 'Delete',
        color: widget.colors.error,
        onPressed: () => _deleteSequence(context),
      ),
    ];
  }

  /// Run-history rollup row ("N runs · last DATE"), straight from the summary.
  /// Hidden for sequences that have never run.
  Widget _buildRunRollup() {
    if (_summary.runCount == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 12,
        runSpacing: 6,
        children: [
          _StatChip(
            colors: widget.colors,
            icon: LucideIcons.play,
            label: '${_summary.runCount} '
                'run${_summary.runCount == 1 ? '' : 's'}',
          ),
          if (_summary.lastRunAt != null)
            _StatChip(
              colors: widget.colors,
              icon: LucideIcons.history,
              label: 'Last run ${_formatDate(_summary.lastRunAt!)}',
            ),
        ],
      ),
    );
  }

  /// Tag chips for the sequence. Hidden when the sequence carries no tags.
  Widget _buildTagRow() {
    if (_summary.tags.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final tag in _summary.tags)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: SkotiqDecorations.tintedBadge(
                widget.colors.primary,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.tag, size: 10, color: widget.colors.primary),
                  const SizedBox(width: 4),
                  Text(
                    tag,
                    style: SkotiqTypography.labelStrongSm
                        .copyWith(color: widget.colors.primary),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Read-only preview: lazily loads the full sequence, then shows the target
  /// list with per-target exposure breakdown derived from the node tree.
  Widget _buildPreview() {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: widget.colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        border: Border.all(color: widget.colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Preview',
            style: SkotiqTypography.h6
                .copyWith(color: widget.colors.textSecondary),
          ),
          const SizedBox(height: 8),
          _buildPreviewBody(),
        ],
      ),
    );
  }

  Widget _buildPreviewBody() {
    if (_previewLoading) {
      return Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: SkotiqSpinner(size: 14, color: widget.colors.primary),
          ),
          const SizedBox(width: 8),
          Text(
            'Loading preview…',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize12,
              color: widget.colors.textMuted,
            ),
          ),
        ],
      );
    }

    if (_previewError != null) {
      return Text(
        'Could not load preview: $_previewError',
        style: TextStyle(
          fontSize: SkotiqTypography.fontSize12,
          color: widget.colors.error,
        ),
      );
    }

    final sequence = _previewSequence;
    if (sequence == null) {
      return Text(
        'Preview unavailable.',
        style: TextStyle(
          fontSize: SkotiqTypography.fontSize12,
          color: widget.colors.textMuted,
        ),
      );
    }

    final headers =
        sequence.nodes.values.whereType<TargetHeaderNode>().toList();

    if (headers.isEmpty) {
      // Frames, not nodes — the shared walk applies loop multipliers and
      // counts SmartExposure plans, so a target-less calibration or
      // Plan-Tonight sequence reports what it will actually capture.
      final planned = plannedCaptureForSequence(sequence);
      return Text(
        'No targets — ${_plannedSummary(planned)}.',
        style: TextStyle(
          fontSize: SkotiqTypography.fontSize12,
          color: widget.colors.textMuted,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final header in headers) ...[
          _buildTargetPreviewRow(sequence, header),
          const SizedBox(height: 4),
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
        '${_formatSecs(planned.integrationSecs)}'
        '${planned.hasUnboundedRepeat ? ' per pass' : ''}',
      );
    }
    if (planned.hasOpenEndedLoop) {
      parts.add(
        planned.openEndedBudgetSecs > 0
            ? 'looping up to ${_formatSecs(planned.openEndedBudgetSecs)}'
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
    // counted. A local walk that does neither renders "No exposures" for a
    // target whose only imager is a Smart Exposure, and reports a tenth of the
    // integration under a `Capture Loop ×10`.
    final planned = plannedCaptureUnder(sequence, header.id);
    final byFilter = planned.integrationSecsByFilter;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(LucideIcons.target, size: 12, color: widget.colors.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                header.targetName.isEmpty ? 'Target' : header.targetName,
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize12,
                  fontWeight: FontWeight.w600,
                  color: widget.colors.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(left: 18, top: 2),
          child: Text(
            _plannedSummary(planned),
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize11,
              color: planned.isEmpty
                  ? widget.colors.textMuted
                  : widget.colors.textSecondary,
            ),
          ),
        ),
        if (byFilter.isNotEmpty)
          for (final entry in byFilter.entries)
            Padding(
              padding: const EdgeInsets.only(left: 18, top: 2),
              child: Text(
                '${entry.key}: ${_formatSecs(entry.value)}',
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize11,
                  color: widget.colors.textSecondary,
                ),
              ),
            ),
      ],
    );
  }

  String _formatSecs(double secs) {
    if (secs <= 0) return '0m';
    final hours = (secs / 3600).floor();
    final mins = ((secs % 3600) / 60).round();
    if (hours > 0) return '${hours}h ${mins}m';
    return '${mins}m';
  }

  /// Load the full sequence from the repository, used by every tree-requiring
  /// action. Returns null and surfaces an error snackbar on failure.
  Future<Sequence?> _loadFullSequence(
    BuildContext context, {
    required SkotiqBackend authority,
    required SequenceRepository repository,
  }) async {
    try {
      final sequence = await repository.loadSequence(_summary.id);
      if (!_isCurrentAuthority(authority)) return null;
      if (sequence == null && context.mounted) {
        context.showErrorSnackBar('Sequence is no longer available');
      }
      return sequence;
    } catch (e) {
      if (context.mounted && _isCurrentAuthority(authority)) {
        context.showErrorSnackBar('Failed to load sequence: $e');
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
    final authority = ref.read(backendProvider);
    final repository = ref.read(sequenceRepositoryProvider);
    setState(() {
      _previewLoading = true;
      _previewError = null;
    });
    try {
      final sequence = await repository.loadSequence(_summary.id);
      if (!mounted || !_isCurrentAuthority(authority)) return;
      setState(() {
        _previewSequence = sequence;
        _previewLoading = false;
        if (sequence == null) {
          _previewError = 'Sequence is no longer available';
        }
      });
    } catch (e) {
      if (!mounted || !_isCurrentAuthority(authority)) return;
      setState(() {
        _previewLoading = false;
        _previewError = e;
      });
    }
  }

  Future<void> _toggleFavorite() async {
    final authority = ref.read(backendProvider);
    final repository = ref.read(sequenceRepositoryProvider);
    try {
      await repository.toggleFavorite(_summary.id);
      if (!_isCurrentAuthority(authority)) return;
      ref.invalidate(savedSequenceSummariesProvider);
    } catch (e) {
      if (mounted && _isCurrentAuthority(authority)) {
        context.showErrorSnackBar('Failed to update favorite: $e');
      }
    }
  }

  /// Switch to the History tab pre-filtered to this sequence's runs.
  void _openHistory(BuildContext context) {
    ref.read(historyFilterSequenceIdProvider.notifier).state = _summary.id;
    ref.read(sequencerTabProvider.notifier).state = SequencerTab.history.index;
  }

  void _openVersionHistory(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => _VersionHistoryDialog(
        colors: widget.colors,
        sequenceId: _summary.id,
        sequenceName: _summary.name,
      ),
    );
  }

  void _editTags(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => _TagEditorDialog(
        colors: widget.colors,
        sequenceId: _summary.id,
        sequenceName: _summary.name,
        initialTags: _summary.tags,
      ),
    );
  }

  String _formatDate(DateTime date) =>
      sequenceCardDateLabel(date, DateTime.now());

  Future<void> _loadSequence(BuildContext context) async {
    final authority = ref.read(backendProvider);
    final repository = ref.read(sequenceRepositoryProvider);
    final source = await _loadFullSequence(
      context,
      authority: authority,
      repository: repository,
    );
    if (source == null || !context.mounted || !_isCurrentAuthority(authority)) {
      return;
    }

    // Create a copy with new IDs so we don't modify the saved one
    final newNodes = <String, SequenceNode>{};
    final idMapping = <String, String>{};

    for (final entry in source.nodes.entries) {
      idMapping[entry.key] = const Uuid().v4();
    }

    for (final entry in source.nodes.entries) {
      final oldNode = entry.value;
      final newId = idMapping[entry.key]!;
      final newParentId =
          oldNode.parentId != null ? idMapping[oldNode.parentId] : null;
      final newChildIds =
          oldNode.childIds.map((id) => idMapping[id] ?? id).toList();

      newNodes[newId] = oldNode.copyWith(
        id: newId,
        parentId: newParentId,
        childIds: newChildIds,
      );
    }

    final newRootId =
        source.rootNodeId != null ? idMapping[source.rootNodeId] : null;

    final loadedSequence = Sequence.create(
      name: source.name,
      description: source.description,
      nodes: newNodes,
      rootNodeId: newRootId,
      isTemplate: false,
      databaseId: source.databaseId, // Keep reference to original
    );

    final editor = ref.read(currentSequenceProvider.notifier);
    try {
      editor.loadSequence(loadedSequence);
    } on UnsavedChangesException catch (e) {
      // Prompt before clobbering — clicking a library item is a user
      // action so we know they meant to switch sequences, but we still
      // give them a chance to save first.
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
                'Loading "${_summary.name}" will discard them.'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Discard and load'),
            ),
          ],
        ),
      );
      if (discard != true || !_isCurrentAuthority(authority)) return;
      editor.loadSequence(loadedSequence, discardUnsaved: true);
    }

    if (!_isCurrentAuthority(authority)) return;

    ref.read(sequencerTabProvider.notifier).state = 0;

    if (context.mounted) {
      context.showSuccessSnackBar('Loaded "${_summary.name}"');
    }
  }

  Future<void> _duplicateSequence(BuildContext context) async {
    final authority = ref.read(backendProvider);
    final repository = ref.read(sequenceRepositoryProvider);
    try {
      final duplicated = await repository.duplicateSequence(
          _summary.id, '${_summary.name} (Copy)');

      if (!_isCurrentAuthority(authority)) return;

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

      if (context.mounted && _isCurrentAuthority(authority)) {
        context.showSuccessSnackBar('Duplicated "${_summary.name}"');
      }
    } catch (e) {
      if (context.mounted && _isCurrentAuthority(authority)) {
        context.showErrorSnackBar('Failed to duplicate: $e');
      }
    }
  }

  /// Export the saved sequence to a JSON file. Mirrors the toolbar's
  /// export path: on a blocking validation failure, surface the structured
  /// issue dialog with a "force export anyway" escape hatch.
  Future<void> _exportSequence(BuildContext context) async {
    final authority = ref.read(backendProvider);
    final repository = ref.read(sequenceRepositoryProvider);
    final sequence = await _loadFullSequence(
      context,
      authority: authority,
      repository: repository,
    );
    if (sequence == null ||
        !context.mounted ||
        !_isCurrentAuthority(authority)) {
      return;
    }
    final fileService = ref.read(sequenceFileServiceProvider);
    try {
      final exportedPath = await fileService.exportSequence(sequence);
      if (exportedPath != null &&
          context.mounted &&
          _isCurrentAuthority(authority)) {
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
      if (!context.mounted || !_isCurrentAuthority(authority)) return;
      final force = await showValidationIssueDialog(
        context,
        issues: e.issues,
        operationName: 'export sequence',
        forceLabel: 'Force export anyway',
      );
      if (!force || !context.mounted || !_isCurrentAuthority(authority)) {
        return;
      }
      try {
        final exportedPath = await fileService.exportSequence(
          sequence,
          forceExport: true,
        );
        if (exportedPath != null &&
            context.mounted &&
            _isCurrentAuthority(authority)) {
          await revealExportedFile(
            context,
            exportedPath,
            subject: 'Skotiq sequence: ${sequence.name}',
            desktopMessage: 'Exported "${sequence.name}" (forced)',
          );
        }
      } catch (err) {
        if (context.mounted && _isCurrentAuthority(authority)) {
          context.showErrorSnackBar('Failed to export: $err');
        }
      }
    } catch (e) {
      if (context.mounted && _isCurrentAuthority(authority)) {
        context.showErrorSnackBar('Failed to export: $e');
      }
    }
  }

  void _deleteSequence(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => _DeleteSequenceDialog(
        colors: widget.colors,
        sequenceId: _summary.id,
        sequenceName: _summary.name,
      ),
    );
  }
}

/// "Today" and "Yesterday" are calendar days in local time, not 24-hour
/// windows: a run that ended at 10:37 PM is "Yesterday" at 8 AM.
@visibleForTesting
String sequenceCardDateLabel(DateTime date, DateTime now) {
  final local = date.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(local.year, local.month, local.day);
  final days = today.difference(day).inHours ~/ 24;
  if (days <= 0) return 'Today ${DateFormat.jm().format(local)}';
  if (days == 1) return 'Yesterday ${DateFormat.jm().format(local)}';
  if (days < 7) return '$days days ago';
  return DateFormat.yMd().format(local);
}
