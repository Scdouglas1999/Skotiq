part of '../remote_access_settings.dart';

/// "Reach this rig from anywhere over Tailscale" panel.
///
/// Behaviour contract:
///   * When the desktop has a detected tailnet address AND the server is bound
///     beyond loopback ([WebServerState.tailscaleReachable]) we render a QR that
///     embeds the **tailnet** host (`100.x.y.z` / `[fd7a:115c::…]`) — never the
///     LAN address. A phone on the same tailnet (even on cellular) can scan it
///     and connect from anywhere, which is the whole point of the feature.
///   * When no tailnet address is detected we show an informational alert
///     explaining how to bring Tailscale up, a **Re-check** action that
///     re-scans the interfaces, and a **manual host** field so an operator who
///     knows their MagicDNS `100.x` address can build the QR by hand. The
///     manual host is validated as a tailnet host via [TailnetDetector] before
///     a QR is produced — a LAN/public/garbage value is refused with a clear
///     message rather than silently embedded.
///
/// This panel deliberately shares the active pairing code with the LAN QR
/// panel so a single "Start pairing" press arms both QRs at once.
class _RemoteTailscalePanel extends ConsumerStatefulWidget {
  final WebServerState webState;
  final String? pairingCode;
  final String appVersion;
  final VoidCallback? onStartPairing;
  final VoidCallback onRecheck;

  const _RemoteTailscalePanel({
    required this.webState,
    required this.pairingCode,
    required this.appVersion,
    required this.onRecheck,
    this.onStartPairing,
  });

  @override
  ConsumerState<_RemoteTailscalePanel> createState() =>
      _RemoteTailscalePanelState();
}

class _RemoteTailscalePanelState extends ConsumerState<_RemoteTailscalePanel> {
  late final TextEditingController _manualHostController;
  String _manualHost = '';

  @override
  void initState() {
    super.initState();
    _manualHostController = TextEditingController();
  }

  @override
  void dispose() {
    _manualHostController.dispose();
    super.dispose();
  }

  /// The host to embed in the Tailscale QR, or `''` when none is usable.
  ///
  /// Prefers the auto-detected tailnet address; otherwise falls back to a
  /// manually-entered host *only if* it positively classifies as a tailnet
  /// host. The LAN address is never considered here.
  String get _effectiveTailscaleHost {
    if (widget.webState.tailscaleReachable &&
        widget.webState.tailscaleIp.isNotEmpty) {
      return widget.webState.tailscaleIp;
    }
    final manual = _manualHost.trim();
    if (manual.isNotEmpty && TailnetDetector.isTailscaleHost(manual)) {
      return manual;
    }
    return '';
  }

  bool get _manualHostInvalid {
    final manual = _manualHost.trim();
    return manual.isNotEmpty && !TailnetDetector.isTailscaleHost(manual);
  }

