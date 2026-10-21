import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../backend/skotiq_backend.dart';
import '../models/autofocus_progress.dart';
import 'backend_provider.dart';
import 'operation_progress_provider.dart';

/// State for the non-blocking autofocus progress overlay
class AutofocusOverlayState {
  /// Whether an autofocus run is currently active
  final bool isRunning;

  /// Current point index (1-based)
  final int currentPoint;

  /// Total expected points
  final int totalPoints;

  /// All V-curve data points collected so far
  final List<VCurvePoint> vcurvePoints;

  /// Current HFR measurement
  final double currentHfr;

  /// Best HFR seen so far in this run
  final double bestHfr;

  /// Current star count
  final int starCount;

  /// Status message
  final String status;

  /// Final autofocus result (null while running)
  final AutofocusResult? result;

  /// Whether the overlay is minimized
  final bool isMinimized;

  /// Whether the overlay should be visible at all
  final bool isVisible;

  /// Focus range for the current run
  final FocusRange? focusRange;

  /// Star crops from the latest measurement
  final List<StarCrop> starCrops;

  /// Whether the autofocus run ended in an error (avoids stringly-typed checks)
  final bool hasError;

  const AutofocusOverlayState({
    this.isRunning = false,
    this.currentPoint = 0,
    this.totalPoints = 0,
    this.vcurvePoints = const [],
    this.currentHfr = 0.0,
    this.bestHfr = 0.0,
    this.starCount = 0,
    this.status = '',
    this.result,
    this.isMinimized = false,
    this.isVisible = false,
    this.focusRange,
    this.starCrops = const [],
    this.hasError = false,
  });

  AutofocusOverlayState copyWith({
    bool? isRunning,
    int? currentPoint,
    int? totalPoints,
    List<VCurvePoint>? vcurvePoints,
    double? currentHfr,
    double? bestHfr,
    int? starCount,
    String? status,
    AutofocusResult? result,
    bool clearResult = false,
    bool? isMinimized,
    bool? isVisible,
    FocusRange? focusRange,
    List<StarCrop>? starCrops,
    bool? hasError,
  }) {
    return AutofocusOverlayState(
      isRunning: isRunning ?? this.isRunning,
      currentPoint: currentPoint ?? this.currentPoint,
      totalPoints: totalPoints ?? this.totalPoints,
      vcurvePoints: vcurvePoints ?? this.vcurvePoints,
      currentHfr: currentHfr ?? this.currentHfr,
      bestHfr: bestHfr ?? this.bestHfr,
      starCount: starCount ?? this.starCount,
      status: status ?? this.status,
      result: clearResult ? null : (result ?? this.result),
      isMinimized: isMinimized ?? this.isMinimized,
      isVisible: isVisible ?? this.isVisible,
      focusRange: focusRange ?? this.focusRange,
      starCrops: starCrops ?? this.starCrops,
      hasError: hasError ?? this.hasError,
    );
  }
}

/// Notifier that tracks autofocus progress from the backend event stream
class AutofocusOverlayNotifier extends StateNotifier<AutofocusOverlayState> {
  final Ref _ref;
  StreamSubscription? _eventSubscription;
  int _backendGeneration = 0;
  Timer? _resultDismissTimer;

  /// How long a finished result stays on screen before the overlay closes
  /// itself. The overlay is shell-mounted (it is the single live V-curve
  /// surface, so it must outlive a screen change during a run), which means a
  /// result that never expires follows the operator onto Guiding, Plan Tonight
  /// and Framing and sits on top of their controls for the rest of the night.
  static const Duration resultAutoDismissDelay = Duration(seconds: 10);

  AutofocusOverlayNotifier(this._ref) : super(const AutofocusOverlayState()) {
    _listenToEvents();
  }

  void _listenToEvents() {
    _bindToBackend(_ref.read(diagnosticsBackendProvider));

    // Re-bind on backend swap (local FFI <-> network) so the overlay keeps
    // receiving AutofocusProgress events from whichever backend is active.
    // The old subscription is cancelled inside [_bindToBackend].
    _ref.listen<DiagnosticsBackend>(diagnosticsBackendProvider, (_, next) {
      _bindToBackend(next);
    });
  }

