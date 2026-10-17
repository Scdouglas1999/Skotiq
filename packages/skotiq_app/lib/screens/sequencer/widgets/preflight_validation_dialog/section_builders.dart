// ignore_for_file: invalid_use_of_protected_member
// Body-state, verdict, simulation and footer builders for the pre-flight
// dialog. The dialog's chrome — title, scroll body, footer rail — belongs to
// `SkotiqDialog` (05 §13), so there is no header builder here.
part of '../preflight_validation_dialog.dart';

/// Diameter of the busy spinner. Matches [EmptyState.iconSize] so a state that
/// is waiting and a state that is empty put their glyph on the same optical
/// line.
const double _busyGlyphSize = EmptyState.iconSize;

/// Vertical padding the dialog body adds for itself.
///
/// `SkotiqDialog` pads the body horizontally only: the header and the
/// footer own the vertical rhythm at the ends, and a body that also padded
/// vertically would double it.
const EdgeInsets _bodyPadding = EdgeInsets.symmetric(
  vertical: SkotiqTokens.spaceXl,
);

extension _PreFlightSectionBuilders on _PreFlightValidationDialogState {
  Widget _buildLoadingState(SkotiqColors colors) => _buildBusyState(
        colors,
        title: 'Running validation checks…',
      );

  Widget _buildPreparingState(SkotiqColors colors) => _buildBusyState(
        colors,
        title: 'Preparing to start…',
        body: 'Checking for unfinished integration to carry over.',
      );

  Widget _buildBusyState(
    SkotiqColors colors, {
    required String title,
    String? body,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.space4xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: _busyGlyphSize,
            height: _busyGlyphSize,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colors.primary,
            ),
          ),
          const SizedBox(height: EmptyState.iconTitleGap),
          Text(
            title,
            style: SkotiqTypography.sectionTitle
                .copyWith(color: colors.textPrimary),
            textAlign: TextAlign.center,
          ),
          if (body != null) ...[
            const SizedBox(height: EmptyState.titleBodyGap),
            Text(
              body,
              style: SkotiqTypography.bodySm
                  .copyWith(color: colors.textSecondary),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  /// No sequence, or a validator that threw. One [EmptyState] either way —
  /// the raw error becomes the body sentence and stays selectable through the
  /// surrounding [SelectionArea].
  Widget _buildErrorState(SkotiqColors colors) {
    final error = _validationError;
    return SelectionArea(
      child: EmptyState(
        icon: LucideIcons.alertCircle,
        title: error == null
            ? 'No sequence to validate'
            : 'Could not validate sequence',
        body: error?.toString(),
        action: error == null
            ? null
            : SkotiqButton(
                label: 'Retry validation',
                icon: SkotiqIcons.refresh,
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                onPressed: _retryValidation,
              ),
      ),
    );
  }

  Widget _buildResults(SkotiqColors colors) {
    final result = _result!;
    final hasSimulationIssues = _simulation?.issues.isNotEmpty ?? false;

    // Partition issues into the Dark Library, Equipment Health, and
    // Optical Train groups so each gets its own collapsible section,
    // then a "General" bucket for the remaining categories
    // (structure / equipment / settings / etc).
    final darkLibrary = result.issues
        .where((i) => i.category == ValidationCategory.darkLibrary)
        .toList(growable: false);
    final equipmentHealth = result.issues
        .where((i) => i.category == ValidationCategory.equipmentHealth)
        .toList(growable: false);
    final opticalTrain = result.issues
        .where((i) => i.category == ValidationCategory.opticalTrain)
        .toList(growable: false);
    final general = result.issues
        .where((i) =>
            i.category != ValidationCategory.darkLibrary &&
            i.category != ValidationCategory.equipmentHealth &&
            i.category != ValidationCategory.opticalTrain)
        .toList(growable: false);

    return Padding(
      padding: _bodyPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Informational only; not a pre-flight blocker.
          if (_previousRunDiff != null && !_previousRunDiff!.isEmpty) ...[
            _buildPreviousRunDiffBanner(colors, _previousRunDiff!),
            const SizedBox(height: SkotiqTokens.spaceMd),
          ],

          _buildVerdictBanner(colors, result, _simulation),
          const SizedBox(height: SkotiqTokens.space2xl),
          _buildSimulationSection(colors),
          const SizedBox(height: SkotiqTokens.space2xl),

          if (result.issues.isEmpty && !hasSimulationIssues)
            const EmptyState.compact(
              icon: SkotiqIcons.success,
              title: 'No issues found',
              body: 'The sequence is ready to run.',
            )
          else ...[
            if (general.isNotEmpty)
              _PreflightSection(
                colors: colors,
                icon: SkotiqIcons.checklist,
                title: 'General',
                issues: general,
                showCategory: true,
              ),
            if (darkLibrary.isNotEmpty)
              _PreflightSection(
                colors: colors,
                icon: SkotiqIcons.moon,
                title: 'Dark library',
                issues: darkLibrary,
                trailing: SkotiqButton(
                  label: 'Capture missing darks',
                  icon: SkotiqIcons.cameraOff,
                  variant: ButtonVariant.secondary,
                  size: ButtonSize.small,
                  onPressed: _openCalibrationCenter,
                ),
              ),
            if (equipmentHealth.isNotEmpty)
              _PreflightSection(
                colors: colors,
                icon: SkotiqIcons.activity,
                title: 'Equipment health',
                issues: equipmentHealth,
              ),
            if (opticalTrain.isNotEmpty)
              _PreflightSection(
                colors: colors,
                icon: SkotiqIcons.crosshair,
                title: 'Optical train',
                issues: opticalTrain,
              ),
          ],
        ],
      ),
    );
  }

