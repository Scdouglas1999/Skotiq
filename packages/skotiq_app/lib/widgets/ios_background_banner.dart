import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Set true while a sequence is running on iOS so the UI displays the
/// "honest banner" advisory. Mobile code drives this; desktop
/// builds never flip it.
final iosBackgroundBannerProvider = StateProvider<bool>((_) => false);

/// True when the user has granted the iOS Critical Alerts authorization
/// (i.e. `UNAuthorizationOptions.criticalAlert` is in the granted set).
/// Mobile code refreshes this from `flutter_local_notifications`'
/// `checkPermissions()` after [iosBackgroundBannerProvider] flips on, so
/// the banner can soften its warning when safety alerts will in fact wake
/// the device. Desktop builds never flip this.
final iosCriticalAlertsAuthorizedProvider = StateProvider<bool>((_) => false);

/// Persistent advisory shown across all screens while a sequence runs on
/// iOS. iOS suspends the app within minutes of backgrounding and we don't
/// declare `UIBackgroundModes`, so general monitoring stops if the user
/// switches apps. Safety alerts (weather unsafe, mount runaway, guide-loss,
/// equipment disconnect) are emitted through Critical Alerts which bypass
/// Do Not Disturb when the entitlement is granted — but if the user has
/// denied that permission (or the build does not carry the entitlement)
/// then nothing will wake the device. The banner copy reflects which of
/// those two cases applies.
class IosBackgroundBanner extends ConsumerWidget {
  const IosBackgroundBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final visible = ref.watch(iosBackgroundBannerProvider);
    if (!visible) return const SizedBox.shrink();

    final criticalAlertsOn = ref.watch(iosCriticalAlertsAuthorizedProvider);

    final colors = SkotiqColors.of(context);
    final warningColor = colors.warning;
    final onWarning = colors.background;

    final message = criticalAlertsOn
        ? 'iOS pauses live monitoring while this app is in the background, '
            'but critical safety alerts (weather unsafe, guide loss, mount '
            'parked, equipment disconnect) will still wake your device.'
        : 'iOS may pause monitoring while this app is in the background, '
            'and Critical Alerts are not granted — safety alerts may be '
            'silenced by Focus or the ringer switch. Keep the app in the '
            'foreground or grant Critical Alerts in Settings.';

    return SafeArea(
      bottom: false,
      child: Material(
        color: warningColor,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.info_outline, size: 18, color: onWarning),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
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