  void _bindToBackend(DiagnosticsBackend backend) {
    final generation = ++_backendGeneration;
    _eventSubscription?.cancel();
    _eventSubscription = backend.eventStream.listen((event) {
      if (!mounted) return;
      if (generation != _backendGeneration) return;
      if (event.category != EventCategory.equipment) return;
      if (event.eventType == 'AutofocusProgress') {
        _handleAutofocusProgress(event);
      } else if (event.eventType == 'PropertyChanged' &&
          event.data['property'] == 'AutofocusFinished') {
        _handleAutofocusFinished(event.data['value'] as String?);
      }
    });
  }

  void _handleAutofocusProgress(SkotiqEvent event) {
    final detail = event.data['detail'] as String?;
    if (detail == null) {
      onAutofocusFailed('Autofocus progress event was missing detail payload');
      return;
    }

    final progressData = AutofocusProgressData.tryParse(detail);
    if (progressData == null) {
      onAutofocusFailed('Autofocus progress event could not be parsed');
      return;
    }

    // Detect the start of a new autofocus run. If we receive point 1 and the
    // overlay is not currently running (or we were showing results from a
    // previous run), reset all state so old V-curve points and star crops
    // from the prior run don't persist.
    if (!state.isRunning || state.result != null) {
      if (progressData.point != 1) {
        // A queued progress frame from a run that has already completed or
        // cancelled must not resurrect the overlay as Running.
        return;
      }
      onAutofocusStarted();
    }

    // Compute best HFR from all V-curve points
    final newBestHfr = progressData.vcurvePoints.isEmpty
        ? 0.0
        : progressData.vcurvePoints
              .map((p) => p.hfr)
              .reduce((a, b) => a < b ? a : b);

    final phase =
        'Measuring point ${progressData.point}/${progressData.totalPoints}';

    state = state.copyWith(
      isRunning: true,
      isVisible: true,
      currentPoint: progressData.point,
      totalPoints: progressData.totalPoints,
      vcurvePoints: progressData.vcurvePoints,
      currentHfr: progressData.hfr,
      bestHfr: newBestHfr,
      starCount: progressData.starCount,
      focusRange: progressData.focusRange,
      starCrops: progressData.starCrops,
      status: phase,
    );

    // Keep the always-visible status-bar chip in step with the floating panel.
    // The chip's step text was only ever set once, at startOperation
    // ("Initializing..."), so a 35-second sweep read as a hung run on every
    // screen other than the one hosting the overlay. `updateProgress` is a
    // no-op when no autofocus operation is registered (e.g. a sequencer-driven
    // run), so this is safe on every path that emits progress.
    _ref
        .read(activeOperationsProvider.notifier)
        .updateProgress(
          OperationType.autofocus,
          progress: progressData.totalPoints > 0
              ? progressData.point / progressData.totalPoints
              : null,
          currentStep: phase,
        );
  }

  /// A sequence's autofocus ended. No call returns its result to Dart, so
  /// the native side publishes the outcome. A manual run reports its own
  /// outcome when its call returns, so this settles only a sweep still shown
  /// as running.
  void _handleAutofocusFinished(String? value) {
    if (!state.isRunning || value == null) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(value);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    final message = decoded['message'] as String?;
    switch (decoded['status']) {
      case 'Success':
        final result = _sequenceResult(decoded['result']);
        if (result == null) {
          onAutofocusFailed(message ?? 'Autofocus finished without a result');
        } else {
          onAutofocusCompleted(result);
        }
      case 'Cancelled':
        onAutofocusCancelled();
      default:
        onAutofocusFailed(message ?? 'Autofocus failed');
    }
  }

