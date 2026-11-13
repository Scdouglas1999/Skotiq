part of '../session_review_controller.dart';

class SessionReviewState {
  /// Every light sub in scope (accepted and rejected), capture-time ascending.
  final List<DbCapturedImage> subs;

  /// Resolved display name for the header (target name, else session label).
  final String title;

  /// Target id backing this review (for master accumulation), or null.
  final int? targetId;

  /// Target display name (used when persisting a master), or null.
  final String? targetName;

  /// The integration settings the A/B compare and the accumulating masters use.
  final IntegrationSettings settings;

  /// Persisted masters for this target (newest first); empty when none. This is
  /// the *library* list (what the master-library panel offers), NOT the master
  /// this screen is reviewing — see [reviewedMaster].
  final List<IntegratedMaster> masters;

  /// The persisted master that actually belongs to the scope under review — the
  /// one the hero image, the smart panels and deconvolution operate on.
  /// Null when this session/target has no master yet.
  ///
  /// Resolved from the `integrated_master_frames` fold records for the subs in
  /// scope, NOT from "newest master in the library":
  /// `integrated_masters.target_id` is frequently NULL, so a `masters.first`
  /// fallback renders another night's stack under this night's heading and
  /// points the finishing actions at the wrong file.
  final IntegratedMaster? reviewedMaster;

  final bool loading;

  /// True while an accumulation run is in flight.
  final bool integrating;

  /// A user-facing error from the last failed action, or null.
  final String? error;

  /// The newest `darkroom_jobs` row for the session under review, or null when
  /// the scope is a target (whose nights were each processed by their own job)
  /// or no pass has ever been queued for it.
  ///
  /// Read so this screen can state a pass that FAILED or was STOPPED. A dawn
  /// job that failed overnight leaves its state and its sentence on that row
  /// and nowhere else the operator looks: the toast that reports a pass belongs
  /// to the button that started it, so a pass nobody was standing at was
  /// invisible here — this screen showed the night's verdict with no sign that
  /// the drafting, the report and the delivery for it had not happened.
  final DarkroomJob? darkroomJob;

  /// The sentence the open-time recovery wrote about a post-session pass a
  /// PROCESS EXIT cut off on this session, or null when none did.
  ///
  /// The sibling of [darkroomJob], for the ending that row cannot hold. A pass
  /// the machine died inside reaches no ending at all — its row is simply
  /// still `running` when the process stops existing — so the recovery in
  /// `beforeOpen` is what discovers it, and what it wrote went to the session's
  /// notes and a `warning` Night Narrator event. This screen renders neither,
  /// so the night showed its masters and its score with nothing saying the
  /// drafting, the night report and the delivery had been cut off mid-run.
  final String? interruptedPassNotice;

  /// The Night Doctor's verdict for this scope (score + headline + findings),
  /// or null before [SessionReviewController.loadSmartData] has run / produced
  /// one. Read by `NightReportPanel`.
  final NightReport? nightReport;

  /// The marginal-SNR keep/cull curve for the reviewed master (decoded from the
  /// master's `improvement_curve_json`), or null when no analysed master is in
  /// scope. Read by `ImprovementCurvePanel` and the curve-linked sub cull.
  final IntegrationCurve? improvementCurve;

  /// The ordered sub on-disk paths the [improvementCurve] was computed over —
  /// the population the optimizer's `keptIndices` index into, persisted with the
  /// curve. Empty when the stored curve carried no population (legacy rows). The
  /// curve-linked cull maps `keptIndices` through this list onto the live
  /// accepted subs and bails out when the population no longer matches, so a
  /// stale curve never rejects arbitrary subs.
  final List<String> improvementCurvePopulation;

  /// The multi-night integration-time growth series for the reviewed master
  /// (ascending by date; empty when single-night / no fold log). Read by
  /// `GrowthCurvePanel`.
  final List<GrowthPoint> growthPoints;

  /// The highest-mean-weight night folded into the reviewed master, or null.
  /// Drives the `GrowthCurvePanel` best-night badge.
  final ReviewBestNight? bestNight;

  /// The catalog-powered annotation layer over the finished master, or null
  /// when the master is un-solved / annotation is unavailable. Read by
  /// `MasterOverlayView`.
  final AnnotationLayer? annotationLayer;

  /// Which of the two renderings is showing (narrative default ↔ workbench).
  final SessionReviewViewMode viewMode;

  /// Live integration progress `(phase, fraction)` bound from the post-session
  /// seam's `IntegrationProgress` event stream, or null when no run is in
  /// flight. Drives the `SkotiqProgressBar`.
  final ({String phase, double fraction})? progress;

