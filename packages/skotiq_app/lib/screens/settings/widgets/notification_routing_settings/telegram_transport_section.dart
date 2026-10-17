part of '../notification_routing_settings.dart';

class _TelegramTransportSection extends ConsumerStatefulWidget {
  final bool isMobile;
  const _TelegramTransportSection({required this.isMobile});

  @override
  ConsumerState<_TelegramTransportSection> createState() =>
      _TelegramTransportSectionState();
}

class _TelegramTransportSectionState
    extends ConsumerState<_TelegramTransportSection> {
  final _bot = TextEditingController();
  final _chat = TextEditingController();
  bool _silent = false;
  bool _initialized = false;
  bool _clearBotToken = false;

  @override
  void dispose() {
    _bot.dispose();
    _chat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cfgAsync = ref.watch(telegramTransportConfigProvider);
    return cfgAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (e, _) {
        _initialized = false;
        return _transportErrorSection(
          title: 'Telegram',
          error: e,
          onRetry: () => ref.invalidate(telegramTransportConfigProvider),
        );
      },
      data: (cfg) {
        if (!_initialized) {
          _bot.clear();
          _chat.text = cfg.chatId;
          _silent = cfg.disableNotification;
          _clearBotToken = false;
          _initialized = true;
        }
        Future<_PrepResult> saveConfig() async {
          final token = _clearBotToken
              ? ''
              : (_bot.text.trim().isEmpty ? cfg.botToken : _bot.text.trim());
          final chatId = _chat.text.trim();
          if (token.isNotEmpty != chatId.isNotEmpty) {
            return const _PrepResult.fail(
              'Enter both the bot token and chat ID.',
            );
          }
          final cfg2 = TelegramTransportConfig(
            botToken: token,
            chatId: chatId,
            disableNotification: _silent,
          );
          await ref.read(telegramTransportConfigProvider.notifier).save(cfg2);
          _bot.clear();
          _clearBotToken = false;
          return const _PrepResult.ok();
        }

        return SettingsSection(
          title: 'Telegram',
          children: [
            _SecretFieldRow(
              icon: LucideIcons.key,
              title: 'Bot token',
              controller: _bot,
              hasStoredValue: cfg.botToken.isNotEmpty,
              isMobile: widget.isMobile,
              hint: '1234:abcd…',
              onChanged: (_) => _clearBotToken = false,
              onClear: () => setState(() => _clearBotToken = true),
            ),
            SettingRow(
              icon: LucideIcons.messageCircle,
              title: 'Chat ID',
              trailing: settingsTrailingTextInput(
                context: context,
                controller: _chat,
                hint: '@channel or numeric id',
                isMobile: widget.isMobile,
              ),
            ),
            SettingRow(
              icon: LucideIcons.bellOff,
              title: 'Silent notification',
              trailing: SettingsSwitch(
                value: _silent,
                onChanged: (v) => setState(() => _silent = v),
              ),
            ),
            SettingRow(
              icon: LucideIcons.save,
              title: 'Save Telegram config',
              trailing: _SaveButton(
                successMessage: 'Telegram config saved',
                onSave: saveConfig,
              ),
            ),
            SettingRow(
              icon: LucideIcons.send,
              title: 'Test Telegram',
              trailing: _TestSendButton(
                kind: NotificationTransportKind.telegram,
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

// Discord (routing-aware)
