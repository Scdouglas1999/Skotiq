import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

import '../../localization/skotiq_localizations.dart';
import '../../utils/snackbar_helper.dart';

part 'pairing_screen_parts/_notifier.dart';
part 'pairing_screen_parts/_dialogs_and_banners.dart';

/// Pairing screen for managing remote connections
class PairingScreen extends ConsumerWidget {
  const PairingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(pairingProvider);
    final l10n = context.l10n;

    return Scaffold(
      backgroundColor: SkotiqColors.of(context).background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // One 56px page header instead of a Material AppBar (04 §4): the
            // route is pushed from Remote access, so the screen's identity is
            // the title and the thing it belongs to is the context line.
            PageHeader(
              icon: SkotiqIcons.link,
              title: l10n.text('pairingTitle'),
              context: l10n.text('pairingContext'),
              actions: <Widget>[
                // The framework's back arrow carries a tooltip and no
                // accessible NAME — read off the live tree, the only way off
                // this page was an unnamed button. SkotiqIconButton
                // requires the tooltip and publishes it as the control's name,
                // so the node says what it is and how to press it.
                if (Navigator.of(context).canPop())
                  SkotiqIconButton(
                    icon: SkotiqIcons.arrowLeft,
                    tooltip: 'Back to Remote access',
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
              ],
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(SkotiqTokens.space2xl),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (state.error != null) ...[
                      _PairingErrorBanner(
                        message: state.error!,
                        onDismiss: () =>
                            ref.read(pairingProvider.notifier).clearError(),
                      ),
                      const SizedBox(height: SkotiqTokens.spaceLg),
                    ],
                    _buildPairingSection(context, ref, state),
                    // Panel gap is spaceLg (03 §3.1), not the 32 this screen
                    // used; 32 is the settings section gap, and these are two
                    // panels on one page.
                    const SizedBox(height: SkotiqTokens.spaceLg),
                    _buildPairedDevicesSection(context, ref, state),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPairingSection(
      BuildContext context, WidgetRef ref, PairingState state) {
    final l10n = context.l10n;
    final colors = SkotiqColors.of(context);
    return SkotiqPanel(
      head: PanelHead(
        icon: SkotiqIcons.link,
        label: l10n.text('pairingNewDeviceTitle'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (state.lastPairedDevice != null) ...[
            _PairedConfirmation(
              device: state.lastPairedDevice!,
              onDismiss: () =>
                  ref.read(pairingProvider.notifier).clearLastPairedDevice(),
            ),
            const SizedBox(height: SkotiqTokens.spaceLg),
          ],
          if (state.pairingCode == null) ...[
            Text(
              l10n.text('pairingStartDesc'),
              style: SkotiqTypography.bodySm
                  .copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            // The page's ONE primary, sized to its label. It was a stretched
            // full-width bar across a 1200px page — a button that wide reads
            // as a banner, and 02 rule 4 gives the page one primary, not one
            // primary per available pixel.
            SkotiqButton(
              label: l10n.text('pairingStartButton'),
              icon: SkotiqIcons.link,
              size: ButtonSize.small,
              isLoading: state.isLoading,
              onPressed: state.isLoading
                  ? null
                  : () => ref.read(pairingProvider.notifier).startPairing(),
            ),
          ] else ...[
            _buildPairingCodeDisplay(context, ref, state),
          ],
        ],
      ),
    );
  }

  Widget _buildPairingCodeDisplay(
      BuildContext context, WidgetRef ref, PairingState state) {
    final l10n = context.l10n;
    final timeRemaining = state.timeRemaining;
    final minutes = timeRemaining?.inMinutes ?? 0;
    final seconds = (timeRemaining?.inSeconds ?? 0) % 60;

    final colors = SkotiqColors.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
          // A well inside the panel — the deepest nesting the design language
          // allows (02 rule 2). It was `primaryContainer`, a Material tone
          // that has no place on the four-step tonal ladder.
          decoration: BoxDecoration(
            color: colors.well,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
          ),
          child: Column(
            children: [
              // Its own node. Bare Texts open no semantics boundary, so
              // Flutter merged this line, the expiry line and the Cancel
              // button's label into ONE node carrying the card's role: the
              // live tree read `button: Pair New Device / Enter this code on
              // your device: / Expires in 04:53 / Cancel Pairing` — a single
              // "button" whose name was four unrelated sentences.
              Semantics(
                container: true,
                child: Text(
                  l10n.text('pairingEnterCode'),
                  style: SkotiqTypography.bodySm
                      .copyWith(color: colors.textSecondary),
                ),
              ),
              const SizedBox(height: SkotiqTokens.spaceMd),
              // Named for assistive tech, not just drawn. A [SelectableText]
              // publishes its text as a semantic value; the live tree exposed
              // "Enter this code on your device:" and "Expires in 04:55" with
              // the code itself missing between them, so the only credential
              // that has to be read aloud was the only thing that could not be.
              Semantics(
                container: true,
                excludeSemantics: true,
                label: 'Pairing code: ${state.pairingCode}',
                child: SelectableText(
                  state.pairingCode!,
                  // The credential is the loudest thing in the panel: a
                  // readout, mono and tabular by construction, instead of a
                  // Material display style with an ad-hoc 'monospace' family
                  // that resolved to whatever the platform had.
                  style: SkotiqTypography.readoutLg.copyWith(
                    color: colors.textPrimary,
                    letterSpacing: SkotiqTokens.spaceXs,
                  ),
                ),
              ),
              const SizedBox(height: SkotiqTokens.spaceSm),
              // The copy control published NO accessible node at all — a bare
              // IconButton's tooltip is not a name — and pressing it changed
              // nothing the operator could see: two screenshots taken 3 s
              // apart across the click were identical. It is now a named
              // button that confirms in place.
              _CopyCodeButton(code: state.pairingCode!),
            ],
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              SkotiqIcons.timer,
              size: SkotiqTokens.iconGlyphPanelHead,
              color: colors.textMuted,
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Semantics(
              container: true,
              child: Text(
                l10n.text(
                  'pairingExpiresIn',
                  params: {
                    'minutes': minutes.toString().padLeft(2, '0'),
                    'seconds': seconds.toString().padLeft(2, '0'),
                  },
                ),
                style: SkotiqTypography.monoCaption
                    .copyWith(color: colors.textMuted),
              ),
            ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        // Sized to its label under the centred code, not stretched across the
        // panel: while a code is live this is the only control here, and a
        // full-width secondary reads as a second surface.
        Align(
          child: SkotiqButton(
            label: l10n.text('pairingCancel'),
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            isLoading: state.isLoading,
            onPressed: state.isLoading
                ? null
                : () => ref.read(pairingProvider.notifier).cancelPairing(),
          ),
        ),
      ],
    );
  }

  Widget _buildPairedDevicesSection(
      BuildContext context, WidgetRef ref, PairingState state) {
    final l10n = context.l10n;
    final colors = SkotiqColors.of(context);
    return SkotiqPanel(
      // The panel's own label row carries its actions (05 §2) instead of a
      // headlineSmall title competing with the page header.
      head: PanelHead(
        icon: SkotiqIcons.device,
        label: l10n.text('pairingDevicesTitle'),
        trailing: <Widget>[
          // Only offered when there is something to revoke: an always-present
          // "Revoke all" on an empty list is a control that cannot do
          // anything.
          if (state.pairedDevices.isNotEmpty)
            SkotiqButton(
              label: l10n.text('pairingRevokeAllButton'),
              icon: SkotiqIcons.shieldOff,
              variant: ButtonVariant.destructive,
              size: ButtonSize.small,
              onPressed: state.isLoading
                  ? null
                  : () => _showRevokeAllDialog(
                        context,
                        ref,
                        state.pairedDevices,
                      ),
            ),
          SkotiqIconButton(
            icon: SkotiqIcons.refresh,
            tooltip: l10n.text('pairingRefresh'),
            onPressed: state.isLoading
                ? null
                : () => ref.read(pairingProvider.notifier).loadPairedDevices(),
            size: IconButtonSize.sm,
          ),
        ],
      ),
      child: state.pairedDevices.isEmpty
          // The one empty-state pattern (05 §12), not a 64px icon over two
          // bare Texts. Padding is internal to EmptyState.
          ? EmptyState.compact(
              icon: SkotiqIcons.device,
              title: l10n.text('pairingNoDevices'),
              body: l10n.text('pairingNoDevicesDesc'),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (var i = 0;
                    i < state.pairedDevices.length;
                    i++) ...<Widget>[
                  // A hairline between rows, never under the last one (05 §9).
                  if (i > 0)
                    Container(height: _rowHairline, color: colors.border),
                  _buildDeviceListItem(
                    context,
                    ref,
                    state.pairedDevices[i],
                    enabled: !state.isLoading,
                  ),
                ],
              ],
            ),
    );
  }

  /// The 1px rule between paired-device rows.
  static const double _rowHairline = 1;

  Widget _buildDeviceListItem(
    BuildContext context,
    WidgetRef ref,
    PairedDevice device, {
    required bool enabled,
  }) {
    final colors = SkotiqColors.of(context);
    final statusText = _deviceStatus(device);

    return Container(
      padding: const EdgeInsets.symmetric(
        vertical: SkotiqTokens.spaceMd,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // A list row's leading icon is a 15px muted glyph (05 §9), not a
          // 44px accent tile — the tile was the loudest thing in a list whose
          // subject is the device NAME.
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
                    Expanded(
                      child: Text(
                        device.deviceName,
                        style: SkotiqTypography.bodyStrong
                            .copyWith(color: colors.textPrimary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: SkotiqTokens.spaceSm),
                    // The kit chip, not a bespoke pill: radiusFull is not on
                    // the radius scale (02 "not rounded-everything"), and the
                    // tone fill is the chip's job.
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
                      style: SkotiqTypography.labelSm
                          .copyWith(color: colors.textMuted),
                    ),
                    // What this token is allowed to DO. The host has always
                    // stored it (paired_devices.auth_grant_spec) and the list
                    // never showed it, so a row holding 'admin' looked exactly
                    // like a view-only one — and revoking is the moment you
                    // most need to know which is which.
                    _AccessBadge(grantSpec: device.authGrantSpec),
                  ],
                ),
                const SizedBox(height: SkotiqTokens.spaceSm),
                // Timestamps are muted (03 §1.1), not body-secondary: they are
                // the quietest thing in the row, under the name and the chip.
                Text(
                  context.l10n.text(
                    'pairingPairedAt',
                    params: {'time': _formatDate(context, device.pairedAt)},
                  ),
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textMuted,
                  ),
                ),
                Text(
                  device.lastConnectedAt != null
                      ? context.l10n.text(
                          'pairingLastConnected',
                          params: {
                            'time':
                                _formatDate(context, device.lastConnectedAt!),
                          },
                        )
                      // Deliberately about the RECORD, not about the device:
                      // the host only stamps this on a fresh token
                      // verification, so a device that connects every night can
                      // legitimately have no entry here.
                      : 'No connection recorded yet',
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textMuted,
                  ),
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
                    const SizedBox(width: 8),
                    Text(context.l10n.text('pairingRenameDevice')),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'revoke',
                child: Row(
                  children: [
                    const Icon(LucideIcons.ban),
                    const SizedBox(width: 8),
                    Text(context.l10n.text('pairingRevokeAccess')),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    const Icon(SkotiqIcons.delete),
                    const SizedBox(width: 8),
                    Text(context.l10n.text('pairingDeleteDevice')),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
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
            : 'Unrecognised device type ($deviceType)';
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
      variant: ButtonVariant.primary,
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
            child: AlertDialog(
              title: Text(context.l10n.text(titleKey)),
              content: Text(body),
              actions: [
                SkotiqButton(
                  label: context.l10n.text('cancel'),
                  variant: ButtonVariant.ghost,
                  size: ButtonSize.small,
                  onPressed: busy ? null : () => Navigator.of(context).pop(),
                ),
                SkotiqButton(
                  label: context.l10n.text(confirmKey),
                  variant: variant,
                  size: ButtonSize.small,
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
          'Could not copy the code — read it off the screen instead.',
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
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        // Filled, not ghost. A ghost button paints no fill until hover, so its
        // label's contrast depends on whatever card it is dropped onto — on
        // `primaryContainer` a `textSecondary` label measures 1.15:1 and the
        // one affordance for the credential reads as disabled. A filled variant
        // carries its own background.
        SkotiqButton(
          label: label,
          icon: _copied ? SkotiqIcons.success : SkotiqIcons.copy,
          variant: ButtonVariant.primary,
          size: ButtonSize.small,
          onPressed: _copy,
        ),
      ],
    );
  }
}
