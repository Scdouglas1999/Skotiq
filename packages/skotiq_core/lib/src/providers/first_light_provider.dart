import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/first_light/first_light_orchestrator.dart';

/// Controls the one-click first-light flow (expose → stretch → plate-solve →
/// annotate) and exposes its progress as [FirstLightState].
///
/// The controller owns a [FirstLightOrchestrator] and is the single seam UI
/// talks to. All state writes funnel through [_apply], which is mounted-guarded
/// so a flow that completes after the notifier is disposed (navigation away
/// mid-capture) cannot throw "state set after dispose".
class FirstLightController extends StateNotifier<FirstLightState> {
  FirstLightController(Ref ref) : super(const FirstLightState()) {
    _orchestrator = FirstLightOrchestrator(ref, onState: _apply);
  }

  late final FirstLightOrchestrator _orchestrator;

  /// Guards against starting a second flow while one is in flight.
  bool _running = false;

  /// Run the first-light flow for a single [exposureSeconds] exposure.
  ///
  /// Re-entrant calls while a flow is already running are ignored (the UI
  /// disables the trigger, but this is the authoritative guard). The flow
  /// never throws; failures are reflected as [FirstLightPhase.failed] state.
  Future<void> run({required double exposureSeconds}) async {
    if (_running) return;
    _running = true;
    try {
      await _orchestrator.run(exposureSeconds: exposureSeconds);
    } finally {
      _running = false;
    }
  }

  /// Stop an in-flight flow, aborting the exposure at the camera.
  ///
  /// [reset] is NOT a substitute: it clears the UI state while the exposure
  /// keeps running on the sensor, which is how a dismissed dialog orphans a
  /// capture and leaves the camera unusable until restart. The run itself
  /// unwinds back to idle once the abort lands.
  void cancel() {
    if (!_running) return;
    _orchestrator.cancel();
  }

  /// Reset back to the idle state so the flow can be run again from scratch.
  void reset() {
    _apply(const FirstLightState());
  }

  /// `true` while a flow is actively running. Mirrors the in-flight guard so
  /// callers don't have to infer it from [FirstLightState.phase].
  bool get isRunning => _running;

  void _apply(FirstLightState next) {
    if (!mounted) return;
    state = next;
  }
}

/// Provider for the first-light flow controller + state.
final firstLightControllerProvider =
    StateNotifierProvider<FirstLightController, FirstLightState>(
      FirstLightController.new,
    );
