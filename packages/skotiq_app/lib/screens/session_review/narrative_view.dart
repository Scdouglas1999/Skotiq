import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../sequencer/widgets/run_dashboard/frame_detail_dialog.dart';
import 'session_review_controller.dart';
import 'widgets/build_in_darkroom_button.dart';
import 'widgets/darkroom_pass_banner.dart';
import 'widgets/growth_curve_panel.dart';
import 'widgets/improvement_curve_panel.dart';
import 'widgets/master_overlay_view.dart';
import 'widgets/night_report_panel.dart';
import 'widgets/session_interruption_banner.dart';

/// The *narrative* rendering of the one [SessionReviewController] state: a
/// top-to-bottom story of the night, read like a morning report.
///
/// Order: hero master (with overlays) → Night-Doctor verdict
/// (headline + score) → "proof it's optimal" integration-improvement curve →
/// the ranked finding cards ("what I fixed/found") → multi-night growth curve →
/// the way into the Darkroom to finish the master. The verdict and findings
/// are two slots of `NightReportPanel` (`NightReportSection.verdict` then
/// `.findings`) so the findings sit *after* the curve, not bundled with the
/// verdict before it.
///
/// This view computes nothing; it reads the same provider the workbench reads,
/// so the two are two renderings of one model. Panels are composed by their
/// contract constructor signatures and are design-system pure.
class NarrativeView extends ConsumerWidget {
  final SessionReviewScope scope;

  const NarrativeView({super.key, required this.scope});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final state = ref.watch(sessionReviewControllerProvider(scope));

    final report = state.nightReport;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── A pass a process exit cut off. ───────────────────────────────
          // First, because it outranks every ending below it: the row that
          // banner reads has been re-queued since, so it no longer says the
          // machine died mid-run.
          SessionInterruptionBanner(notice: state.interruptedPassNotice),

          // ── A Darkroom pass that failed or was stopped. ──────────────────
          // Above the hero: it is the reason the drafts and the delivery this
          // page would otherwise be read as reporting are not there.
          DarkroomPassBanner(job: state.darkroomJob),

          // ── Hero: the finished master with toggleable overlays. ──────────
          _HeroSection(state: state),
          const SizedBox(height: SkotiqTokens.spaceLg),

          // ── Verdict: big headline + 0..100 score ring. ───────────────────
          // Verdict header only here; the ranked finding cards render after the
          // improvement curve. A null report degrades to the
          // "analysis pending" placeholder in this slot.
          NightReportPanel(
            report: report,
            section: NightReportSection.verdict,
            onEvidenceTap: (id) =>
                FrameDetailDialog.showForFrame(context, imageId: id),
          ),
          _GradedSubsDisagreement(subs: state.lights, report: report),
          _CalibrationRecordDisagreement(master: state.reviewedMaster),
          const SizedBox(height: SkotiqTokens.spaceLg),

          const SectionTitle(title: 'How deep is deep enough?'),
          const SizedBox(height: SkotiqTokens.spaceSm),
          ImprovementCurvePanel(curve: state.improvementCurve),
          const SizedBox(height: SkotiqTokens.spaceLg),

          if (report != null && report.findings.isNotEmpty) ...[
            const SectionTitle(title: 'What I fixed and found'),
            const SizedBox(height: SkotiqTokens.spaceSm),
            NightReportPanel(
              report: report,
              section: NightReportSection.findings,
              onEvidenceTap: (id) =>
                  FrameDetailDialog.showForFrame(context, imageId: id),
            ),
            const SizedBox(height: SkotiqTokens.spaceLg),
          ],

          const SectionTitle(title: 'This project over time'),
          const SizedBox(height: SkotiqTokens.spaceSm),
          GrowthCurvePanel(
            points: state.growthPoints,
            best: state.bestNight,
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),

          if (state.reviewedMaster case final master?) ...[
            const SectionTitle(title: 'Finishing'),
            const SizedBox(height: SkotiqTokens.spaceSm),
            _FinishInDarkroomCard(master: master),
          ],
          // Bottom breathing room so the last card clears the progress bar.
          SizedBox(
            height: SkotiqTokens.spaceXl,
            child: ColoredBox(color: colors.background),
          ),
        ],
      ),
    );
  }
}

/// The narrative hero: the finished master rendered through [MasterOverlayView]
/// (which extends the on-disk [MasterPreviewView] load/stretch path). The
/// narrative shows annotations on by default and leaves the dense rejection /
/// coverage toggles to the workbench. When no master exists yet it offers the
/// Darkroom's guided build so the read-first narrative is never a dead end.
class _HeroSection extends StatelessWidget {
  final SessionReviewState state;

