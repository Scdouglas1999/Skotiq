import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../services/app_update.dart';
import '../settings/widgets/update_settings.dart';

/// Opens the host's own update controls for a host this device cannot link
/// to. A provider so widget tests can watch it being asked.
final hostUpdateOpenerProvider = Provider<
    Future<void> Function(BuildContext, DiscoveredServer, String token)>(
  (_) => showHostUpdateDialog,
);

/// What to do about a host of another Skotiq release ([LinkVersionMismatch]):
/// "Update the host" when the host is the older side, "Update this app" when
/// this device is. The host's update routes are the only ones another release
/// may call, so the update runs without a link.
class LinkMismatchActions extends ConsumerStatefulWidget {
  const LinkMismatchActions({
    super.key,
    required this.host,
    required this.mismatch,
    this.authToken,
  });

  final DiscoveredServer host;
  final LinkVersionMismatch mismatch;

  /// The credential this device holds for [host], when the caller has it.
  /// Without it the remembered rig's token is used if [host] is that rig.
  final String? authToken;

  @override
  ConsumerState<LinkMismatchActions> createState() =>
      _LinkMismatchActionsState();
}

class _LinkMismatchActionsState extends ConsumerState<LinkMismatchActions> {
  String? _note;
  bool _busy = false;

  Future<String?> _tokenForHost() async {
    final given = widget.authToken ?? widget.host.authToken;
    if (given != null && given.isNotEmpty) return given;
    final store = ref.read(linkedRigStoreProvider);
    final rig = await store.load();
    if (rig == null) return null;
    final sameRig = rig.fingerprint != null && widget.host.fingerprint != null
        ? rig.fingerprint!.toLowerCase() ==
            widget.host.fingerprint!.toLowerCase()
        : rig.host == widget.host.host && rig.port == widget.host.webPort;
    return sameRig ? store.readToken() : null;
  }

  Future<void> _updateHost() async {
    setState(() {
      _busy = true;
      _note = null;
    });
    final token = await _tokenForHost();
    if (!mounted) return;
    setState(() => _busy = false);
    // A host that asks for no credential is updated without one.
    if (token == null && widget.host.authRequired) {
      setState(
        () => _note = 'This device is not paired with '
            '${widget.host.displayName} yet, so it cannot update it. Update '
            'Skotiq on that computer (Settings > About > Check for updates), '
            'then link.',
      );
      return;
    }
    await ref.read(hostUpdateOpenerProvider)(context, widget.host, token ?? '');
  }

  Future<void> _updateThisApp() async {
    setState(() {
      _busy = true;
      _note = null;
    });
    try {
      await ref.read(updateProvider.notifier).checkForUpdates();
      if (!mounted) return;
      final found = ref.read(updateProvider).availableUpdate;
      setState(
        () => _note = found == null
            ? 'No newer Skotiq was found for this device. Install Skotiq '
                '${widget.mismatch.host} here by hand, or check again later.'
            : 'Skotiq ${found.version} is available for this device; follow '
                'the update prompt.',
      );
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _note = 'Could not check for an update on this device. Check '
            'its internet connection and try again.',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final older = widget.mismatch.older;
    if (older == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SkotiqButton(
          key: ValueKey(
            older == LinkSide.host ? 'link.updateHost' : 'link.updateThisApp',
          ),
          label: older == LinkSide.host ? 'Update the host' : 'Update this app',
          icon: LucideIcons.download,
          size: ButtonSize.small,
          onPressed: _busy
              ? null
              : () => unawaited(
                    older == LinkSide.host ? _updateHost() : _updateThisApp(),
                  ),
        ),
        if (_note != null) ...[
          const SizedBox(height: SkotiqTokens.spaceSm),
          Text(
            _note!,
            key: const ValueKey('link.updateNote'),
            style: SkotiqTypography.caption.copyWith(
              color: colors.textSecondary,
            ),
          ),
        ],
      ],
    );
  }
}

/// Shows [host]'s update controls, talking only to the routes another release
/// may call ([LinkVersion.openToOtherReleases]). The connection made for it
/// is never linked and is closed with the dialog.
Future<void> showHostUpdateDialog(
  BuildContext context,
  DiscoveredServer host,
  String token,
) async {
  final updates = NetworkBackend(
    serverHost: host.host,
    serverPort: host.webPort,
    scheme: host.scheme,
    pinnedFingerprint: host.fingerprint,
    authToken: token.isEmpty ? null : token,
    autoConnectWebSocket: false,
  );
  try {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => ProviderScope(
        overrides: [linkedHostUpdatesProvider.overrideWithValue(updates)],
        child: Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640, maxHeight: 720),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Flexible(child: UpdateSettings()),
                Padding(
                  padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: SkotiqButton(
                      label: 'Close',
                      variant: ButtonVariant.ghost,
                      size: ButtonSize.small,
                      onPressed: () => Navigator.of(dialogContext).pop(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  } finally {
    updates.dispose();
  }
}
