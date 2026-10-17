import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../run_status_presentation.dart';
import 'notes_panel.dart';
part 'session_report_dialog/header_overview.dart';
part 'session_report_dialog/target_conditions.dart';
part 'session_report_dialog/recovery_insights.dart';
part 'session_report_dialog/diagnostic_issue_tile.dart';

/// Rich end-of-session report dialog (Feature A).
///
/// Opens automatically after a sequence run completes (or aborts / errors)
/// and is also reachable from the analytics history tab "View Report"
/// button. Renders the per-target / per-filter rollup, guiding summary,
/// mount events and recorded errors and exposes Markdown / .txt exports.
class SessionReportDialog extends ConsumerWidget {
  /// The session whose report should be rendered.
  final int sessionId;

  /// The completed run's `sequence_runs.id`, passed EXPLICITLY when the report
  /// auto-opens for a just-finished run. The run-scoped Journal binds to this
  /// instead of watching `currentRunIdProvider`, which finalization has
  /// (correctly) already cleared by the time the report opens. Null for opens
  /// from history / analytics, where the run is long over and the Journal falls
  /// back to the per-target notes.
  final int? runId;

  const SessionReportDialog({super.key, required this.sessionId, this.runId});

  /// Convenience launcher — mirrors how the other sequencer dialogs in this
  /// folder are opened. Pass [runId] when opening for a just-completed run so
  /// the run-scoped Journal resolves correctly.
  static Future<void> show(BuildContext context, int sessionId, {int? runId}) {
    return showDialog<void>(
      context: context,
      builder: (_) => SessionReportDialog(sessionId: sessionId, runId: runId),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final reportAsync = ref.watch(sessionReportProvider(sessionId));

    return reportAsync.when(
      data: (report) =>
          _ReportBody(report: report, colors: colors, runId: runId),
      loading: () => const SkotiqDialog(
        title: 'Session report',
        icon: LucideIcons.fileBarChart,
        width: 720,
        child: SizedBox(
          height: 200,
          child: Center(
              child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36)),
        ),
      ),
      error: (err, _) => SkotiqDialog(
        title: 'Session report',
        icon: LucideIcons.fileBarChart,
        width: 720,
        child: EmptyState(
          icon: LucideIcons.alertTriangle,
          title: 'Could not build session report',
          body: '$err',
          action: SkotiqButton(
            label: 'Retry',
            icon: LucideIcons.refreshCw,
            variant: ButtonVariant.outline,
            size: ButtonSize.small,
            onPressed: () => ref.invalidate(sessionReportProvider(sessionId)),
          ),
        ),
      ),
    );
  }
}

class _ReportBody extends ConsumerWidget {
  final SessionReport report;
  final SkotiqColors colors;

  /// The completed run id, threaded from [SessionReportDialog.runId]. Null for
  /// history / analytics opens.
  final int? runId;

