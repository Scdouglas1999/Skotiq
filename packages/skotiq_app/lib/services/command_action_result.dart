enum CommandFeedbackType {
  error,
  warning,
  info,
  success,
}

class CommandActionResult {
  final bool isSuccess;
  final String? message;
  final CommandFeedbackType feedbackType;

  /// The message already reached the operator through the app-wide
  /// notification toasts, so a caller must not show it a second time.
  final bool alreadyShown;

  /// A manual action's release left the run paused under another pause:
  /// who paused it ([RunStillPaused.pausedBy]).
  final String? stillPausedBy;

  /// A manual action's hold ended and the run was left as it was: the hold
  /// had found it paused, or it is no longer paused.
  final bool leftPaused;

  const CommandActionResult._({
    required this.isSuccess,
    required this.message,
    required this.feedbackType,
    this.alreadyShown = false,
    this.stillPausedBy,
    this.leftPaused = false,
  });

  const CommandActionResult.success({
    String? message,
    CommandFeedbackType feedbackType = CommandFeedbackType.success,
  }) : this._(
          isSuccess: true,
          message: message,
          feedbackType: feedbackType,
        );

  const CommandActionResult.failure(
    String message, {
    CommandFeedbackType feedbackType = CommandFeedbackType.error,
    bool alreadyShown = false,
  }) : this._(
          isSuccess: false,
          message: message,
          feedbackType: feedbackType,
          alreadyShown: alreadyShown,
        );

  /// A manual action's release ended its hold, and the run stays paused
  /// because [pausedBy] paused it while the hold lasted.
  const CommandActionResult.stillPaused(String pausedBy)
      : this._(
          isSuccess: false,
          message: 'The run is still paused: $pausedBy.',
          feedbackType: CommandFeedbackType.info,
          stillPausedBy: pausedBy,
        );

  /// A manual action's hold ended and nothing was resumed: the run was not
  /// the hold's to resume.
  const CommandActionResult.leftPaused()
      : this._(
          isSuccess: true,
          message: null,
          feedbackType: CommandFeedbackType.info,
          leftPaused: true,
        );

  /// The operator answered no to a question the command asked; there is
  /// nothing more to tell them.
  const CommandActionResult.declined()
      : this._(
          isSuccess: false,
          message: null,
          feedbackType: CommandFeedbackType.info,
        );

  static const ok = CommandActionResult.success();

  bool get hasMessage => (message ?? '').trim().isNotEmpty;
}
