import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../utils/user_facing_error.dart';

/// INDI server address configuration (Linux/macOS).
class IndiServerDialog extends ConsumerStatefulWidget {
  const IndiServerDialog({super.key});

  @override
  ConsumerState<IndiServerDialog> createState() => _IndiServerDialogState();
}

class _IndiServerDialogState extends ConsumerState<IndiServerDialog> {
  late final TextEditingController _hostController;
  late final TextEditingController _portController;

  // Independent busy flags so a probe and a save can each guard against
  // double-taps and against each other without either being mistaken for the
  // other's spinner.
  bool _isTesting = false;
  bool _isSaving = false;

  // Tracks whether the async settings hydration has completed and whether the
  // user has typed into each field. Late hydration must never clobber an edit
  // the operator made while the load was still in flight.
  bool _hostEdited = false;
  bool _portEdited = false;

  String? _statusMessage;
  bool? _statusSuccess;
  String? _hostError;
  String? _portError;

  @override
  void initState() {
    super.initState();
    // Initialize with default values; persisted settings hydrate in below.
    _hostController = TextEditingController(text: 'localhost');
    _portController = TextEditingController(text: '7624');

    WidgetsBinding.instance.addPostFrameCallback((_) => _hydrateFromSettings());
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  /// Load the persisted INDI address, tolerating a failing settings source.
  Future<void> _hydrateFromSettings() async {
    try {
      final settings = await ref.read(appSettingsProvider.future);
      if (!mounted) return;
      setState(() {
        // Only adopt persisted values for fields the operator has not touched,
        // so a slow load never overwrites what they typed in the meantime.
        if (!_hostEdited) {
          _hostController.text = settings.indiServerHost;
        }
        if (!_portEdited) {
          _portController.text = settings.indiServerPort.toString();
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusSuccess = false;
        _statusMessage = 'Could not load saved INDI settings: $e';
      });
    }
  }

  /// Validate host and port, surfacing per-field errors. Returns the parsed
  /// values only when both are valid — never silently coerces a malformed port
  /// to a default.
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

    if (hostError != null || portError != null || port == null) {
      return null;
    }
    return (host: host, port: port);
  }

  /// Drop a Test connection verdict once the address it describes is gone.
  ///
  /// The status line names the endpoint it probed ("No response on
  /// localhost:7624."). Leaving it up while the operator retypes the host
  /// leaves a failure report attached to an address that is no longer in the
  /// dialog, and the natural reading is that the NEW address failed. Must be
  /// called from inside a `setState`.
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
      // Real, awaited discovery probe against the entered address.
      final deviceService = ref.read(deviceServiceProvider);
      final devices =
          await deviceService.discoverIndiAtAddress(inputs.host, inputs.port);

      if (!mounted) return;
      setState(() {
        _isTesting = false;
        final n = devices.length;
        // An EMPTY result is not evidence of a connection. The FFI backend
        // catches a refused/timed-out INDI socket and returns an empty device
        // list (ffi_backend/discovery_camera_operations.dart
        // `_discoverAddressDevices`), so "connected to a server with no drivers
        // loaded" and "nothing is listening on that address at all" arrive here
        // as the exact same value. Reporting the first as a green tick sent an
        // operator who had typo'd their Raspberry Pi's address off to hunt the
        // wrong problem all night. Only a device we actually enumerated proves
        // the server answered.
        _statusSuccess = n > 0;
        _statusMessage = n > 0
            ? 'Connected. Found $n device${n == 1 ? '' : 's'}.'
            : 'No INDI devices at ${inputs.host}:${inputs.port}. If '
                'indiserver is running there, it has no drivers loaded — '
                'otherwise check the host and port.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isTesting = false;
        _statusSuccess = false;
        // Name the endpoint that was actually probed, matching the PHD2 test's
        // wording on the guider step.
        _statusMessage = 'No response on ${inputs.host}:${inputs.port}. '
            '${userFacingError(e)}';
      });
    }
  }

  /// Persist the INDI server address. This only stores configuration — it does
  /// not open a live INDI session (startup discovery consults it later) — so
  /// the action is labelled "Save", not "Connect".
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
      final settingsNotifier = ref.read(appSettingsProvider.notifier);
      await settingsNotifier.setIndiServerHost(inputs.host);
      await settingsNotifier.setIndiServerPort(inputs.port);
    } catch (e) {
      if (!mounted) return;
      // Keep the dialog open so the operator can retry.
      setState(() {
        _isSaving = false;
        _statusSuccess = false;
        _statusMessage = 'Could not save INDI settings: $e';
      });
      return;
    }

    if (!mounted) return;
    Navigator.pop(context, {
      'host': inputs.host,
      'port': inputs.port,
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final busy = _isTesting || _isSaving;

    return SkotiqDialog(
      title: 'INDI server',
      width: SkotiqDialog.widthConfirm,
      closeEnabled: !busy,
      actions: [
        SkotiqButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          label: 'Cancel',
          variant: ButtonVariant.ghost,
        ),
        SkotiqButton(
          onPressed: busy ? null : _save,
          label: _isSaving ? 'Saving…' : 'Save',
          variant: ButtonVariant.primary,
          isLoading: _isSaving,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // One line of context under the title (05 §13), not a tinted card.
          Text(
            'INDI gives Linux and macOS a common interface to astronomical '
            'equipment. Skotiq reads devices from the server at this '
            'address.',
            style:
                SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          FormRow(
            label: 'Host',
            child: Semantics(
              label: 'Host',
              child: SkotiqTextField(
                key: const ValueKey('indi-host-field'),
                controller: _hostController,
                hint: 'localhost or IP address',
                errorText: _hostError,
                onChanged: (_) {
                  _hostEdited = true;
                  setState(() {
                    _hostError = null;
                    _clearStaleProbeResult();
                  });
                },
              ),
            ),
          ),
          const SizedBox(height: FormRow.rowGap),
          FormRow(
            label: 'Port',
            child: Semantics(
              label: 'Port',
              child: SkotiqTextField(
                key: const ValueKey('indi-port-field'),
                controller: _portController,
                hint: '7624',
                mono: true,
                errorText: _portError,
                keyboardType: TextInputType.number,
                onChanged: (_) {
                  _portEdited = true;
                  setState(() {
                    _portError = null;
                    _clearStaleProbeResult();
                  });
                },
              ),
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          Align(
            alignment: Alignment.centerLeft,
            child: SkotiqButton(
              onPressed: busy ? null : _testConnection,
              icon: SkotiqIcons.refresh,
              label: _isTesting ? 'Testing…' : 'Test connection',
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              isLoading: _isTesting,
            ),
          ),

          // The probe's verdict, as the one banner this dialog has.
          if (_statusMessage != null) ...[
            const SizedBox(height: SkotiqTokens.spaceMd),
            SkotiqBanner(
              tone: (_statusSuccess ?? false)
                  ? BannerTone.success
                  : BannerTone.error,
              icon: (_statusSuccess ?? false)
                  ? SkotiqIcons.success
                  : SkotiqIcons.error,
              title: _statusMessage!,
            ),
          ],
        ],
      ),
    );
  }
}
