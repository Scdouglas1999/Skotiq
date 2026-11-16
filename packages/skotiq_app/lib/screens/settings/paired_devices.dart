import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

import '../../localization/skotiq_localizations.dart';
import '../../utils/snackbar_helper.dart';
import 'widgets/settings_widgets.dart';

part 'paired_devices_parts/_notifier.dart';
part 'paired_devices_parts/_dialogs_and_banners.dart';

/// Settings > Remote access, "Pair a device" and "Paired devices": the code
/// that lets a phone, tablet or browser in, and the devices already let in.
class PairingSettings extends ConsumerWidget {
  const PairingSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(pairingProvider);
    final webState = ref.watch(webServerStateProvider);
    final l10n = context.l10n;
    final notifier = ref.read(pairingProvider.notifier);
    final fingerprint = webState.serverFingerprint;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSection(
          title: 'Pair a device',
          children: [
            if (state.error case final error?)
              SettingsItem(
                child: SkotiqBanner(
                  tone: BannerTone.error,
                  title: l10n.text(error),
                  onDismiss: notifier.clearError,
                ),
              ),
            if (state.lastPairedDevice case final device?)
              SettingsItem(
                child: SkotiqBanner(
                  tone: BannerTone.success,
                  title: '${device.deviceName} paired',
                  onDismiss: notifier.clearLastPairedDevice,
                ),
              ),
            if (state.pairingCode case final code?)
              SettingsItem(
                child: _PairingCodePanel(
                  code: code,
                  timeRemaining: state.timeRemaining,
                  webState: webState,
                  appVersion: ref.watch(appVersionProvider).version,
                  busy: state.isLoading,
                  onStop: notifier.cancelPairing,
                ),
              )
            else
              SettingRow(
                icon: SkotiqIcons.link,
                title: 'Pair a phone, tablet or browser',
                subtitle: l10n.text('pairingStartDesc'),
                trailing: SkotiqButton(
                  label: l10n.text('pairingStartButton'),
                  icon: SkotiqIcons.link,
                  variant: ButtonVariant.secondary,
                  size: ButtonSize.small,
                  isLoading: state.isLoading,
                  onPressed: state.isLoading ? null : notifier.startPairing,
                ),
              ),
            if (fingerprint.isNotEmpty)
              SettingRow(
                icon: LucideIcons.fingerprint,
                title: l10n.text('remoteAccessFingerprint'),
                subtitle: 'The phone shows it too. Check that they match '
                    'before you connect.',
                trailing: SelectableText(
                  shortServerFingerprint(fingerprint),
                  style: SkotiqTypography.readoutSm.copyWith(
                    color: SkotiqColors.of(context).textPrimary,
                  ),
                ),
              ),
          ],
        ),
        _PairedDevicesSection(state: state),
      ],
    );
  }
}

/// A live pairing code: the QR a phone scans, the code a browser asks for,
/// how long it lasts, and the ways to copy it or stop.
class _PairingCodePanel extends StatelessWidget {
  const _PairingCodePanel({
    required this.code,
    required this.timeRemaining,
    required this.webState,
    required this.appVersion,
    required this.busy,
    required this.onStop,
  });

  final String code;
  final Duration? timeRemaining;
  final WebServerState webState;
  final String appVersion;
  final bool busy;
  final VoidCallback onStop;

  static const double _qrSize = 168;

