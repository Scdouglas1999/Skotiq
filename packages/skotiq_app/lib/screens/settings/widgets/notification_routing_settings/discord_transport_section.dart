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

  /// One-shot guard for the legacy-webhook adoption below. Set before the
  /// adopting write is scheduled and never reset, so a failed adoption cannot
  /// spin the provider in a rebuild loop.
  bool _legacyAdoptionScheduled = false;

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cfgAsync = ref.watch(discordTransportConfigProvider);
    // The pre-router `NotificationService` sends Discord straight from the
    // plaintext `app_settings` key. This section is the ONLY Discord
    // configuration on the page, so it has to account for that key or a user
    // who set it would be told Discord is unconfigured.
    final legacyWebhook =
        ref.watch(appSettingsProvider).valueOrNull?.discordWebhook.trim() ?? '';
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
        // Adopt a legacy plaintext webhook into the keyring-backed config the
        // router uses. Without this the single Discord section would render an
        // empty field for a user whose webhook is configured and firing.
        if (cfg.webhookUrl.isEmpty &&
            legacyWebhook.isNotEmpty &&
            !_legacyAdoptionScheduled) {
          _legacyAdoptionScheduled = true;
          Future.microtask(() async {
            if (!mounted) return;
            await ref
                .read(discordTransportConfigProvider.notifier)
                .save(cfg.copyWith(webhookUrl: legacyWebhook));
          });
        }
        Future<_PrepResult> saveConfig() async {
          final webhook = _clearWebhook
              ? ''
              : (_url.text.trim().isEmpty
                  ? (cfg.webhookUrl.isEmpty ? legacyWebhook : cfg.webhookUrl)
                  : _url.text.trim());
          final urlError = _validateUrlField(webhook);
          if (urlError != null) return _PrepResult.fail(urlError);
          final cfg2 = DiscordTransportConfig(
            webhookUrl: webhook,
            username: _user.text.trim().isEmpty ? null : _user.text.trim(),
            avatarUrl: cfg.avatarUrl,
          );
          await ref.read(discordTransportConfigProvider.notifier).save(cfg2);
          // Update an existing legacy value for compatibility, but never copy
          // a new bearer token out of the keyring into exported settings.
          if (legacyWebhook.isNotEmpty) {
            await ref
                .read(appSettingsProvider.notifier)
                .setDiscordWebhook(webhook);
          }
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
              hasStoredValue:
                  cfg.webhookUrl.isNotEmpty || legacyWebhook.isNotEmpty,
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
