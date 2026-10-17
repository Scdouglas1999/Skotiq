// Discovery and pairing operations: the user-facing entry points that
// FIND or NAME a server (auto-discovery, QR scan, manual entry, Tailscale
// onboarding, the relay-connect dialog, the saved-servers screen) and the
// code-pairing dialog. Each ultimately hands a resolved
// [DiscoveredServer] to [_connectToServer] (or routes through
// [_connectViaRelay]) in the (re)connect/disconnect ops mixin.
//
// Shared session state lives in [_MobileConnectionState]; this mixin
// constrains `on` it so it can read/write the same fields.
part of '../main.dart';

mixin _MobileDiscoveryOps on _MobileConnectionState {
  @override
  Future<void> _autoConnect() async {
    setState(() {
      _isDiscovering = true;
      _error = null;
      _statusMessage = 'Starting discovery...';
    });

    try {
      developer.log('Starting enhanced auto-discovery...', name: 'Discovery');

      // Use enhanced discovery with cascading fallback
      final server = await EnhancedSkotiqDiscovery.discoverWithFallback(
        onStatus: (status) {
          if (mounted) {
            setState(() => _statusMessage = status);
          }
        },
      );

      if (server != null) {
        developer.log(
          'Found server: ${server.name} at ${server.host}',
          name: 'Discovery',
          level: 800,
        );

        // Save for future reconnects
        await _connectToServer(server);
      } else {
        developer.log(
          'No server found via any method',
          name: 'Discovery',
          level: 900,
        );
        setState(() {
          _isDiscovering = false;
          _statusMessage = '';
          _error =
              'No Skotiq server found on this network.\n\n'
              'If you are away from the observatory, use "Connect over '
              'Tailscale" to reach it by its MagicDNS name — local discovery '
              'only works on the same WiFi.\n\n'
              'On the same network, try:\n'
              '- Scanning the QR code from the desktop\n'
              '- Entering the host address manually\n'
              '- Allowing UDP 45679 and HTTP 8080 through the firewall';
        });
      }
    } catch (e, stackTrace) {
      developer.log(
        'Discovery error: $e',
        name: 'Discovery',
        level: 1000,
        error: e,
        stackTrace: stackTrace,
      );
      setState(() {
        _isDiscovering = false;
        _statusMessage = '';
        _error =
            'Discovery failed: $e\n\nTry entering the IP address manually or scan QR code.';
      });
    }
  }

  @override
  Future<String?> _pairWithServer({
    required String host,
    required int port,
    String scheme = 'http',
    String? pinnedFingerprint,
    String? initialCode,
  }) async {
    final uiContext = _connectionUiContext;
    if (uiContext == null || !uiContext.mounted) {
      setState(() {
        _isDiscovering = false;
        _statusMessage = '';
        _error = 'Connection UI is not ready yet. Try again in a moment.';
      });
      return null;
    }

    // The dialog owns its TextEditingController (see PairingCodeDialog),
    // because the route outlives showDialog's future: a method-local
    // controller disposed when that future resolves is still read by one more
    // TextField rebuild during the route's exit animation, and the build
    // exception cascades into duplicate-GlobalKey / '_dependents.isEmpty'
    // assertions as the connection MaterialApp is swapped for the main shell.
    final pairingInput = await showDialog<({String code, bool admin})>(
      context: uiContext,
      builder: (ctx) =>
          PairingCodeDialog(host: host, port: port, initialCode: initialCode),
    );

    if (pairingInput == null || pairingInput.code.isEmpty || !mounted) {
      if (mounted) {
        setState(() {
          _isDiscovering = false;
          _statusMessage = '';
        });
      }
      return null;
    }

    setState(() {
      _statusMessage = 'Pairing with $host:$port...';
    });

    final pairing = MobilePairingService(
      host: host,
      port: port,
      // A TLS-fronted tailnet rig answers pairing only on https; speaking the
      // wrong scheme returns 400. Carry the scheme learned from the saved
      // server / discovery record.
      scheme: scheme,
      // When the server identity is already known (saved server, prior
      // /api/info), enforce it BEFORE the pairing code is transmitted so a
      // MITM cannot harvest the code. Null on a genuine first-pair where the
      // fingerprint is not yet known (LAN trust establishes it out-of-band).
      pinnedFingerprint: pinnedFingerprint,
    );

    final RemotePairingVerifyResult result;
    try {
      result = await pairing.pairWithCode(
        code: pairingInput.code,
        requestAdminScope: pairingInput.admin,
      );
    } on RemotePairingFingerprintMismatch catch (e) {
      // Fail-closed: the pre-flight identity check refused to send the code.
      // Surface it loudly rather than letting it read as a generic failure.
      if (!mounted) return null;
      setState(() {
        _isDiscovering = false;
        _statusMessage = '';
        _error = e.message;
      });
      return null;
    }

    if (!mounted) return null;

    if (!result.success || result.token == null || result.token!.isEmpty) {
      setState(() {
        _isDiscovering = false;
        _statusMessage = '';
        _error =
            result.message ??
            'Pairing failed (${result.statusCode ?? 'unknown'}).';
      });
      return null;
    }

    return result.token;
  }

  /// Prompt for a relay URL + appliance id, then dial through the relay.
  /// Uses the connection-screen navigator context (the same one the QR scanner
  /// and pairing dialogs use) so the dialog mounts inside the MaterialApp.
  Future<void> _showRelayConnectDialog() async {
    // Prefill the relay URL + appliance id from a previously-connected relay
    // row so a returning operator taps Connect instead of re-reading the id
    // off the headless daemon. loadAll() is sorted most-recent-first. Done
    // before grabbing the UI context so the context is fetched fresh on the
    // far side of this await.
    String initialRelayUrl = '';
    String initialApplianceId = '';
    bool initialAllowInsecure = false;
    try {
      final saved = await ref.read(savedServersServiceProvider).loadAll();
      for (final s in saved) {
        if (s.isRelay) {
          initialRelayUrl = s.relayUrl ?? '';
          initialApplianceId = s.relayApplianceId ?? '';
          initialAllowInsecure = s.relayAllowInsecureTls;
          break;
        }
      }
    } catch (e) {
      developer.log(
        'relay prefill lookup failed: $e',
        name: 'Relay',
        level: 900,
      );
    }
    if (!mounted) return;

    final dialogContext = _connectionUiContext;
    if (dialogContext == null || !dialogContext.mounted) return;

    // The dialog owns its text controllers for the lifetime of the route (see
    // [RelayConnectDialog]) so they are disposed exactly once, when the route
    // is torn down — after the dismiss animation. Disposing them the instant
    // showDialog resolves would race that animation, which still rebuilds the
    // fields, and throw a use-after-dispose.
    final result =
        await showDialog<
          ({String relayUrl, String applianceId, bool allowInsecure})
        >(
          context: dialogContext,
          builder: (_) => RelayConnectDialog(
            initialRelayUrl: initialRelayUrl,
            initialApplianceId: initialApplianceId,
            initialAllowInsecure: initialAllowInsecure,
          ),
        );

    if (result == null) return;
    final relayUrl = result.relayUrl.trim();
    final applianceId = result.applianceId.trim();
    if (relayUrl.isEmpty || applianceId.isEmpty) {
      setState(() => _error = 'Enter both a relay URL and an appliance id.');
      return;
    }
    await _connectViaRelay(
      relayUrl: relayUrl,
      applianceId: applianceId,
      allowInsecureTls: result.allowInsecure,
    );
  }

  /// Open the Saved Servers screen from the connection screen.
  ///
  /// This is the DEFAULT-UI entry point into the roaming list. The screen's
  /// "Add server" FAB routes back here via [onAddServer]: rather than forking
  /// the QR / manual-entry / discovery plumbing, the callback simply pops the
  /// list so the operator lands back on the connection screen and uses its
  /// existing Search / Scan QR / Enter manually / Tailscale / Relay actions.
  /// Each of those now upserts the rig into Saved Servers on a successful
  /// connect, so the new row appears the next time the list is opened.
  ///
  /// Tapping a saved row connects through the screen's own activate path,
  /// which swaps the backend but does NOT touch [_connectedServer]. From the
  /// connection screen that leaves the shell stuck on "Not Connected", so we
  /// adopt the established session in [onServerSelected] rather than
  /// reconnecting.
  Future<void> _openSavedServers() async {
    final uiContext = _connectionUiContext;
    if (uiContext == null || !uiContext.mounted) {
      setState(() {
        _error = 'Connection UI is not ready yet. Try again in a moment.';
      });
      return;
    }
    await Navigator.of(uiContext).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SavedServersScreen(
          // "Add server" returns to the connection screen so the operator can
          // use the existing pairing flows. Returning null means "no row added
          // inline" — the screen just closes without a spurious snackbar.
          onAddServer: (screenContext) async {
            Navigator.of(screenContext).pop();
            return null;
          },
          // A saved row's _activateServer already brought the backend up; adopt
          // that live session so the shell leaves the connection screen. A
          // relay row is adopted inside _reconnectSavedRelay -> _connectToServer
          // (which already set _connectedServer + the monitor), so just pop.
          onServerSelected: (screenContext, server) async {
            if (server.isRelay) {
              if (screenContext.mounted) Navigator.of(screenContext).pop();
              return;
            }
            final token = await ref
                .read(savedServersServiceProvider)
                .tokenFor(server.id);
            if (!mounted) return;
            setState(() {
              _connectedServer = DiscoveredServer(
                name: server.displayName,
                host: server.host,
                webPort: server.port,
                mode: 'headless',
                scheme: server.scheme,
                authToken: token,
                authRequired: token != null,
                pairingSupported: true,
                fingerprint: server.pinnedFingerprint,
              );
              _error = null;
              _statusMessage = '';
            });
            _startConnectionMonitor();
            unawaited(_registerPushToken());
            ref.invalidate(appSettingsProvider);
            ref.invalidate(equipmentProfilesProvider);
            if (screenContext.mounted) Navigator.of(screenContext).pop();
          },
        ),
      ),
    );
  }

  Future<void> _scanQrCode() async {
    // The scanner performs strict schema + host-locality validation and pops a
    // confirmed [QrConnectionData], or null on cancel — never a raw string
    // through a permissive parser.
    final uiContext = _connectionUiContext;
    if (uiContext == null || !uiContext.mounted) {
      setState(() {
        _error = 'Connection UI is not ready yet. Try again in a moment.';
      });
      return;
    }

    QrConnectionData? data;
    try {
      data = await Navigator.of(uiContext).push<QrConnectionData>(
        MaterialPageRoute(
          builder: (_) => const QrScannerScreen(),
          fullscreenDialog: true,
        ),
      );
    } catch (e, stackTrace) {
      developer.log(
        'QR scanner failed: $e',
        name: 'Discovery',
        level: 1000,
        error: e,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _error = 'QR scanner failed: $e';
      });
      return;
    }

    if (data == null) return;

    setState(() {
      _isDiscovering = true;
      _statusMessage = 'Connecting via QR code...';
      _error = null;
    });

    var authToken = data.authToken;
    if ((authToken == null || authToken.isEmpty) &&
        data.pairingCode != null &&
        data.pairingCode!.isNotEmpty) {
      final pairing = MobilePairingService(
        host: data.host,
        port: data.webPort,
        // Speak the scheme the QR advertised (https for a TLS-fronted tailnet
        // rig, which answers pairing only over https).
        scheme: data.scheme,
        // Verify the server's identity BEFORE the pairing code leaves the
        // device. This runs the /api/info pre-flight inside the pairing
        // client; a hostile node presenting its own pairing endpoint cannot
        // harvest the code because the pin won't match.
        pinnedFingerprint: data.fingerprint,
      );
      final RemotePairingVerifyResult result;
      try {
        result = await pairing.pairWithCode(code: data.pairingCode!);
      } on RemotePairingFingerprintMismatch catch (e) {
        if (!mounted) return;
        setState(() {
          _isDiscovering = false;
          _statusMessage = '';
          _error = e.message;
        });
        return;
      }
      if (!mounted) return;
      if (!result.success || result.token == null) {
        setState(() {
          _isDiscovering = false;
          _statusMessage = '';
          _error = result.message ?? 'QR pairing failed.';
        });
        return;
      }
      authToken = result.token;
    }

    final server = data.toDiscoveredServer().copyWith(authToken: authToken);
    // Defense-in-depth: even when no pairing happened (the QR already carried a
    // token, so the pre-flight pin check above did not run), re-verify the live
    // server identity against the fingerprint baked into the QR before we hand
    // the connection to _connectToServer. _connectToServer's NetworkBackend
    // also pins via /api/info, but checking here keeps the failure local to the
    // QR flow with a QR-specific message.
    final fetched = await EnhancedSkotiqDiscovery.fetchServerInfo(server);
    if (!mounted) return;
    if (fetched?.fingerprint != null &&
        fetched!.fingerprint != data.fingerprint) {
      setState(() {
        _isDiscovering = false;
        _statusMessage = '';
        _error =
            'Server fingerprint does not match the QR code. Refusing to connect.';
      });
      return;
    }

    await _connectToServer(server);
  }

  /// Off-site onboarding: collect a Tailscale endpoint via the guided
  /// setup sheet, then run it through the canonical [_connectToServer]
  /// path (which handles /api/info enrichment, pairing, compatibility, and
  /// persistence). This is the primary path when the phone is NOT on the
  /// observatory LAN — discovery finds nothing because Tailscale has no
  /// broadcast domain, so the operator reaches the rig by its MagicDNS
  /// name / 100.x address.
  Future<void> _connectViaTailscale() async {
    // Prefill the host from a previously-connected rig's recorded tailnet
    // address so a returning operator taps Connect instead of retyping the
    // MagicDNS name. We pick the most-recently-connected saved server that
    // carries a tailscaleHost (loadAll() is sorted most-recent-first). Done
    // before grabbing the UI context so the context is fetched fresh on the
    // far side of this await.
    String? initialHost;
    try {
      final saved = await ref.read(savedServersServiceProvider).loadAll();
      for (final s in saved) {
        if (s.hasTailscaleHost) {
          initialHost = s.tailscaleHost;
          break;
        }
        // A rig whose primary host is itself a tailnet endpoint also seeds the
        // field — it is already a usable Tailscale address.
        if (s.isPrimaryTailscale) {
          initialHost = s.host;
          break;
        }
      }
    } catch (e) {
      // Best-effort prefill — fall through to an empty field on any failure.
      developer.log(
        'tailscale prefill lookup failed: $e',
        name: 'Discovery',
        level: 900,
      );
    }
    if (!mounted) return;

    final uiContext = _connectionUiContext;
    if (uiContext == null || !uiContext.mounted) {
      setState(() {
        _error = 'Connection UI is not ready yet. Try again in a moment.';
      });
      return;
    }
    final result = await TailscaleSetupSheet.show(
      uiContext,
      initialHost: initialHost,
    );
    if (result == null || !mounted) return;

    setState(() {
      _isDiscovering = true;
      _error = null;
      _statusMessage = 'Connecting to ${result.host}:${result.port}...';
    });

    // Build a DiscoveredServer carrying the operator's scheme + token so
    // fetchServerInfo probes the right protocol and the pairing branch in
    // _connectToServer only fires when no token was supplied.
    final server = DiscoveredServer(
      name: result.host,
      host: result.host,
      webPort: result.port,
      mode: 'headless',
      scheme: result.scheme,
      authToken: result.authToken,
      authRequired: result.authToken == null,
      pairingSupported: true,
    );
    await _connectToServer(server);
  }

  Future<void> _connectManually() async {
    final input = _ipController.text.trim();
    if (input.isEmpty) {
      setState(() {
        _error = 'Please enter a host name or IP address';
      });
      return;
    }

    final ManualServerEndpoint endpoint;
    try {
      endpoint = parseManualServerEndpoint(input);
    } on FormatException catch (error) {
      setState(() {
        _error = error.message.toString();
      });
      return;
    }
    final host = endpoint.host;
    final port = endpoint.port;

    var authToken = _accessTokenController.text.trim().isEmpty
        ? null
        : _accessTokenController.text.trim();

    setState(() {
      _isDiscovering = true;
      _error = null;
      _statusMessage = 'Connecting to ${endpoint.authority}...';
    });

    var server = DiscoveredServer(
      name: 'Skotiq Server',
      host: host,
      webPort: port,
      mode: 'headless',
      scheme: endpoint.scheme,
      authToken: authToken,
      pairingSupported: true,
    );

    final fetched = await EnhancedSkotiqDiscovery.fetchServerInfo(server);
    if (fetched != null) {
      server = fetched;
      if ((authToken == null || authToken.isEmpty) &&
          server.authRequired &&
          server.pairingSupported) {
        final paired = await _pairWithServer(
          host: host,
          port: port,
          // Use the scheme + identity the enriched /api/info reported so a
          // TLS-fronted host pairs over https and the pre-flight pins the
          // server before the code is sent.
          scheme: server.scheme,
          pinnedFingerprint: server.fingerprint,
        );
        if (paired == null) {
          return;
        }
        authToken = paired;
        server = server.copyWith(authToken: authToken);
      }
    } else {
      setState(() {
        _isDiscovering = false;
        _statusMessage = '';
        // Keep this platform-neutral: the host may be a Windows or Linux
        // desktop *or* a headless Raspberry Pi appliance, and this client runs
        // on phones as well as tablets. Naming "Windows Firewall" / "the
        // tablet" sent appliance users chasing settings that do not exist.
        _error =
            'Cannot reach ${endpoint.scheme}://${endpoint.authority}/api/info '
            'from this device.\n\n'
            'On the computer running Skotiq: confirm Settings → Remote '
            'Access shows "Running" (on a headless appliance, that the service '
            'is up), note the LAN URL, and allow port $port through that '
            "machine's firewall on the private/local network.\n\n"
            'On this device: open that URL in a browser — you should see JSON. '
            'Then try Connect again or scan the QR after starting pairing.';
      });
      return;
    }

    await _connectToServer(server);
  }
}

