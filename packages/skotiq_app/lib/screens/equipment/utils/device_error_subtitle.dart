// Shared widget that renders the subtitle line for
// a device card. When the device is in error state it surfaces a plain-language
// headline drawn from the connection-troubleshooter knowledge base (the same
// classifier that powers ConnectionTroubleshooterDialog), with the FULL raw
// driver message carried through verbatim in a tooltip. Otherwise it renders the
// descriptive subtitle the card normally shows.
//
// Why the troubleshooter KB instead of the older PrettyError pretty-printer:
// scope item 5 of the Onboarding & First-Light feature requires that the same
// plain-language classification used in the troubleshooter dialog also drives
// the inline subtitle, so a first-light user reads consistent guidance whether
// they glance at the card or open the full troubleshooter. PrettyError is still
// used by other surfaces (equipment_screen.dart, connect_all_summary.dart) and
// is intentionally left in place.
//
// Errors-are-a-feature: the raw driver string is never discarded. The friendly
// headline is shown inline; the untouched raw message is always reachable via
// the tooltip.
//
// This is a standalone public widget so equipment device cards can compose it
// for their subtitle line and the equipment widget tests can construct it
// directly. Its production consumer is the connected-device card
// (connected_device_card.dart, `_buildHeader`), which supplies the device's
// type/driver, its `lastError` message, the `isError` flag, and an `onDiagnose`
// callback that opens ConnectionTroubleshooterDialog.

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
// The connection-troubleshooter knowledge base is a pure, side-effect-free model
// that its owner deliberately kept out of the skotiq_core barrel (matching
// its own test suite, which imports the source path directly). We follow that
// precedent — the same pattern ConnectionTroubleshooterDialog uses (see
// connection_troubleshooter_dialog.dart:4-10).
// ignore: implementation_imports
import 'package:skotiq_core/src/models/troubleshooter/connection_diagnostic.dart';
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
