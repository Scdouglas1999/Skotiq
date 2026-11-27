// The connection screen's entry points that open a dialog or a screen first
// (the relay dialog, the Saved Servers list, the QR scanner, the Tailscale
// sheet, the address form) and then hand what the operator gave to the core
// connect flow ([RigConnectionService]).
part of '../main.dart';

mixin _MobileConnectActions on ConsumerState<SkotiqMobileApp> {
  RigConnectionService get _connection => ref.read(rigConnectionProvider);

  final TextEditingController _ipController = TextEditingController(text: '');
  final TextEditingController _accessTokenController = TextEditingController(
    text: '',
  );

  // Tokens are sensitive: obscured by default. The trailing icon shows the
  // value for an operator who needs to check it while pairing.
  bool _accessTokenVisible = false;

  /// Prompt for a relay URL + appliance id, then dial through the relay.
  Future<void> _showRelayConnectDialog() async {
    // Prefill from the most recent relay row (loadAll() is sorted
    // most-recent-first) so a returning operator taps Connect instead of
    // re-reading the id off the headless daemon. Done before grabbing the UI
    // context so the context is fetched fresh on the far side of this await.
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

    final dialogContext = phoneConnectionUiContext();
    if (dialogContext == null || !dialogContext.mounted) return;

    // The dialog owns its text controllers for the lifetime of the route (see
    // [RelayConnectDialog]) so they are disposed after the dismiss animation.
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
      _connection.report(const ConnectRelayFieldsMissing());
      return;
    }
    await _connection.connectViaRelay(
      relayUrl: relayUrl,
      applianceId: applianceId,
      allowInsecureTls: result.allowInsecure,
    );
  }

  /// Opens the Saved Servers list from the connection screen. Its "Add
  /// server" returns here, to the screen's own search, scan and address
  /// actions; each of those saves the rig on a successful connect. A saved
  /// row connects through the core flow, which leaves this screen on
  /// success, so the list only has to close.
  Future<void> _openSavedServers() async {
    final uiContext = phoneConnectionUiContext();
    if (uiContext == null) {
      _connection.report(const ConnectUiNotReady());
      return;
    }
    await Navigator.of(uiContext).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SavedServersScreen(
          // Returning null means "no row added inline": the screen closes
          // without a snackbar.
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

  Future<void> _scanQrCode() => scanQrAndConnect(_connection);

  /// Off-site onboarding: a Tailscale endpoint from the guided setup sheet.
  Future<void> _connectViaTailscale() async {
    // Prefill from the most recently connected saved server that carries a
    // tailnet address (loadAll() is sorted most-recent-first).
    String? initialHost;
    try {
      final saved = await ref.read(savedServersServiceProvider).loadAll();
      for (final s in saved) {
        if (s.hasTailscaleHost) {
          initialHost = s.tailscaleHost;
          break;
        }
        // A rig whose primary host is itself a tailnet endpoint also seeds
        // the field.
        if (s.isPrimaryTailscale) {
          initialHost = s.host;
          break;
        }
      }
    } catch (e) {
      // The field starts empty.
      Log.warning('tailscale prefill lookup failed: $e', source: 'Discovery');
    }
    if (!mounted) return;

    final uiContext = phoneConnectionUiContext();
    if (uiContext == null || !uiContext.mounted) {
      _connection.report(const ConnectUiNotReady());
      return;
    }
    final result = await TailscaleSetupSheet.show(
      uiContext,
      initialHost: initialHost,
    );
    if (result == null || !mounted) return;

    await _connection.connectTailscale(
      host: result.host,
      port: result.port,
      scheme: result.scheme,
      authToken: result.authToken,
    );
  }

  Future<void> _connectManually() async {
    final input = _ipController.text.trim();
    if (input.isEmpty) {
      _connection.report(const ConnectAddressMissing());
      return;
    }

    final ManualServerEndpoint endpoint;
    try {
      endpoint = parseManualServerEndpoint(input);
    } on FormatException catch (error) {
      _connection.report(ConnectAddressInvalid(error.message.toString()));
      return;
    }

    final token = _accessTokenController.text.trim();
    await _connection.connectAddress(
      host: endpoint.host,
      port: endpoint.port,
      scheme: endpoint.scheme,
      authority: endpoint.authority,
      authToken: token.isEmpty ? null : token,
    );
  }
}