  const _ReportBody({required this.report, required this.colors, this.runId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dateFormat = DateFormat('MMM d, yyyy HH:mm');
    // The client ROLE, not the connection: a desktop launched with
    // `--remote-host` that has not reached its rig is `Disconnected`, so
    // `backend is NetworkBackend` read false for the whole pre-handshake
    // window — and this button then offered "Review & Integrate" on a machine
    // that owns none of the host's subs and pushed it onto the host-only wall.
    final isRemote = ref.watch(isRemoteClientProvider);
    return SkotiqDialog(
      title: 'Session report',
      icon: LucideIcons.fileBarChart,
      width: 720,
      height: 760,
      bodyPadding: const EdgeInsets.fromLTRB(
        SkotiqTokens.space2xl,
        SkotiqTokens.spaceLg,
        SkotiqTokens.space2xl,
        SkotiqTokens.space2xl,
      ),
      actions: [
        if (report.sessionId > 0)
          SkotiqButton(
            label: isRemote ? 'Review on imaging host' : 'Review & Integrate',
            icon: LucideIcons.sparkles,
            variant: ButtonVariant.outline,
            size: ButtonSize.small,
            onPressed: () {
              if (isRemote) {
                SkotiqToastHelper.show(
                  context: context,
                  message: 'Session Review uses full-resolution files stored '
                      'on the imaging host. Open Skotiq there to continue.',
                  severity: SkotiqAlertSeverity.info,
                  icon: LucideIcons.monitor,
                );
                return;
              }
              Navigator.of(context).pop();
              context.push('/session-review?session=${report.sessionId}');
            },
          ),
        SkotiqButton(
          label: 'Close',
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Header(
            report: report,
            colors: colors,
            dateFormat: dateFormat,
            onCopyMarkdown: () => _copyMarkdown(context, ref),
            onExportTxt: () => _exportText(context, ref),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          _OverviewGrid(report: report, colors: colors),
          const SizedBox(height: 20),
          _SectionTitle(
              title: 'Mount / operations',
              icon: LucideIcons.settings2,
              colors: colors),
          _MountStatsRow(report: report, colors: colors),
          const SizedBox(height: 20),
          _SectionTitle(
              title: 'Guiding', icon: LucideIcons.activity, colors: colors),
          _GuideStatsBlock(report: report, colors: colors),
          if (report.avgTemperatureC != null ||
              report.avgHumidityPercent != null ||
              report.avgSeeingArcsec != null) ...[
            const SizedBox(height: 20),
            _SectionTitle(
                title: 'Conditions',
                icon: LucideIcons.thermometer,
                colors: colors),
            _ConditionsRow(report: report, colors: colors),
          ],
          const SizedBox(height: 20),
          _SectionTitle(
              title: 'Targets', icon: LucideIcons.target, colors: colors),
          if (report.targets.isEmpty)
            // "No light frames" is true of a calibration run, but on its own it
            // read as "this session captured nothing" — which is what the whole
            // dialog said about a 3-frame dark run. Name what the session DID
            // capture, not only what it did not.
            _muted(report.calibration.isEmpty
                ? 'No accepted light frames recorded.'
                : 'Calibration only — no light frames. See Calibration below.'),
          for (final target in report.targets) ...[
            const SizedBox(height: 8),
            _TargetBlock(target: target, colors: colors),
          ],
          if (report.calibration.isNotEmpty) ...[
            const SizedBox(height: 20),
            _SectionTitle(
                title: 'Calibration', icon: LucideIcons.layers, colors: colors),
            for (final cal in report.calibration) ...[
              const SizedBox(height: 8),
              _muted('${cal.frameType}: ${cal.framesAccepted}/'
                  '${cal.framesAttempted} accepted · '
                  '${cal.totalIntegrationSecs.toStringAsFixed(1)}s exposed'),
            ],
          ],
          // A run the operator stopped is not a failed run. The cancellation
          // notice is dropped from Errors (and stated plainly instead) only for
          // that outcome — a run that failed on its own keeps every message.
          // WHY the run ended, above the cascade it ended in. The Errors list
          // is everything the run reported in order, and reading it top-down
          // is how an operator came to believe a cancelled filter change had
          // ended his night. This states the answer first.
          if (_failureCause != null) ...[
            const SizedBox(height: 20),
            _SectionTitle(
                title: 'Why it ended',
                icon: LucideIcons.alertOctagon,
                colors: colors,
                titleColor: colors.error),
            const SizedBox(height: 8),
            SelectableText(
              runFailureMessage(_failureCause!),
              style:
                  SkotiqTypography.bodySm.copyWith(color: colors.textPrimary),
            ),
            if (report.rejectFolder != null) ...[
              const SizedBox(height: 8),
              _muted('Rejected frames: ${report.rejectFolder}'),
            ],
          ],
          if (_errorMessages.isNotEmpty) ...[
            const SizedBox(height: 20),
            _SectionTitle(
                title: _failureCause == null ? 'Errors' : 'Everything reported',
                icon: LucideIcons.xCircle,
                colors: colors,
                titleColor: colors.error),
            ..._buildErrorList(),
          ],
          if (_wasStoppedByOperator &&
              _errorMessages.length != report.errorMessages.length) ...[
            const SizedBox(height: 12),
            _muted('You stopped this run. Everything captured before the stop '
                'is saved.'),
          ],
          // Surface the warningMessages the executor accumulated during
          // the run. They are collected whether or not anything renders
          // them, so without this a warning like "filter Ha could not be
          // matched 14 times" vanishes the moment the run ends.
          if (report.warningMessages.isNotEmpty) ...[
            const SizedBox(height: 20),
            _SectionTitle(
                title: 'Warnings',
                icon: LucideIcons.alertTriangle,
                colors: colors,
                titleColor: colors.warning),
            ..._buildWarningList(),
          ],
          // List every recovery loop that fired during the run
          // with its cause, attempt count, duration, and outcome.
          // Scoped to this report's session via
          // `recoveryHistoryForSessionProvider`, which reloads the
          // persisted `session_diagnostics` row rather than the live
          // `recoveryHistoryProvider` — so a report viewed from the
          // History tab shows that session's recoveries, not the
          // currently-running one's.
          Consumer(builder: (context, ref, _) {
            final recoveriesAsync =
                ref.watch(recoveryHistoryForSessionProvider(report.sessionId));
            return recoveriesAsync.when(
              loading: () => _AuxiliaryReportState(
                label: 'Loading recovery history…',
                colors: colors,
              ),
              error: (error, _) => _AuxiliaryReportState(
                label: 'Could not load recovery history: $error',
                colors: colors,
                error: true,
                onRetry: () => ref.invalidate(
                  recoveryHistoryForSessionProvider(report.sessionId),
                ),
              ),
              data: (recoveries) {
                if (recoveries.isEmpty) return const SizedBox.shrink();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 20),
                    _SectionTitle(
                        title: 'Recoveries',
                        icon: LucideIcons.rotateCw,
                        colors: colors,
                        titleColor: colors.error),
                    for (final entry in recoveries) ...[
                      _RecoveryHistoryTile(entry: entry, colors: colors),
                      const SizedBox(height: 4),
                    ],
                  ],
                );
              },
            );
          }),
          // Diagnostics section. Rendered last, after warnings +
          // recoveries. Combines the
          // optical-train drift comparison (pre/post snapshot)
          // with the equipment-health summary (USB disconnects,
          // cooler stability, focuser moves, sky brightness,
          // noticed concerns).
          Consumer(builder: (context, ref, _) {
            final settingsAsync = ref.watch(appSettingsProvider);
            return settingsAsync.when(
              loading: () => _AuxiliaryReportState(
                label: 'Loading diagnostic settings…',
                colors: colors,
              ),
              error: (error, _) => _AuxiliaryReportState(
                label: 'Could not load diagnostic settings: $error',
                colors: colors,
                error: true,
                onRetry: () => ref.invalidate(appSettingsProvider),
              ),
              data: (settings) {
                // Scoped to this report's session: reload the persisted
                // pre/post optical-train snapshots from the session row.
                final snapshotAsync = ref.watch(
                  opticalTrainSnapshotForSessionProvider(report.sessionId),
                );
                return snapshotAsync.when(
                  loading: () => _AuxiliaryReportState(
                    label: 'Loading optical-train diagnostics…',
                    colors: colors,
                  ),
                  error: (error, _) => _AuxiliaryReportState(
                    label: 'Could not load optical-train diagnostics: $error',
                    colors: colors,
                    error: true,
                    onRetry: () => ref.invalidate(
                      opticalTrainSnapshotForSessionProvider(report.sessionId),
                    ),
                  ),
                  data: (snapshot) {
                    final baseline = snapshot.baseline;
                    final current = snapshot.current;
                    final healthSummary = ref.watch(
                      postSessionHealthSummaryProvider(report.sessionId),
                    );

                    // A persisted snapshot is two penalty scores and a capture
                    // time — nothing in it records whether either score came
                    // from a measurement, and a penalty of 0 is both
                    // "perfectly flat field" and "nothing looked". So BOTH
                    // operands of the drift subtraction have their measured
                    // flags re-derived from this session's own PSF tiles /
                    // astrometric residuals, which are permanent rows keyed by
                    // session id.
                    //
                    // The flags are passed explicitly rather than left to the
                    // constructor defaults. Those defaults stay fail-OPEN
                    // (`true`) on purpose: the analyzer is the one caller that
                    // may legitimately omit them because it always knows what
                    // it looked at, and defaulting it to `false` would
                    // downgrade its own honest readings. Reconstructions like
                    // this one carry no such knowledge, so they state the
                    // flags and fail CLOSED on unknown — a session whose
                    // science rows we cannot read is unmeasured, not healthy.
                    final analysis = ref
                        .watch(
                          opticalTrainDiagnosticsProvider(report.sessionId),
                        )
                        .valueOrNull;
                    final currentTiltMeasured = analysis?.tiltMeasured ?? false;
                    final currentCollimationMeasured =
                        analysis?.collimationMeasured ?? false;

                    OpticalTrainDiagnostics? currentDiag;
                    if (current != null) {
                      currentDiag = OpticalTrainDiagnostics(
                        tiltScore: current.tiltScore,
                        collimationScore: current.collimationScore,
                        dominantTiltDirection:
                            analysis?.dominantTiltDirection ?? 'unknown',
                        issues: const [],
                        tiltMeasured: currentTiltMeasured,
                        collimationMeasured: currentCollimationMeasured,
                      );
                    }

                    // The far operand needs the same treatment. The executor
                    // analysed the baseline from the rows that existed at
                    // `capturedAt`, so replay that same cut through the same
                    // service to recover ITS flags. Gating only the near
                    // operand still let a run that first measured collimation
                    // mid-session subtract the baseline's placeholder 0 and
                    // report "collimation Δ 22 — re-check spacers".
                    final baselineAnalysis = _analyzeOpticalTrainAsOf(
                      ref,
                      sessionId: report.sessionId,
                      asOf: baseline?.capturedAt,
                    );

                    // An axis supports a verdict only when BOTH ends of the
                    // subtraction measured it.
                    final tiltMeasured = currentTiltMeasured &&
                        (baselineAnalysis?.tiltMeasured ?? false);
                    final collimationMeasured = currentCollimationMeasured &&
                        (baselineAnalysis?.collimationMeasured ?? false);

                    // The drift verdict subtracts the two snapshots. It is
                    // only a measurement when both axes behind those numbers
                    // were measured at both ends; otherwise "held steady" is
                    // vouching for a comparison that never happened.
                    final driftIsComparable = currentDiag != null &&
                        tiltMeasured &&
                        collimationMeasured;

                    final diagnostics = PostSessionDiagnostics.build(
                      preSession: baseline,
                      postSession: driftIsComparable ? currentDiag : null,
                      healthSummary: healthSummary,
                      opticalTrainDriftThreshold:
                          settings.opticalTrainDriftThreshold,
                    );
                    // Say what was not measured exactly where the drift
                    // verdict would have gone, so the section does not simply
                    // go quiet about the optical train.
                    final issues = <ValidationIssue>[
                      if (baseline != null &&
                          currentDiag != null &&
                          !driftIsComparable)
                        ValidationIssue(
                          severity: ValidationSeverity.info,
                          category: ValidationCategory.opticalTrain,
                          title: 'Optical Train Drift Not Measured',
                          description:
                              '${_unmeasuredOpticalAxes(tiltMeasured: tiltMeasured, collimationMeasured: collimationMeasured)} '
                              'not measured at both ends of this run, so a '
                              'pre/post comparison would subtract placeholder '
                              'zeros rather than report drift.',
                          resolutionHint:
                              'Plate-solve frames across the whole field so '
                              'tilt and edge-versus-centre residuals can be '
                              'compared next time.',
                        ),
                      ...diagnostics.all,
                    ];
                    if (issues.isEmpty) {
                      return const SizedBox.shrink();
                    }

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 20),
                        _SectionTitle(
                            title: 'Diagnostics',
                            icon: LucideIcons.stethoscope,
                            colors: colors,
                            titleColor: colors.primary),
                        for (final issue in issues) ...[
                          _DiagnosticIssueTile(
                            issue: issue,
                            colors: colors,
                          ),
                          const SizedBox(height: 6),
                        ],
                      ],
                    );
                  },
                );
              },
            );
          }),
          // Post-session retrospective insights. Renders after
          // Diagnostics so the operator sees raw observations
          // first, then "what to change next time" last. Each insight
          // exposes Apply (when actionable) + Dismiss + sticky
          // "Don't suggest this again".
          Consumer(builder: (context, ref, _) {
            final insightsAsync =
                ref.watch(sessionInsightsProvider(report.sessionId));
            return insightsAsync.when(
              loading: () => _AuxiliaryReportState(
                label: 'Loading retrospective suggestions…',
                colors: colors,
              ),
              error: (error, _) => _AuxiliaryReportState(
                label: 'Could not load retrospective suggestions: $error',
                colors: colors,
                error: true,
                onRetry: () => ref.invalidate(
                  sessionInsightsProvider(report.sessionId),
                ),
              ),
              data: (insights) {
                if (insights.isEmpty) return const SizedBox.shrink();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 20),
                    _SectionTitle(
                      title: 'Suggestions',
                      icon: LucideIcons.lightbulb,
                      colors: colors,
                      titleColor: colors.primary,
                    ),
                    for (final insight in insights) ...[
                      _SessionInsightTile(
                        insight: insight,
                        colors: colors,
                      ),
                      const SizedBox(height: 6),
                    ],
                  ],
                );
              },
            );
          }),
          if (report.notes != null && report.notes!.isNotEmpty) ...[
            const SizedBox(height: 20),
            _SectionTitle(
                title: 'Session notes',
                icon: LucideIcons.fileText,
                colors: colors),
            Text(
              report.notes!,
              style:
                  SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
            ),
          ],
          // Journal notes attached to either this session's run
          // or its primary target. Renders
          // the same `_NoteTile` rows the History tab and
          // target card use, so an edit propagates everywhere.
          Consumer(builder: (context, ref, _) {
            // Prefer the run id passed in from the auto-open (an immutable
            // snapshot of the just-completed run). Only fall back to the live
            // provider for history / analytics opens, where no run id was
            // passed and the provider reflects whatever run — if any — is live.
            final runId = this.runId ?? ref.watch(currentRunIdProvider);
            // Prefer run-scoped notes when we have a run id; fall
            // back to per-target notes via the first target in the
            // report (most common: a sequence images one target
            // per session).
            if (runId != null) {
              final primaryTarget = report.targets.isNotEmpty
                  ? report.targets.first.targetName
                  : (report.sessionName);
              return Padding(
                padding: const EdgeInsets.only(top: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SectionTitle(
                      title: 'Journal',
                      icon: LucideIcons.bookOpen,
                      colors: colors,
                    ),
                    RunNotesSection(
                      sequenceRunId: runId,
                      targetId: primaryTarget,
                      colors: colors,
                      embedded: true,
                    ),
                  ],
                ),
              );
            }
            if (report.targets.isEmpty) return const SizedBox.shrink();
            final primaryTarget = report.targets.first.targetName;
            return Padding(
              padding: const EdgeInsets.only(top: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SectionTitle(
                    title: 'Journal',
                    icon: LucideIcons.bookOpen,
                    colors: colors,
                  ),
                  TargetNotesSection(
                    targetId: primaryTarget,
                    colors: colors,
                    embedded: true,
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _muted(String text) => Text(
        text,
        style: SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
      );

  bool get _wasStoppedByOperator => runWasStoppedByOperator(report.status);

  /// The report's error messages minus, on an operator stop, the cancellation
  /// notice that a Stop always produces. See [runErrorMessagesFor].
  List<String> get _errorMessages =>
      runErrorMessagesFor(report.status, report.errorMessages);

  /// The cause to headline, or null when there is nothing to explain.
  ///
  /// Suppressed on an operator stop for the same reason the cancellation notice
  /// is dropped from Errors: a run the operator stopped did not fail, and
  /// heading it "Why it ended" with a teardown message would say it did.
  String? get _failureCause =>
      _wasStoppedByOperator ? null : report.terminalCause;

  List<Widget> _buildErrorList() {
    return [
      for (final msg in _errorMessages)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            runFailureMessage(msg),
            style: SkotiqTypography.caption.copyWith(color: colors.error),
          ),
        ),
      if (_errorMessages.any((msg) => runFailureMessage(msg) != msg))
        ExpansionTile(
          title: const Text('Technical details'),
          children: [SelectableText(_errorMessages.join('\n'))],
        ),
    ];
  }

  List<Widget> _buildWarningList() {
    return [
      for (final msg in report.warningMessages)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(LucideIcons.chevronRight,
                    size: 13, color: colors.warning),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  msg,
                  style:
                      SkotiqTypography.caption.copyWith(color: colors.warning),
                ),
              ),
            ],
          ),
        ),
    ];
  }

  Future<void> _copyMarkdown(BuildContext context, WidgetRef ref) async {
    final service = ref.read(sessionReportServiceProvider);
    final markdown = service.renderMarkdown(report);
    await Clipboard.setData(ClipboardData(text: markdown));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Session report copied as Markdown'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  /// Platforms with a system share sheet `share_plus` can drive. Desktop
  /// (Windows / Linux) has none, so those write to the documents dir and
  /// report the path instead. Mirrors the snippet-palette share gate.
  bool get _platformHasShareSheet {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
      case TargetPlatform.android:
      case TargetPlatform.macOS:
        return true;
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        return false;
    }
  }

  Future<void> _exportText(BuildContext context, WidgetRef ref) async {
    final service = ref.read(sessionReportServiceProvider);
    final text = service.renderPlainText(report);
    final ts =
        DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
    final safeName =
        report.sessionName.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final filename = '${safeName}_${report.sessionId}_$ts.txt';
    try {
      // On mobile, route through the system share sheet so the .txt is
      // actually reachable (the documents-dir write + 4s snackbar path was
      // a dead end on phones). Stage in the OS temp dir for the share.
      if (_platformHasShareSheet) {
        final tmpDir = await getTemporaryDirectory();
        final tmpFile = File(p.join(tmpDir.path, filename));
        await tmpFile.writeAsString(text);
        await Share.shareXFiles(
          [XFile(tmpFile.path, mimeType: 'text/plain')],
          subject: 'Session report — ${report.sessionName}',
        );
        return;
      }

      // Desktop: write to the documents dir and surface the path with a
      // reveal-in-clipboard action so the snackbar isn't a dead end.
      final docsDir = await resolveSkotiqDocumentsDirectory();
      final dir = Directory(p.join(docsDir.path, 'Skotiq', 'reports'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final file = File(p.join(dir.path, filename));
      await file.writeAsString(text);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Report exported to ${file.path}'),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: 'Copy path',
            onPressed: () => Clipboard.setData(ClipboardData(text: file.path)),
          ),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Export failed: $e')),
      );
    }
  }
}

