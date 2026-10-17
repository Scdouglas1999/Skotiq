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

  const CommandActionResult._({
    required this.isSuccess,
    required this.message,
    required this.feedbackType,
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
  }) : this._(
          isSuccess: false,
          message: message,
          feedbackType: feedbackType,
        );

  static const ok = CommandActionResult.success();

  bool get hasMessage => (message ?? '').trim().isNotEmpty;
}
