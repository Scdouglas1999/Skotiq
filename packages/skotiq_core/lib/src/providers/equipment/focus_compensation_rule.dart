/// The temperature compensation rule, as the app's idle compensator applies
/// it.
///
/// This mirrors `FocusCompensation` in
/// `native/skotiq_native/sequencer/src/temperature_compensation.rs`, which a
/// run applies before each light frame, method for method. The two are held
/// to one definition by
/// `native/skotiq_native/sequencer/src/temperature_compensation_cases.json`:
/// the Rust and the Dart tests both run every case in it, so a change to the
/// rule on one side fails the other side's test until it follows.
class FocusCompensationRule {
  FocusReference? _reference;

  /// Where compensation last put the focuser, or the reference position.
  int _expectedPosition = 0;

  /// A focuser may report a step or two off a commanded target.
  static const int arrivalToleranceSteps = 2;

  /// The reading compensation measures from, or null before the first one.
  FocusReference? get reference => _reference;

  /// What one temperature and position reading calls for.
  CompensationStep step({
    required double stepsPerDegree,
    required int minSteps,
    required double temperature,
    required int position,
  }) {
    final reference = _reference;
    if (reference == null) {
      _takeReference(temperature, position);
      return const TakeReference();
    }
    if ((position - _expectedPosition).abs() > arrivalToleranceSteps) {
      final movedFrom = _expectedPosition;
      _takeReference(temperature, position);
      return TakeReference(movedFrom: movedFrom);
    }
    if (stepsPerDegree == 0 || !stepsPerDegree.isFinite) {
      return const Hold();
    }
    final degreesSinceReference = temperature - reference.temperature;
    final target =
        reference.position + (degreesSinceReference * stepsPerDegree).round();
    final owed = target - position;
    if (owed.abs() < minSteps.clamp(1, 10000)) {
      return const Hold();
    }
    if (target < 0) {
      return Refuse(target: target);
    }
    return Move(
      target: target,
      owed: owed,
      degreesSinceReference: degreesSinceReference,
    );
  }

  /// A filter's focus offset moved the focuser [steps]. The reference moves
  /// with it, so the correction owed for the temperature so far is kept.
  void shiftedBy(int steps) {
    final reference = _reference;
    if (reference != null) {
      _reference = FocusReference(
        temperature: reference.temperature,
        position: reference.position + steps,
        takenAt: reference.takenAt,
      );
    }
    _expectedPosition += steps;
  }

  /// The focuser reached [target]; the reference stays where it is.
  void movedTo(int target) {
    _expectedPosition = target;
  }

  /// Measure from the next reading.
  void forgetReference() {
    _reference = null;
  }

  void _takeReference(double temperature, int position) {
    _reference = FocusReference(
      temperature: temperature,
      position: position,
      takenAt: DateTime.now(),
    );
    _expectedPosition = position;
  }
}

/// The temperature and position compensation measures from.
class FocusReference {
  const FocusReference({
    required this.temperature,
    required this.position,
    required this.takenAt,
  });

  final double temperature;
  final int position;
  final DateTime takenAt;
}

sealed class CompensationStep {
  const CompensationStep();
}

/// Measure from this reading on. [movedFrom] is where the focuser was
/// expected when something else moved it.
final class TakeReference extends CompensationStep {
  const TakeReference({this.movedFrom});

  final int? movedFrom;
}

/// Nothing worth a move is owed.
final class Hold extends CompensationStep {
  const Hold();
}

final class Move extends CompensationStep {
  const Move({
    required this.target,
    required this.owed,
    required this.degreesSinceReference,
  });

  final int target;
  final int owed;
  final double degreesSinceReference;
}

/// The correction would put the focuser below zero.
final class Refuse extends CompensationStep {
  const Refuse({required this.target});

  final int target;
}