  const _HeroSection({required this.state});

  @override
  Widget build(BuildContext context) {
    final previewPath = state.reviewedMaster?.previewPngPath;

    if (previewPath == null) {
      return SkotiqPanel(
        padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const EmptyState(
              icon: SkotiqIcons.image,
              title: 'No finished master yet',
              body: 'Masters are built in the Darkroom from every night of a '
                  'target. Once they are, the master appears here, annotated '
                  'with the objects in frame.',
            ),
            const SizedBox(height: SkotiqTokens.spaceLg),
            Align(
              alignment: Alignment.center,
              child: BuildInDarkroomButton(targetName: state.targetName),
            ),
          ],
        ),
      );
    }

    return SkotiqPanel(
      padding: EdgeInsets.zero,
      child: SizedBox(
        height: 460,
        child: MasterOverlayView(
          previewPngPath: previewPath,
          annotations: state.annotationLayer,
          rejectionMapPngPath: state.reviewedMaster?.rejectionMapPreviewPath,
          coverageMapPngPath: state.coverageMapPath,
          showAnnotations: true,
          finishingLayers: finishingLayersForMaster(state.reviewedMaster),
        ),
      ),
    );
  }
}

/// Where the reviewed master is finished: the Darkroom, whose recipe steps
/// stay adjustable and never write over the master.
class _FinishInDarkroomCard extends StatelessWidget {
  final IntegratedMaster master;

  const _FinishInDarkroomCard({required this.master});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return SkotiqPanel(
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(SkotiqIcons.sparkle,
                  size: SkotiqTokens.iconSm, color: colors.primary),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Expanded(
                child: Text(
                  'Finish in the Darkroom',
                  style: SkotiqTypography.sectionTitle
                      .copyWith(color: colors.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          Text(
            'Gradient removal, color calibration, star reduction and channel '
            'combination are recipe steps in the Darkroom. Every step stays '
            'adjustable, and the master on disk is not changed.',
            style:
                SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          EditMasterInDarkroomButton(master: master),
        ],
      ),
    );
  }
}

/// Reconciles the Night Doctor's verdict with the frame grader that the
/// Workbench tab of this same screen renders.
///
/// The two panels read different inputs: the night report is a session-level
/// degradation score built from session-level findings, the badges come from
/// [FrameQualityAssessmentService] per frame. So a four-frame run can score
/// **100 / 100 — "A clean night, no problems detected" — 0 findings** here
/// while the Workbench badges every one of its four subs red POOR at HFR 5.7
/// against a cull line of 3.5. Advisory badges never changing acceptance is
/// documented policy; a night on which *every* frame is graded POOR being
/// reported as having nothing wrong with it is not.
///
/// So the same grader the Workbench uses is read here, and when it disagrees
/// with a clean verdict the disagreement is stated instead of being left for the
/// operator to find on the other tab.
class _GradedSubsDisagreement extends StatelessWidget {
  final List<DbCapturedImage> subs;
  final NightReport? report;

  const _GradedSubsDisagreement({required this.subs, required this.report});

