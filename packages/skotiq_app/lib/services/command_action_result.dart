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

  const CommandActionResult._({
    required this.isSuccess,
    required this.message,
    required this.feedbackType,
    this.alreadyShown = false,
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

  static const ok = CommandActionResult.success();

  bool get hasMessage => (message ?? '').trim().isNotEmpty;
}