  /// True while [SessionReviewController.loadSmartData] is loading the smart
  /// backbone (night report / curve / growth / annotations).
  final bool loadingSmartData;

  final bool deconvolving;

  /// The newest narrowband composite an earlier build combined here, or null.
  final NarrowbandComposite? narrowbandComposite;

  const SessionReviewState({
    this.subs = const [],
    this.title = 'Session Review',
    this.targetId,
    this.targetName,
    this.settings = IntegrationSettings.defaults,
    this.masters = const [],
    this.reviewedMaster,
    this.loading = true,
    this.integrating = false,
    this.error,
    this.darkroomJob,
    this.interruptedPassNotice,
    this.nightReport,
    this.improvementCurve,
    this.improvementCurvePopulation = const [],
    this.growthPoints = const [],
    this.bestNight,
    this.annotationLayer,
    this.viewMode = SessionReviewViewMode.narrative,
    this.progress,
    this.loadingSmartData = false,
    this.deconvolving = false,
    this.narrowbandComposite,
  });

  /// On-disk coverage-map PNG for the reviewed master, when drizzle wrote one.
  String? get coverageMapPath => reviewedMaster?.coverageMapPreviewPath;

  /// True while an accumulation or a deconvolution is in flight; the views
  /// disable their action buttons while this holds.
  bool get busy => integrating || deconvolving;

  /// Light subs only (the integration population is always lights).
  List<DbCapturedImage> get lights =>
      subs.where((s) => s.frameType == 'light').toList(growable: false);

  /// Accepted light subs — the population the A/B compare and accumulation
  /// consume.
  List<DbCapturedImage> get acceptedLights =>
      lights.where((s) => s.isAccepted).toList(growable: false);

  int get acceptedCount => acceptedLights.length;
  int get rejectedCount => lights.length - acceptedCount;

  SessionReviewState copyWith({
    List<DbCapturedImage>? subs,
    String? title,
    int? targetId,
    String? targetName,
    IntegrationSettings? settings,
    List<IntegratedMaster>? masters,
    IntegratedMaster? reviewedMaster,
    bool clearReviewedMaster = false,
    bool? loading,
    bool? integrating,
    String? error,
    bool clearError = false,
    DarkroomJob? darkroomJob,
    bool clearDarkroomJob = false,
    String? interruptedPassNotice,
    bool clearInterruptedPassNotice = false,
    NightReport? nightReport,
    bool clearNightReport = false,
    IntegrationCurve? improvementCurve,
    bool clearImprovementCurve = false,
    List<String>? improvementCurvePopulation,
    List<GrowthPoint>? growthPoints,
    ReviewBestNight? bestNight,
    bool clearBestNight = false,
    AnnotationLayer? annotationLayer,
    bool clearAnnotationLayer = false,
    SessionReviewViewMode? viewMode,
    ({String phase, double fraction})? progress,
    bool clearLiveProgress = false,
    bool? loadingSmartData,
    bool? deconvolving,
    NarrowbandComposite? narrowbandComposite,
  }) {
    return SessionReviewState(
      subs: subs ?? this.subs,
      title: title ?? this.title,
      targetId: targetId ?? this.targetId,
      targetName: targetName ?? this.targetName,
      settings: settings ?? this.settings,
      masters: masters ?? this.masters,
      reviewedMaster:
          clearReviewedMaster ? null : (reviewedMaster ?? this.reviewedMaster),
      loading: loading ?? this.loading,
      integrating: integrating ?? this.integrating,
      error: clearError ? null : (error ?? this.error),
      darkroomJob: clearDarkroomJob ? null : (darkroomJob ?? this.darkroomJob),
      interruptedPassNotice: clearInterruptedPassNotice
          ? null
          : (interruptedPassNotice ?? this.interruptedPassNotice),
      nightReport: clearNightReport ? null : (nightReport ?? this.nightReport),
      improvementCurve: clearImprovementCurve
          ? null
          : (improvementCurve ?? this.improvementCurve),
      improvementCurvePopulation: clearImprovementCurve
          ? const []
          : (improvementCurvePopulation ?? this.improvementCurvePopulation),
      growthPoints: growthPoints ?? this.growthPoints,
      bestNight: clearBestNight ? null : (bestNight ?? this.bestNight),
      annotationLayer: clearAnnotationLayer
          ? null
          : (annotationLayer ?? this.annotationLayer),
      viewMode: viewMode ?? this.viewMode,
      progress: clearLiveProgress ? null : (progress ?? this.progress),
      loadingSmartData: loadingSmartData ?? this.loadingSmartData,
      deconvolving: deconvolving ?? this.deconvolving,
      narrowbandComposite: narrowbandComposite ?? this.narrowbandComposite,
    );
  }
}
