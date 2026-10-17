import '../../database/daos/settings_dao.dart';

/// Where the backlash figure autofocus will use came from. Ordered best-first:
/// this is the resolution chain.
enum FocuserBacklashOrigin {
  /// The operator typed it into Settings. Always wins; nothing overwrites it.
  operatorEntered,

  /// This app measured it on the focuser in question.
  measured,

  /// No figure — neither entered nor measured, or measured and found to be
  /// nothing worth compensating.
  none,
}

/// The backlash figure that will actually be applied, with the sentence that
/// says where it came from.
class EffectiveFocuserBacklash {
  const EffectiveFocuserBacklash({
    required this.steps,
    required this.origin,
    required this.provenance,
    this.record,
    this.switchedOffOperatorSteps,
  });

  /// Backlash in focuser steps, 0 when [origin] is
  /// [FocuserBacklashOrigin.none].
  final int steps;

  final FocuserBacklashOrigin origin;

  /// Where this number came from, as a phrase that reads as the tail of
  /// `<n> steps, <provenance>`. For [FocuserBacklashOrigin.none] it reads as
  /// the tail of `Backlash compensation is off: <provenance>`.
  final String provenance;

  /// The measurement behind [steps]. Non-null only for
  /// [FocuserBacklashOrigin.measured].
  final FocuserBacklashCalibrationRecord? record;

  /// A figure the operator typed that is NOT being applied because they have
  /// switched backlash compensation off, so `af_backlash_comp_method` zeroes it
  /// before it reaches the engine.
  ///
  /// Null whenever their figure is in force, or when there is none. It exists
  /// so a surface can say "your 200 steps is switched off" rather than quietly
  /// reporting a different number than the field above it shows.
  final int? switchedOffOperatorSteps;

  /// Whether there is a figure to size a run-up from.
  bool get hasFigure => origin != FocuserBacklashOrigin.none;
}

/// What the operator typed outranks what we measured, always.
const String _operatorProvenance = 'the value you entered';

/// Resolve the figure to apply from the two places one can come from.
///
/// [operatorEnteredSteps] is `AppSettings.afBacklashIn`, which ships as 0.
/// A non-zero value there is the operator's own answer to this question and
/// wins outright — measuring never overwrites a number somebody typed.
/// [measured] is consulted only when they have left theirs at 0.
///
/// [operatorCompensationEnabled] is `af_backlash_comp_method` being anything
/// other than "None". It has to be here, and not assumed true, because that is
/// the switch Dart already honours when it builds the wire config: with
/// compensation off it sends `backlash_compensation: 0`, so the operator's
/// figure never reaches the engine and claiming it is in force would be a
/// straight untruth. The measured figure is unaffected — it rides
/// `measured_backlash_in`, which is ungated, because it sizes the final run-up
/// rather than the sweep's overshoot moves.
///
/// A measured record of 0 steps ([FocuserBacklashCalibrationRecord.measurable]
/// false) resolves to [FocuserBacklashOrigin.none]: "no backlash larger than
/// the scans could resolve" is a real result, and it is not a figure to size a
/// run-up from.
EffectiveFocuserBacklash resolveEffectiveFocuserBacklash({
  required int operatorEnteredSteps,
  required bool operatorCompensationEnabled,
  required FocuserBacklashCalibrationRecord? measured,
}) {
  if (operatorEnteredSteps > 0 && operatorCompensationEnabled) {
    return EffectiveFocuserBacklash(
      steps: operatorEnteredSteps,
      origin: FocuserBacklashOrigin.operatorEntered,
      provenance: _operatorProvenance,
    );
  }
  // Their figure is set but switched off. Carried through every branch below
  // so the surface can say so instead of reporting a different number than the
  // field beside it shows.
  final switchedOff = operatorEnteredSteps > 0 ? operatorEnteredSteps : null;
  if (measured == null || !measured.isUsable) {
    return EffectiveFocuserBacklash(
      steps: 0,
      origin: FocuserBacklashOrigin.none,
      switchedOffOperatorSteps: switchedOff,
      provenance: switchedOff == null
          ? 'this focuser has not been measured and you have not entered a '
                'figure'
          : 'the figure you entered is switched off and this focuser has not '
                'been measured',
    );
  }
  if (!measured.measurable) {
    return EffectiveFocuserBacklash(
      steps: 0,
      origin: FocuserBacklashOrigin.none,
      switchedOffOperatorSteps: switchedOff,
      provenance:
          'no backlash larger than '
          '${_formatSteps(measured.resolutionLimitSteps)} steps was '
          'detectable when this focuser was ${_measuredPhrase(measured)}',
    );
  }
  return EffectiveFocuserBacklash(
    steps: measured.steps,
    origin: FocuserBacklashOrigin.measured,
    provenance: _measuredPhrase(measured),
    record: measured,
    switchedOffOperatorSteps: switchedOff,
  );
}

/// `measured on 2026-09-14 at position 6620, 14.5 °C`.
///
/// The position is never left out: backlash varies along the travel (105 steps
/// at 6600 against 83 at 2500 on the same focuser), so a figure quoted without
/// where it was taken claims more than the measurement supports.
String _measuredPhrase(FocuserBacklashCalibrationRecord record) {
  final temperature = record.temperatureCelsius;
  final at = temperature == null
      ? ''
      : ', ${temperature.toStringAsFixed(1)} °C';
  return 'measured on ${_formatDate(record.measuredAt)} at position '
      '${record.measuredAtPosition}$at';
}

String _formatDate(DateTime value) {
  final local = value.toLocal();
  return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}

String _formatSteps(double value) => value == value.roundToDouble()
    ? value.round().toString()
    : value.toStringAsFixed(1);
