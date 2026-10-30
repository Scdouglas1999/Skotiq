import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// True after the mobile app has finished requesting Android notification
/// permissions and confirmed they are granted.
///
/// Defaults to `true` because a freshly constructed provider has no decision
/// yet and the banner is only useful as a POST-DENIAL nag. Mobile code flips it
/// off when `requestNotificationsPermission()` returns false on Android 13+.
final androidNotificationsAuthorizedProvider = StateProvider<bool>((_) => true);

/// Persistent advisory shown across all screens on Android when
/// `POST_NOTIFICATIONS` (Android 13+ runtime permission) is *not* granted.
///
/// Without that permission, `flutter_local_notifications` and
/// `flutter_foreground_task` silently produce nothing — no exception, no
/// log. That means sequence-failure, guiding-loss, weather-unsafe, and
/// equipment-disconnect alerts are dropped on the floor during overnight
/// sessions, and the foreground service notification that keeps the
/// process alive may also not render. This banner surfaces the gap so
/// the operator can grant the permission in system settings before
/// starting a sequence.
class AndroidNotificationsBanner extends ConsumerWidget {
  const AndroidNotificationsBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authorized = ref.watch(androidNotificationsAuthorizedProvider);
    if (authorized) return const SizedBox.shrink();

    final colors = SkotiqColors.of(context);
    final warningColor = colors.warning;
    final onWarning = colors.background;

    return SafeArea(
      bottom: false,
      child: Material(
        color: warningColor,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.notifications_off, size: 18, color: onWarning),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Notifications are disabled. Sequence failures, guiding '
                  'loss, and safety alerts will not wake you. Enable '
                  'notifications for Skotiq in System Settings → Apps '
                  '→ Skotiq → Notifications.',
                  style: TextStyle(
                    color: onWarning,
                    fontSize: SkotiqTypography.fontSize12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
