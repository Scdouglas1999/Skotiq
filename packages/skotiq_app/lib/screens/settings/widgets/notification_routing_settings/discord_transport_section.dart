part of '../notification_routing_settings.dart';

class _DiscordRoutingSection extends ConsumerStatefulWidget {
  final bool isMobile;
  const _DiscordRoutingSection({required this.isMobile});

  @override
  ConsumerState<_DiscordRoutingSection> createState() =>
      _DiscordRoutingSectionState();
}

class _DiscordRoutingSectionState
    extends ConsumerState<_DiscordRoutingSection> {
  final _url = TextEditingController();
  final _user = TextEditingController();
  bool _initialized = false;
  bool _clearWebhook = false;

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cfgAsync = ref.watch(discordTransportConfigProvider);
    return cfgAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (e, _) {
        _initialized = false;
        return _transportErrorSection(
          title: 'Discord',
          error: e,
          onRetry: () => ref.invalidate(discordTransportConfigProvider),
        );
      },
      data: (cfg) {
        if (!_initialized) {
          _url.clear();
          _user.text = cfg.username ?? '';
          _clearWebhook = false;
          _initialized = true;
        }
        Future<_PrepResult> saveConfig() async {
          final webhook = _clearWebhook
              ? ''
              : (_url.text.trim().isEmpty ? cfg.webhookUrl : _url.text.trim());
          final urlError = _validateUrlField(webhook);
          if (urlError != null) return _PrepResult.fail(urlError);
          final cfg2 = DiscordTransportConfig(
            webhookUrl: webhook,
            username: _user.text.trim().isEmpty ? null : _user.text.trim(),
            avatarUrl: cfg.avatarUrl,
          );
          await ref.read(discordTransportConfigProvider.notifier).save(cfg2);
          _url.clear();
          _clearWebhook = false;
          return const _PrepResult.ok();
        }

        return SettingsSection(
          title: 'Discord',
          children: [
            _SecretFieldRow(
              icon: LucideIcons.link,
              title: 'Webhook URL',
              subtitle:
                  'The URL itself authenticates the request, so it is stored securely.',
              controller: _url,
              hasStoredValue: cfg.webhookUrl.isNotEmpty,
              isMobile: widget.isMobile,
              hint: 'https://discord.com/api/webhooks/…',
              onChanged: (_) => _clearWebhook = false,
              onClear: () => setState(() => _clearWebhook = true),
            ),
            SettingRow(
              icon: LucideIcons.user,
              title: 'Username override',
              trailing: settingsTrailingTextInput(
                context: context,
                controller: _user,
                hint: 'Skotiq',
                isMobile: widget.isMobile,
              ),
            ),
            SettingRow(
              icon: LucideIcons.save,
              title: 'Save Discord config',
              trailing: _SaveButton(
                successMessage: 'Discord settings saved',
                onSave: saveConfig,
              ),
            ),
            SettingRow(
              icon: LucideIcons.send,
              title: 'Test Discord',
              trailing: _TestSendButton(
                kind: NotificationTransportKind.discord,
                onBeforeSend: saveConfig,
              ),
              isLast: true,
            ),
          ],
        );
      },
    );
  }
}

// MQTT
