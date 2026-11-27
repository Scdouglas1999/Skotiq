// Discovery and pairing operations: the user-facing entry points that
// FIND or NAME a server (auto-discovery, QR scan, manual entry, Tailscale
// onboarding, the relay-connect dialog, the saved-servers screen) and the
// code-pairing dialog. Each ultimately hands a resolved
// [DiscoveredServer] to [connectToRig] (or routes through
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
      _statusMessage = 'Looking for it on this Wi-Fi…';
    });

    try {
      Log.debug('Starting enhanced auto-discovery...', source: 'Discovery');

      final server = await EnhancedSkotiqDiscovery.discoverWithFallback(
        onStatus: (status) {
          if (mounted) {
            setState(() => _statusMessage = _discoveryStatusText(status));
          }
        },
      );

      if (server != null) {
        Log.info(
          'Found server: ${server.name} at ${server.host}',
          source: 'Discovery',
        );

        // Save for future reconnects
        await connectToRig(server);
      } else {
        Log.warning('No server found via any method', source: 'Discovery');
        setState(() {
          _isDiscovering = false;
          _statusMessage = '';
          _error =
              'No imaging computer answered on this Wi-Fi. Check that '
              'Skotiq is open on it and that both are on the same network, '
              'then scan its QR code or enter its address. Away from home, '
              'use Tailscale or a relay below. If it still is not found, '
              'its firewall may be blocking UDP 45679 and TCP 8080.';
        });
      }
    } catch (e, stackTrace) {
      Log.error(
        'Discovery error: $e',
        source: 'Discovery',
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
  Future<String?> _pairWithServer(
    DiscoveredServer server, {
    String? initialCode,
  }) async {
    final host = server.host;
    final port = server.webPort;
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
    final pairingInput = await showDialog<PairingDialogResult>(
      context: uiContext,
      builder: (ctx) => PairingCodeDialog(
        host: host,
        port: port,
        serverName: server.name,
        initialCode: initialCode,
      ),
    );

    if (pairingInput != null && pairingInput.scan && mounted) {
      setState(() {
        _isDiscovering = false;
        _statusMessage = '';
      });
      await _scanQrCode();
      return null;
    }

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

    try {
      final paired = await MobilePairingService.pairWithCode(
        server,
        code: pairingInput.code,
        fullAccess: pairingInput.admin,
      );
      return paired.token;
    } on RigPairingFailure catch (failure) {
      final message = _phonePairingError(
        failure,
        fallback: 'Pairing failed (${failure.statusCode ?? 'unknown'}).',
      );
      if (!mounted) return null;
      setState(() {
        _isDiscovering = false;
        _statusMessage = '';
        _error = message;
      });
      return null;
    }
  }

  /// The phone's words for a refused pairing. A request that never reached
  /// the host is rethrown to the connect flow's own error handling.
  String _phonePairingError(
    RigPairingFailure failure, {
    required String fallback,
  }) {
    final cause = failure.cause;
    if (failure.kind == RigPairingFailureKind.fingerprintMismatch) {
      return failure.message;
    }
    if (cause != null) throw cause;
    return failure.hostMessage ?? fallback;
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
      Log.warning('relay prefill lookup failed: $e', source: 'Relay');
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
  /// Tapping a saved row connects through [connectToRig] (registered as
  /// [rigConnectProvider]), which leaves the connection screen on success, so
  /// the list only has to close.
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
          onServerSelected: (screenContext, server) async {
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
      Log.error(
        'QR scanner failed: $e',
        source: 'Discovery',
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
      try {
        // The QR's fingerprint is checked before the code leaves the phone.
        final paired = await MobilePairingService.pairWithCode(
          data.toDiscoveredServer(),
          code: data.pairingCode!,
          fullAccess: true,
        );
        authToken = paired.token;
      } on RigPairingFailure catch (failure) {
        final message = _phonePairingError(
          failure,
          fallback: 'QR pairing failed.',
        );
        if (!mounted) return;
        setState(() {
          _isDiscovering = false;
          _statusMessage = '';
          _error = message;
        });
        return;
      }
    }

    final server = data.toDiscoveredServer().copyWith(authToken: authToken);
    // Defense-in-depth: even when no pairing happened (the QR already carried a
    // token, so the pre-flight pin check above did not run), re-verify the live
    // server identity against the fingerprint baked into the QR before we hand
    // the connection to connectToRig. connectToRig's NetworkBackend
    // also pins via /api/info, but checking here keeps the failure local to the
    // QR flow with a QR-specific message.
    final fetched = (await EnhancedSkotiqDiscovery.readServer(server)).server;
    if (!mounted) return;
    if (fetched.fingerprint != null &&
        fetched.fingerprint != data.fingerprint) {
      setState(() {
        _isDiscovering = false;
        _statusMessage = '';
        _error =
            'Server fingerprint does not match the QR code. Refusing to connect.';
      });
      return;
    }

    await connectToRig(server);
  }

  /// Off-site onboarding: collect a Tailscale endpoint via the guided
  /// setup sheet, then run it through the canonical [connectToRig]
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
      Log.warning('tailscale prefill lookup failed: $e', source: 'Discovery');
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
    // readServer probes the right protocol and the pairing branch in
    // connectToRig only fires when no token was supplied.
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
    await connectToRig(server);
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

    final read = await EnhancedSkotiqDiscovery.readServer(server);
    final problem = read.problem;
    if (problem != null && problem.kind != LinkProblemKind.mismatch) {
      setState(() {
        _isDiscovering = false;
        _statusMessage = '';
        _error = problem.message;
        _mismatchedHost = null;
      });
      return;
    }
    // connectToRig pairs when the host needs it: one tap on the home network,
    // else the code dialog, the same as for a host found by searching.
    server = read.server;
    await connectToRig(server);
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
                  style: TextStyle(fontSize: SkotiqTypography.fontSize13),
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
                    style: TextStyle(fontSize: SkotiqTypography.fontSize13),
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

/// What [PairingCodeDialog] pops: a typed [code], or [scan] when the operator
/// chose to scan the QR code instead. [admin] asks the host for full control.
typedef PairingDialogResult = ({String code, bool admin, bool scan});

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

  /// The name the computer announced, shown so a phone near two rigs knows
  /// which one it is pairing with.
  final String? serverName;

  const PairingCodeDialog({
    super.key,
    required this.host,
    required this.port,
    this.initialCode,
    this.serverName,
  });

  @override
  State<PairingCodeDialog> createState() => _PairingCodeDialogState();
}

class _PairingCodeDialogState extends State<PairingCodeDialog> {
  late final TextEditingController _codeController;
  bool _requestAdmin = true;

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

  void _submit() {
    final trimmed = _codeController.text.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _codeError = 'Enter the pairing code before tapping Pair.';
      });
      return;
    }
    Navigator.of(
      context,
    ).pop((code: trimmed, admin: _requestAdmin, scan: false));
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
        SkotiqButton(onPressed: _submit, label: 'Pair', size: ButtonSize.small),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(LucideIcons.monitor, size: 16, color: colors.textSecondary),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Expanded(
                child: Text(
                  [
                    if (widget.serverName case final name? when name.isNotEmpty)
                      name,
                    widget.host,
                  ].join(' · '),
                  style: SkotiqTypography.labelStrongSm.copyWith(
                    color: colors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'On the imaging computer, open Settings → Remote access and '
            'press Start pairing. Scan the QR code it shows, or type the code.',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize14,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          SkotiqButton(
            onPressed: () => Navigator.of(
              context,
            ).pop((code: '', admin: _requestAdmin, scan: true)),
            label: 'Scan QR code',
            icon: LucideIcons.scanLine,
            variant: ButtonVariant.secondary,
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
            enableSuggestions: false,
            keyboardType: TextInputType.visiblePassword,
            textInputAction: TextInputAction.go,
            onSubmitted: (_) => _submit(),
            onChanged: (_) {
              if (_codeError != null) setState(() => _codeError = null);
            },
          ),
          const SizedBox(height: 12),
          SkotiqSwitchRow(
            label: 'Full control of the imaging computer',
            subtitle:
                'Lets this phone choose capture folders and manage '
                'backups too. Turn it off for a phone you lend to someone.',
            value: _requestAdmin,
            onChanged: (value) => setState(() => _requestAdmin = value),
          ),
          const SizedBox(height: 12),
          Text(
            // The page at /pair never shows a code, and on the same Wi-Fi
            // this dialog does not come up at all: the phone pairs in one
            // tap. It is here for a rig reached from away or set to require
            // a code, where the code sits in a file on that computer.
            'No screen on the imaging computer? On its Wi-Fi this phone '
            'pairs without a code. From elsewhere, the code is in '
            'pairing-code.txt in Skotiq\'s data folder on that computer.',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize13,
              color: colors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

/// The discovery's progress in the phone's words: the methods it tries are
/// its business, where it is looking is the operator's.
String _discoveryStatusText(String status) {
  if (status.startsWith('Checking last server')) {
    return 'Trying the computer this phone used last…';
  }
  if (status.contains('broadcast') || status.contains('mDNS')) {
    return 'Looking for it on this Wi-Fi…';
  }
  return status;
}
