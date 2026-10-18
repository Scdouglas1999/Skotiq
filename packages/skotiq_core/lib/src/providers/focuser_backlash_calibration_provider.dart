import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/skotiq_backend.dart';
import '../backend/skotiq_exception.dart' show SkotiqException;
import '../models/autofocus_progress.dart';
import '../models/focuser_backlash_calibration.dart';
import '../models/focuser_backlash_progress.dart';
import '../services/device_service.dart';
import 'backend_provider.dart';
import 'database_provider.dart';
import 'focuser_backlash_provider.dart';

/// Live state of a focuser backlash calibration run.
class FocuserBacklashCalibrationState {
  const FocuserBacklashCalibrationState({
    this.phase = FocuserBacklashPhase.idle,
    this.progress = 0,
    this.status = '',
    this.currentPoint = 0,
    this.totalPoints = 0,
    this.belowPoints = const [],
    this.abovePoints = const [],
    this.scanRange,
    this.result,
    this.errorMessage,
    this.isSaved = false,
    this.plan,
  });

  final FocuserBacklashPhase phase;

  /// 0..100 across both scans and the analysis.
  final double progress;

  /// One short line describing what the run is doing, or how it ended.
  final String status;

  final int currentPoint;
  final int totalPoints;

  /// The two scans are kept apart because the measurement IS the difference
  /// between them: a single merged list would draw one curve and hide the
  /// thing being measured.
  final List<VCurvePoint> belowPoints;
  final List<VCurvePoint> abovePoints;

  /// The position range both scans sample, for a chart to fix its axis on
  /// before the points arrive.
  final FocusRange? scanRange;

  final FocuserBacklashResult? result;

  /// A run that could not happen or was cancelled. A refusal is NOT an error:
  /// it arrives in [result] with the reason and the remedy native wrote.
  final String? errorMessage;

  /// Whether [result]'s figure has been written to the focuser's record.
  final bool isSaved;

  /// What the run will cost, when it has been asked for.
  final FocuserBacklashCalibrationPlan? plan;

  bool get isRunning => phase.isActive;

  FocuserBacklashCalibrationState copyWith({
    FocuserBacklashPhase? phase,
    double? progress,
    String? status,
    int? currentPoint,
    int? totalPoints,
    List<VCurvePoint>? belowPoints,
    List<VCurvePoint>? abovePoints,
    FocusRange? scanRange,
    FocuserBacklashResult? result,
    bool clearResult = false,
    String? errorMessage,
    bool clearErrorMessage = false,
    bool? isSaved,
    FocuserBacklashCalibrationPlan? plan,
    bool clearPlan = false,
  }) {
    return FocuserBacklashCalibrationState(
      phase: phase ?? this.phase,
      progress: progress ?? this.progress,
      status: status ?? this.status,
      currentPoint: currentPoint ?? this.currentPoint,
      totalPoints: totalPoints ?? this.totalPoints,
      belowPoints: belowPoints ?? this.belowPoints,
      abovePoints: abovePoints ?? this.abovePoints,
      scanRange: scanRange ?? this.scanRange,
      result: clearResult ? null : (result ?? this.result),
      errorMessage: clearErrorMessage
          ? null
          : (errorMessage ?? this.errorMessage),
      isSaved: isSaved ?? this.isSaved,
      plan: clearPlan ? null : (plan ?? this.plan),
    );
  }
}

