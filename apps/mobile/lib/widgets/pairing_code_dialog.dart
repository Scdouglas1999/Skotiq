import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_app/screens/connection/rig_pairing_text.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// What [PairingCodeDialog] pops: a typed [code], or [scan] when the operator
/// chose to scan the QR code instead. [admin] asks the host for full control.
typedef PairingDialogResult = ({String code, bool admin, bool scan});

/// Code-pairing dialog. A real StatefulWidget (not a StatefulBuilder over
/// method-locals) so the [TextEditingController] is disposed by the
/// framework when the dialog element unmounts — after the route's exit
/// animation — never while a final rebuild can still touch it.
class PairingCodeDialog extends StatefulWidget {
  final String host;
  final int port;
  final String? initialCode;

  /// The name the computer announced, shown so a phone near two rigs knows
  /// which one it is pairing with.
  final String? serverName;

  /// Set for a host with no screen to show a code on: asks it to make one.
  final Future<RemotePairingStartResult> Function()? requestCode;

  const PairingCodeDialog({
    super.key,
    required this.host,
    required this.port,
    this.initialCode,
    this.serverName,
    this.requestCode,
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

  RemotePairingStartResult? _codeMade;
  String? _codeRequestError;
  bool _requestingCode = false;

  DiscoveredServer get _server => DiscoveredServer(
    host: widget.host,
    webPort: widget.port,
    name: widget.serverName ?? widget.host,
    hostMode: 'headless',
  );

  Future<void> _requestCode() async {
    final request = widget.requestCode;
    if (request == null || _requestingCode) return;
    setState(() {
      _requestingCode = true;
      _codeRequestError = null;
    });
    try {
      final made = await request();
      if (!mounted) return;
      setState(() {
        _requestingCode = false;
        _codeMade = made;
        _codeController.clear();
      });
    } on RigPairingFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _requestingCode = false;
        _codeRequestError = describeRigPairingFailure(failure, _server);
      });
    }
  }

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
          if (widget.requestCode == null)
            Text(
              // The page at /pair never shows a code, and on the same Wi-Fi
              // this dialog does not come up at all: the phone pairs in one
              // tap.
              'No screen on the imaging computer? On its Wi-Fi this phone '
              'pairs without a code.',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize13,
                color: colors.textSecondary,
              ),
            )
          else ...[
            Text(
              'No screen on the imaging computer? Ask it for a code, then '
              'read the code where it says it put it.',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize13,
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            SkotiqButton(
              onPressed: _requestingCode ? null : _requestCode,
              isLoading: _requestingCode,
              label: _codeMade == null ? 'Get a code' : 'Get a new code',
              icon: LucideIcons.keyRound,
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
            ),
            if (_codeMade case final made?) ...[
              const SizedBox(height: SkotiqTokens.spaceSm),
              Text(
                describeCodeWhereabouts(
                  _server.displayName,
                  made,
                  askedForCode: false,
                ),
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize13,
                  color: colors.textPrimary,
                ),
              ),
            ],
            if (_codeRequestError case final error?) ...[
              const SizedBox(height: SkotiqTokens.spaceSm),
              Text(
                error,
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize13,
                  color: colors.error,
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}