  String? _buildQrPayload(String host) {
    if (host.isEmpty || widget.pairingCode == null) {
      return null;
    }
    // The QR carries the bare host string (the client reconstructs the URL and
    // brackets an IPv6 literal itself), so a tailnet `fd7a:…` is stored
    // unbracketed exactly as `isLocalNetworkHost` / TailnetDetector expect.
    return EnhancedSkotiqDiscovery.generateQrData(
      host: host,
      webPort: widget.webState.actualPort,
      version: widget.appVersion,
      fingerprint: widget.webState.serverFingerprint,
      serverName: 'Skotiq',
      mode: 'desktop',
      authRequired: widget.webState.requiresAuthentication,
      authenticationMode:
          widget.webState.requiresAuthentication ? 'token' : 'none',
      pairingSupported: true,
      pairingCode: widget.pairingCode,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final l10n = context.l10n;

    final host = _effectiveTailscaleHost;
    final qrPayload = _buildQrPayload(host);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.globe2, size: 16, color: colors.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _l10nOr(
                    l10n,
                    'remoteAccessTailscaleTitle',
                    'Reach this rig over Tailscale',
                  ),
                  style: SkotiqTypography.labelStrong
                      .copyWith(color: colors.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _l10nOr(
              l10n,
              'remoteAccessTailscaleBody',
              'Tailscale lets a paired phone connect from anywhere — even on '
                  'cellular — without opening ports on your router. Scan this '
                  'QR while signed in to the same tailnet.',
            ),
            style: SkotiqTypography.caption.copyWith(
              color: colors.textSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          if (widget.webState.tailscaleReachable &&
              widget.webState.tailscaleIp.isNotEmpty) ...[
            _TailscaleReachableRow(
              host: widget.webState.tailscaleIp,
              url: widget.webState.tailscaleUrl,
            ),
            const SizedBox(height: 12),
          ] else
            _TailscaleNotDetectedSection(
              manualHostController: _manualHostController,
              manualHostInvalid: _manualHostInvalid,
              onManualHostChanged: (value) =>
                  setState(() => _manualHost = value),
              onRecheck: widget.onRecheck,
            ),
          if (host.isNotEmpty) ...[
            if (widget.pairingCode == null &&
                widget.onStartPairing != null) ...[
              SkotiqButton(
                label: l10n.text('pairingStartButton'),
                icon: LucideIcons.link,
                variant: ButtonVariant.primary,
                size: ButtonSize.small,
                onPressed: widget.onStartPairing,
              ),
              const SizedBox(height: 8),
              Text(
                _l10nOr(
                  l10n,
                  'remoteAccessTailscaleStartHint',
                  'Start pairing to arm the Tailscale QR for this session.',
                ),
                style: SkotiqTypography.caption.copyWith(
                  color: colors.textMuted,
                ),
              ),
            ] else if (widget.pairingCode != null && qrPayload != null) ...[
              Center(
                child: QrImageView(
                  data: qrPayload,
                  size: 200,
                  backgroundColor: ImageOverlayColors.foreground,
                  semanticsLabel: 'Skotiq Tailscale pairing QR for '
                      '$host:${widget.webState.actualPort}',
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// Success row shown when a tailnet address is live: a status pill plus the
/// reachable URL the operator can copy/verify.
class _TailscaleReachableRow extends StatelessWidget {
  final String host;
  final String url;

  const _TailscaleReachableRow({
    required this.host,
    required this.url,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        StatusPill(
          icon: LucideIcons.checkCircle2,
          label: _l10nOr(
            l10n,
            'remoteAccessTailscaleReachable',
            'Reachable',
          ),
          value: host,
          status: StatusPillStatus.success,
        ),
        if (url.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colors.well,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
            ),
            child: SelectableText(
              url,
              style: SkotiqTypography.readoutSm.copyWith(
                color: colors.primary,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Shown when no tailnet address is detected: an info alert with a re-check
/// action, plus a manual tailnet-host entry field.
class _TailscaleNotDetectedSection extends StatelessWidget {
  final TextEditingController manualHostController;
  final bool manualHostInvalid;
  final ValueChanged<String> onManualHostChanged;
  final VoidCallback onRecheck;

  const _TailscaleNotDetectedSection({
    required this.manualHostController,
    required this.manualHostInvalid,
    required this.onManualHostChanged,
    required this.onRecheck,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SkotiqBanner(
          icon: LucideIcons.globe2,
          title: _l10nOr(
            l10n,
            'remoteAccessTailscaleNotDetectedTitle',
            'No Tailscale address detected',
          ),
          message: _l10nOr(
            l10n,
            'remoteAccessTailscaleNotDetectedBody',
            'Install Tailscale and run "tailscale up" on this computer, then '
                're-check. If your tailnet is already up you can enter this '
                'machine\'s 100.x address manually below.',
          ),
          action: SkotiqButton(
            label: _l10nOr(l10n, 'remoteAccessTailscaleRecheck', 'Re-check'),
            icon: LucideIcons.refreshCw,
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: onRecheck,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          _l10nOr(
            l10n,
            'remoteAccessTailscaleManualLabel',
            'Tailscale address (manual)',
          ),
          style: SkotiqTypography.caption
              .copyWith(fontWeight: FontWeight.w600, color: colors.textPrimary),
        ),
        const SizedBox(height: 6),
        SkotiqTextField(
          controller: manualHostController,
          hint: '100.96.0.7',
          prefixIcon: LucideIcons.globe2,
          errorText: manualHostInvalid
              ? _l10nOr(
                  l10n,
                  'remoteAccessTailscaleManualInvalid',
                  'Not a Tailscale address (must be 100.64–127.x.x or '
                      'fd7a:115c::…).',
                )
              : null,
          onChanged: onManualHostChanged,
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}
