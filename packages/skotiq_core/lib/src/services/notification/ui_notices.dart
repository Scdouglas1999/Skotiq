/// The on-screen notices (banners and snackbars) a service raises for the
/// operator. `UiNotificationNotifier` in providers/ implements it.
abstract interface class UiNotices {
  void showInfo(
    String message, {
    String? title,
    Duration? duration,
    String? deepLink,
  });

  void showSuccess(
    String message, {
    String? title,
    Duration? duration,
    String? deepLink,
  });

  void showWarning(
    String message, {
    String? title,
    Duration? duration,
    String? deepLink,
  });

  void showError(
    String message, {
    String? title,
    Duration? duration,
    String? deepLink,
  });
}