/// Relay-connect dialog. Owns its text controllers for the lifetime of the
/// route so they are disposed exactly once, when the route is torn down —
/// after the dismiss animation. Pops a `(relayUrl, applianceId,
/// allowInsecure)` record on Connect, or `null` on Cancel; the caller trims and
/// validates the fields. (The relay URL / appliance id are read at pop time,
/// before the controllers are disposed.)
class RelayConnectDialog extends StatefulWidget {
  final String initialRelayUrl;
  final String initialApplianceId;
  final bool initialAllowInsecure;

  const RelayConnectDialog({
    super.key,
    required this.initialRelayUrl,
    required this.initialApplianceId,
    required this.initialAllowInsecure,
  });

  @override
  State<RelayConnectDialog> createState() => _RelayConnectDialogState();
}

class _RelayConnectDialogState extends State<RelayConnectDialog> {
  late final TextEditingController _relayController = TextEditingController(
    text: widget.initialRelayUrl,
  );
  late final TextEditingController _idController = TextEditingController(
    text: widget.initialApplianceId,
  );
  late bool _allowInsecure = widget.initialAllowInsecure;

  @override
  void dispose() {
    _relayController.dispose();
    _idController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final keyboardAvailableHeight =
        mediaQuery.size.height - mediaQuery.viewInsets.vertical;
    final keyboardCompact =
        mediaQuery.viewInsets.bottom > 0 && keyboardAvailableHeight < 480;
    return AlertDialog(
      scrollable: true,
      insetPadding: keyboardCompact
          ? const EdgeInsets.symmetric(horizontal: 12, vertical: 4)
          : null,
      contentPadding: keyboardCompact
          ? const EdgeInsets.symmetric(horizontal: 16, vertical: 8)
          : null,
      actionsPadding: keyboardCompact
          ? const EdgeInsets.fromLTRB(8, 0, 8, 4)
          : null,
      titlePadding: keyboardCompact ? EdgeInsets.zero : null,
      title: Offstage(
        offstage: keyboardCompact,
        child: const Text('Connect via Relay'),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Offstage(
            offstage: keyboardCompact,
            child: const Column(
              children: [
                Text(
                  'Reach your rig from anywhere through a self-hosted '
                  'Skotiq relay — no VPN or port forwarding. The appliance '
                  'id is printed by the headless daemon on first connect.',
                  style: TextStyle(fontSize: 13),
                ),
                SizedBox(height: 12),
              ],
            ),
          ),
          TextField(
            key: const ValueKey('relay-url-field'),
            controller: _relayController,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'Relay URL',
              hintText: 'wss://relay.example.com',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('relay-appliance-id-field'),
            controller: _idController,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Appliance id',
              hintText: 'xxxx-xxxx-xxxx',
            ),
          ),
          Offstage(
            offstage: keyboardCompact,
            child: Column(
              children: [
                const SizedBox(height: 8),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _allowInsecure,
                  onChanged: (v) => setState(() => _allowInsecure = v ?? false),
                  title: const Text(
                    'Trust self-signed relay TLS',
                    style: TextStyle(fontSize: 13),
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop((
            relayUrl: _relayController.text,
            applianceId: _idController.text,
            allowInsecure: _allowInsecure,
          )),
          child: const Text('Connect'),
        ),
      ],
    );
  }
}

/// Code-pairing dialog. A real StatefulWidget (not a StatefulBuilder over
/// method-locals) so the [TextEditingController] is disposed by the
/// framework when the dialog element unmounts — after the route's exit
/// animation — never while a final rebuild can still touch it.
///
/// Public (rather than library-private) so widget tests can pump the dialog
/// directly and pin its input validation.
@visibleForTesting
class PairingCodeDialog extends StatefulWidget {
  final String host;
  final int port;
  final String? initialCode;

  const PairingCodeDialog({
    super.key,
    required this.host,
    required this.port,
    this.initialCode,
  });

  @override
  State<PairingCodeDialog> createState() => _PairingCodeDialogState();
}

class _PairingCodeDialogState extends State<PairingCodeDialog> {
  late final TextEditingController _codeController;
  bool _requestAdmin = false;

  /// Inline validation message for the code field. An empty code must say why
  /// rather than no-op behind an enabled-looking "Pair" button.
  String? _codeError;

  @override
  void initState() {
    super.initState();
    _codeController = TextEditingController(text: widget.initialCode ?? '');
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return SkotiqDialog(
      title: 'Pair with Skotiq',
      icon: LucideIcons.link,
      width: 420,
      actions: [
        SkotiqButton(
          onPressed: () => Navigator.of(context).pop(),
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
        ),
        SkotiqButton(
          onPressed: () {
            final trimmed = _codeController.text.trim();
            if (trimmed.isEmpty) {
              setState(() {
                _codeError = 'Enter the pairing code before tapping Pair.';
              });
              return;
            }
            Navigator.of(context).pop((code: trimmed, admin: _requestAdmin));
          },
          label: 'Pair',
          size: ButtonSize.small,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Enter the pairing code shown on the appliance. Read it '
            'from the pairing page in a browser — open '
            'http://${widget.host}:${widget.port}/pair — or from the '
            "desktop's Remote Access screen.",
            style: TextStyle(fontSize: 13, color: colors.textSecondary),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _codeController,
            decoration: InputDecoration(
              labelText: 'Pairing code',
              hintText: 'STAR-LYRA-1234',
              errorText: _codeError,
            ),
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
            onChanged: (_) {
              if (_codeError != null) setState(() => _codeError = null);
            },
          ),
          // Own Material: SkotiqDialog paints its surface with a
          // DecoratedBox, which sits between this tile and the nearest
          // Material ancestor. Flutter asserts on that arrangement because the
          // tile's background and tap ripple are painted on that Material and
          // would be hidden — the admin toggle gave no touch feedback at all.
          Material(
            type: MaterialType.transparency,
            child: CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Grant full admin access'),
              subtitle: const Text(
                'Off by default. Enable only if this device should '
                'manage backups and filesystem paths.',
              ),
              value: _requestAdmin,
              onChanged: (value) {
                setState(() => _requestAdmin = value ?? false);
              },
            ),
          ),
        ],
      ),
    );
  }
}
