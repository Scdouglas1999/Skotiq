import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../localization/skotiq_localizations.dart';
import '../../../services/android_alert_permission.dart';

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
    // The device class, not the width: on its side a phone is wide but only
    // ~400 dp tall, and the long banner took a fifth of it.
    final phone = Responsive.isPhone(context);
    final l10n = context.l10n;

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
        // On a phone it shows on every screen, so it is one line there.
        title: phone ? l10n.text('alertsOff') : '${l10n.text('alertsOff')}.',
        message: phone ? null : l10n.text('alertsOffReason'),
        action: request == null
            ? null
            : SkotiqButton(
                label: l10n.text('alertsTurnOn'),
                size: ButtonSize.small,
                onPressed: () => requestAndroidAlerts(ref),
              ),
        onDismiss: () => ref
            .read(androidNotificationsBannerDismissedProvider.notifier)
            .state = true,
      ),
    );
  }
}
