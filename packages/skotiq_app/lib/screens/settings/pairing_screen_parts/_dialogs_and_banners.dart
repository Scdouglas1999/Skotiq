// Rename dialog, access badge, paired confirmation and error banner.
part of '../pairing_screen.dart';

/// Renames one paired device.
///
/// Deliberately a plain one-field dialog: the field opens focused and holding
/// the current name, Return commits it, and an empty name is refused rather
/// than written (a blank row would be even less identifiable than the
/// duplicate it was meant to fix).
class _RenameDeviceDialog extends StatefulWidget {
  final PairedDevice device;
  final Future<bool> Function(String name) onSubmit;

  const _RenameDeviceDialog({required this.device, required this.onSubmit});

  @override
  State<_RenameDeviceDialog> createState() => _RenameDeviceDialogState();
}

class _RenameDeviceDialogState extends State<_RenameDeviceDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.device.deviceName);
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    setState(() => _busy = true);
    final succeeded = await widget.onSubmit(name);
    if (!mounted) return;
    if (succeeded) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _busy = false);
    context.showErrorSnackBar(context.l10n.text('pairingErrorRename'));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return PopScope(
      canPop: !_busy,
      child: SkotiqDialog(
        title: l10n.text('pairingRenameTitle'),
        width: SkotiqDialog.widthConfirm,
        closeEnabled: !_busy,
        onClose: () => Navigator.of(context).pop(),
        actions: [
          SkotiqButton(
            label: l10n.text('cancel'),
            variant: ButtonVariant.ghost,
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
          ),
          SkotiqButton(
            label: l10n.text('save'),
            isLoading: _busy,
            onPressed:
                _busy || _controller.text.trim().isEmpty ? null : _submit,
          ),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.text('pairingRenameBody'),
              style: SkotiqTypography.body.copyWith(
                color: SkotiqColors.of(context).textSecondary,
              ),
            ),
            const SizedBox(height: SkotiqTokens.spaceLg),
            SkotiqTextField(
              controller: _controller,
              label: l10n.text('pairingRenameLabel'),
              autofocus: true,
              enabled: !_busy,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              // Rebuild so Save disables the moment the field is emptied.
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
      ),
    );
  }
}

/// What a paired device's token is allowed to do, as a badge.
///
/// `auth_grant_spec` is either one of the three coarse grants or the host
/// API's fine-grained `resource:level,...` form; the raw spec is always on the
/// tooltip so a custom grant is still inspectable.
class _AccessBadge extends StatelessWidget {
  final String grantSpec;

  const _AccessBadge({required this.grantSpec});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final spec = grantSpec.trim().toLowerCase();
    final (String label, Color color) = switch (spec) {
      // Admin can re-pair, revoke other devices and manage stored
      // credentials, backups, plugins and updates.
      // Coloured as a warning because it is the grant you look for when you
      // are deciding what to revoke.
      'admin' => ('Full access', colors.warning),
      'control' => ('Can control the rig', colors.info),
      'view' => ('View only', colors.textMuted),
      _ => ('Custom access', colors.textMuted),
    };

    return Tooltip(
      message: 'Granted access: $grantSpec',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusFull),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Text(
          label,
          style: SkotiqTypography.labelQuiet.copyWith(color: color),
        ),
      ),
    );
  }
}

/// `<device> paired` confirmation shown the moment the outstanding code is
/// consumed. Names the device because that is what tells the operator the phone
/// in their hand — and not something else on the network — is what connected.
const Object _pairingUnset = Object();
