import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/skotiq_backend.dart';
import '../errors/error_text.dart';
import '../models/plate_solver.dart';
import '../services/plate_solve_service.dart';
import 'backend_provider.dart';
import 'settings_provider.dart';
import 'logging_service_provider.dart';
import 'plate_solve_service_provider.dart';

/// The imaging host's plate solvers: what it found on its disk and what its
/// operator chose. Either is null until it has been read.
typedef PlateSolverSetup = ({
  PlateSolverDetection? detection,
  PlateSolverPreference? preference,
});

/// The host's solvers as a linked client was last told them by the host
/// (the plate-solver channel, or the host's answer to this client's own
/// rescan or save); null on the host itself and on a client the host has
/// not told yet.
final hostPlateSolverSetupProvider = StateProvider<PlateSolverSetup?>((ref) {
  ref.watch(backendProvider);
  return null;
});

/// [value] as the host told it; loading until the host has.
Future<T> _toldByHost<T>(T? value) => value != null
    ? Future.value(value)
    : Completer<T>().future;

/// Detection snapshot for the Plate Solving settings page. Re-runs the
/// filesystem probe + ASTAP catalog scan via `PlateSolveService.detect()`
/// whenever invalidated (after the user picks a new path or hits "Re-scan").
/// A linked client shows what the host told it.
final plateSolverDetectionProvider =
    FutureProvider.autoDispose<PlateSolverDetection>((ref) {
      ref.watch(backendProvider);
      if (ref.watch(isRemoteModeProvider)) {
        return _toldByHost(
          ref.watch(
            hostPlateSolverSetupProvider.select((setup) => setup?.detection),
          ),
        );
      }
      return ref.watch(plateSolveServiceProvider).detect();
    });

/// Persisted plate-solver UX configuration. Backed by Rust storage
/// (`platesolver.json`), exposed through `apiPlatesolveGetConfig`. A linked
/// client shows what the host told it.
final plateSolverPreferenceProvider =
    FutureProvider.autoDispose<PlateSolverPreference>((ref) {
      ref.watch(backendProvider);
      if (ref.watch(isRemoteModeProvider)) {
        return _toldByHost(
          ref.watch(
            hostPlateSolverSetupProvider.select((setup) => setup?.preference),
          ),
        );
      }
      return ref.watch(plateSolveServiceProvider).getConfig();
    });

/// The solvers as this process has them, which the host shares with its
/// linked clients.
final plateSolverSetupShownProvider = Provider.autoDispose<PlateSolverSetup>(
  (ref) => (
    detection: ref.watch(plateSolverDetectionProvider).valueOrNull,
    preference: ref.watch(plateSolverPreferenceProvider).valueOrNull,
  ),
);

/// Whether the solver the operator selected can solve right now: false when
/// it is missing, null while detection or the preference is still loading or
/// could not be read (a solver still being looked for is not a missing one).
final plateSolverReadyProvider = Provider.autoDispose<bool?>((ref) {
  final detection = ref.watch(plateSolverDetectionProvider).valueOrNull;
  final preference = ref.watch(plateSolverPreferenceProvider).valueOrNull;
  if (detection == null || preference == null) return null;
  return detection.supports(preference.choice);
});

/// State + controller for the Plate Solving settings page.
///
/// The page interacts with this notifier rather than touching the service
/// directly so verify-result toasts, in-flight spinners, and the latest
/// preference round-trip all live in one observable place.
class PlateSolverSettingsState {
  /// Most recent verify-solver result for ASTAP. `null` until the user has
  /// pressed "Verify" at least once for the configured ASTAP binary.
  final PlateSolverInfo? astapVerifyInfo;

  /// Error message from the most recent ASTAP verify attempt, or `null` if
  /// verify hasn't run or succeeded.
  final String? astapVerifyError;

  /// Most recent verify-solver result for Astrometry.net.
  final PlateSolverInfo? astrometryVerifyInfo;

  /// Error message from the most recent Astrometry.net verify attempt.
  final String? astrometryVerifyError;

  /// True while a verify-solver call is in flight, irrespective of which
  /// engine. The UI disables both verify buttons during that window so the
  /// user can't queue overlapping `--help` invocations.
  final bool verifying;

  /// True while a `setConfig` write is in flight. Re-entering save before
  /// the previous write returns would race the cache invalidation.
  final bool savingPreference;

  /// True while a fresh executable/catalog detection is running.
  final bool rescanning;

  const PlateSolverSettingsState({
    this.astapVerifyInfo,
    this.astapVerifyError,
    this.astrometryVerifyInfo,
    this.astrometryVerifyError,
    this.verifying = false,
    this.savingPreference = false,
    this.rescanning = false,
  });

  PlateSolverSettingsState copyWith({
    PlateSolverInfo? astapVerifyInfo,
    String? astapVerifyError,
    PlateSolverInfo? astrometryVerifyInfo,
    String? astrometryVerifyError,
    bool? verifying,
    bool? savingPreference,
    bool? rescanning,
    bool clearAstapVerify = false,
    bool clearAstrometryVerify = false,
  }) {
    return PlateSolverSettingsState(
      astapVerifyInfo: clearAstapVerify
          ? null
          : (astapVerifyInfo ?? this.astapVerifyInfo),
      astapVerifyError: clearAstapVerify
          ? null
          : (astapVerifyError ?? this.astapVerifyError),
      astrometryVerifyInfo: clearAstrometryVerify
          ? null
          : (astrometryVerifyInfo ?? this.astrometryVerifyInfo),
      astrometryVerifyError: clearAstrometryVerify
          ? null
          : (astrometryVerifyError ?? this.astrometryVerifyError),
      verifying: verifying ?? this.verifying,
      savingPreference: savingPreference ?? this.savingPreference,
      rescanning: rescanning ?? this.rescanning,
    );
  }
}

