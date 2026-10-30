part of '../remote_access_settings.dart';

class _RemotePairingQrPanel extends StatelessWidget {
  final WebServerState webState;
  final String? pairingCode;
  final Duration? timeRemaining;
  final String appVersion;
  final VoidCallback? onStartPairing;
  final VoidCallback? onStopPairing;

  const _RemotePairingQrPanel({
    required this.webState,
    required this.pairingCode,
    required this.appVersion,
    this.timeRemaining,
    this.onStartPairing,
    this.onStopPairing,
  });

  /// `mm:ss` left on the outstanding code, or null when there is no expiry to
  /// report.
  static String? _countdown(Duration? remaining) {
    if (remaining == null) return null;
    final minutes = remaining.inMinutes;
    final seconds = remaining.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final l10n = context.l10n;
    // Never embed localhost in QR — tablets cannot reach the PC loopback.
    final host = webState.localIp.isNotEmpty &&
            webState.localIp != 'localhost' &&
            webState.localIp != '127.0.0.1'
        ? webState.localIp
        : '';
    final qrPayload = host.isEmpty
        ? null
        : EnhancedSkotiqDiscovery.generateQrData(
            host: host,
            webPort: webState.actualPort,
            version: appVersion,
            fingerprint: webState.serverFingerprint,
            serverName: 'Skotiq',
            mode: 'desktop',
            authRequired: webState.requiresAuthentication,
            authenticationMode:
                webState.requiresAuthentication ? 'token' : 'none',
            pairingSupported: true,
            pairingCode: pairingCode,
          );
    final countdown = _countdown(timeRemaining);
    final expired = timeRemaining != null && timeRemaining! <= Duration.zero;

    return Container(
      // Full width, like every other card on this leaf. Sized to its content
      // this card drew ~530 px in a ~1150 px column while idle and then snapped
      // to full width the moment pairing started — the QR's [Center] is what
      // was stretching it — so the page reflowed under the operator at exactly
      // the moment they were reading a credential off it.
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.text('remoteAccessQrTitle'),
            style: SkotiqTypography.labelStrong
                .copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: 6),
          Text(
            l10n.text('remoteAccessQrBody'),
            style: SkotiqTypography.caption.copyWith(
              color: colors.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 8),
          SelectableText(
            '${l10n.text('remoteAccessFingerprint')}: '
            '${shortServerFingerprint(webState.serverFingerprint)}',
            style: SkotiqTypography.readoutXs.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          if (pairingCode == null && onStartPairing != null) ...[
            SkotiqButton(
              label: l10n.text('pairingStartButton'),
              icon: LucideIcons.link,
              variant: ButtonVariant.primary,
              size: ButtonSize.small,
              onPressed: onStartPairing,
            ),
            const SizedBox(height: 8),
            Text(
              l10n.text('remoteAccessQrStartHint'),
              style: SkotiqTypography.caption.copyWith(
                color: colors.textMuted,
              ),
            ),
          ] else if (pairingCode != null) ...[
            // The card promises "a QR code and pairing phrase", and a QR alone
            // is unusable to anyone typing the code into a browser or reading
            // the screen with assistive tech — the image is the one part of
            // this panel a screen reader cannot convey. Phrase, countdown and
            // a way out are text, so all three are announced.
            if (qrPayload != null)
              Center(
                child: QrImageView(
                  data: qrPayload,
                  size: 200,
                  backgroundColor: ImageOverlayColors.foreground,
                  semanticsLabel:
                      'Skotiq pairing QR for $host:${webState.actualPort}',
                ),
              )
            else
              Text(
                l10n.text('remoteAccessQrNoLanIp'),
                style: SkotiqTypography.caption.copyWith(
                  color: colors.warning,
                ),
              ),
            const SizedBox(height: 10),
            Text(
              _l10nOr(l10n, 'remoteAccessQrPhraseLabel', 'Pairing phrase'),
              style: SkotiqTypography.caption.copyWith(
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: 4),
            // The phrase is the one credential on this panel, and a
            // [SelectableText] publishes its text as a semantic VALUE, not a
            // name: the live accessibility tree gave "panel: Pairing phrase"
            // followed by "panel: Expires in 4:49" and nothing in between — the
            // QR is an image, so a screen-reader user was told a phrase exists
            // and never told what it is. Name it explicitly.
            Semantics(
              container: true,
              excludeSemantics: true,
              label: 'Pairing phrase: $pairingCode',
              child: SelectableText(
                pairingCode!,
                style: SkotiqTypography.readoutBadge.copyWith(
                  color: colors.textPrimary,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              countdown == null
                  ? _l10nOr(
                      l10n,
                      'remoteAccessQrExpiresUnknown',
                      'This phrase expires a few minutes after it is created.',
                    )
                  : _l10nOr(
                      l10n,
                      'remoteAccessQrExpiresIn',
                      'Expires in {left}',
                      params: {'left': countdown},
                    ),
              style: SkotiqTypography.caption.copyWith(
                color: expired ? colors.warning : colors.textSecondary,
              ),
            ),
            if (onStopPairing != null) ...[
              const SizedBox(height: 10),
              SkotiqButton(
                label: _l10nOr(
                    l10n, 'remoteAccessQrStopButton', 'Stop pairing mode'),
                icon: LucideIcons.x,
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                onPressed: onStopPairing,
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// Look up a localization [key], falling back to [fallback] when the key is
/// not present in the active locale's table.
///
/// [SkotiqLocalizations.text] returns the *key itself* for an unknown key
/// (see its `?? key` tail). The Tailscale strings introduced here are new and
/// may not yet exist in every `skotiq_localizations.dart` table; routing
/// them through this helper keeps the i18n contract live — a translator who
/// adds the key later wins automatically — while guaranteeing we never render a
/// raw `remoteAccessTailscale…` identifier to the operator. [params] tokens are
/// substituted into whichever string is used.
String _l10nOr(
  SkotiqLocalizations l10n,
  String key,
  String fallback, {
  Map<String, String> params = const {},
}) {
  final resolved = l10n.text(key, params: params);
  if (resolved != key) {
    return resolved;
  }
  var value = fallback;
  params.forEach((paramKey, paramValue) {
    value = value.replaceAll('{$paramKey}', paramValue);
  });
  return value;
}
