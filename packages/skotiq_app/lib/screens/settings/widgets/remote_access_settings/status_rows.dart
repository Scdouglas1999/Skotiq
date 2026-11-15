part of '../remote_access_settings.dart';

@visibleForTesting
String describeRemoteAccessPairing({
  required bool requiresAuthentication,
  String? linkedHost,
  bool? hostRequiresPairing,
}) {
  if (linkedHost != null) {
    return switch (hostRequiresPairing) {
      true => '$linkedHost serves its dashboard and this link. Every device '
          'has to pair with it before it can load data or control the rig; '
          'this computer is paired.',
      false => '$linkedHost serves its dashboard and this link. It does not '
          'ask for pairing, so anything that can reach it can control the '
          'rig.',
      null => '$linkedHost serves its dashboard and this link. It did not '
          'say whether devices have to pair with it.',
    };
  }
  if (requiresAuthentication) {
    return 'Desktop remote access serves the same dashboard locally and on '
        'your LAN. Every client has to pair before it can load data or control '
        'the app — a browser on this computer is not exempt.';
  }
  return 'Desktop remote access serves the same dashboard locally and on your '
      'LAN. Pairing is currently not required, so anything that can reach this '
      'port can control the app.';
}

/// Body for the "Open on this computer" card.
///
/// The shipped copy told the operator to use the local link "to confirm the
/// dashboard is working before sharing it elsewhere". Unpaired, that page is a
/// shell with no data, so following the instruction reads as a broken server.
@visibleForTesting
String describeLocalDashboardAction({required bool requiresAuthentication}) {
  if (requiresAuthentication) {
    return 'Opens the dashboard on this computer. This browser pairs like any '
        'other client — until it does, the page loads but stays empty.';
  }
  return 'Opens the dashboard on this computer.';
}

/// Turn a raw server startup failure into something an operator can act on.
///
/// A bare `SocketException`, clipped after two lines, hides the one detail that
/// matters: which port is taken. The raw text stays available via the row's
/// copy button — this only replaces what is *displayed*.
@visibleForTesting
String explainRemoteAccessError(String rawError, int configuredPort) {
  final lower = rawError.toLowerCase();
  if (lower.contains('address already in use') ||
      lower.contains('errno = 98') ||
      lower.contains('errno = 10048')) {
    return 'Port $configuredPort is already in use by another program. '
        'Choose a different port, or stop the program holding it.';
  }
  if (lower.contains('permission denied') || lower.contains('errno = 13')) {
    return 'The system refused to open port $configuredPort. Ports below 1024 '
        'usually need elevated privileges — pick a higher port.';
  }
  if (lower.contains('cannot assign requested address') ||
      lower.contains('errno = 99')) {
    return 'The chosen network address is not available on this machine. '
        'Switch the access scope, or reconnect the network interface.';
  }
  return rawError;
}

class _StatusRow extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String value;

  /// Raw text to put on the clipboard. When non-null a copy button is shown —
  /// used for diagnostics the operator needs to paste elsewhere.
  final String? copyValue;

  /// How many lines the value may occupy before it is ellipsised.
  final int valueMaxLines;

  const _StatusRow({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
    this.copyValue,
    this.valueMaxLines = 2,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final copyable = copyValue;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceLg,
        vertical: SkotiqTokens.spaceMd,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: iconColor),
          const SizedBox(width: 12),
          Text(
            label,
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const Spacer(),
          Flexible(
            child: SelectableText(
              value,
              maxLines: valueMaxLines,
              textAlign: TextAlign.right,
              style: SkotiqTypography.labelStrong
                  .copyWith(color: colors.textPrimary),
            ),
          ),
          if (copyable != null) ...[
            const SizedBox(width: 8),
            SkotiqIconButton(
              icon: LucideIcons.copy,
              tooltip: 'Copy the full error',
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: copyable));
                if (!context.mounted) return;
                context.showInfoSnackBar(
                  'Error copied to clipboard',
                  duration: const Duration(seconds: 2),
                );
              },
              size: IconButtonSize.sm,
              color: colors.textSecondary,
            ),
          ],
        ],
      ),
    );
  }
}
