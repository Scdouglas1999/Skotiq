import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/user_facing_error.dart';

/// Alpaca (ASCOM Remote) server address editor.
///
/// The only writer of `setAlpacaServerHost` / `setAlpacaServerPort`, which
/// `unified_discovery_provider.dart` reads. Without it the address is pinned to
/// the stored default `localhost:11111`, and the common Alpaca deployment —
/// ASCOM Remote on another machine on the LAN — is unreachable.
///
/// Deliberately mirrors [IndiServerDialog] (host / port / Test / Save,
/// per-field validation, no silent coercion of a bad port) so the two protocol
/// addresses behave identically.
class AlpacaServerDialog extends ConsumerStatefulWidget {
  const AlpacaServerDialog({super.key});

  @override
  ConsumerState<AlpacaServerDialog> createState() => _AlpacaServerDialogState();
}

class _AlpacaServerDialogState extends ConsumerState<AlpacaServerDialog> {
  late final TextEditingController _hostController;
  late final TextEditingController _portController;

  bool _isTesting = false;
  bool _isSaving = false;

  // Late hydration must never clobber an edit made while the load was still
  // in flight.
  bool _hostEdited = false;
  bool _portEdited = false;

  String? _statusMessage;
  bool? _statusSuccess;
  String? _hostError;
  String? _portError;

