import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Whether Android lets Skotiq post notifications (`POST_NOTIFICATIONS`,
/// a runtime permission from Android 13).
///
/// Defaults to `true` so nothing shows until the mobile app has read the
/// real state.
final androidNotificationsAuthorizedProvider = StateProvider<bool>((_) => true);

/// Asks Android for the permission, or opens the app's notification settings
/// once Android no longer shows the prompt. Returns whether it is granted.
/// The mobile app supplies it; null elsewhere.
final androidNotificationsRequestProvider =
    Provider<Future<bool> Function()?>((_) => null);

/// Ask for the alert permission and keep what Android answered. Does nothing
/// where the app cannot ask.
Future<void> requestAndroidAlerts(WidgetRef ref) async {
  final request = ref.read(androidNotificationsRequestProvider);
  if (request == null) return;
  final granted = await request();
  ref.read(androidNotificationsAuthorizedProvider.notifier).state = granted;
}
