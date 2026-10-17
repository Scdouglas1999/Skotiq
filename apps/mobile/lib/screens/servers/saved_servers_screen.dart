// Saved servers screen.
//
// Surfaces every server the operator has paired with so they can roam
// between rigs without re-running discovery / re-pairing. Composes
// SavedServersService for persistence and the existing BackendNotifier
// for live connection switching.
//
// UX contract (per brief):
//   * Each row: display name, last-connected relative time, dot
//     indicator showing last-known reachability.
//   * Tap a row → open that server (BackendNotifier.connect + persist
//     into EnhancedSkotiqDiscovery so the auto-reconnect path also
//     updates).
//   * Long-press → rename / edit notes / remove.
//   * FAB → kicks off the existing pairing flow (passes the new host
//     through the same SavedServersService.upsert path so the row is
//     visible immediately).
//   * Pull-to-refresh → pings each saved host's /api/info and refreshes
//     the reachability dots.
//
// We do *not* duplicate the QR / mDNS discovery UI from main.dart's
// connection screen; "Add a server" routes back through the existing
// pairing helper exposed to the screen via the [onAddServer] callback
// so there's one canonical pairing path.

import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../services/saved_servers_service.dart';

/// Async snapshot of the saved-server list — drives the screen state.
final _savedServersListProvider = FutureProvider.autoDispose<List<SavedServer>>(
  (ref) async {
    final service = ref.watch(savedServersServiceProvider);
    return service.loadAll();
  },
);

/// Per-entry reachability cache keyed by [SavedServer.id]. We populate
/// it lazily on screen first build and on pull-to-refresh; the screen
/// doesn't auto-ping on a timer because every saved row would spawn an
/// HTTP request as soon as the screen opens.
class _ReachabilityNotifier extends StateNotifier<Map<String, bool?>> {
  _ReachabilityNotifier() : super(const {});

  void setStatus(String id, bool? reachable) {
    state = {...state, id: reachable};
  }

  void clearAll() {
    state = const {};
  }
}

final _reachabilityProvider =
    StateNotifierProvider.autoDispose<
      _ReachabilityNotifier,
      Map<String, bool?>
    >((ref) => _ReachabilityNotifier());

/// Saved-server list screen.
///
/// [onAddServer] launches the existing pairing flow — provided by the
/// caller (`main.dart`'s connection shell) so we don't fork the QR /
/// manual-entry plumbing.
///
/// [onServerSelected] fires AFTER the BackendNotifier.connect call
/// resolves for a saved entry. Most callers pop back to the dashboard
/// here; tests pass a no-op.
class SavedServersScreen extends ConsumerStatefulWidget {
  /// Async callback that runs the existing pairing flow and returns
  /// the freshly-paired record (or `null` if the user cancelled).
  final Future<SavedServer?> Function(BuildContext context)? onAddServer;

  /// Called after a saved entry successfully reconnects. `null` lets
  /// the screen close via the default Navigator.pop.
  final void Function(BuildContext context, SavedServer server)?
  onServerSelected;

  const SavedServersScreen({
    super.key,
    this.onAddServer,
    this.onServerSelected,
  });

  @override
  ConsumerState<SavedServersScreen> createState() => _SavedServersScreenState();
}

