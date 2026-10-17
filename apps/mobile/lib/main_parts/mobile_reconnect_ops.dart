// (Re)connect, disconnect, relay-tunnel, persistence, and
// checkpoint-resume operations. These take a resolved [DiscoveredServer]
// (handed over by the discovery/pairing ops mixin) and perform the actual
// backend swap: /api/info enrichment, compatibility gate, one-tap LAN or
// code pairing, reachability test, the NetworkBackend connect, the
// saved-servers upsert, and the WebSocket monitor hand-off. Also owns the
// relay loopback tunnel lifecycle and the post-connect checkpoint prompt.
//
// Shared session state lives in [_MobileConnectionState]; this mixin
// constrains `on` it so it can read/write the same fields.
part of '../main.dart';

mixin _MobileReconnectOps on _MobileConnectionState {
  /// Close any active relay tunnel. Idempotent; safe to call from every
  /// session-teardown path. The backend disconnect that accompanies a session
  /// end races this close — that is fine, the loopback socket simply errors and
  /// the tunnel completes.
  @override
  Future<void> _closeActiveRelayTunnel() async {
    final tunnel = _activeRelayTunnel;
    _activeRelayTunnel = null;
    if (tunnel != null) {
      try {
        await tunnel.close();
      } catch (_) {
        // Best-effort teardown only.
      }
    }
  }

  /// v4 couch-grade remote: connect to an appliance through a self-hosted
  /// relay. The relay exposes the remote rig's headless API as a LOCAL
  /// loopback port, so the rest of the connect flow (pairing, HMAC tokens,
  /// the event WebSocket, even TLS if the appliance serves https) reuses the
  /// existing [_connectToServer] path unchanged — the tunnel is just another
  /// base URL pointing at 127.0.0.1.
  ///
  /// [relayUrl] is the operator's relay (ws(s)://host[:port]); [applianceId]
  /// is the id the relay minted for the rig (printed by the daemon on first
  /// contact). End-to-end auth is unchanged; the relay only splices bytes.
  /// [presetAuthToken] short-circuits pairing when reconnecting a *saved*
  /// relay row whose appliance bearer is already in secure storage — mirrors
  /// how [SavedServersScreen] reconnects a direct row with a stored token.
  /// `null` for a first-time relay connect (the appliance is paired through
  /// the normal [_connectToServer] flow). [savedServerDisplayName] feeds the
  /// persisted row's label; defaults to `Relay: <id>` when null.
  @override
  Future<void> _connectViaRelay({
    required String relayUrl,
    required String applianceId,
    bool allowInsecureTls = false,
    String? presetAuthToken,
    String? savedServerDisplayName,
  }) async {
    setState(() {
      _isDiscovering = true;
      _error = null;
      _statusMessage = 'Connecting via relay...';
    });

    final trimmedId = applianceId.trim();
    if (!isValidApplianceId(trimmedId)) {
      setState(() {
        _isDiscovering = false;
        _statusMessage = '';
        _error = 'Appliance id must look like xxxx-xxxx-xxxx.';
      });
      return;
    }

    final Uri parsedRelay;
    try {
      parsedRelay = Uri.parse(relayUrl.trim());
    } catch (e) {
      setState(() {
        _isDiscovering = false;
        _statusMessage = '';
        _error = 'Invalid relay URL: $e';
      });
      return;
    }

    // A fresh tunnel per connect attempt — drop any previous one first.
    await _closeActiveRelayTunnel();

    try {
      final tunnel = await RelayTunnelClient.connect(
        relayUrl: parsedRelay,
        applianceId: trimmedId,
        allowBadTlsCertificate: allowInsecureTls,
        onLog: (message) => developer.log(message, name: 'Relay'),
      );
      _activeRelayTunnel = tunnel;

      // If the relay/appliance drops, surface it: closing the backend kicks
      // the user back to the connection screen through the normal monitor.
      unawaited(
        tunnel.done.then((_) {
          if (!mounted || !identical(_activeRelayTunnel, tunnel)) return;
          _activeRelayTunnel = null;
        }),
      );

      // The relay carries opaque bytes end-to-end; the appliance behind it may
      // still serve plain http (typical) — the loopback hop is local-only, so
      // dialling the tunnel over http is correct regardless of the appliance's
      // own TLS. The appliance's pairing token / HMAC remain end-to-end.
      final relayServer = DiscoveredServer(
        name: savedServerDisplayName ?? 'Relay: $trimmedId',
        host: '127.0.0.1',
        webPort: tunnel.localPort,
        signalingPort: tunnel.localPort,
        mode: 'headless',
        scheme: 'http',
        authRequired: true,
        pairingSupported: true,
        // A saved relay carries its appliance bearer in secure storage —
        // pass it through so _connectToServer skips re-pairing every night.
        authToken: presetAuthToken,
      );
      // Capture the live backend instance BEFORE the connect attempt. A
      // successful connect swaps in a brand-new NetworkBackend (see
      // BackendNotifier.connect -> _swapBackend, which always assigns a fresh
      // instance); a failed connect leaves the existing backend in place.
      // Keying success on a backend *swap* — rather than merely `is
      // NetworkBackend` — means a stale prior NetworkBackend session (from a
      // previous rig) cannot be mistaken for a successful relay connect.
      final priorBackend = ref.read(backendProvider);
      await _connectToServer(relayServer);

      // If the connect failed (no backend swap happened), tear the tunnel back
      // down so we don't leak a loopback listener or persist a bogus relay row.
      final swappedBackend = ref.read(backendProvider);
      if (!mounted ||
          swappedBackend is! NetworkBackend ||
          identical(swappedBackend, priorBackend)) {
        await _closeActiveRelayTunnel();
        return;
      }

      // Persist (or refresh) the relay entry in the saved-servers list so the
      // operator reconnects from the roaming list next session instead of
      // re-running the relay setup. Keyed on (relayUrl, applianceId) so a
      // reconnect updates the existing row rather than duplicating it. The
      // bearer the appliance ended up authenticating with is mirrored into
      // secure storage; non-secret fields go in the JSON blob.
      final connectedToken = _connectedServer?.authToken;
      try {
        await ref
            .read(savedServersServiceProvider)
            .upsertRelay(
              displayName: savedServerDisplayName ?? 'Relay: $trimmedId',
              relayUrl: relayUrl.trim(),
              relayApplianceId: trimmedId,
              relayAllowInsecureTls: allowInsecureTls,
              authToken: connectedToken,
              lastConnectedAt: DateTime.now(),
            );
      } catch (e, st) {
        // A persistence failure must not drop the live session — the relay
        // tunnel and backend are already up. Log and carry on.
        developer.log(
          'relay: failed to persist saved server: $e',
          name: 'Relay',
          level: 1000,
          error: e,
          stackTrace: st,
        );
      }
    } on RelayTunnelException catch (e) {
      await _closeActiveRelayTunnel();
      if (!mounted) return;
      setState(() {
        _isDiscovering = false;
        _statusMessage = '';
        _error = 'Relay refused the connection (${e.code}): ${e.message}';
      });
    } catch (e) {
      await _closeActiveRelayTunnel();
      if (!mounted) return;
      setState(() {
        _isDiscovering = false;
        _statusMessage = '';
        _error = 'Could not reach the relay: $e';
      });
    }
  }

  /// Reconnect a *saved* relay row from [SavedServersScreen].
  ///
  /// Loads the appliance bearer from secure storage (so the appliance behind
  /// the relay isn't re-paired every session) and dials through the relay
  /// using the row's persisted relay URL + appliance id + TLS-trust flag.
  /// Registered into [relayReconnectProvider] by the shell so the
  /// dashboard-launched screen can invoke it.
  Future<void> _reconnectSavedRelay(SavedServer server) async {
    if (!server.isRelay) return;
    final token = await ref
        .read(savedServersServiceProvider)
        .tokenFor(server.id);
    await _connectViaRelay(
      relayUrl: server.relayUrl!,
      applianceId: server.relayApplianceId!,
      allowInsecureTls: server.relayAllowInsecureTls,
      presetAuthToken: token,
      savedServerDisplayName: server.displayName,
    );
  }

  /// Mirror a freshly-connected direct (LAN / Tailscale) server into the
  /// roaming Saved Servers list so it stays in sync with the legacy
  /// single-slot last-server record. Keyed on host:port by
  /// [SavedServersService.upsert] so reconnecting the same rig updates the
  /// existing row rather than duplicating it. The bearer goes to secure
  /// storage; non-secret fields (host/port/scheme/fingerprint/name) live in
  /// the JSON blob. The rig's advertised [DiscoveredServer.tailscaleHost]
  /// (from /api/info) is recorded when it is a genuine tailnet endpoint so
  /// the off-site "Connect over Tailscale" path can prefill it later.
  ///
  /// Best-effort: a persistence failure must not drop the live session, so we
  /// log and carry on — the backend is already connected.
  Future<void> _upsertSavedServer(DiscoveredServer server) async {
    final tailscaleHost = server.tailscaleHost;
    final validTailscaleHost =
        tailscaleHost != null &&
            tailscaleHost.isNotEmpty &&
            SavedServer.isTailscaleEndpoint(tailscaleHost)
        ? tailscaleHost
        : null;
    try {
      await ref
          .read(savedServersServiceProvider)
          .upsert(
            displayName: server.name,
            host: server.host,
            port: server.webPort,
            authToken: server.authToken,
            pinnedFingerprint: server.fingerprint,
            scheme: server.scheme,
            lastConnectedAt: DateTime.now(),
            tailscaleHost: validTailscaleHost,
          );
    } catch (e, st) {
      developer.log(
        'saved_servers: failed to upsert connected server: $e',
        name: 'Discovery',
        level: 1000,
        error: e,
        stackTrace: st,
      );
    }
  }

  @override
  Future<void> _connectToServer(DiscoveredServer server) async {
    if (!mounted) return;
    final operationGeneration = ++_connectionOperationGeneration;
    setState(() {
      _statusMessage = 'Connecting to ${server.name}...';
      _error = null;
    });

    try {
      // do not persist last-server based on synthetic
      // metadata. Track whether the /api/info call actually returned
      // server-supplied fields; if it didn't, we still allow the user
      // to connect for this session but refuse to write the server to
      // disk (next launch should re-discover or re-prompt).
      final fetched = await EnhancedSkotiqDiscovery.fetchServerInfo(server);
      if (!_isCurrentConnectionOperation(operationGeneration)) return;
      var enrichedServer = fetched ?? server;
      final compatibility = SkotiqServerCompatibility.check(
        enrichedServer.apiVersion ?? enrichedServer.version,
      );
      if (!compatibility.isCompatible) {
        setState(() {
          _isDiscovering = false;
          _statusMessage = '';
          _error = compatibility.message;
        });
        return;
      }

      var authToken = enrichedServer.authToken;
      if (enrichedServer.authRequired &&
          (authToken == null || authToken.isEmpty) &&
          enrichedServer.pairingSupported) {
        // One-tap LAN pairing: when /api/info advertised lan-open mode
        // (lanPairing == true), try POST /api/pairing/lan-claim first. The
        // appliance mints a scoped token for a request from a trusted
        // private-LAN source with NO code. The pinnedFingerprint (when known
        // from a saved server / QR / prior /api/info) is threaded into the
        // pairing service so the lan-claim pre-flight pins the server identity
        // before the minted token is trusted — exactly like the code path.
        // A null result (server in code-required mode, reached over
        // tailnet/relay so the source isn't a trusted LAN address, or an older
        // server without the endpoint) or any pairing exception falls through
        // to the unchanged code-dialog path below.
        if (enrichedServer.lanPairing) {
          try {
            final lanPairing = MobilePairingService(
              host: enrichedServer.host,
              port: enrichedServer.webPort,
              scheme: enrichedServer.scheme,
              pinnedFingerprint: enrichedServer.fingerprint,
            );
            final lanResult = await lanPairing.lanClaim();
            if (!_isCurrentConnectionOperation(operationGeneration)) return;
            if (lanResult != null &&
                lanResult.success &&
                lanResult.token != null &&
                lanResult.token!.isNotEmpty) {
              developer.log(
                'One-tap LAN pairing succeeded for '
                '${enrichedServer.host}:${enrichedServer.webPort} — '
                'no code needed',
                name: 'Discovery',
                level: 800,
              );
              authToken = lanResult.token;
              enrichedServer = enrichedServer.copyWith(authToken: authToken);
            }
          } on RemotePairingFingerprintMismatch catch (e) {
            // Fail-closed: the lan-claim pre-flight refused the identity.
            // Surface it rather than silently dropping to the code dialog —
            // a mismatch means the host we reached is not the one we trust.
            if (!_isCurrentConnectionOperation(operationGeneration)) return;
            setState(() {
              _isDiscovering = false;
              _statusMessage = '';
              _error = e.message;
            });
            return;
          } on RemotePairingException catch (e) {
            // Transport / unexpected error from the one-tap path. Log and fall
            // through to the code dialog — the operator can still pair by code.
            developer.log(
              'One-tap LAN pairing unavailable, falling back to code: $e',
              name: 'Discovery',
              level: 900,
            );
          }
        }

        if (!_isCurrentConnectionOperation(operationGeneration)) return;

        if (authToken == null || authToken.isEmpty) {
          final pairedToken = await _pairWithServer(
            host: enrichedServer.host,
            port: enrichedServer.webPort,
            scheme: enrichedServer.scheme,
            // Pin the server identity (when known from /api/info) so the
            // pairing pre-flight verifies it before the code is sent — the
            // MITM defense matters most on the Tailscale / Internet-reachable
            // path.
            pinnedFingerprint: enrichedServer.fingerprint,
          );
          if (!_isCurrentConnectionOperation(operationGeneration)) return;
          if (pairedToken == null) {
            return;
          }
          authToken = pairedToken;
          enrichedServer = enrichedServer.copyWith(authToken: authToken);
        }
      }

      // Test connection first
      final isReachable = await EnhancedSkotiqDiscovery.testServerConnection(
        enrichedServer.host,
        enrichedServer.webPort,
        authToken: authToken,
        // Probe over the transport the server actually speaks. A TLS-fronted
        // tailnet/relay rig (scheme=='https') answers only on https; without
        // this it defaulted to plain http and read as unreachable. UDP/LAN
        // rigs keep scheme=='http' and probe unchanged.
        scheme: enrichedServer.scheme,
      );
      if (!_isCurrentConnectionOperation(operationGeneration)) return;

      if (isReachable) {
        developer.log('Connection successful!', name: 'Discovery', level: 800);

        // Update global backend state to use NetworkBackend.
        //
        // also wire up the collaboration identity so the backend
        // can emit a `collaboration.join` frame as soon as the WS upgrade
        // completes. The viewerId we derive matches what the server
        // computes from the authenticated bearer (see +
        // computeServerFingerprint) so the join is a no-op override
        // rather than an impersonation attempt for hosts with auth on;
        // for auth-off hosts the value still gives the operator a stable
        // human-readable slot label. Display-name preference lookup is
        // best-effort — failures fall back to the platform default.
        final collabIdentity = await _buildCollaborationIdentity(
          enrichedServer.authToken,
        );
        if (!_isCurrentConnectionOperation(operationGeneration)) return;
        final backendNotifier = ref.read(backendProvider.notifier);
        await backendNotifier.connect(
          enrichedServer.host,
          enrichedServer.webPort,
          authToken: enrichedServer.authToken,
          // Carry the transport scheme so a TLS-fronted tailnet host is
          // dialled over wss, not plain ws. NetworkBackend classifies the
          // host (LAN vs tailnet) itself for timeout tuning.
          scheme: enrichedServer.scheme,
          // Pin the server identity (when /api/info advertised one) so the
          // handshake verifies it before opening the socket — a mismatch
          // becomes a terminal identity error rather than a connect.
          pinnedFingerprint: enrichedServer.fingerprint,
          collaborationViewerId: collabIdentity.viewerId,
          collaborationDeviceName: collabIdentity.deviceName,
          collaborationDisplayName: collabIdentity.displayName,
        );
        final connectedBackend = backendNotifier.currentBackend;
        if (!_isCurrentConnectionOperation(operationGeneration) ||
            !backendNotifier.isCurrentBackend(connectedBackend)) {
          return;
        }

        // A reachable /api/info probe is not a live session. Publish the
        // selected server only after the WebSocket handshake above succeeds.
        setState(() {
          _connectedServer = enrichedServer;
          _isDiscovering = false;
          _statusMessage = '';
          // The manual form did its job. Leaving it latched meant that after
          // any manual connect the flag stayed true for the rest of the app's
          // life, and the "don't fight the operator while they are typing"
          // guard on the lost-session auto-retry then suppressed every retry
          // forever — the app sat on "Retrying automatically" without ever
          // actually retrying.
          _showManualEntry = false;
          _lostSessionServer = null;
        });

        if (fetched != null) {
          // Persistence is secondary to the already-live session. A disk or
          // keychain failure must not turn a successful connection into a
          // misleading connection error.
          try {
            await EnhancedSkotiqDiscovery.saveLastServer(enrichedServer);
          } catch (e, stackTrace) {
            developer.log(
              'Could not cache connected server for startup reconnect: $e',
              name: 'Discovery',
              level: 1000,
              error: e,
              stackTrace: stackTrace,
            );
          }
          if (!_isCurrentConnectionOperation(operationGeneration) ||
              !backendNotifier.isCurrentBackend(connectedBackend)) {
            return;
          }
          // Relay sessions are persisted by _connectViaRelay under their
          // stable relay identity, not their ephemeral loopback port.
          if (_activeRelayTunnel == null) {
            await _upsertSavedServer(enrichedServer);
          }
          if (!_isCurrentConnectionOperation(operationGeneration) ||
              !backendNotifier.isCurrentBackend(connectedBackend)) {
            return;
          }
        } else {
          developer.log(
            'Skipping saveLastServer — /api/info did not return metadata',
            name: 'Discovery',
            level: 900,
          );
        }

        // Start monitoring the WS heartbeat
        _startConnectionMonitor();

        // Register this device's push token (APNs/FCM) with the desktop so it
        // can deliver critical alerts when the phone is asleep and out of
        // LAN-UDP push range. No-op off iOS/Android (and on unprovisioned FCM
        // builds) and best-effort (never throws) — a registration failure
        // must not affect the live session.
        unawaited(_registerPushToken());

        // Reload host-backed providers now that NetworkBackend is live.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_isCurrentConnectionOperation(operationGeneration) ||
              !backendNotifier.isCurrentBackend(connectedBackend)) {
            return;
          }
          ref.invalidate(appSettingsProvider);
          ref.invalidate(equipmentProfilesProvider);
        });
      } else {
        final authMessage =
            enrichedServer.authRequired &&
                (enrichedServer.authToken == null ||
                    enrichedServer.authToken!.isEmpty)
            ? '\n\nThis host requires an access token or paired-device QR code.'
            : '';
        setState(() {
          _isDiscovering = false;
          _statusMessage = '';
          _error =
              'Could not connect to ${enrichedServer.host}:${enrichedServer.webPort}\n\nServer may be offline, or this device is not authorized.$authMessage';
        });
      }
    } on BackendTransitionSupersededException {
      return;
    } catch (e, stackTrace) {
      if (!_isCurrentConnectionOperation(operationGeneration)) return;
      developer.log(
        'Connection error: $e',
        name: 'Discovery',
        level: 1000,
        error: e,
        stackTrace: stackTrace,
      );
      setState(() {
        _isDiscovering = false;
        _statusMessage = '';
        _error = 'Connection error: $e';
      });
    }
  }

  Future<void> _skipConnection() async {
    ++_connectionOperationGeneration;
    setState(() {
      _skippedConnection = true;
      _isDiscovering = false;
      _error = null;
    });
    // Ensure backend is disconnected. Drop cached APNs registration so a later
    // connect to a (possibly different) desktop re-POSTs the token rather than
    // assuming it is already registered there.
    _pushRegistration?.reset();
    try {
      await ref.read(backendProvider.notifier).disconnect();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _skippedConnection = false;
        _error = 'Cannot leave this host yet: $e';
      });
      return;
    }
    // v4 relay: tear down any active loopback tunnel on explicit skip.
    unawaited(_closeActiveRelayTunnel());
  }

  void _checkForCheckpoint(BuildContext context, WidgetRef ref) {
    // Only check once after connection
    if (_checkpointChecked) return;
    _checkpointChecked = true;

    // Schedule the check for after the current frame
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        final executor = ref.read(sequenceExecutorProvider);

        // Initialize the checkpoint directory only when this device IS the
        // backend. Against a remote host the directory belongs to the host —
        // pushing this phone's documents path replaced the rig's checkpoint
        // directory with one that cannot exist there, so every checkpoint
        // write failed and a mid-night crash became unrecoverable.
        if (ref.read(backendProvider) is! NetworkBackend) {
          final docsDir = await resolveSkotiqDocumentsDirectory();
          await executor.initializeCheckpoints(docsDir.path);
        }

        // Get checkpoint info
        final info = await executor.getCheckpointInfo();
        if (info == null || !info.canResume) return;
        if (!context.mounted) return;

        // Keep recovery actionable until the selected operation succeeds.
        // `_checkpointChecked` stays true for the rest of this connection, so
        // the prompt must survive a failed resume/discard or the checkpoint is
        // stranded until the operator reconnects.
        while (true) {
          if (!context.mounted) return;
          final shouldResume = await CheckpointResumeDialog.show(context, info);
          if (shouldResume == null || !context.mounted) return;

          try {
            if (shouldResume) {
              await executor.resumeFromCheckpoint();
              if (!context.mounted) return;
              final colors = Theme.of(context).extension<SkotiqColors>();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Text('Sequence resumed from checkpoint'),
                  backgroundColor:
                      colors?.success ?? Theme.of(context).colorScheme.primary,
                ),
              );
            } else {
              await executor.discardCheckpoint();
            }
            return;
          } catch (e) {
            if (!context.mounted) return;
            showApiErrorWithPrefix(
              context,
              shouldResume ? 'Failed to resume' : 'Failed to discard',
              e,
            );
          }
        }
      } catch (e) {
        developer.log(
          'Error checking for checkpoint: $e',
          name: 'Main',
          level: 1000,
        );
      }
    });
  }
}
