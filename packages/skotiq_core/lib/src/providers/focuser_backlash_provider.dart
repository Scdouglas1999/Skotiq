import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/daos/settings_dao.dart';
import '../models/equipment/equipment_models.dart' show DeviceConnectionState;
import '../models/focuser_backlash_calibration.dart';
import '../services/focuser_backlash/effective_focuser_backlash.dart';
import 'database_provider.dart';
import 'equipment/camera_state_provider.dart';
import 'equipment/filter_wheel_state_provider.dart';
import 'equipment/focuser_state_provider.dart';
import 'settings_provider.dart';

export '../services/focuser_backlash/effective_focuser_backlash.dart';

/// The stored backlash measurement for the focuser that is connected now.
///
/// Keyed by device id, so plugging in a different focuser reads that focuser's
/// record — or none — rather than inheriting the last one's figure.
final savedFocuserBacklashProvider =
    FutureProvider<FocuserBacklashCalibrationRecord?>((ref) async {
      final focuserId = ref.watch(
        focuserStateProvider.select((state) => state.deviceId),
      );
      if (focuserId == null || focuserId.isEmpty) return null;
      return ref
          .watch(settingsDaoProvider)
          .getFocuserBacklashCalibration(focuserId);
    });

/// The backlash figure autofocus will apply, and where it came from.
///
/// Resolves to [FocuserBacklashOrigin.none] while either input is still
/// loading. That is deliberate: if the operator's own `afBacklashIn` is not
/// known yet, applying a measured figure could override a number they typed.
final effectiveFocuserBacklashProvider = Provider<EffectiveFocuserBacklash>((
  ref,
) {
  final settings = ref.watch(appSettingsProvider);
  final saved = ref.watch(savedFocuserBacklashProvider);
  if (!settings.hasValue || settings.isLoading || saved.isLoading) {
    return const EffectiveFocuserBacklash(
      steps: 0,
      origin: FocuserBacklashOrigin.none,
      provenance: 'the saved settings are still loading',
    );
  }
  final resolved = settings.requireValue;
  return resolveEffectiveFocuserBacklash(
    operatorEnteredSteps: resolved.afBacklashIn,
    // The same switch `sequence_serializer` and `autofocus_controls` already
    // honour when they build the wire config: with compensation off the
    // operator's figure is zeroed before native sees it, so it is not in force
    // and must not be reported as though it were.
    operatorCompensationEnabled: !resolved.afBacklashCompMethod
        .trim()
        .toLowerCase()
        .contains('none'),
    measured: saved.valueOrNull,
  );
});

/// The measured figure to put on the wire as `measured_backlash_in`, or null
/// when this focuser has none worth applying.
///
/// Deliberately independent of what the operator typed: native decides that
/// precedence (a typed figure outranks a measured one), and sending the
/// measurement regardless keeps the engine's logs describing what was actually
/// known rather than what Dart chose to reveal.
final measuredFocuserBacklashStepsProvider = Provider<int?>((ref) {
  final record = ref.watch(savedFocuserBacklashProvider).valueOrNull;
  if (record == null || !record.isUsable || !record.measurable) return null;
  return record.steps;
});

/// The settings the next backlash calibration will run with.
///
/// The operator's persisted choices win; with none stored the values are
/// seeded from the autofocus settings — already tuned for this rig — plus
/// the active filter's per-filter autofocus overrides where autofocus itself
/// would apply them (exposure, binning, gain, offset). A stored blob that
/// parses but fails validation is still surfaced, so the dialog can name the
/// problem rather than silently substituting different values.
final focuserBacklashCalibrationSettingsProvider =
    Provider<FocuserBacklashCalibrationSettings>((ref) {
      final stored = ref.watch(
        appSettingsProvider.select(
          (s) => s.valueOrNull?.focuserBacklashCalibrationJson ?? '',
        ),
      );
      final autofocus = ref.watch(autofocusSettingsProvider);
      final activeFilterName = ref.watch(
        filterWheelStateProvider.select((s) => s.currentFilterName),
      );
      return FocuserBacklashCalibrationSettings.resolve(
        stored,
        autofocus: autofocus,
        activeFilter: activeFilterName == null
            ? null
            : autofocus.filterSettings[activeFilterName],
      );
    });

// The offer ----------------------------------------------------------------

/// Substring of the autofocus verification failure native produces when the
/// focuser does not end up where the curve was measured. Produced by
/// `native/skotiq_native/sequencer/src/instructions/autofocus.rs`
/// ("Autofocus moved to N but the frame taken there measures HFR ..."), which
/// is the one place it is worded; matched rather than re-worded so a Dart copy
/// of the sentence cannot drift away from the real one.
const String autofocusLandingVerificationFailureMarker =
    'the frame taken there measures HFR';

/// Consecutive verification failures on one focuser before the app offers to
/// measure its backlash again.
///
/// One failure is ordinary: a cloud, a gust, a satellite through the frame.
/// Two in a row on the SAME focuser, with the curve fitting and the landing
/// frame disagreeing each time, is the signature of an uncalibrated or changed
/// drive train — exactly the case a measurement answers.
const int autofocusVerificationFailuresBeforeReoffer = 2;

