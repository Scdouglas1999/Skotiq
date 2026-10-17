import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../utils/phd2_helper.dart';

/// Reusable PHD2 connection configuration dialog.
///
/// Allows users to enter PHD2 host and port, saves settings,
/// and initiates connection.
class Phd2ConnectionDialog extends ConsumerStatefulWidget {
  final String initialHost;
  final int initialPort;

  const Phd2ConnectionDialog({
    super.key,
    required this.initialHost,
    required this.initialPort,
  });

  /// Shows the PHD2 connection dialog.
  ///
  /// Reads current settings from [appSettingsProvider] and displays
  /// a dialog for the user to configure and connect.
  static Future<void> show(BuildContext context, WidgetRef ref) async {
    final settings = await ref.read(appSettingsProvider.future);
    if (!context.mounted) return;
    return showDialog(
      context: context,
      builder: (_) => UncontrolledProviderScope(
        container: ProviderScope.containerOf(context),
        child: Phd2ConnectionDialog(
          initialHost: settings.phd2Host,
          initialPort: settings.phd2Port,
        ),
      ),
    );
  }

  @override
  ConsumerState<Phd2ConnectionDialog> createState() =>
      _Phd2ConnectionDialogState();
}

class _Phd2ConnectionDialogState extends ConsumerState<Phd2ConnectionDialog> {
  late final TextEditingController _hostController;
  late final TextEditingController _portController;

  /// Guards against a double-tapped Connect (each tap otherwise saves settings
  /// and fires a fresh connect).
  bool _connecting = false;

  @override
  void initState() {
    super.initState();
    _hostController = TextEditingController(text: widget.initialHost);
    _portController =
        TextEditingController(text: widget.initialPort.toString());
  }

  @override
  void dispose() {
    _hostController.dispose();
    _portController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final mediaQuery = MediaQuery.of(context);
    final keyboardAvailableHeight =
        mediaQuery.size.height - mediaQuery.viewInsets.vertical;
    final keyboardCompact =
        mediaQuery.viewInsets.bottom > 0 && keyboardAvailableHeight < 480;

    final dialog = AlertDialog(
      backgroundColor: colors.surface,
      scrollable: true,
      insetPadding: keyboardCompact
          ? const EdgeInsets.symmetric(horizontal: 12, vertical: 4)
          : null,
      contentPadding: keyboardCompact
          ? const EdgeInsets.symmetric(horizontal: 16, vertical: 8)
          : null,
      actionsPadding:
          keyboardCompact ? const EdgeInsets.fromLTRB(8, 0, 8, 4) : null,
      titlePadding: keyboardCompact ? EdgeInsets.zero : null,
      title: Offstage(
        offstage: keyboardCompact,
        child: Text(
          'PHD2 Connection',
          style: TextStyle(color: colors.textPrimary),
        ),
      ),
      content: ConstrainedBox(
        constraints: Responsive.dialogConstraints(
          context,
          preferredWidth: 360,
          minWidth: 280,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _hostController,
              style: TextStyle(color: colors.textPrimary),
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Host',
                labelStyle: TextStyle(color: colors.textMuted),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: colors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: colors.primary),
                ),
              ),
            ),
            SizedBox(height: keyboardCompact ? 8 : 16),
            TextField(
              controller: _portController,
              style: TextStyle(color: colors.textPrimary),
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'Port',
                labelStyle: TextStyle(color: colors.textMuted),
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: colors.border),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: colors.primary),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        SkotiqButton(
          onPressed: _connecting ? null : () => Navigator.pop(context),
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
        ),
        SkotiqButton(
          onPressed: _connecting ? null : _connect,
          isLoading: _connecting,
          label: 'Connect',
          size: keyboardCompact ? ButtonSize.small : ButtonSize.medium,
        ),
      ],
    );
    return PopScope(canPop: !_connecting, child: dialog);
  }

  Future<void> _connect() async {
    if (_connecting) return;
    final host = _hostController.text.trim();
    final port = int.tryParse(_portController.text.trim());
    final messenger = ScaffoldMessenger.of(context);
    final errorColor = SkotiqColors.of(context).error;
    if (host.isEmpty || port == null || port < 1 || port > 65535) {
      messenger.showSnackBar(
        SnackBar(
          content: const Text(
            'Enter a PHD2 host and a port between 1 and 65535.',
          ),
          backgroundColor: errorColor,
        ),
      );
      return;
    }

    setState(() => _connecting = true);

    // Save settings. A persistence failure must surface (not vanish) and must
    // NOT proceed to connect against unsaved values.
    try {
      await ref.read(appSettingsProvider.notifier).setPhd2Endpoint(host, port);
    } catch (e) {
      if (!mounted) return;
      setState(() => _connecting = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text('Could not save PHD2 connection settings: $e'),
          backgroundColor: errorColor,
        ),
      );
      return;
    }

    try {
      await ref.read(phd2ControllerProvider).connect(host, port);
    } catch (e) {
      if (!mounted) return;
      setState(() => _connecting = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'PHD2 connection failed: ${phd2FailureMessage(e)}',
          ),
          backgroundColor: errorColor,
        ),
      );
      return;
    }

    if (!mounted) return;
    Navigator.pop(context);
  }
}
