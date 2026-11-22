// Renders the subtitle line for a device card. When the device is in error
// state it surfaces a plain-language headline from the connection-
// troubleshooter classifier (the one ConnectionTroubleshooterDialog uses), so
// the card and the dialog give the same guidance, with the FULL raw driver
// message carried verbatim in a tooltip. Otherwise it renders the card's
// descriptive subtitle.

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../localization/skotiq_localizations.dart';

class DeviceErrorSubtitle extends StatelessWidget {
  /// The descriptive subtitle the card normally shows (device name,
  /// short purpose blurb, etc.). Rendered verbatim when the device is
  /// not in an error state.
  final String descriptiveSubtitle;

  /// Whether the owning device is currently in
  /// `DeviceConnectionState.error`.
  final bool isError;

  /// The raw driver error message — typically
  /// `state.lastError?.message`. When null/empty, the widget falls
  /// back to [descriptiveSubtitle] even if [isError] is true.
  final String? errorMessage;

  /// The kind of device this card represents. Feeds the troubleshooter
  /// classifier so the inline headline and remediation guidance are
  /// hardware-aware (e.g. "camera" vs "mount").
  final DeviceType deviceType;

  /// The driver protocol in use (ASCOM / Alpaca / INDI / native /
  /// simulator). Feeds the troubleshooter classifier so a network error
  /// only routes to a network playbook for remote protocols, etc.
  final DriverType driverType;

  /// Optional callback that, when provided AND the device is in an error
  /// state with a real message, renders a small trailing ghost "Diagnose"
  /// button after the headline. The parent wires this to open
  /// `ConnectionTroubleshooterDialog`. When `null`, no button is shown.
  final VoidCallback? onDiagnose;

  final SkotiqColors colors;

  const DeviceErrorSubtitle({
    super.key,
    required this.descriptiveSubtitle,
    required this.isError,
    required this.errorMessage,
    required this.deviceType,
    required this.driverType,
    required this.colors,
    this.onDiagnose,
  });

  @override
  Widget build(BuildContext context) {
    final raw = errorMessage?.trim();
    if (isError && raw != null && raw.isNotEmpty) {
      // Same classifier that powers the full troubleshooter dialog. The raw
      // string is carried through into the diagnosis verbatim, so the tooltip
      // can surface it untouched.
      final diagnosis = diagnoseConnectionFailure(
        deviceType: deviceType,
        driverType: driverType,
        rawError: raw,
      );

      return Tooltip(
        // Never lose the raw text — the untouched driver message is the audit
        // trail and what a user shares with support.
        message: raw,
        waitDuration: const Duration(milliseconds: 250),
        child: Row(
          children: [
            Icon(
              LucideIcons.alertCircle,
              size: SkotiqTokens.iconXs,
              color: colors.error,
            ),
            const SizedBox(width: SkotiqTokens.spaceXs),
            Flexible(
              child: Text(
                diagnosis.headline,
                style: SkotiqTypography.captionSm.copyWith(
                  color: colors.error,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (onDiagnose != null) ...[
              const SizedBox(width: SkotiqTokens.spaceXs),
              SkotiqButton(
                label: context.l10n.text('diagnose'),
                icon: LucideIcons.stethoscope,
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
                onPressed: onDiagnose,
              ),
            ],
          ],
        ),
      );
    }
    return Text(
      descriptiveSubtitle,
      style: SkotiqTypography.captionSm.copyWith(
        color: colors.textMuted,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
