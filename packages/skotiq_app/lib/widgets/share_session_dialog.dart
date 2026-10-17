import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Opens the Remote Access sheet: the local and LAN URLs, the pairing state
/// and the attached-viewer count.
///
/// It used to hang off a share glyph in the status bar. The status bar reports
/// state and nothing else now (04 §5), and sharing a session is an action on
/// the remote connection, so it lives on the top bar's remote indicator, which
/// is already the control for everything else about that connection.
Future<void> showShareSessionDialog(BuildContext context) {
  final colors = SkotiqColors.of(context);
  final webState = ProviderScope.containerOf(
    context,
  ).read(webServerStateProvider);
  return showDialog<void>(
    context: context,
    builder: (context) =>
        _ShareSessionDialog(webState: webState, colors: colors),
  );
}

class _ShareSessionDialog extends ConsumerWidget {
  final WebServerState webState;
  final SkotiqColors colors;

  const _ShareSessionDialog({
    required this.webState,
    required this.colors,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentState = ref.watch(webServerStateProvider);
    final networkUrl = currentState.networkUrl;
    final hasLanAccess = networkUrl.isNotEmpty;
    final viewerLabel =
        currentState.requiresAuthentication ? 'authenticated viewer' : 'viewer';
    // Remote clients attached to this server. Reading the co-imaging viewer
    // list here made this panel say "No viewers connected" to an operator whose
    // phone was holding an authenticated event socket.
    final connected = currentState.connectedClients;

    return AlertDialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: SkotiqTokens.borderRadiusInline8,
        side: BorderSide(color: colors.border),
      ),
      title: Row(
        children: [
          Icon(SkotiqIcons.share, size: 20, color: colors.primary),
          const SizedBox(width: 10),
          Text(
            'Remote Access',
            style: TextStyle(
              color: colors.textPrimary,
              fontSize: SkotiqTypography.fontSize18,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: Responsive.dialogConstraints(
          context,
          preferredWidth: ShellChromeMetrics.shareDialogPreferredWidth,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              currentState.bindLocalOnly
                  ? 'Remote access is currently limited to this machine.'
                  : currentState.requiresAuthentication
                      ? 'Local access works immediately on this machine. Remote browsers on your LAN must pair before they can control the app.'
                      : 'Remote access is available on your local network.',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize13,
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            _UrlCard(
              label: 'Local dashboard',
              url: currentState.localUrl,
              colors: colors,
            ),
            if (hasLanAccess) ...[
              const SizedBox(height: 12),
              _UrlCard(
                label: currentState.requiresAuthentication
                    ? 'LAN endpoint (paired devices only)'
                    : 'LAN endpoint',
                url: networkUrl,
                colors: colors,
              ),
            ],
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: connected > 0
                    ? colors.success.withValues(alpha: 0.08)
                    : colors.surfaceAlt,
                borderRadius: SkotiqTokens.borderRadiusInline8,
                border: Border.all(
                  color: connected > 0
                      ? colors.success.withValues(alpha: 0.3)
                      : colors.border,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    LucideIcons.users,
                    size: 14,
                    color: connected > 0 ? colors.success : colors.textMuted,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    connected > 0
                        ? '$connected $viewerLabel${connected == 1 ? '' : 's'} connected'
                        : 'No viewers connected',
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize13,
                      color: connected > 0 ? colors.success : colors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            if (currentState.lastError.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.error.withValues(alpha: 0.08),
                  borderRadius: SkotiqTokens.borderRadiusInline8,
                  border: Border.all(
                    color: colors.error.withValues(alpha: 0.2),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      SkotiqIcons.warning,
                      size: 14,
                      color: colors.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        currentState.lastError,
                        style: TextStyle(
                          fontSize: SkotiqTypography.fontSize12,
                          color: colors.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        SkotiqButton(
          label: 'Close',
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

class _UrlCard extends StatelessWidget {
  final String label;
  final String url;
  final SkotiqColors colors;

  const _UrlCard({
    required this.label,
    required this.url,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return SkotiqCard(
      variant: CardVariant.standard,
      borderRadius: SkotiqTokens.radiusInline8,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: SkotiqTypography.labelStrongSm
                .copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(SkotiqIcons.link, size: 14, color: colors.textMuted),
              const SizedBox(width: 8),
              Expanded(
                child: SelectableText(
                  url,
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize13,
                    fontWeight: FontWeight.w500,
                    color: colors.primary,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              InkWell(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: url));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Text('Link copied to clipboard'),
                      duration: const Duration(seconds: 2),
                      behavior: SnackBarBehavior.floating,
                      backgroundColor: colors.surfaceAlt,
                    ),
                  );
                },
                borderRadius: SkotiqTokens.borderRadiusMd,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: SkotiqDecorations.tintedBadge(
                    colors.primary,
                    borderRadius: SkotiqTokens.borderRadiusMd,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        SkotiqIcons.copy,
                        size: 12,
                        color: colors.primary,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Copy',
                        style: SkotiqTypography.labelSm
                            .copyWith(color: colors.primary),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