  /// The sequencer's own result shape, which differs from the one-shot
  /// API's in field names.
  static AutofocusResult? _sequenceResult(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final position = json['best_position'];
    final hfr = json['best_hfr'];
    if (position is! int || hfr is! num) return null;
    final points = json['data_points'];
    return AutofocusResult(
      bestPosition: position,
      bestHfr: hfr.toDouble(),
      focusData: [
        if (points is List)
          for (final point in points)
            if (point is Map<String, dynamic>) FocusDataPoint.fromJson(point),
      ],
      method: json['method_used']?.toString() ?? '',
      temperature: (json['temperature_celsius'] as num?)?.toDouble(),
      timestamp: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      curveFitQuality: (json['curve_fit_quality'] as num?)?.toDouble() ?? 0,
      backlashApplied: json['backlash_applied'] as bool? ?? false,
    );
  }

  /// Called when autofocus starts (from any trigger: focus tab, dashboard, sequencer)
  void onAutofocusStarted() {
    _cancelResultDismiss();
    state = const AutofocusOverlayState(
      isRunning: true,
      isVisible: true,
      hasError: false,
      status: 'Initializing autofocus...',
    );
  }

  /// Called when autofocus completes with a result
  ///
  /// The panel collapses to its one-line summary as soon as the run ends. It is
  /// a shell-mounted floating panel pinned bottom-right, which is exactly where
  /// the imaging screen's focus column lives: left expanded it covered the
  /// "Run Autofocus" button plus the Step Size / Steps Out / Exposure fields
  /// and swallowed every click aimed at them, so retrying a focus run appeared
  /// to do nothing. Minimised it keeps the result readable (and one tap
  /// re-expands the V-curve) without holding the controls hostage.
  void onAutofocusCompleted(AutofocusResult result) {
    _armResultDismiss();
    state = state.copyWith(
      isRunning: false,
      hasError: false,
      result: result,
      isMinimized: true,
      status:
          'Complete - HFR: ${result.bestHfr.toStringAsFixed(2)} '
          'at position ${result.bestPosition}',
    );
  }

  /// Called when autofocus fails
  void onAutofocusFailed(String error) {
    // A failed run carries an error the operator has to read, so it stays up
    // until dismissed by hand.
    _cancelResultDismiss();
    state = state.copyWith(
      isRunning: false,
      hasError: true,
      isMinimized: true,
      status: 'Failed: $error',
    );
  }

  void onAutofocusCancellationRequested() {
    if (!state.isRunning) return;
    state = state.copyWith(status: 'Cancelling autofocus...');
  }

  void onAutofocusCancelFailed() {
    if (!state.isRunning) return;
    state = state.copyWith(status: 'Cancellation failed — autofocus continues');
  }

  void onAutofocusCancelled() {
    _armResultDismiss();
    state = state.copyWith(
      isRunning: false,
      hasError: false,
      isMinimized: true,
      status: 'Autofocus cancelled',
      clearResult: true,
    );
  }

  /// Toggle minimized state
  void toggleMinimized() {
    state = state.copyWith(isMinimized: !state.isMinimized);
  }

  /// Close/dismiss the overlay
  ///
  /// Only the floating panel closes. The last result stays, because the
  /// Tonight Focus tab reads it from here; the next run replaces it.
  void dismiss() {
    _cancelResultDismiss();
    state = state.copyWith(isVisible: false, isRunning: false);
  }

  void _armResultDismiss() {
    _resultDismissTimer?.cancel();
    _resultDismissTimer = Timer(resultAutoDismissDelay, () {
      if (!mounted) return;
      // Only a settled result expires: if another run started in the meantime
      // the timer was already cancelled, and a failure re-cancels it.
      if (state.isRunning || state.hasError) return;
      dismiss();
    });
  }

  void _cancelResultDismiss() {
    _resultDismissTimer?.cancel();
    _resultDismissTimer = null;
  }

  @override
  void dispose() {
    _cancelResultDismiss();
    _eventSubscription?.cancel();
    super.dispose();
  }
}

/// Provider for the autofocus progress overlay state
final autofocusOverlayProvider =
    StateNotifierProvider<AutofocusOverlayNotifier, AutofocusOverlayState>((
      ref,
    ) {
      return AutofocusOverlayNotifier(ref);
    });