  @override
  void initState() {
    super.initState();
    _hostController = TextEditingController(text: 'localhost');
    _portController = TextEditingController(text: '11111');
    WidgetsBinding.instance.addPostFrameCallback((_) => _hydrateFromSettings());
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  Future<void> _hydrateFromSettings() async {
    try {
      final settings = await ref.read(appSettingsProvider.future);
      if (!mounted) return;
      setState(() {
        if (!_hostEdited) _hostController.text = settings.alpacaServerHost;
        if (!_portEdited) {
          _portController.text = settings.alpacaServerPort.toString();
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusSuccess = false;
        _statusMessage = 'Could not load saved Alpaca settings: $e';
      });
    }
  }

  /// Validate host and port, surfacing per-field errors. Returns the parsed
  /// values only when both are valid — never silently coerces a malformed
  /// port to a default.
  ({String host, int port})? _validatedInputs() {
    final host = _hostController.text.trim();
    final portRaw = _portController.text.trim();

    String? hostError;
    String? portError;

    if (host.isEmpty) {
      hostError = 'Enter a host name or IP address.';
    }
    final port = int.tryParse(portRaw);
    if (port == null) {
      portError = 'Port must be a whole number.';
    } else if (port < 1 || port > 65535) {
      portError = 'Port must be between 1 and 65535.';
    }

    setState(() {
      _hostError = hostError;
      _portError = portError;
    });

    if (hostError != null || portError != null || port == null) return null;
    return (host: host, port: port);
  }

  /// Drop a Test Connection verdict once the address it describes is gone.
  ///
  /// The status line names the endpoint it probed ("No response on
  /// localhost:11111."). Leaving it up while the operator retypes the host
  /// leaves a failure report attached to an address that is no longer in the
  /// dialog — the reader has no way to tell it is stale, and the natural
  /// reading is that the NEW address failed. Must be called from inside a
  /// `setState`.
  void _clearStaleProbeResult() {
    _statusMessage = null;
    _statusSuccess = null;
  }

  Future<void> _testConnection() async {
    if (_isTesting || _isSaving) return;
    final inputs = _validatedInputs();
    if (inputs == null) return;

    setState(() {
      _isTesting = true;
      _statusMessage = null;
      _statusSuccess = null;
    });

    try {
      final devices = await ref
          .read(deviceServiceProvider)
          .discoverAlpacaAtAddress(inputs.host, inputs.port);
      if (!mounted) return;
      setState(() {
        _isTesting = false;
        final n = devices.length;
        // An empty list is not evidence of a connection: a refused socket and
        // a reachable server with nothing published both arrive here as zero
        // devices. Only an enumerated device proves the server answered.
        _statusSuccess = n > 0;
        _statusMessage = n > 0
            ? 'Connected. Found $n device${n == 1 ? '' : 's'}.'
            : 'No Alpaca devices at ${inputs.host}:${inputs.port}. If an '
                'Alpaca/ASCOM Remote server is running there it has nothing '
                'published — otherwise check the host and port.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isTesting = false;
        _statusSuccess = false;
        _statusMessage = 'No response on ${inputs.host}:${inputs.port}. '
            '${userFacingError(e)}';
      });
    }
  }

  /// Persist the address. This stores configuration only — startup discovery
  /// consults it later — so the action is "Save", not "Connect".
  Future<void> _save() async {
    if (_isSaving || _isTesting) return;
    final inputs = _validatedInputs();
    if (inputs == null) return;

    setState(() {
      _isSaving = true;
      _statusMessage = null;
      _statusSuccess = null;
    });

    try {
      final notifier = ref.read(appSettingsProvider.notifier);
      await notifier.setAlpacaServerHost(inputs.host);
      await notifier.setAlpacaServerPort(inputs.port);
    } catch (e) {
      if (!mounted) return;
      // Keep the dialog open so the operator can retry.
      setState(() {
        _isSaving = false;
        _statusSuccess = false;
        _statusMessage = 'Could not save Alpaca settings: $e';
      });
      return;
    }

    if (!mounted) return;
    Navigator.pop(context, {'host': inputs.host, 'port': inputs.port});
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    final dialog = AlertDialog(
      backgroundColor: colors.surface,
      title: Row(
        children: [
          Icon(SkotiqIcons.power, color: colors.primary, size: 24),
          const SizedBox(width: 12),
          Text(
            'Alpaca Server Configuration',
            style: SkotiqTypography.body.copyWith(
              color: colors.textPrimary,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: dialogMaxWidth(context, 400),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: SkotiqDecorations.emphasisSurface(
                colors.primary,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(SkotiqIcons.info, color: colors.primary, size: 16),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'ASCOM Alpaca exposes equipment over the network, so the '
                      'server is often another machine on the LAN (an ASCOM '
                      'Remote host or a device with built-in Alpaca).',
                      style: SkotiqTypography.captionSm.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              key: const ValueKey('alpaca-host-field'),
              controller: _hostController,
              style: SkotiqTypography.body.copyWith(
                color: colors.textPrimary,
              ),
              onChanged: (_) {
                _hostEdited = true;
                setState(() {
                  _hostError = null;
                  _clearStaleProbeResult();
                });
              },
              decoration: InputDecoration(
                labelText: 'Alpaca Server Host',
                labelStyle: SkotiqTypography.body.copyWith(
                  color: colors.textMuted,
                ),
                hintText: 'localhost or IP address',
                hintStyle: SkotiqTypography.body.copyWith(
                  color: colors.textMuted.withValues(alpha: 0.5),
                ),
                errorText: _hostError,
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: colors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: colors.primary),
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('alpaca-port-field'),
              controller: _portController,
              style: SkotiqTypography.body.copyWith(
                color: colors.textPrimary,
              ),
              keyboardType: TextInputType.number,
              onChanged: (_) {
                _portEdited = true;
                setState(() {
                  _portError = null;
                  _clearStaleProbeResult();
                });
              },
              decoration: InputDecoration(
                labelText: 'Port',
                labelStyle: SkotiqTypography.body.copyWith(
                  color: colors.textMuted,
                ),
                hintText: '11111 (default)',
                hintStyle: SkotiqTypography.body.copyWith(
                  color: colors.textMuted.withValues(alpha: 0.5),
                ),
                errorText: _portError,
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: colors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: colors.primary),
                ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: SkotiqButton(
                onPressed: (_isTesting || _isSaving) ? null : _testConnection,
                icon: SkotiqIcons.refresh,
                label: _isTesting ? 'Testing...' : 'Test Connection',
                variant: ButtonVariant.secondary,
                isLoading: _isTesting,
              ),
            ),
            if (_statusMessage != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: SkotiqDecorations.emphasisSurface(
                  _statusSuccess == true ? colors.success : colors.error,
                  borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
                ),
                child: Row(
                  children: [
                    Icon(
                      _statusSuccess == true
                          ? SkotiqIcons.success
                          : SkotiqIcons.error,
                      size: 16,
                      color: _statusSuccess == true
                          ? colors.success
                          : colors.error,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _statusMessage!,
                        style: SkotiqTypography.captionSm.copyWith(
                          color: colors.textSecondary,
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
          onPressed:
              (_isSaving || _isTesting) ? null : () => Navigator.pop(context),
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
        ),
        SkotiqButton(
          onPressed: (_isSaving || _isTesting) ? null : _save,
          label: _isSaving ? 'Saving...' : 'Save',
          variant: ButtonVariant.primary,
          isLoading: _isSaving,
        ),
      ],
    );
    return PopScope(canPop: !_isTesting && !_isSaving, child: dialog);
  }
}
