part of '../integrations_settings.dart';

/// Discord configuration dialog.
///
/// The Discord plugin's real credential is per-NODE: each `discord.webhook`
/// sequence node carries its own URL. This dialog explains that, lets the user
/// persist a default/test webhook URL (to the plugin's storage), and runs a
/// "Test send" through the plugin's REAL node execute path (so it reuses the
/// plugin's validation + HTTP code and fires the `plugin.discord.sent` event
/// against the live context, updating "last fired").
class _DiscordConfigDialog extends StatefulWidget {
  const _DiscordConfigDialog({
    required this.storage,
    required this.pluginContext,
    required this.httpClientFactory,
  });

  final PluginStorage storage;
  final PluginContext pluginContext;

  /// Test seam: factory the test-send node uses to build its HTTP client.
  /// Null in production → a real [http.Client].
  final http.Client Function()? httpClientFactory;

  @override
  State<_DiscordConfigDialog> createState() => _DiscordConfigDialogState();
}

class _DiscordConfigDialogState extends State<_DiscordConfigDialog> {
  final _webhookController = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  bool _testing = false;
  String? _validationError;

  @override
  void initState() {
    super.initState();
    _prefill();
  }

  Future<void> _prefill() async {
    final url =
        await widget.storage.getString(kDiscordDefaultWebhookStorageKey);
    if (!mounted) return;
    setState(() {
      _webhookController.text = url ?? '';
      _loading = false;
    });
  }

  @override
  void dispose() {
    _webhookController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final url = _webhookController.text.trim();
    // An empty default is allowed (each node can still carry its own URL), but
    // a non-empty value must be a plausible Discord webhook.
    if (url.isNotEmpty) {
      final problem = _webhookUrlProblem(url);
      if (problem != null) {
        setState(() => _validationError = problem);
        return;
      }
    }
    setState(() {
      _saving = true;
      _validationError = null;
    });
    try {
      await widget.storage.setString(kDiscordDefaultWebhookStorageKey, url);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (error, stackTrace) {
      if (!mounted) return;
      setState(() => _saving = false);
      await ErrorDialog.show(
        context,
        title: 'Could not save Discord webhook',
        message: 'Skotiq could not write the default webhook URL to plugin '
            'storage.',
        technicalDetails: '$error\n$stackTrace',
      );
    }
  }

  Future<void> _testSend() async {
    final url = _webhookController.text.trim();
    final problem = url.isEmpty
        ? 'Enter a webhook URL to send a test.'
        : _webhookUrlProblem(url);
    if (problem != null) {
      setState(() => _validationError = problem);
      return;
    }
    setState(() {
      _testing = true;
      _validationError = null;
    });

    // Build a node through the plugin's REAL definition so validation + HTTP
    // behaviour exactly match a sequence run. The plugin instance we build
    // here carries the (test) http client factory; in production the factory
    // is null and the node uses a real http.Client.
    final plugin =
        DiscordWebhookPlugin(clientBuilder: widget.httpClientFactory);
    final node = plugin.nodeDefinitions.first.createNode({
      'webhookUrl': url,
      'embedTitle': 'Skotiq test message',
      'embedDescription':
          'If you can read this, your Discord webhook is configured correctly.',
      'embedColor': 0x3498db,
    });

    bool success;
    Object? failure;
    StackTrace? failureStack;
    try {
      // The node's own validate() runs the same checks a sequence would; surface
      // a validation failure as a friendly message rather than POSTing garbage.
      final invalid = node?.validate();
      if (invalid != null) {
        setState(() {
          _testing = false;
          _validationError = invalid;
        });
        return;
      }
      // Execute against the LIVE plugin context so the success event fires on
      // the same bus the activity tracker listens to.
      success = await node!.execute(widget.pluginContext);
    } catch (error, stackTrace) {
      success = false;
      failure = error;
      failureStack = stackTrace;
    }

    if (!mounted) return;
    setState(() => _testing = false);

    if (success) {
      SkotiqToastHelper.show(
        context: context,
        message: 'Discord test message sent.',
        severity: SkotiqAlertSeverity.success,
      );
    } else {
      await ErrorDialog.show(
        context,
        title: 'Discord test failed',
        message: 'The test message was not accepted by Discord. Check that the '
            'webhook URL is correct and still active.',
        technicalDetails: failure == null
            ? 'The Discord webhook POST did not return a success status '
                '(expected 200/204).'
            : '$failure\n$failureStack',
      );
    }
  }

  /// Returns a problem string for an obviously-wrong webhook URL, or null if it
  /// looks plausible. Mirrors the plugin node's own validation so the dialog
  /// fails fast with the same rules.
  String? _webhookUrlProblem(String url) {
    final parsed = Uri.tryParse(url);
    if (parsed == null || parsed.scheme != 'https') {
      return 'The webhook URL must be an https URL.';
    }
    if (!isDiscordWebhookHost(parsed.host)) {
      return 'The host must be discord.com or discordapp.com (got '
          '${parsed.host}).';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return SkotiqDialog(
      title: 'Configure Discord Webhook',
      icon: LucideIcons.messageSquare,
      width: 520,
      closeEnabled: !_saving && !_testing,
      actions: [
        SkotiqButton(
          label: 'Test send',
          icon: LucideIcons.send,
          variant: ButtonVariant.secondary,
          isLoading: _testing,
          onPressed: (_testing || _saving) ? null : _testSend,
        ),
        SkotiqButton(
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          onPressed:
              (_testing || _saving) ? null : () => Navigator.of(context).pop(),
        ),
        SkotiqButton(
          label: 'Save',
          icon: LucideIcons.save,
          isLoading: _saving,
          onPressed: (_testing || _saving) ? null : _save,
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
                const SkotiqBanner(
                  title: 'Per-node webhooks',
                  message:
                      'This plugin adds a "Discord Webhook" sequence node. Each '
                      'node carries its own webhook URL, so the same sequence '
                      'can route different steps to different channels. The URL '
                      'below is a default/test webhook saved for convenience — '
                      'to fire on observatory events instead, use Notification '
                      'Routing.',
                ),
                const SizedBox(height: SkotiqTokens.spaceLg),
                SkotiqTextField(
                  label: 'Default / test webhook URL',
                  hint: 'https://discord.com/api/webhooks/…',
                  controller: _webhookController,
                ),
                const SizedBox(height: SkotiqTokens.spaceSm),
                Text(
                  'Use "Test send" to post a sample embed and confirm the '
                  'webhook works.',
                  style: SkotiqTypography.captionSm
                      .copyWith(color: colors.textMuted),
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
