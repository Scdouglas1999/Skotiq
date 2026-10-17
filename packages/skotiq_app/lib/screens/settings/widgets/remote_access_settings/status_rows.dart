part of '../remote_access_settings.dart';

class _PairingCallout extends StatelessWidget {
  final String title;
  final String description;
  final VoidCallback onPressed;

  const _PairingCallout({
    required this.title,
    required this.description,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.well,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: SkotiqTypography.labelStrong
                      .copyWith(color: colors.textPrimary),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textSecondary,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SkotiqButton(
            label: context.l10n.text('remoteAccessManagePairing'),
            icon: LucideIcons.link,
            variant: ButtonVariant.primary,
            onPressed: onPressed,
          ),
        ],
      ),
    );
  }
}

/// Who has to pair before the dashboard will show anything.
///
/// NOT `remoteAccessInfoBody`: that string promises "Localhost stays
/// frictionless for this machine, while non-local clients must pair", and the
/// auth middleware has no loopback branch anywhere. From 127.0.0.1,
/// `/api/status`, `/api/images/recent` and `/api/auth/csrf` return the same 401
/// they return to a LAN address — only the static `/dashboard` shell is 200,
/// and it can load no data. Kept as a literal here rather than a new l10n key
/// because the translation table is owned elsewhere; lifting these two strings
/// into `translations.dart` (en + es) is tracked as a follow-up.
@visibleForTesting
String describeRemoteAccessPairing({required bool requiresAuthentication}) {
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
  final bool isLast;

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
    this.isLast = false,
    this.copyValue,
    this.valueMaxLines = 2,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final copyable = copyValue;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : Border(
                bottom: BorderSide(
                  color: colors.border.withValues(alpha: 0.5),
                ),
              ),
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
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Error copied to clipboard'),
                    duration: Duration(seconds: 2),
                  ),
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
