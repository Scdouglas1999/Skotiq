/// What the guider did when a mount move this app started asked it to stop.
///
/// The rule has one owner, the host's native mount commands: a GoTo, a park
/// and a home stop a guider that is guiding first, because a guider left
/// guiding chases the move and loses its star. Guiding is not started again
/// afterwards. When the guider cannot be asked or does not stop in time, a
/// park and a home still go ahead (getting the mount safe outranks a guide
/// star) and a GoTo is refused with [GuiderNotAnsweringException] unless the
/// operator already chose to move anyway.
enum GuiderForMove {
  /// No guider was guiding.
  idle('idle'),

  /// Guiding was stopped before the move.
  stopped('stopped'),

  /// The guider did not answer and the mount moved without stopping it.
  unanswered('not_answering');

  const GuiderForMove(this.wire);

  /// The value of [responseKey] in the host's answer to a move.
  final String wire;

  /// The key a host's answer to a mount move names the guider's part under.
  static const responseKey = 'guider';

  /// The request key that lets a GoTo go ahead with the guider not answering.
  static const silentOkKey = 'guiderSilentOk';

  static GuiderForMove fromResponse(Map<String, dynamic> response) {
    final wire = response[responseKey];
    return values.firstWhere(
      (value) => value.wire == wire,
      orElse: () => throw FormatException(
        'The host did not say what the guider did for the move ($wire)',
      ),
    );
  }

  /// What to tell the operator after a [move] ("park", "home", "GoTo") that
  /// went ahead; null when there is nothing to tell.
  String? noticeFor(String move) => switch (this) {
    GuiderForMove.unanswered =>
      'The guider did not answer, so guiding was not stopped before the '
          '$move. Check the guider.',
    GuiderForMove.idle || GuiderForMove.stopped => null,
  };
}

/// A GoTo was refused because the guider did not answer when asked to stop.
/// An interactive surface asks the operator once whether to move anyway and
/// repeats the move with the guider's silence accepted.
class GuiderNotAnsweringException implements Exception {
  const GuiderNotAnsweringException([this.reason]);

  /// The host's error code for this refusal.
  static const code = 'guider_not_answering';

  /// One sentence for the operator.
  static const message =
      'The guider is not answering, so guiding could not be stopped and the '
      'mount was not moved.';

  /// The question an interactive surface asks before moving anyway.
  static const question =
      'The guider is not answering, so guiding cannot be stopped first. A '
      'guider that is still guiding will chase the move and lose its star. '
      'Move anyway?';

  /// Why the guider could not be stopped, in the device layer's words.
  final String? reason;

  @override
  String toString() => message;
}