/// Runs a backlash calibration and follows it on the backend event stream.
///
/// Deliberately not routed through [AutofocusOverlayNotifier]: that notifier
/// drops any progress frame whose point is not 1 while it is not running, so
/// a calibration's second scan would vanish into it.
class FocuserBacklashCalibrationNotifier
    extends StateNotifier<FocuserBacklashCalibrationState> {
  FocuserBacklashCalibrationNotifier(this._ref)
    : super(const FocuserBacklashCalibrationState()) {
    _bindToBackend(_ref.read(diagnosticsBackendProvider));
    // Re-bind on a backend swap (local FFI <-> network) so progress keeps
    // arriving from whichever backend is active.
    _ref.listen<DiagnosticsBackend>(diagnosticsBackendProvider, (_, next) {
      _bindToBackend(next);
    });
    // The plan on screen states the travel and cost of the settings that were
    // in force when it was fetched; editing a field silently makes those
    // numbers wrong, so the plan is re-read rather than left describing a run
    // that will not happen. A rejected plan also retries — the operator's fix
    // is exactly the change this listener sees.
    _ref.listen(focuserBacklashCalibrationSettingsProvider, (previous, next) {
      if (!mounted || previous == next) return;
      if (state.isRunning) return;
      if (state.plan == null && state.errorMessage == null) return;
      unawaited(loadPlan());
    });
  }

  final Ref _ref;
  StreamSubscription<SkotiqEvent>? _eventSubscription;
  int _backendGeneration = 0;

  /// Each scan is half the work, and the analysis that follows is arithmetic
  /// on data already in hand. 96% at the start of the analysis leaves a
  /// visible step for the result rather than sitting at 100 while the focuser
  /// is still being returned.
  static const double _analysisProgress = 96;
  static const double _scanShare = _analysisProgress / 2;

  void _bindToBackend(DiagnosticsBackend backend) {
    final generation = ++_backendGeneration;
    _eventSubscription?.cancel();
    _eventSubscription = backend.eventStream.listen((event) {
      if (!mounted) return;
      if (generation != _backendGeneration) return;
      if (event.category != EventCategory.equipment) return;
      if (event.eventType != 'FocuserBacklashCalibrationProgress') return;
      final detail = event.data['detail'] as String?;
      if (detail == null) return;
      _handleFrame(detail);
    });
  }

  void _handleFrame(String detail) {
    final progress = FocuserBacklashProgressData.tryParse(detail);
    if (progress != null) {
      _applyProgress(progress);
      return;
    }
    final result = FocuserBacklashProgressData.tryParseResult(detail);
    if (result != null) _applyResult(result);
  }

  void _applyProgress(FocuserBacklashProgressData progress) {
    if (progress.phase == FocuserBacklashPhase.analysing) {
      state = state.copyWith(
        phase: FocuserBacklashPhase.analysing,
        progress: _analysisProgress,
        status: 'Comparing the two scans',
      );
      return;
    }

    final fromBelow = progress.phase == FocuserBacklashPhase.scanningFromBelow;
    final scanFraction = progress.totalPoints > 0
        ? progress.point / progress.totalPoints
        : 0.0;
    state = state.copyWith(
      phase: progress.phase,
      progress: fromBelow
          ? _scanShare * scanFraction
          : _scanShare + _scanShare * scanFraction,
      status:
          '${fromBelow ? 'Scanning up from below' : 'Scanning down from above'}'
          ': point ${progress.point} of ${progress.totalPoints}',
      currentPoint: progress.point,
      totalPoints: progress.totalPoints,
      // A phase change starts the other list: native sends the current scan's
      // points only, so each list is replaced by what its own scan has so far.
      belowPoints: fromBelow ? progress.points : null,
      abovePoints: fromBelow ? null : progress.points,
      scanRange: progress.scanRange,
    );
  }

  void _applyResult(FocuserBacklashResult result) {
    // The run's return value and the terminal event frame carry the same
    // outcome; whichever lands first settles it, and the second is a no-op.
    if (state.result != null) return;
    state = state.copyWith(
      phase: result.kind == FocuserBacklashOutcomeKind.refused
          ? FocuserBacklashPhase.refused
          : FocuserBacklashPhase.complete,
      progress: 100,
      status: _resultStatus(result),
      result: result,
    );
  }

  static String _resultStatus(FocuserBacklashResult result) {
    final refusal = result.refusal;
    if (refusal != null) return refusal.message;
    final calibration = result.calibration!;
    if (!calibration.measurable) {
      return 'No backlash larger than '
          '${calibration.resolutionLimitSteps.round()} steps was detectable '
          'at position ${calibration.measuredAtPosition}';
    }
    return '${calibration.steps} steps of backlash at position '
        '${calibration.measuredAtPosition}';
  }

  /// Ask what a run would cost, so the operator can be told before agreeing.
  Future<void> loadPlan({int? centerPosition}) async {
    try {
      final plan = await _ref
          .read(deviceServiceProvider)
          .planFocuserBacklashCalibration(centerPosition: centerPosition);
      if (!mounted) return;
      state = state.copyWith(plan: plan, clearErrorMessage: true);
    } catch (error) {
      if (!mounted) return;
      // A stale plan quotes travel and time for settings that are no longer
      // in force; without a fresh one there is nothing honest to quote.
      state = state.copyWith(errorMessage: '$error', clearPlan: true);
    }
  }

  Future<void> run({int? centerPosition}) async {
    if (state.isRunning) return;
    state = FocuserBacklashCalibrationState(
      phase: FocuserBacklashPhase.scanningFromBelow,
      status: 'Starting the from-below scan',
      plan: state.plan,
    );
    try {
      final result = await _ref
          .read(deviceServiceProvider)
          .calibrateFocuserBacklash(centerPosition: centerPosition);
      if (!mounted) return;
      _applyResult(result);
    } catch (error) {
      if (!mounted) return;
      if (_isCancellation(error)) {
        // The operator stopped it. Native returns the focuser to where they
        // left it before reporting, so there is nothing to warn about and no
        // error to leave on screen: back to idle with a line saying so.
        state = FocuserBacklashCalibrationState(
          status:
              'Calibration stopped at your request — the focuser is back '
              'where you left it',
          plan: state.plan,
        );
        return;
      }
      state = state.copyWith(
        phase: FocuserBacklashPhase.failed,
        progress: 0,
        status: 'The calibration could not finish',
        errorMessage: '$error',
      );
    }
  }

  /// Whether [error] is the operator's own cancellation rather than a fault.
  ///
  /// Native raises `SkotiqError::Cancelled`, which the FFI backend maps to
  /// [SkotiqError.cancelled]; over a network backend the same stop arrives
  /// as text, hence the second test — the same two-step check the autofocus
  /// path makes.
  static bool _isCancellation(Object error) {
    if (error is SkotiqError && error.isCancellation) return true;
    if (error is SkotiqException && error.isCancellation) return true;
    final text = error.toString().toLowerCase();
    return text.contains('cancelled') || text.contains('canceled');
  }

  Future<void> cancel() async {
    if (!state.isRunning) return;
    state = state.copyWith(status: 'Cancelling the calibration');
    try {
      await _ref.read(deviceServiceProvider).cancelFocuserBacklashCalibration();
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        status: 'Cancellation failed — the calibration continues',
        errorMessage: '$error',
      );
    }
  }

  /// Write the measured figure to the record for the focuser it was measured
  /// on. Nothing else is touched: the operator's own `afBacklashIn` still
  /// outranks this everywhere it is read.
  Future<void> save() async {
    final calibration = state.result?.calibration;
    if (calibration == null || state.isSaved) return;
    try {
      await _ref
          .read(settingsDaoProvider)
          .saveFocuserBacklashCalibration(
            calibration.focuserDeviceId,
            calibration.toRecord(),
          );
      _ref.invalidate(savedFocuserBacklashProvider);
      if (!mounted) return;
      state = state.copyWith(isSaved: true, clearErrorMessage: true);
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(errorMessage: 'Could not save the figure: $error');
    }
  }

  /// Throw away this run's figure without saving it, keeping the plan so the
  /// operator can run it again.
  void discard() {
    state = FocuserBacklashCalibrationState(plan: state.plan);
  }

  void reset() {
    state = const FocuserBacklashCalibrationState();
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    super.dispose();
  }
}

final focuserBacklashCalibrationProvider =
    StateNotifierProvider<
      FocuserBacklashCalibrationNotifier,
      FocuserBacklashCalibrationState
    >((ref) => FocuserBacklashCalibrationNotifier(ref));