/// Re-runs the optical-train analysis over only the science rows that existed
/// at [asOf] — the cut the executor's session-start hook analysed to produce
/// the persisted baseline.
///
/// Returns `null` when there is no baseline to reconstruct or the rows are not
/// readable yet, which callers must treat as "not measured": the persisted
/// baseline carries scores but no provenance, and trusting a placeholder 0 on
/// this end of a subtraction fabricates drift exactly as readily as one on the
/// other end.
OpticalTrainDiagnostics? _analyzeOpticalTrainAsOf(
  WidgetRef ref, {
  required int sessionId,
  required DateTime? asOf,
}) {
  if (asOf == null) return null;
  final psfTiles = ref.watch(psfTilesForSessionProvider(sessionId)).valueOrNull;
  final residuals =
      ref.watch(residualVectorsForSessionProvider(sessionId)).valueOrNull;
  if (psfTiles == null || residuals == null) return null;
  return ref.read(opticalTrainDiagnosticsServiceProvider).analyze(
        psfTiles: psfTiles
            .where((row) => !row.timestamp.isAfter(asOf))
            .toList(growable: false),
        residualVectors: residuals
            .where((row) => !row.timestamp.isAfter(asOf))
            .toList(growable: false),
      );
}

/// Sentence subject naming the axes that lack data on at least one end of the
/// pre/post comparison, for the report line that replaces a drift verdict those
/// axes could not support. Says "not measured at both ends" rather than "never
/// measured" because an axis first measured mid-run is equally uncomparable.
String _unmeasuredOpticalAxes({
  required bool tiltMeasured,
  required bool collimationMeasured,
}) {
  if (!tiltMeasured && !collimationMeasured) {
    return 'Field tilt and collimation were';
  }
  return tiltMeasured ? 'Collimation was' : 'Field tilt was';
}

class _AuxiliaryReportState extends StatelessWidget {
  final String label;
  final SkotiqColors colors;
  final bool error;
  final VoidCallback? onRetry;

  const _AuxiliaryReportState({
    required this.label,
    required this.colors,
    this.error = false,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final accent = error ? colors.error : colors.textMuted;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          Icon(
            error ? LucideIcons.alertTriangle : LucideIcons.loader2,
            size: 14,
            color: accent,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: SkotiqTypography.caption.copyWith(color: accent),
            ),
          ),
          if (onRetry != null)
            TextButton(
              onPressed: onRetry,
              child: const Text('Retry'),
            ),
        ],
      ),
    );
  }
}