class _SavedServersScreenState extends ConsumerState<SavedServersScreen> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<SkotiqColors>()!;
    final l10n = context.l10n;
    final asyncList = ref.watch(_savedServersListProvider);
    final reachability = ref.watch(_reachabilityProvider);

    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.surface,
        elevation: 0,
        title: Text(
          l10n.text('savedServersTitle'),
          style: TextStyle(
            color: colors.textPrimary,
            fontWeight: FontWeight.w600,
            fontSize: 17,
          ),
        ),
      ),
      body: asyncList.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              l10n.text('savedServersLoadError', params: {'error': '$e'}),
              style: TextStyle(color: colors.error),
              textAlign: TextAlign.center,
            ),
          ),
        ),
        data: (servers) {
          if (servers.isEmpty) {
            return _EmptyState(colors: colors);
          }
          return RefreshIndicator(
            onRefresh: () => _refreshReachability(servers),
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: servers.length,
              separatorBuilder: (_, __) =>
                  Divider(height: 1, color: colors.border),
              itemBuilder: (context, index) {
                final server = servers[index];
                final reach = reachability[server.id];
                return _SavedServerRow(
                  server: server,
                  reachable: reach,
                  busy: _busy,
                  colors: colors,
                  onTap: () => _activateServer(server),
                  onLongPress: () => _showRowMenu(server),
                );
              },
            ),
          );
        },
      ),
      floatingActionButton: widget.onAddServer == null
          ? null
          : FloatingActionButton.extended(
              backgroundColor: colors.primary,
              foregroundColor: colors.onPrimary,
              icon: const Icon(LucideIcons.plus, size: 18),
              label: Text(l10n.text('savedServersAdd')),
              onPressed: _busy ? null : _handleAddServer,
            ),
    );
  }

  Future<void> _refreshReachability(List<SavedServer> servers) async {
    // Concurrent pings so the indicator refresh feels snappy. The
    // remote-protocol package's testServerConnection has a built-in 5s
    // timeout; we cap the whole batch at 6s so the spinner doesn't
    // hang on an unreachable host.
    final notifier = ref.read(_reachabilityProvider.notifier);
    final futures = <Future<void>>[];
    for (final s in servers) {
      futures.add(_pingOne(s, notifier));
    }
    await Future.wait(futures).timeout(
      const Duration(seconds: 6),
      onTimeout: () {
        // Outstanding pings keep running in the background; the
        // notifier will update each one as it lands. Don't propagate
        // the timeout — the user's pull-to-refresh is already done.
        return <void>[];
      },
    );
  }

  Future<void> _pingOne(SavedServer s, _ReachabilityNotifier notifier) async {
    // A relay row's host:port is a synthetic loopback placeholder — there's
    // nothing to probe without first opening the tunnel (which would be a
    // full connect, not a cheap pull-to-refresh ping). Leave it as unknown.
    if (s.isRelay) {
      notifier.setStatus(s.id, null);
      return;
    }
    try {
      final token = await ref.read(savedServersServiceProvider).tokenFor(s.id);
      final ok = await EnhancedSkotiqDiscovery.testServerConnection(
        s.host,
        s.port,
        authToken: token,
        scheme: s.scheme,
      );
      if (!mounted) return;
      notifier.setStatus(s.id, ok);
    } catch (_) {
      if (!mounted) return;
      notifier.setStatus(s.id, false);
    }
  }

  /// Open a saved server.
  ///
  /// [hostOverride] forces a specific host — used by the "Connect over
  /// Tailscale" action to dial the rig's tailnet address rather than its
  /// (possibly off-LAN-unreachable) primary host. When null the primary
  /// [SavedServer.host] is used. The transport [SavedServer.scheme] is
  /// honoured throughout so a TLS-fronted tailnet host is probed and
  /// dialled over https, not plain http.
  Future<void> _activateServer(
    SavedServer server, {
    String? hostOverride,
  }) async {
    if (_busy) return;
    // Relay rows can't be dialled directly — their host:port is a synthetic
    // loopback placeholder. Route them through the relay tunnel flow owned by
    // the connection shell (registered into relayReconnectProvider).
    if (server.isRelay) {
      await _activateRelayServer(server);
      return;
    }
    setState(() => _busy = true);
    final host = hostOverride ?? server.host;
    final scheme = server.scheme;
    try {
      final service = ref.read(savedServersServiceProvider);
      final backendNotifier = ref.read(backendProvider.notifier);
      final token = await service.tokenFor(server.id);
      // Sanity-check reachability before swapping backends — a fail-
      // fast here keeps the dashboard from booting into a hung WS.
      //
      // `probeServer`, not `testServerConnection`: the bool form reports a
      // live host that REJECTED our token as `false`, and this screen then
      // told the operator "Could not reach <host>". A Skotiq host drops
      // every paired token when it restarts, so that is the single most
      // common failure here — and the message sent people to debug their
      // network when the actual fix is to pair again.
      final outcome = await EnhancedSkotiqDiscovery.probeServer(
        host,
        server.port,
        authToken: token,
        scheme: scheme,
      );
      if (outcome != ServerProbeOutcome.reachable) {
        if (!mounted) return;
        final authExpired = outcome == ServerProbeOutcome.authRejected;
        _showSnack(
          context.l10n.text(
            authExpired
                ? 'savedServersPairingExpired'
                : outcome == ServerProbeOutcome.incompatible
                ? 'savedServersIncompatible'
                : 'savedServersUnreachable',
            params: {'name': server.displayName, 'host': host},
          ),
          isError: true,
        );
        // Only a genuine reachability failure marks the row unreachable; a
        // rejected credential must not paint the host as down, because it is
        // demonstrably up and answering.
        ref
            .read(_reachabilityProvider.notifier)
            .setStatus(server.id, authExpired);
        return;
      }
      final viewerId = (token != null && token.isNotEmpty)
          ? computeServerFingerprint(token)
          : server.id;
      await backendNotifier.connect(
        host,
        server.port,
        authToken: token,
        scheme: scheme,
        pinnedFingerprint: server.pinnedFingerprint,
        collaborationViewerId: viewerId,
        collaborationDeviceName: server.id,
        collaborationDisplayName: server.displayName,
      );
      final connectedBackend = backendNotifier.currentBackend;
      // Mirror the active server into the legacy single-slot record so
      // auto-reconnect on cold start still works. Also re-stamp our
      // own lastConnectedAt + reachability cache.
      final discovered = DiscoveredServer(
        name: server.displayName,
        host: host,
        webPort: server.port,
        mode: 'headless',
        scheme: scheme,
        authToken: token,
        authRequired: token != null,
        pairingSupported: true,
        fingerprint: server.pinnedFingerprint,
      );
      try {
        await EnhancedSkotiqDiscovery.saveLastServer(discovered);
      } catch (e, stackTrace) {
        developer.log(
          'Could not cache the active server for startup reconnect: $e',
          name: 'SavedServersScreen',
          level: 1000,
          error: e,
          stackTrace: stackTrace,
        );
      }
      try {
        await service.touchLastConnected(server.id);
      } catch (e, stackTrace) {
        developer.log(
          'Could not update last-connected time for ${server.id}: $e',
          name: 'SavedServersScreen',
          level: 1000,
          error: e,
          stackTrace: stackTrace,
        );
      }
      if (!backendNotifier.isCurrentBackend(connectedBackend)) return;
      ref.read(_reachabilityProvider.notifier).setStatus(server.id, true);
      ref.invalidate(_savedServersListProvider);
      if (!mounted) return;
      if (widget.onServerSelected != null) {
        widget.onServerSelected!(context, server);
      } else {
        Navigator.of(context).pop();
      }
    } on BackendTransitionSupersededException {
      return;
    } catch (e) {
      if (!mounted) return;
      _showSnack(
        context.l10n.text(
          'savedServersOpenError',
          params: {'name': server.displayName, 'error': '$e'},
        ),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Reconnect a saved relay row through the relay-reconnect bridge the
  /// connection shell registered. The shell opens the tunnel and swaps the
  /// backend; the screen just kicks it off and pops back to the dashboard
  /// (mirroring the direct-connect [onServerSelected] contract). When the
  /// bridge is absent (the shell isn't mounted, e.g. an isolated widget test)
  /// we surface a clear message rather than silently no-op.
  Future<void> _activateRelayServer(SavedServer server) async {
    final reconnect = ref.read(relayReconnectProvider);
    if (reconnect == null) {
      _showSnack(
        context.l10n.text('savedServersRelayUnavailable'),
        isError: true,
      );
      return;
    }
    setState(() => _busy = true);
    try {
      await reconnect(server);
      if (!mounted) return;
      // The shell stamps lastConnectedAt + secure-storage token via
      // upsertRelay; refresh the list so the row floats to the top.
      ref.invalidate(_savedServersListProvider);
      if (widget.onServerSelected != null) {
        widget.onServerSelected!(context, server);
      } else {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (!mounted) return;
      _showSnack(
        context.l10n.text(
          'savedServersOpenError',
          params: {'name': server.displayName, 'error': '$e'},
        ),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleAddServer() async {
    if (widget.onAddServer == null) {
      _showSnack(context.l10n.text('savedServersAddDisabled'), isError: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final added = await widget.onAddServer!(context);
      if (!mounted) return;
      if (added != null) {
        ref.invalidate(_savedServersListProvider);
        _showSnack(
          context.l10n.text(
            'savedServersAdded',
            params: {'name': added.displayName},
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      _showSnack(
        context.l10n.text('savedServersAddError', params: {'error': '$e'}),
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showRowMenu(SavedServer server) async {
    final colors = Theme.of(context).extension<SkotiqColors>()!;
    final l10n = context.l10n;
    final action = await showModalBottomSheet<_RowMenuAction>(
      context: context,
      backgroundColor: colors.surface,
      builder: (sheetContext) {
        // Offer a one-tap "connect over Tailscale" only when the rig has a
        // distinct tailnet path (a dual-homed rig whose primary host is the
        // LAN address). When the primary host is already the tailnet host
        // the normal row tap already does the right thing, so we omit it.
        final remoteHost = server.preferredRemoteHost;
        final showConnectTailscale =
            remoteHost != null && remoteHost != server.host;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showConnectTailscale)
                ListTile(
                  leading: Icon(LucideIcons.radioTower, color: colors.primary),
                  title: Text(
                    l10n.text('tailscaleConnect'),
                    style: TextStyle(color: colors.textPrimary),
                  ),
                  subtitle: Text(
                    remoteHost,
                    style: TextStyle(color: colors.textSecondary),
                  ),
                  onTap: () => Navigator.of(
                    sheetContext,
                  ).pop(_RowMenuAction.connectTailscale),
                ),
              ListTile(
                leading: Icon(LucideIcons.edit, color: colors.textPrimary),
                title: Text(
                  l10n.text('savedServersRename'),
                  style: TextStyle(color: colors.textPrimary),
                ),
                onTap: () =>
                    Navigator.of(sheetContext).pop(_RowMenuAction.rename),
              ),
              ListTile(
                leading: Icon(LucideIcons.fileText, color: colors.textPrimary),
                title: Text(
                  l10n.text('savedServersEditNotes'),
                  style: TextStyle(color: colors.textPrimary),
                ),
                onTap: () =>
                    Navigator.of(sheetContext).pop(_RowMenuAction.notes),
              ),
              ListTile(
                leading: Icon(
                  LucideIcons.radioTower,
                  color: colors.textPrimary,
                ),
                title: Text(
                  server.hasTailscaleHost
                      ? l10n.text('savedServersEditTailscale')
                      : l10n.text('savedServersAddTailscale'),
                  style: TextStyle(color: colors.textPrimary),
                ),
                subtitle: Text(
                  server.hasTailscaleHost
                      ? server.tailscaleHost!
                      : l10n.text('savedServersTailscaleSubtitle'),
                  style: TextStyle(color: colors.textSecondary),
                ),
                onTap: () => Navigator.of(
                  sheetContext,
                ).pop(_RowMenuAction.tailscaleHost),
              ),
              ListTile(
                leading: Icon(LucideIcons.trash, color: colors.error),
                title: Text(
                  l10n.text('savedServersRemove'),
                  style: TextStyle(color: colors.error),
                ),
                onTap: () =>
                    Navigator.of(sheetContext).pop(_RowMenuAction.remove),
              ),
            ],
          ),
        );
      },
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _RowMenuAction.connectTailscale:
        await _activateServer(server, hostOverride: server.preferredRemoteHost);
        break;
      case _RowMenuAction.rename:
        await _renameServer(server);
        break;
      case _RowMenuAction.notes:
        await _editNotes(server);
        break;
      case _RowMenuAction.tailscaleHost:
        await _editTailscaleHost(server);
        break;
      case _RowMenuAction.remove:
        await _confirmAndRemove(server);
        break;
    }
  }

  Future<void> _editTailscaleHost(SavedServer server) async {
    final l10n = context.l10n;
    // The dialog owns its TextEditingController for the lifetime of the route
    // (see [_EditTextDialog]); disposing here right after showDialog resolves
    // would race the dismiss animation, which still rebuilds the field.
    final raw = await showDialog<String>(
      context: context,
      builder: (_) => _EditTextDialog(
        title: l10n.text('savedServersTailscaleDialogTitle'),
        bodyText: l10n.text('savedServersTailscaleDialogBody'),
        fieldLabel: l10n.text('savedServersTailscaleHostLabel'),
        hintText: 'my-rig.tailnet.ts.net',
        autocorrect: false,
        initialValue: server.tailscaleHost ?? '',
        saveLabel: l10n.text('savedServersSave'),
        cancelLabel: l10n.text('savedServersCancel'),
      ),
    );
    if (raw == null) return;
    final result = raw.trim();
    await _persistServerChange(
      server,
      () => ref
          .read(savedServersServiceProvider)
          .setTailscaleHost(server.id, result),
      argumentErrorMessage: l10n.text('savedServersTailscaleInvalid'),
    );
  }

  Future<void> _renameServer(SavedServer server) async {
    final l10n = context.l10n;
    final raw = await showDialog<String>(
      context: context,
      builder: (_) => _EditTextDialog(
        title: l10n.text('savedServersRenameTitle'),
        fieldLabel: l10n.text('savedServersDisplayNameLabel'),
        initialValue: server.displayName,
        saveLabel: l10n.text('savedServersSave'),
        cancelLabel: l10n.text('savedServersCancel'),
      ),
    );
    if (raw == null) return;
    final newName = raw.trim();
    if (newName.isEmpty || newName == server.displayName) {
      return;
    }
    await _persistServerChange(
      server,
      () => ref.read(savedServersServiceProvider).rename(server.id, newName),
    );
  }

  Future<void> _editNotes(SavedServer server) async {
    final l10n = context.l10n;
    final updated = await showDialog<String>(
      context: context,
      builder: (_) => _EditTextDialog(
        title: l10n.text('savedServersNotesTitle'),
        fieldLabel: l10n.text('savedServersNotesLabel'),
        helperText: l10n.text('savedServersNotesHelper'),
        maxLines: 4,
        maxLength: 280,
        initialValue: server.notes,
        saveLabel: l10n.text('savedServersSave'),
        cancelLabel: l10n.text('savedServersCancel'),
      ),
    );
    if (updated == null) return;
    await _persistServerChange(
      server,
      () => ref
          .read(savedServersServiceProvider)
          .setNotes(server.id, updated.trim()),
    );
  }

  Future<void> _confirmAndRemove(SavedServer server) async {
    final l10n = context.l10n;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(
            l10n.text(
              'savedServersRemoveTitle',
              params: {'name': server.displayName},
            ),
          ),
          content: Text(l10n.text('savedServersRemoveBody')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: Text(l10n.text('savedServersCancel')),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(l10n.text('savedServersRemove')),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    final removed = await _persistServerChange(
      server,
      () => ref.read(savedServersServiceProvider).removeById(server.id),
    );
    if (removed && mounted) {
      ref.read(_reachabilityProvider.notifier).setStatus(server.id, null);
    }
  }

  Future<bool> _persistServerChange(
    SavedServer server,
    Future<void> Function() operation, {
    String? argumentErrorMessage,
  }) async {
    if (_busy || !mounted) return false;
    setState(() => _busy = true);
    try {
      await operation();
      if (!mounted) return true;
      ref.invalidate(_savedServersListProvider);
      return true;
    } catch (e) {
      if (!mounted) return false;
      final message = e is ArgumentError && argumentErrorMessage != null
          ? argumentErrorMessage
          : context.l10n.text(
              'savedServersUpdateError',
              params: {'name': server.displayName, 'error': '$e'},
            );
      _showSnack(message, isError: true);
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    final colors = Theme.of(context).extension<SkotiqColors>()!;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? colors.error : null,
      ),
    );
  }
}

enum _RowMenuAction { connectTailscale, rename, notes, tailscaleHost, remove }

/// Single-field text-edit dialog used by the rename / notes / Tailscale-host
/// actions. It owns its [TextEditingController] so the controller is disposed
/// exactly once, when the route is torn down — i.e. AFTER the dismiss animation
/// finishes. Disposing the controller the instant `showDialog` resolves would
/// race that animation (which keeps rebuilding the field) and throw a
/// use-after-dispose. Pops the raw field text on Save and `null` on Cancel;
/// callers apply their own trimming / validation.
class _EditTextDialog extends StatefulWidget {
  final String title;
  final String? bodyText;
  final String fieldLabel;
  final String? helperText;
  final String? hintText;
  final String initialValue;
  final int maxLines;
  final int? maxLength;
  final bool autocorrect;
  final String saveLabel;
  final String cancelLabel;

  const _EditTextDialog({
    required this.title,
    required this.fieldLabel,
    required this.initialValue,
    required this.saveLabel,
    required this.cancelLabel,
    this.bodyText,
    this.helperText,
    this.hintText,
    this.maxLines = 1,
    this.maxLength,
    this.autocorrect = true,
  });

  @override
  State<_EditTextDialog> createState() => _EditTextDialogState();
}

class _EditTextDialogState extends State<_EditTextDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: _controller,
      autofocus: true,
      autocorrect: widget.autocorrect,
      maxLines: widget.maxLines,
      maxLength: widget.maxLength,
      decoration: InputDecoration(
        labelText: widget.fieldLabel,
        helperText: widget.helperText,
        hintText: widget.hintText,
      ),
    );
    return AlertDialog(
      title: Text(widget.title),
      content: widget.bodyText == null
          ? field
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.bodyText!),
                const SizedBox(height: 12),
                field,
              ],
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.cancelLabel),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(widget.saveLabel),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  final SkotiqColors colors;
  const _EmptyState({required this.colors});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.server, size: 36, color: colors.textSecondary),
            const SizedBox(height: 12),
            Text(
              l10n.text('savedServersEmptyTitle'),
              style: TextStyle(
                color: colors.textPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.text('savedServersEmptyBody'),
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _SavedServerRow extends StatelessWidget {
  final SavedServer server;
  final bool? reachable;
  final bool busy;
  final SkotiqColors colors;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _SavedServerRow({
    required this.server,
    required this.reachable,
    required this.busy,
    required this.colors,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final dotColor = reachable == null
        ? colors.textSecondary.withValues(alpha: 0.4)
        : (reachable! ? colors.success : colors.error);
    final l10n = context.l10n;
    final dotLabel = reachable == null
        ? l10n.text('savedServersReachabilityUnknown')
        : (reachable!
              ? l10n.text('savedServersReachable')
              : l10n.text('savedServersUnreachableShort'));
    final secondary = _secondaryLine();
    return InkWell(
      onTap: busy ? null : onTap,
      onLongPress: busy ? null : onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Semantics(
              label: dotLabel,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          server.displayName,
                          style: TextStyle(
                            color: colors.textPrimary,
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _ReachBadge(server: server, colors: colors),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    secondary,
                    style: TextStyle(color: colors.textSecondary, fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (server.notes.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      server.notes,
                      style: TextStyle(
                        color: colors.textSecondary,
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              LucideIcons.chevronRight,
              size: 18,
              color: colors.textSecondary,
            ),
          ],
        ),
      ),
    );
  }

  String _secondaryLine() {
    // Relay rows have a synthetic loopback host:port — show the relay
    // endpoint + appliance id instead, which is what actually identifies the
    // rig the row reconnects to.
    final endpoint = server.isRelay
        ? '${server.relayUrl} · ${server.relayApplianceId}'
        : '${server.host}:${server.port}';
    final last = server.lastConnectedAt;
    if (last == null) return '$endpoint · never connected';
    return '$endpoint · ${_formatRelative(last)}';
  }

  static String _formatRelative(DateTime when) {
    final diff = DateTime.now().difference(when);
    if (diff.isNegative) return 'just now';
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    if (diff.inDays < 30) return '${(diff.inDays / 7).floor()}w ago';
    if (diff.inDays < 365) return '${(diff.inDays / 30).floor()}mo ago';
    return '${(diff.inDays / 365).floor()}y ago';
  }
}

/// Small reachability-tier chip rendered next to a saved-server's name.
///
/// Tells the operator at a glance whether the rig is on the LAN (on-site
/// only) or has a Tailscale path (reachable from anywhere). A LAN rig that
/// *also* has a tailnet host on file shows "LAN + TS" so the operator knows
/// the off-site option exists without opening the menu.
class _ReachBadge extends StatelessWidget {
  final SavedServer server;
  final SkotiqColors colors;

  const _ReachBadge({required this.server, required this.colors});

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = _descriptor();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: SkotiqDecorations.statusChip(
        color,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 4),
          Text(label, style: SkotiqTypography.overline.copyWith(color: color)),
        ],
      ),
    );
  }

  (String, Color, IconData) _descriptor() {
    // A relay entry is reached through the self-hosted tunnel, not a direct
    // LAN/Tailscale dial — surface that first so the operator knows the row
    // reconnects via the relay rather than probing a (synthetic) host:port.
    if (server.isRelay) {
      return ('RELAY', colors.info, LucideIcons.globe);
    }
    if (server.isPrimaryTailscale) {
      return ('TAILSCALE', colors.info, LucideIcons.radioTower);
    }
    if (server.hasTailscaleHost) {
      // Dual-homed: paired over LAN but a tailnet path is available.
      return ('LAN + TS', colors.accent, LucideIcons.radioTower);
    }
    switch (server.hostTier) {
      case HostReachabilityTier.lan:
        return ('LAN', colors.textSecondary, LucideIcons.wifi);
      case HostReachabilityTier.loopback:
        return ('LOCAL', colors.textSecondary, LucideIcons.monitor);
      case HostReachabilityTier.tailscale:
        return ('TAILSCALE', colors.info, LucideIcons.radioTower);
      case HostReachabilityTier.public:
      case HostReachabilityTier.invalid:
        // A saved host that no longer classifies as private (e.g. a
        // hand-edited blob) — surface it rather than hide it.
        return ('?', colors.warning, LucideIcons.helpCircle);
    }
  }
}