  /// The QR a phone scans, or null when this computer has no LAN address
  /// to put in it: a phone cannot reach the computer's loopback.
  String? get _qrPayload {
    final host = webState.localIp;
    if (!webState.isRunning ||
        host.isEmpty ||
        host == 'localhost' ||
        host == '127.0.0.1') {
      return null;
    }
    return EnhancedSkotiqDiscovery.generateQrData(
      host: host,
      webPort: webState.actualPort,
      version: appVersion,
      fingerprint: webState.serverFingerprint,
      serverName: 'Skotiq',
      mode: 'desktop',
      authRequired: webState.requiresAuthentication,
      authenticationMode: webState.requiresAuthentication ? 'token' : 'none',
      pairingSupported: true,
      pairingCode: code,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = SkotiqColors.of(context);
    final remaining = timeRemaining;
    final expired = remaining != null && remaining <= Duration.zero;
    final qr = _qrPayload;

    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // Its own node, so the instruction, the code and the expiry are
        // three things to a screen reader and not one run-on button name.
        Semantics(
          container: true,
          child: Text(
            qr == null
                ? l10n.text('pairingEnterCode')
                : 'Scan the QR code with the Skotiq app, or enter this code:',
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textSecondary,
            ),
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        // The code is named for assistive tech: a SelectableText publishes
        // its text as a value, not a name, and the code is the one thing
        // that has to be read aloud.
        Semantics(
          container: true,
          excludeSemantics: true,
          label: 'Pairing code: $code',
          // One line at any width: a code broken at its hyphens reads as
          // two codes.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: SelectableText(
              code,
              maxLines: 1,
              style: SkotiqTypography.readoutLg.copyWith(
                color: colors.textPrimary,
                letterSpacing: SkotiqTokens.spaceXs,
              ),
            ),
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        Semantics(
          container: true,
          child: Text(
            remaining == null
                ? 'Works for a few minutes.'
                : l10n.text(
                    'pairingExpiresIn',
                    params: {
                      'minutes': remaining.inMinutes.toString().padLeft(2, '0'),
                      'seconds':
                          (remaining.inSeconds % 60).toString().padLeft(2, '0'),
                    },
                  ),
            style: SkotiqTypography.monoCaption.copyWith(
              color: expired ? colors.warning : colors.textMuted,
            ),
          ),
        ),
        if (webState.isRunning && qr == null) ...[
          const SizedBox(height: SkotiqTokens.spaceSm),
          Text(
            l10n.text('remoteAccessQrNoLanIp'),
            style: SkotiqTypography.bodySm.copyWith(color: colors.warning),
          ),
        ],
        const SizedBox(height: SkotiqTokens.spaceMd),
        Wrap(
          spacing: SkotiqTokens.spaceSm,
          runSpacing: SkotiqTokens.spaceSm,
          children: [
            _CopyCodeButton(code: code),
            SkotiqButton(
              label: l10n.text('pairingCancel'),
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              isLoading: busy,
              onPressed: busy ? null : onStop,
            ),
          ],
        ),
      ],
    );

    if (qr == null) return details;
    final qrImage = QrImageView(
      data: qr,
      size: _qrSize,
      backgroundColor: ImageOverlayColors.foreground,
      semanticsLabel:
          'Skotiq pairing QR for ${webState.localIp}:${webState.actualPort}',
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < _qrSize * 2.5) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              qrImage,
              const SizedBox(height: SkotiqTokens.spaceLg),
              details,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            qrImage,
            const SizedBox(width: SkotiqTokens.space2xl),
            Expanded(child: details),
          ],
        );
      },
    );
  }
}

/// The "Paired devices" group: every device let in, what it may do, when it
/// was last seen, and the way to rename, revoke or delete it.
class _PairedDevicesSection extends ConsumerWidget {
  const _PairedDevicesSection({required this.state});