  /// The run simulation: a [SectionTitle] over a `well` of [Readout]s, the
  /// segment bar and up to three issue lines.
  ///
  /// The four figures are measurements, so they are readouts and not tiles
  /// (05 §3). The end time is a fact about the run and rides on the section
  /// title; with no simulation it is [kReadoutUnknown], never `--:--`.
  Widget _buildSimulationSection(SkotiqColors colors) {
    final simulation = _simulation;
    final unavailableReason = _simulationUnavailableReason;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTitle(
          icon: LucideIcons.ganttChart,
          title: 'Simulation',
          trailing: Text(
            'Ends ${simulation == null ? kReadoutUnknown : _formatClock(simulation.end)}',
            style: SkotiqTypography.readoutXs
                .copyWith(color: colors.textMuted),
          ),
        ),
        Container(
          padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
          decoration: SkotiqDecorations.well(colors),
          child: simulation == null
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      SkotiqIcons.info,
                      size: SkotiqTokens.iconGlyphRow,
                      color: colors.info,
                    ),
                    const SizedBox(width: ListRow.gap),
                    Expanded(
                      child: Text(
                        unavailableReason ?? 'Simulation unavailable.',
                        style: SkotiqTypography.bodySm
                            .copyWith(color: colors.textSecondary),
                      ),
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ReadoutRow(
                      gap: SkotiqTokens.space2xl,
                      children: [
                        Readout(
                          value: DurationFormat.of(
                            simulation.duration,
                            style: DurationStyle.compact,
                          ),
                          label: 'Duration',
                          size: ReadoutSize.sm,
                        ),
                        Readout(
                          value: '${simulation.segments.length}',
                          label: 'Segments',
                          size: ReadoutSize.sm,
                        ),
                        Readout(
                          value: '${simulation.targetWindows.length}',
                          label: 'Targets',
                          size: ReadoutSize.sm,
                        ),
                        Readout(
                          value: '${simulation.issues.length}',
                          label: 'Issues',
                          size: ReadoutSize.sm,
                          // Green only when the simulation actually walked
                          // something. An empty sequence simulates to 0
                          // segments and therefore 0 issues, which would paint
                          // a reassuring green "0" inside a dialog headed
                          // "Cannot start": the simulation did not clear the
                          // run, it did not evaluate it.
                          valueColor: simulation.hasBlockingIssues
                              ? colors.error
                              : simulation.issues.isNotEmpty
                                  ? colors.warning
                                  : simulation.segments.isEmpty
                                      ? colors.textMuted
                                      : colors.success,
                        ),
                      ],
                    ),
                    if (simulation.segments.isNotEmpty) ...[
                      const SizedBox(height: SkotiqTokens.spaceMd),
                      _SimulationTimeline(
                          colors: colors, simulation: simulation),
                    ],
                    if (simulation.issues.isNotEmpty) ...[
                      const SizedBox(height: SkotiqTokens.spaceMd),
                      for (final issue in simulation.issues.take(3))
                        _SimulationIssueRow(colors: colors, issue: issue),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  /// Deep-link to the dark-library settings section. We deliberately do not
  /// build the capture sequence here — opening the existing tool keeps the
  /// responsibility with the dark-library screen.
  void _openCalibrationCenter() {
    // Capture the router before closing so the dialog's context isn't defunct
    // by the time we navigate.
    final router = GoRouter.maybeOf(context);
    Navigator.of(context).pop();
    router?.go('/settings?section=dark-library');
  }

  /// ONE banner carries the verdict (05 §11). The counts ride on it as chips,
  /// not as stat tiles: they are labels on a sentence, not measurements the
  /// operator reads off an instrument.
  Widget _buildVerdictBanner(
    SkotiqColors colors,
    ValidationResult result,
    PreSessionSimulationResult? simulation,
  ) {
    final simulationErrorCount = simulation?.issues
            .where(
                (issue) => issue.severity == PreSessionSimulationSeverity.error)
            .length ??
        0;
    final simulationWarningCount = simulation?.issues
            .where((issue) =>
                issue.severity == PreSessionSimulationSeverity.warning)
            .length ??
        0;
    final simulationInfoCount = simulation?.issues
            .where(
                (issue) => issue.severity == PreSessionSimulationSeverity.info)
            .length ??
        0;

    final errorCount = result.errorCount + simulationErrorCount;
    final warningCount = result.warningCount + simulationWarningCount;
    final infoCount = result.infoCount + simulationInfoCount;
    final hasErrors = errorCount > 0;
    final hasWarnings = warningCount > 0;

    final counts = <Widget>[
      if (errorCount > 0)
        SkotiqChip(
          label: '$errorCount ${errorCount == 1 ? 'error' : 'errors'}',
          icon: SkotiqIcons.error,
          tone: ChipTone.error,
        ),
      if (warningCount > 0)
        SkotiqChip(
          label: '$warningCount ${warningCount == 1 ? 'warning' : 'warnings'}',
          icon: SkotiqIcons.warning,
          tone: ChipTone.warning,
        ),
      if (infoCount > 0)
        SkotiqChip(
          label: '$infoCount ${infoCount == 1 ? 'note' : 'notes'}',
          icon: SkotiqIcons.info,
          tone: ChipTone.primary,
        ),
    ];

    return SkotiqBanner(
      tone: hasErrors
          ? BannerTone.error
          : hasWarnings
              ? BannerTone.warning
              : BannerTone.success,
      title: hasErrors
          ? 'Cannot start'
          : hasWarnings
              ? 'Ready with warnings'
              : 'All checks passed',
      action: counts.isEmpty
          ? null
          : Wrap(
              spacing: SkotiqTokens.spaceXs,
              runSpacing: SkotiqTokens.spaceXs,
              children: counts,
            ),
    );
  }

  /// Info banner shown when the in-editor sequence differs structurally from
  /// the most recent COMPLETED run of the same sequence. "View changes" pops
  /// the structural diff dialog.
  Widget _buildPreviousRunDiffBanner(
    SkotiqColors colors,
    SequenceDiffResult diff,
  ) {
    final changeCount =
        diff.added.length + diff.removed.length + diff.modified.length;
    return SkotiqBanner(
      tone: BannerTone.info,
      icon: LucideIcons.gitCompare,
      title: 'Sequence has changed since last successful run',
      message: '$changeCount change${changeCount == 1 ? '' : 's'} '
          'across ${diff.added.length} added, '
          '${diff.removed.length} removed, '
          '${diff.modified.length} modified '
          'node${diff.modified.length == 1 ? '' : 's'}.',
      action: SkotiqButton(
        label: 'View changes',
        icon: SkotiqIcons.visible,
        variant: ButtonVariant.secondary,
        size: ButtonSize.small,
        onPressed: () => SequenceDiffDialog.show(context, diff),
      ),
    );
  }

  /// Why Start cannot run, as a sentence fragment for [GatedAction.announce] —
  /// or null when it can.
  ///
  /// With errors on the board the primary is inert. Left undeclared it
  /// publishes a plain `button: Start sequence` beside its live siblings
  /// `Re-check` and `Cancel` — clicking does nothing and says nothing, so a
  /// blocked dialog is indistinguishable from a working one for anyone reading
  /// the screen through assistive tech.
  String? _startBlockedReason({
    required bool canStart,
    required bool hasWarningsOnly,
    required bool hasBlockingSimulationIssue,
  }) {
    if (canStart || hasWarningsOnly) return null;
    final result = _result;
    if (result == null) {
      return _isValidating
          ? 'the pre-flight checks have not finished'
          : 'the pre-flight checks have not run yet';
    }
    if (result.hasErrors) {
      final count = result.errorCount;
      return 'fix the $count pre-flight '
          '${count == 1 ? 'error' : 'errors'} above first';
    }
    if (hasBlockingSimulationIssue) {
      return 'the run simulation found a blocking issue';
    }
    return 'the pre-flight checks have not cleared this run';
  }

  /// The footer, in 05 §13's reading order: `[ghost Cancel] [secondary
  /// Re-check] [primary Start]`. `SkotiqDialog` right-aligns them with the
  /// 8px gap; the ONE primary of this dialog wears the `start` face because
  /// starting a night is the act the operator finds by colour across a dark
  /// room (05 §6).
  List<Widget> _buildActions(SkotiqColors colors) {
    final hasBlockingSimulationIssue = _simulation?.hasBlockingIssues ?? false;
    final hasSimulationWarnings = _simulation?.issues.any(
            (issue) => issue.severity != PreSessionSimulationSeverity.error) ??
        false;
    final canStart = (_result?.isValid ?? false) && !hasBlockingSimulationIssue;
    final hasWarningsOnly = _result != null &&
        !_result!.hasErrors &&
        !hasBlockingSimulationIssue &&
        (_result!.hasWarnings || hasSimulationWarnings);

    return [
      SkotiqButton(
        label: 'Cancel',
        variant: ButtonVariant.ghost,
        onPressed: () => Navigator.of(context).pop(),
      ),
      SkotiqButton(
        label: 'Re-check',
        icon: SkotiqIcons.refresh,
        variant: ButtonVariant.secondary,
        onPressed: () {
          setState(() {
            _validationError = null;
            _isValidating = true;
          });
          _runValidation();
        },
      ),
      _StartSequenceButton(
        canStart: canStart,
        hasWarningsOnly: hasWarningsOnly,
        blockedReason: _startBlockedReason(
          canStart: canStart,
          hasWarningsOnly: hasWarningsOnly,
          hasBlockingSimulationIssue: hasBlockingSimulationIssue,
        ),
        onPressed: (canStart || hasWarningsOnly)
            ? () async {
                await _handleStartSequence();
              }
            : null,
      ),
    ];
  }
}
