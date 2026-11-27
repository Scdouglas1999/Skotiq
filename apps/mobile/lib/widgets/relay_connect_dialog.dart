import 'package:flutter/material.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

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
    final l10n = context.l10n;
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
        child: Text(l10n.text('relayConnect')),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Offstage(
            offstage: keyboardCompact,
            child: Column(
              children: [
                Text(
                  l10n.text('mobileRelayDialogBody'),
                  style: const TextStyle(fontSize: SkotiqTypography.fontSize13),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
          TextField(
            key: const ValueKey('relay-url-field'),
            controller: _relayController,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: l10n.text('mobileRelayUrl'),
              hintText: 'wss://relay.example.com',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('relay-appliance-id-field'),
            controller: _idController,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: l10n.text('mobileApplianceId'),
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
                  title: Text(
                    l10n.text('mobileRelayTrustSelfSigned'),
                    style: const TextStyle(
                      fontSize: SkotiqTypography.fontSize13,
                    ),
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
          child: Text(l10n.text('cancel')),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop((
            relayUrl: _relayController.text,
            applianceId: _idController.text,
            allowInsecure: _allowInsecure,
          )),
          child: Text(l10n.text('connect')),
        ),
      ],
    );
  }
}
