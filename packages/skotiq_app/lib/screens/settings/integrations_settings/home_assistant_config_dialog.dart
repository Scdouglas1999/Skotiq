part of '../integrations_settings.dart';

/// Home Assistant connection dialog. Writes baseUrl + token through the
/// plugin's public [HomeAssistantPlugin.configureConnection].
class _HomeAssistantConfigDialog extends StatefulWidget {
  const _HomeAssistantConfigDialog({
    required this.plugin,
    required this.storage,
  });

  final HomeAssistantPlugin plugin;
  final PluginStorage storage;

  @override
  State<_HomeAssistantConfigDialog> createState() =>
      _HomeAssistantConfigDialogState();
}

class _HomeAssistantConfigDialogState
    extends State<_HomeAssistantConfigDialog> {
  final _baseUrlController = TextEditingController();
  final _tokenController = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  String? _validationError;

  static const _baseUrlKey = 'home_assistant.baseUrl';
  static const _tokenKey = 'home_assistant.token';

  @override
  void initState() {
    super.initState();
    _prefill();
  }

  Future<void> _prefill() async {
    final baseUrl = await widget.storage.getString(_baseUrlKey);
    final token = await widget.storage.getString(_tokenKey);
    if (!mounted) return;
    setState(() {
      _baseUrlController.text = baseUrl ?? '';
      _tokenController.text = token ?? '';
      _loading = false;
    });
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final baseUrl = _baseUrlController.text.trim();
    final token = _tokenController.text.trim();
    if (baseUrl.isEmpty || token.isEmpty) {
      setState(() => _validationError =
          'Both the base URL and a long-lived access token are required.');
      return;
    }
    final urlProblem = homeAssistantBaseUrlProblem(baseUrl);
    if (urlProblem != null) {
      setState(() => _validationError = urlProblem);
      return;
    }
    setState(() {
      _saving = true;
      _validationError = null;
    });
    try {
      await widget.plugin
          .configureConnection(baseUrl: baseUrl, accessToken: token);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (error, stackTrace) {
      if (!mounted) return;
      setState(() => _saving = false);
      await ErrorDialog.show(
        context,
        title: 'Could not save Home Assistant connection',
        message: 'Skotiq could not write the Home Assistant connection '
            'details to plugin storage.',
        technicalDetails: '$error\n$stackTrace',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return SkotiqDialog(
      title: 'Configure Home Assistant',
      icon: LucideIcons.home,
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
                  'Connect to your Home Assistant instance with a long-lived '
                  'access token. Sequence nodes can then turn entities on/off '
                  'to automate dew heaters, dome shutters, and lighting.',
                  style: SkotiqTypography.bodySm
                      .copyWith(color: colors.textSecondary),
                ),
                const SizedBox(height: SkotiqTokens.spaceLg),
                SkotiqTextField(
                  label: 'Base URL',
                  hint: 'http://homeassistant.local:8123',
                  controller: _baseUrlController,
                ),
                const SizedBox(height: SkotiqTokens.spaceLg),
                SkotiqTextField(
                  label: 'Long-lived access token',
                  hint: 'eyJ0eXAiOiJKV1QiLCJhbGc…',
                  controller: _tokenController,
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