/// Session-scoped state behind the offer: what the operator waved away this
/// session, and the failures that justify asking again anyway.
class FocuserBacklashOfferSession {
  const FocuserBacklashOfferSession({
    this.dismissedThisSession = false,
    this.verificationFailuresByFocuser = const {},
  });

  /// "Not now" — suppressed until the app restarts. The durable "never" lives
  /// in `AppSettings.focuserBacklashOfferMode`.
  final bool dismissedThisSession;

  /// Consecutive autofocus landing-verification failures, per focuser id. Any
  /// autofocus that lands cleanly clears its focuser's count.
  final Map<String, int> verificationFailuresByFocuser;

  FocuserBacklashOfferSession copyWith({
    bool? dismissedThisSession,
    Map<String, int>? verificationFailuresByFocuser,
  }) => FocuserBacklashOfferSession(
    dismissedThisSession: dismissedThisSession ?? this.dismissedThisSession,
    verificationFailuresByFocuser:
        verificationFailuresByFocuser ?? this.verificationFailuresByFocuser,
  );
}

class FocuserBacklashOfferNotifier
    extends StateNotifier<FocuserBacklashOfferSession> {
  FocuserBacklashOfferNotifier(this._ref)
    : super(const FocuserBacklashOfferSession());

  final Ref _ref;

  /// The operator said no. [never] persists that answer; otherwise it holds
  /// only until the app restarts.
  ///
  /// Either way the focus operation the offer interrupted proceeds — declining
  /// is an answer to a question, not a cancellation.
  Future<void> declineOffer({required bool never}) async {
    state = state.copyWith(dismissedThisSession: true);
    if (!never) return;
    await _ref
        .read(appSettingsProvider.notifier)
        .setFocuserBacklashOfferMode('never');
  }

  /// Record how an autofocus run ended on [focuserId].
  ///
  /// [failureMessage] is null for a run that landed cleanly, which clears the
  /// count: the drive train is behaving, whatever it did last time.
  void noteAutofocusOutcome({
    required String focuserId,
    String? failureMessage,
  }) {
    if (focuserId.isEmpty) return;
    final counts = Map<String, int>.from(state.verificationFailuresByFocuser);
    if (failureMessage == null) {
      if (counts.remove(focuserId) == null) return;
      state = state.copyWith(verificationFailuresByFocuser: counts);
      return;
    }
    if (!failureMessage.contains(autofocusLandingVerificationFailureMarker)) {
      // Some other failure — no stars, a cancelled run, a driver fault. It
      // says nothing about the gear train, so it must not push towards a
      // calibration the operator does not need.
      return;
    }
    counts[focuserId] = (counts[focuserId] ?? 0) + 1;
    // The session dismissal is left standing: the re-offer is decided per
    // focuser by [focuserBacklashOfferProvider] reading the count for the one
    // that is actually connected. Clearing the dismissal here instead let a
    // second focuser's failures reopen the offer for the first, which is the
    // focuser the operator had already waved away.
    state = state.copyWith(verificationFailuresByFocuser: counts);
  }

  /// Forget this session's dismissal, e.g. after the operator opens the
  /// calibration themselves and cancels out of it.
  void resetSessionDismissal() {
    state = state.copyWith(dismissedThisSession: false);
  }
}

final focuserBacklashOfferSessionProvider =
    StateNotifierProvider<
      FocuserBacklashOfferNotifier,
      FocuserBacklashOfferSession
    >((ref) => FocuserBacklashOfferNotifier(ref));

/// Whether to offer to measure this focuser's backlash right now.
///
/// Answers the question "a focus operation is about to run — should we ask?",
/// so it is consulted at that moment and nowhere else. Never true with no
/// hardware connected, which is what keeps it off a first launch.
///
/// Fail-closed while the settings or the stored record are loading: a
/// synchronous read before the async load lands reports "nothing dismissed",
/// which is how a dismissed prompt comes back every cold start.
final focuserBacklashOfferProvider = Provider<bool>((ref) {
  final settings = ref.watch(appSettingsProvider);
  final saved = ref.watch(savedFocuserBacklashProvider);
  if (!settings.hasValue || settings.isLoading || saved.isLoading) {
    return false;
  }
  if (saved.hasError) return false;
  if (settings.requireValue.focuserBacklashOfferMode == 'never') return false;

  // An operator-entered figure is their answer to this question already.
  if (settings.requireValue.afBacklashIn > 0) return false;

  // Already measured on this focuser.
  if (saved.valueOrNull != null) return false;

  final focuser = ref.watch(focuserStateProvider);
  final camera = ref.watch(cameraStateProvider);
  final focuserId = focuser.deviceId;
  if (focuser.connectionState != DeviceConnectionState.connected ||
      focuserId == null ||
      focuserId.isEmpty) {
    return false;
  }
  if (camera.connectionState != DeviceConnectionState.connected ||
      camera.deviceId == null ||
      camera.deviceId!.isEmpty) {
    return false;
  }

  final session = ref.watch(focuserBacklashOfferSessionProvider);
  if (!session.dismissedThisSession) return true;
  // Dismissed this session, but the focuser has since failed to land where
  // the curve said twice over: ask again.
  return (session.verificationFailuresByFocuser[focuserId] ?? 0) >=
      autofocusVerificationFailuresBeforeReoffer;
});