class PlateSolverSettingsNotifier
    extends StateNotifier<PlateSolverSettingsState> {
  final Ref ref;
  int _authorityGeneration = 0;

  PlateSolverSettingsNotifier(this.ref)
    : super(const PlateSolverSettingsState()) {
    ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
      if (previous == null || identical(previous, next)) return;
      _authorityGeneration++;
      state = const PlateSolverSettingsState();
    });
  }

  PlateSolveService get _service => ref.read(plateSolveServiceProvider);

  /// Force a fresh detection round (file system probe + catalog scan).
  Future<bool> rescan() async {
    if (state.rescanning) return false;
    final generation = _authorityGeneration;
    state = state.copyWith(rescanning: true);
    try {
      if (ref.read(isRemoteModeProvider)) {
        // The host detects again and tells every linked client; this one
        // shows the host's answer at once.
        final detection = await _service.detect();
        if (!_isCurrent(generation)) return false;
        final told = ref.read(hostPlateSolverSetupProvider.notifier);
        told.state = (
          detection: detection,
          preference: told.state?.preference,
        );
      } else {
        ref.invalidate(plateSolverDetectionProvider);
        // The `await` here ensures any test driver can observe the new detect
        // result before returning. Production callers can fire-and-forget.
        await ref.read(plateSolverDetectionProvider.future);
      }
      if (!_isCurrent(generation)) return false;
      state = state.copyWith(rescanning: false);
      return true;
    } catch (_) {
      if (!_isCurrent(generation)) return false;
      state = state.copyWith(rescanning: false);
      rethrow;
    }
  }

  /// Persist a new preference and refresh both detection + preference
  /// providers so the UI rebuilds against the new paths.
  ///
  /// Surfaces failures as state-level errors rather than re-throwing so
  /// the settings page can render an inline message — but does NOT swallow
  /// the underlying error: callers checking the returned bool know whether
  /// to leave optimistic UI changes in place.
  Future<bool> updatePreference(PlateSolverPreference next) async {
    if (state.savingPreference) {
      // A previous save is still in flight. Refuse to queue duplicates —
      // the user can retry once the active save resolves.
      return false;
    }
    final generation = _authorityGeneration;
    state = state.copyWith(savingPreference: true);
    try {
      await _service.setConfig(next);
      if (!_isCurrent(generation)) return false;
      // Keep the `plate_solver` app-setting — the value backup export and the
      // remote wire model serve — pointing at the selection just applied.
      // Without this the two disagreed until the next settings load.
      //
      // Failing to update the projection must NOT fail the save: the engine
      // preference is already written and in force, and reporting the save as
      // failed would be the same class of lie this projection exists to end.
      try {
        await ref
            .read(appSettingsProvider.notifier)
            .syncPlateSolverFromPreference(next.choice);
      } catch (error) {
        ref
            .read(loggingServiceProvider)
            .warning(
              'Solver preference saved, but the plate_solver projection could '
              'not be updated; it will re-sync on the next settings load: '
              '$error',
              source: 'PlateSolverSettings',
            );
      }
      if (!_isCurrent(generation)) return false;
      // A linked host tells its clients the saved preference and what it
      // finds with it; until then this client shows what it saved.
      if (ref.read(isRemoteModeProvider)) {
        final told = ref.read(hostPlateSolverSetupProvider.notifier);
        told.state = (detection: told.state?.detection, preference: next);
      }
      ref.invalidate(plateSolverPreferenceProvider);
      ref.invalidate(plateSolverDetectionProvider);
      state = state.copyWith(savingPreference: false);
      return true;
    } catch (_) {
      if (!_isCurrent(generation)) return false;
      state = state.copyWith(savingPreference: false);
      rethrow;
    }
  }

  /// Run `--help` against the user-supplied ASTAP path. Updates state so
  /// the settings page can render a green check or red banner inline.
  Future<void> verifyAstap(String executablePath) async {
    if (state.verifying) return;
    final generation = _authorityGeneration;
    state = state.copyWith(verifying: true, clearAstapVerify: true);
    try {
      final info = await _service.verify(executablePath);
      if (!_isCurrent(generation)) return;
      state = state.copyWith(verifying: false, astapVerifyInfo: info);
    } catch (e) {
      if (!_isCurrent(generation)) return;
      state = state.copyWith(verifying: false, astapVerifyError: userFacingError(e));
    }
  }

  /// Run `--help` against the user-supplied solve-field path.
  Future<void> verifyAstrometry(String executablePath) async {
    if (state.verifying) return;
    final generation = _authorityGeneration;
    state = state.copyWith(verifying: true, clearAstrometryVerify: true);
    try {
      final info = await _service.verify(executablePath);
      if (!_isCurrent(generation)) return;
      state = state.copyWith(verifying: false, astrometryVerifyInfo: info);
    } catch (e) {
      if (!_isCurrent(generation)) return;
      state = state.copyWith(
        verifying: false,
        astrometryVerifyError: userFacingError(e),
      );
    }
  }

  bool _isCurrent(int generation) => generation == _authorityGeneration;
}

final plateSolverSettingsNotifierProvider =
    StateNotifierProvider.autoDispose<
      PlateSolverSettingsNotifier,
      PlateSolverSettingsState
    >((ref) {
      return PlateSolverSettingsNotifier(ref);
    });
