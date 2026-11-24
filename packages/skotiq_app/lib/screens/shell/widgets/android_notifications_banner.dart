import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

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

/// Set when the operator closes the banner; it stays closed until the app
/// starts again.
final androidNotificationsBannerDismissedProvider = StateProvider<bool>(
  (_) => false,
);

/// The offer to turn on alerts, shown once the phone is linked to a rig.
///
/// The app does not ask at launch: a permission prompt before the app has
/// shown anything gives no reason to say yes. Without the permission the
/// run-failed, guiding-lost and weather alerts are dropped silently, so the
/// shell offers it here, with the reason, until it is granted or closed.
class AndroidNotificationsBanner extends ConsumerWidget {
  const AndroidNotificationsBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authorized = ref.watch(androidNotificationsAuthorizedProvider);
    final dismissed = ref.watch(androidNotificationsBannerDismissedProvider);
    if (authorized || dismissed) return const SizedBox.shrink();
    final request = ref.watch(androidNotificationsRequestProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SkotiqTokens.spaceSm,
        SkotiqTokens.spaceXs,
        SkotiqTokens.spaceSm,
        0,
      ),
      child: SkotiqBanner(
        tone: BannerTone.warning,
        icon: Icons.notifications_off_outlined,
        title: 'Alerts are off.',
        message: 'Turn them on to hear if the run stops, guiding is lost or '
            'clouds arrive.',
        action: request == null
            ? null
            : SkotiqButton(
                label: 'Turn on',
                size: ButtonSize.small,
                onPressed: () async {
                  final granted = await request();
                  ref
                      .read(androidNotificationsAuthorizedProvider.notifier)
                      .state = granted;
                },
              ),
        onDismiss: () => ref
            .read(androidNotificationsBannerDismissedProvider.notifier)
            .state = true,
      ),
    );
  }
}
