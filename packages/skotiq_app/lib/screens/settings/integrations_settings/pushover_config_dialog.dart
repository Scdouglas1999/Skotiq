part of '../integrations_settings.dart';

// Configuration dialogs

/// Pushover credentials dialog. Writes apiToken + userKey through the plugin's
/// public [PushoverNotificationPlugin.configureCredentials] (which persists to
/// plugin storage). Pre-fills from existing storage so re-opening shows the
/// current values.
class _PushoverConfigDialog extends StatefulWidget {
  const _PushoverConfigDialog({
    required this.plugin,
    required this.storage,
  });

  final PushoverNotificationPlugin plugin;
  final PluginStorage storage;

  @override
  State<_PushoverConfigDialog> createState() => _PushoverConfigDialogState();
}

class _PushoverConfigDialogState extends State<_PushoverConfigDialog> {
  final _apiTokenController = TextEditingController();
  final _userKeyController = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  String? _validationError;

  static const _apiTokenKey = 'pushover.apiToken';
  static const _userKeyKey = 'pushover.userKey';

  @override
  void initState() {
    super.initState();
    _prefill();
  }

  Future<void> _prefill() async {
    final token = await widget.storage.getString(_apiTokenKey);
    final user = await widget.storage.getString(_userKeyKey);
    if (!mounted) return;
    setState(() {
      _apiTokenController.text = token ?? '';
      _userKeyController.text = user ?? '';
      _loading = false;
    });
  }

  @override
  void dispose() {
    _apiTokenController.dispose();
    _userKeyController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final token = _apiTokenController.text.trim();
    final user = _userKeyController.text.trim();
    if (token.isEmpty || user.isEmpty) {
      setState(() => _validationError =
          'Both the application token and user/group key are required.');
      return;
    }
    setState(() {
      _saving = true;
      _validationError = null;
    });
    try {
      await widget.plugin.configureCredentials(apiToken: token, userKey: user);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (error, stackTrace) {
      if (!mounted) return;
      setState(() => _saving = false);
      await ErrorDialog.show(
        context,
        title: 'Could not save Pushover credentials',
        message: 'Skotiq could not write the Pushover credentials to '
            'plugin storage.',
        technicalDetails: '$error\n$stackTrace',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return SkotiqDialog(
      title: 'Configure Pushover',
      icon: LucideIcons.bell,
      width: 480,
      closeEnabled: !_saving,
      actions: [
        SkotiqButton(
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
        ),
        SkotiqButton(
          label: 'Save',
          icon: LucideIcons.save,
          isLoading: _saving,
          onPressed: _saving ? null : _save,
        ),
      ],
      child: _loading
          ? const Padding(
              padding: EdgeInsets.all(SkotiqTokens.space2xl),
              child: Center(child: ShimmerLoading(child: SizedBox(height: 80))),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Stored once per plugin so credentials never leak into saved '
                  'sequences. Add a Pushover Notification node to a sequence to '
                  'send pushes.',
                  style: SkotiqTypography.bodySm
                      .copyWith(color: colors.textSecondary),
                ),
                const SizedBox(height: SkotiqTokens.spaceLg),
                SkotiqTextField(
                  label: 'Application token',
                  hint: 'azGDORePK8gMaC0QOYAMyEEuzJnyUi',
                  controller: _apiTokenController,
                  obscureText: true,
                ),
                const SizedBox(height: SkotiqTokens.spaceLg),
                SkotiqTextField(
                  label: 'User / group key',
                  hint: 'uQiRzpo4DXghDmr9QzzfQu27cmVRsG',
                  controller: _userKeyController,
                  obscureText: true,
                ),
                if (_validationError != null) ...[
                  const SizedBox(height: SkotiqTokens.spaceLg),
                  SkotiqInlineBanner(
                    message: _validationError!,
                    severity: SkotiqAlertSeverity.error,
                  ),
                ],
              ],
            ),
    );
  }
}