  @override
  Widget build(BuildContext context) {
    final message = gradedSubsDisagreementMessage(subs: subs, report: report);
    if (message == null) return const SizedBox.shrink();

    final colors = SkotiqColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: SkotiqTokens.spaceMd),
      child: Container(
        padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
        decoration: BoxDecoration(
          color: colors.warning.withValues(alpha: 0.10),
          borderRadius: SkotiqTokens.borderRadiusLg,
          border: Border.all(color: colors.warning.withValues(alpha: 0.45)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(SkotiqIcons.warning,
                size: SkotiqTokens.iconSm, color: colors.warning),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Expanded(
              child: Text(
                message,
                style:
                    SkotiqTypography.bodySm.copyWith(color: colors.textPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Reconciles the Night Doctor's verdict with what the night's own integration
/// recorded about its CALIBRATION.
///
/// Same shape as [_GradedSubsDisagreement] and the same reason. The verdict is
/// built from session-level degradation findings, and the calibration record is
/// written somewhere else entirely: the integration stores it on the master's
/// row (`stats_json`), the master FITS carries it as `CALWARN`, and the dawn
/// pass's morning report prints every sentence of it. None of those reach the
/// score — so a night whose masters recorded twenty calibration warnings scored
/// 100 / 100 under "a clean night, no problems detected", and the operator had
/// to open a FITS header or a JSON artifact to learn otherwise.
///
/// It states, it does not score: whether a calibration warning should MOVE the
/// verdict is a decision about the grader, not about this line, and the number
/// beside the headline is left exactly as the Doctor computed it.
class _CalibrationRecordDisagreement extends StatelessWidget {
  /// The master this review is about, or null when the night produced none.
  final IntegratedMaster? master;

  const _CalibrationRecordDisagreement({required this.master});

  @override
  Widget build(BuildContext context) {
    final message = calibrationRecordMessage(master: master);
    if (message == null) return const SizedBox.shrink();

    final colors = SkotiqColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: SkotiqTokens.spaceMd),
      child: Container(
        padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
        decoration: BoxDecoration(
          color: colors.warning.withValues(alpha: 0.10),
          borderRadius: SkotiqTokens.borderRadiusLg,
          border: Border.all(color: colors.warning.withValues(alpha: 0.45)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(SkotiqIcons.warning,
                size: SkotiqTokens.iconSm, color: colors.warning),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Expanded(
              child: Text(
                message,
                style:
                    SkotiqTypography.bodySm.copyWith(color: colors.textPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// How many recorded calibration sentences [calibrationRecordMessage] quotes
/// before it counts the rest.
///
/// A master with an unreadable anchor raises one sentence per slot per
/// dimension, so the record runs to twenty-odd lines. Quoting all of them turns
/// the verdict block into a wall the operator scrolls past; quoting none makes
/// the line unactionable. Three names the shape of the problem, and the count
/// says how much more of it there is.
const int kCalibrationSentencesQuoted = 3;

/// The sentence stating what the master's own integration record says about its
/// calibration, or null when the record raised nothing.
///
/// Read from `integrated_masters.stats_json` through [DawnMasterStats] — the
/// same parse the dawn autopilot's morning report uses, so this screen and that
/// report cannot disagree about the same master. A row whose stats are
/// unreadable parses to [DawnMasterStats.unrecorded], which warns about
/// nothing: an unparseable payload is not evidence of a calibration problem,
/// and inventing one would be the cry-wolf defect pointed the other way.
///
/// Pure, and public, so the reconciliation can be pinned without driving the
/// whole review screen.
String? calibrationRecordMessage({required IntegratedMaster? master}) {
  if (master == null) return null;
  final stats = DawnMasterStats.parse(master.statsJson);
  if (!stats.calibrationWarned) return null;

  final sentences = stats.calibrationSentences;
  if (sentences.isEmpty) return null;
  final quoted = sentences.take(kCalibrationSentencesQuoted).toList();
  final remaining = sentences.length - quoted.length;
  final tail = remaining == 0
      ? ''
      : ' …and $remaining more recorded against this master.';

  final count = sentences.length == 1
      ? 'one calibration warning'
      : '${sentences.length} calibration warnings';
  return 'The verdict above scores the session\'s frames; it does not read the '
      'calibration record. Integrating "${master.name}" recorded $count: '
      '${quoted.join(' ')}$tail';
}

/// The sentence stating a clean Night-Doctor verdict's disagreement with the
/// per-frame grader, or null when the two do not disagree.
///
/// Pure, and public, so the reconciliation can be pinned without driving the
/// whole review screen: it states a claim, and a claim is exactly what a unit
/// test can hold.
String? gradedSubsDisagreementMessage({
  required List<DbCapturedImage> subs,
  required NightReport? report,
}) {
  // Only a *clean graded* verdict can be contradicted. An ungraded night
  // already says it could not judge, and a night that lists findings is not
  // claiming there is nothing wrong.
  if (report == null || !report.graded || report.findings.isNotEmpty) {
    return null;
  }
  if (subs.isEmpty) return null;

  const assessor = FrameQualityAssessmentService();
  final assessments = assessor.assessBatch(subs);
  final poor =
      assessments.values.where((a) => a.level == FrameQualityLevel.poor).length;
  if (poor == 0) return null;

  final hfrs = subs
      .map((s) => s.hfr)
      .whereType<double>()
      .where((v) => v.isFinite && v > 0)
      .toList()
    ..sort();
  final median = hfrs.isEmpty
      ? null
      : hfrs.length.isOdd
          ? hfrs[hfrs.length ~/ 2]
          : (hfrs[hfrs.length ~/ 2 - 1] + hfrs[hfrs.length ~/ 2]) / 2;
  final hfrClause =
      median == null ? '' : ' (median HFR ${median.toStringAsFixed(1)})';
  final total = subs.length;

  return poor == total
      ? 'The verdict above found no session-level problem, but the frame '
          'grader marks all $total subs POOR$hfrClause. Open Workbench before '
          'treating this night as clean.'
      : 'The verdict above found no session-level problem, but the frame '
          'grader marks $poor of $total subs POOR$hfrClause. Open Workbench '
          'to see which.';
}
