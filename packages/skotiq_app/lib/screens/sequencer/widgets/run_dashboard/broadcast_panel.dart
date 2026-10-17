// Run-dashboard panel for the live-stacking broadcast.
//
// When a LiveStackingNode is active, this panel renders the
// "Broadcasting" indicator, a copyable broadcast URL, and a QR code
// the audience can scan with a phone. When inactive the panel
// collapses to a neutral "Not broadcasting" hint so it does not
// dominate the dashboard for users who never use the feature.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class BroadcastPanel extends ConsumerWidget {
  const BroadcastPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final svc = ref.watch(liveStackingBroadcastServiceProvider);
    // Engage the master kill switch bridge so a toggle in
    // Sequencer Settings flows live into the broadcast service.
    // Watching the bridge here is sufficient because the panel mounts
    // once the user opens the sequencer screen, which covers every
    // realistic broadcast scenario; in headless mode the bridge is
    // also watched explicitly during boot (see app shell).
    ref.watch(liveStackingKillSwitchBridgeProvider);
    final state = svc.state;
    final theme = Theme.of(context);

    if (!state.active) {
      return _InactiveCard(theme: theme);
    }
    return _ActiveCard(state: state, svc: svc, theme: theme);
  }
}

class _InactiveCard extends StatelessWidget {
  final ThemeData theme;
  const _InactiveCard({required this.theme});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Row(
          children: [
            Icon(LucideIcons.cast, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Live Stacking broadcast not active. Drop a Live Stacking '
                'node in your sequence to broadcast a building stack.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActiveCard extends StatelessWidget {
  final BroadcastSessionState state;
  final LiveStackingBroadcastService svc;
  final ThemeData theme;

  const _ActiveCard({
    required this.state,
    required this.svc,
    required this.theme,
  });

  String _resolveBroadcastBase(BuildContext context) {
    // Best-effort: the broadcast HTML page is served by the SAME
    // headless API server, so the IP comes from the existing
    // web_server_provider snapshot. The audience url is what the
    // operator hands out (network IP), not localhost.
    final web = ProviderScope.containerOf(context).read(webServerStateProvider);
    final ip = web.localIp.isNotEmpty ? web.localIp : 'localhost';
    // The broadcast lives on the headless server's port, NOT on
    // state.port (which is the user-typed metadata for the
    // LiveStackingNode — the headless server actually binds whatever
    // the user configured in app settings). Use the same port as
    // dashboard so the URL maps to the running server.
    final port = web.actualPort != 0 ? web.actualPort : state.port;
    return 'http://$ip:$port${state.path}';
  }

  @override
  Widget build(BuildContext context) {
    final base = _resolveBroadcastBase(context);
    // The on-screen URL masks the private token (…) so it never renders
    // as text, while Copy Link and the audience QR carry the real
    // tokenised URL so a private stream actually opens.
    final displayUrl = state.isPublic ? base : '$base?token=…';
    final shareUrl = state.isPublic
        ? base
        : '$base?token=${Uri.encodeQueryComponent(state.authToken ?? '')}';
    final cs = theme.colorScheme;
    final liveColor = state.isPublic ? cs.tertiary : cs.secondary;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row with live indicator + mode badges.
            Row(
              children: [
                _LiveDot(color: liveColor),
                const SizedBox(width: 8),
                Text(
                  'Broadcasting',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Chip(
                  label: Text(
                    state.isPublic ? 'Public' : 'Private',
                    style: theme.textTheme.labelSmall,
                  ),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: state.isPublic
                      ? cs.tertiaryContainer
                      : cs.secondaryContainer,
                  side: BorderSide.none,
                ),
                const SizedBox(width: 6),
                Chip(
                  label: Text(
                    state.stackMethod.label,
                    style: theme.textTheme.labelSmall,
                  ),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: cs.surfaceContainerHigh,
                  side: BorderSide.none,
                ),
              ],
            ),
            const SizedBox(height: 12),
            // URL + copy button.
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    displayUrl,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Copy URL',
                  icon: const Icon(SkotiqIcons.copy, size: 18),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: shareUrl));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Broadcast URL copied'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            // QR + stats side-by-side.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFFFFF),
                    border: Border.all(color: cs.outlineVariant),
                    borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
                  ),
                  child: _BroadcastQr(url: shareUrl, semanticsUrl: displayUrl),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _statRow(theme, 'Target', state.currentTarget ?? '—'),
                      _statRow(theme, 'Frames', state.framesStacked.toString()),
                      _statRow(theme, 'Integration', state.integrationHms),
                      _statRow(theme, 'Viewers', state.viewerCount.toString()),
                    ],
                  ),
                ),
              ],
            ),
            if (state.watermarkText != null &&
                state.watermarkText!.trim().isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                'Watermark',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              Text(
                svc.renderWatermark(),
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _statRow(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveDot extends StatefulWidget {
  final Color color;
  const _LiveDot({required this.color});

  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    // Created idle and started by the OnScreenAnimationGate in build(): a
    // repeat() that outlives visibility schedules a frame on every vsync and
    // stops the whole app from idling.
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return OnScreenAnimationGate(
      controller: _ctrl,
      repeating: true,
      reverse: true,
      child: FadeTransition(
        opacity: Tween<double>(begin: 0.45, end: 1.0).animate(_ctrl),
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: widget.color,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}

class _BroadcastQr extends StatelessWidget {
  /// Scannable payload — carries the real token for a private stream.
  final String url;

  /// Masked URL used for the accessibility label so the token is never
  /// exposed as readable text.
  final String semanticsUrl;

  const _BroadcastQr({required this.url, required this.semanticsUrl});

  @override
  Widget build(BuildContext context) {
    return QrImageView(
      data: url,
      size: 96,
      padding: const EdgeInsets.all(8),
      backgroundColor: const Color(0xFFFFFFFF),
      eyeStyle: const QrEyeStyle(
        eyeShape: QrEyeShape.square,
        color: Color(0xFF000000),
      ),
      dataModuleStyle: const QrDataModuleStyle(
        dataModuleShape: QrDataModuleShape.square,
        color: Color(0xFF000000),
      ),
      semanticsLabel: 'Broadcast QR: $semanticsUrl',
    );
  }
}