  final PairingState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return SettingsSection(
      title: l10n.text('pairingDevicesTitle'),
      trailing: [
        // Only offered when there is something to revoke.
        if (state.pairedDevices.isNotEmpty)
          SkotiqButton(
            label: l10n.text('pairingRevokeAllButton'),
            icon: SkotiqIcons.shieldOff,
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
            onPressed: state.isLoading
                ? null
                : () => _showRevokeAllDialog(context, ref, state.pairedDevices),
          ),
        SkotiqIconButton(
          icon: SkotiqIcons.refresh,
          tooltip: l10n.text('pairingRefresh'),
          size: IconButtonSize.sm,
          onPressed: state.isLoading
              ? null
              : () => ref.read(pairingProvider.notifier).loadPairedDevices(),
        ),
      ],
      children: [
        if (state.pairedDevices.isEmpty)
          SettingsItem(
            child: EmptyState.compact(
              icon: SkotiqIcons.device,
              title: l10n.text('pairingNoDevices'),
              body: l10n.text('pairingNoDevicesDesc'),
            ),
          )
        else
          for (final device in state.pairedDevices)
            SettingsItem(
              child: _buildDeviceListItem(
                context,
                ref,
                device,
                enabled: !state.isLoading,
              ),
            ),
      ],
    );
  }

  Widget _buildDeviceListItem(
    BuildContext context,
    WidgetRef ref,
    PairedDevice device, {
    required bool enabled,
  }) {
    final colors = SkotiqColors.of(context);
    final statusText = _deviceStatus(device);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: SkotiqTokens.spaceXs / 2),
          child: Icon(
            _getDeviceIcon(device.deviceType),
            size: SkotiqTokens.iconGlyphPanelHead,
            color: colors.textMuted,
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceMd),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      device.deviceName,
                      style: SkotiqTypography.bodyStrong
                          .copyWith(color: colors.textPrimary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  SkotiqChip(
                    label: statusText,
                    tone: _deviceStatusTone(device),
                    dot: true,
                  ),
                ],
              ),
              const SizedBox(height: SkotiqTokens.spaceXs),
              Wrap(
                spacing: SkotiqTokens.spaceSm,
                runSpacing: SkotiqTokens.spaceXs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    _deviceTypeLabel(device.deviceType),
                    style: SkotiqTypography.bodySm
                        .copyWith(color: colors.textMuted),
                  ),
                  // What this token may do: revoking is the moment it
                  // matters which row holds full access.
                  _AccessBadge(grantSpec: device.authGrantSpec),
                ],
              ),
              const SizedBox(height: SkotiqTokens.spaceXs),
              Text(
                [
                  context.l10n.text(
                    'pairingPairedAt',
                    params: {'time': _formatDate(context, device.pairedAt)},
                  ),
                  if (device.lastConnectedAt case final seen?)
                    context.l10n.text(
                      'pairingLastConnected',
                      params: {'time': _formatDate(context, seen)},
                    )
                  else
                    // About the record, not the device: the host stamps this
                    // only on a fresh token check, so a device that connects
                    // every night can have no entry.
                    'No connection recorded yet',
                ].join(' · '),
                style:
                    SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
              ),
            ],
          ),
        ),
        PopupMenuButton<String>(
          enabled: enabled,
          tooltip: 'Device actions',
          icon: Icon(
            SkotiqIcons.more,
            size: SkotiqTokens.iconGlyphPanelHead,
            color: colors.textMuted,
          ),
          onSelected: (value) {
            if (value == 'rename') {
              _showRenameDialog(context, ref, device);
            } else if (value == 'revoke') {
              _showRevokeDialog(context, ref, device);
            } else if (value == 'delete') {
              _showDeleteDialog(context, ref, device);
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'rename',
              child: Row(
                children: [
                  const Icon(LucideIcons.pencil),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  Text(context.l10n.text('pairingRenameDevice')),
                ],
              ),
            ),
            PopupMenuItem(
              value: 'revoke',
              child: Row(
                children: [
                  const Icon(LucideIcons.ban),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  Text(context.l10n.text('pairingRevokeAccess')),
                ],
              ),
            ),
            PopupMenuItem(
              value: 'delete',
              child: Row(
                children: [
                  const Icon(SkotiqIcons.delete),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  Text(context.l10n.text('pairingDeleteDevice')),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  // The primary pairing path (mobile_pairing_service.pairWithCode) sends
  // `defaultTargetPlatform.name`, so real rows carry 'android' / 'iOS' /
  // 'windows' / 'macOS' / 'linux'. Only the lanClaim fallback sends 'mobile'.
  IconData _getDeviceIcon(String deviceType) {
    switch (deviceType.toLowerCase()) {
      case 'mobile':
      case 'android':
      case 'ios':
        return SkotiqIcons.phone;
      case 'tablet':
        return LucideIcons.tablet;
      case 'desktop':
      case 'windows':
      case 'macos':
      case 'linux':
        return SkotiqIcons.device;
      case 'browser':
      case 'web':
        return LucideIcons.globe;
      default:
        return SkotiqIcons.device;
    }
  }

  String _deviceTypeLabel(String deviceType) {
    switch (deviceType.toLowerCase()) {
      case 'mobile':
        return 'Phone';
      case 'android':
        return 'Android phone or tablet';
      case 'ios':
        return 'iPhone or iPad';
      case 'tablet':
        return 'Tablet';
      case 'desktop':
        return 'Computer';
      case 'windows':
        return 'Windows computer';
      case 'macos':
        return 'Mac';
      case 'linux':
        return 'Linux computer';
      case 'browser':
      case 'web':
        return 'Browser';
      default:
        // Say we do not recognise it rather than asserting a category.
        return deviceType.trim().isEmpty
            ? 'Unknown device type'
            : 'Unrecognized device type ($deviceType)';
    }
  }

  String _deviceStatus(PairedDevice device) {
    if (!device.isActive) {
      return 'Revoked';
    }
    if (device.lastConnectedAt == null) {
      // A stale pairing row is not an invitation. "Ready to connect" was a
      // promise the app cannot make — it has never recorded this device
      // connecting, and it has no idea whether the device still exists.
      return 'Not seen yet';
    }
    final difference = DateTime.now().difference(device.lastConnectedAt!);
    if (difference.inHours < 24) {
      return 'Seen recently';
    }
    return 'Trusted';
  }

  /// The chip tone for a device's status.
  ///
  /// Neutral, not the accent, for a device that has never been seen: nothing
  /// about that row is a positive signal, and a blue badge read as "this
  /// device is good to go".
  ChipTone _deviceStatusTone(PairedDevice device) {
    if (!device.isActive) {
      return ChipTone.error;
    }
    if (device.lastConnectedAt == null) {
      return ChipTone.neutral;
    }
    final difference = DateTime.now().difference(device.lastConnectedAt!);
    if (difference.inHours < 24) {
      return ChipTone.success;
    }
    return ChipTone.neutral;
  }

  String _formatDate(BuildContext context, DateTime date) {
    final l10n = context.l10n;
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inDays == 0) {
      if (difference.inHours == 0) {
        if (difference.inMinutes == 0) {
          return l10n.text('pairingJustNow');
        }
        return l10n.text(
          'pairingMinutesAgo',
          params: {'count': difference.inMinutes.toString()},
        );
      }
      return l10n.text(
        'pairingHoursAgo',
        params: {'count': difference.inHours.toString()},
      );
    } else if (difference.inDays < 7) {
      return l10n.text(
        'pairingDaysAgo',
        params: {'count': difference.inDays.toString()},
      );
    } else {
      return '${date.month}/${date.day}/${date.year}';
    }
  }

  void _showRenameDialog(
      BuildContext context, WidgetRef ref, PairedDevice device) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => _RenameDeviceDialog(
        device: device,
        onSubmit: (name) => ref
            .read(pairingProvider.notifier)
            .renameDevice(device.deviceId, name),
      ),
    );
  }

  void _showRevokeDialog(
      BuildContext context, WidgetRef ref, PairedDevice device) {
    _showDeviceActionDialog(
      context,
      titleKey: 'pairingRevokeTitle',
      bodyKey: 'pairingRevokeBody',
      confirmKey: 'pairingRevokeAccess',
      errorKey: 'pairingErrorRevoke',
      device: device,
      variant: ButtonVariant.destructive,
      action: () =>
          ref.read(pairingProvider.notifier).revokeDevice(device.deviceId),
    );
  }

  void _showDeleteDialog(
      BuildContext context, WidgetRef ref, PairedDevice device) {
    _showDeviceActionDialog(
      context,
      titleKey: 'pairingDeleteTitle',
      bodyKey: 'pairingDeleteBody',
      confirmKey: 'pairingDeleteDevice',
      errorKey: 'pairingErrorDelete',
      device: device,
      variant: ButtonVariant.destructive,
      action: () =>
          ref.read(pairingProvider.notifier).deleteDevice(device.deviceId),
    );
  }

  /// Revoke every paired device, after saying how many that is.
  ///
  /// The count is the whole point of the confirmation: the list is scrollable
  /// and inherited stores run to a dozen rows, so "revoke all" without a
  /// number is asking the operator to agree to something they cannot see.
  ///
  /// With exactly one device there is no "all" and no plural — the page said
  /// "Revoke access for all 1 paired devices?" — so the single-device wording
  /// is used, naming the device instead of counting it.
  void _showRevokeAllDialog(
    BuildContext context,
    WidgetRef ref,
    List<PairedDevice> devices,
  ) {
    final single = devices.length == 1 ? devices.single : null;
    _showConfirmDialog(
      context,
      titleKey: single != null ? 'pairingRevokeTitle' : 'pairingRevokeAllTitle',
      body: single != null
          ? context.l10n
              .text('pairingRevokeBody', params: {'name': single.deviceName})
          : context.l10n.text(
              'pairingRevokeAllBody',
              params: {'count': devices.length.toString()},
            ),
      confirmKey:
          single != null ? 'pairingRevokeAccess' : 'pairingRevokeAllConfirm',
      errorKey: 'pairingErrorRevokeAll',
      variant: ButtonVariant.destructive,
      action: () => ref.read(pairingProvider.notifier).revokeAll(),
    );
  }

  void _showDeviceActionDialog(
    BuildContext context, {
    required String titleKey,
    required String bodyKey,
    required String confirmKey,
    required String errorKey,
    required PairedDevice device,
    required ButtonVariant variant,
    required Future<bool> Function() action,
  }) {
    _showConfirmDialog(
      context,
      titleKey: titleKey,
      body: context.l10n.text(bodyKey, params: {'name': device.deviceName}),
      confirmKey: confirmKey,
      errorKey: errorKey,
      variant: variant,
      action: action,
    );
  }

  void _showConfirmDialog(
    BuildContext context, {
    required String titleKey,
    required String body,
    required String confirmKey,
    required String errorKey,
    required ButtonVariant variant,
    required Future<bool> Function() action,
  }) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        var busy = false;
        return StatefulBuilder(
          builder: (context, setDialogState) => PopScope(
            canPop: !busy,
            child: SkotiqDialog(
              title: context.l10n.text(titleKey),
              width: SkotiqDialog.widthConfirm,
              closeEnabled: !busy,
              onClose: () => Navigator.of(context).pop(),
              actions: [
                SkotiqButton(
                  label: context.l10n.text('cancel'),
                  variant: ButtonVariant.ghost,
                  onPressed: busy ? null : () => Navigator.of(context).pop(),
                ),
                SkotiqButton(
                  label: context.l10n.text(confirmKey),
                  variant: variant,
                  isLoading: busy,
                  onPressed: busy
                      ? null
                      : () async {
                          setDialogState(() => busy = true);
                          final succeeded = await action();
                          if (!dialogContext.mounted) return;
                          if (succeeded) {
                            Navigator.of(dialogContext).pop();
                            return;
                          }
                          setDialogState(() => busy = false);
                          dialogContext.showErrorSnackBar(
                            dialogContext.l10n.text(errorKey),
                          );
                        },
                ),
              ],
              child: Text(
                body,
                style: SkotiqTypography.body.copyWith(
                  color: SkotiqColors.of(context).textSecondary,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Copy-the-pairing-code control.
///
/// A named button (so assistive tech can find and press it) that acknowledges
/// itself where the operator is looking: the label swaps to "Copied" for a few
/// seconds. The snack bar stays for the screen-reader announcement, but it is
/// not the only feedback.
class _CopyCodeButton extends StatefulWidget {
  const _CopyCodeButton({required this.code});

  final String code;

  @override
  State<_CopyCodeButton> createState() => _CopyCodeButtonState();
}

class _CopyCodeButtonState extends State<_CopyCodeButton> {
  static const Duration _confirmFor = Duration(seconds: 3);
  Timer? _resetTimer;
  bool _copied = false;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  void _copy() {
    // The confirmation is NOT gated on the platform round-trip. Awaiting
    // `Clipboard.setData` before touching the UI is why the click looked dead:
    // where the channel does not answer, the label never changed and no snack
    // bar was ever posted. Acknowledge the press, then correct the record if
    // the write actually fails.
    setState(() => _copied = true);
    _resetTimer?.cancel();
    _resetTimer = Timer(_confirmFor, () {
      if (mounted) setState(() => _copied = false);
    });
    context.showSuccessSnackBar(context.l10n.text('pairingCodeCopied'));

    unawaited(
      Clipboard.setData(ClipboardData(text: widget.code)).catchError((_) {
        if (!mounted) return;
        setState(() => _copied = false);
        context.showErrorSnackBar(
          'Could not copy the code. Read it off the screen instead.',
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final label =
        _copied ? l10n.text('pairingCodeCopied') : l10n.text('pairingCopyCode');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Secondary, not ghost: a ghost button paints no fill until hover,
        // and this is the one control for the credential.
        SkotiqButton(
          label: label,
          icon: _copied ? SkotiqIcons.success : SkotiqIcons.copy,
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: _copy,
        ),
      ],
    );
  }
}
