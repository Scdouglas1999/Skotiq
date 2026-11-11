part of '../notification_routing_settings.dart';

class _PushoverRoutingSection extends ConsumerStatefulWidget {
  final bool isMobile;
  const _PushoverRoutingSection({required this.isMobile});

  @override
  ConsumerState<_PushoverRoutingSection> createState() =>
      _PushoverRoutingSectionState();
}

class _PushoverRoutingSectionState
    extends ConsumerState<_PushoverRoutingSection> {
  final _token = TextEditingController();
  final _user = TextEditingController();
  final _device = TextEditingController();
  bool _initialized = false;
  bool _clearToken = false;
  bool _clearUser = false;

  @override
  void dispose() {
    _token.dispose();
    _user.dispose();
    _device.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cfgAsync = ref.watch(pushoverTransportConfigProvider);
    return cfgAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (e, _) {
        _initialized = false;
        return _transportErrorSection(
          title: 'Pushover',
          error: e,
          onRetry: () => ref.invalidate(pushoverTransportConfigProvider),
        );
      },
      data: (cfg) {
        if (!_initialized) {
          _token.clear();
          _user.clear();
          _device.text = cfg.device ?? '';
          _clearToken = false;
          _clearUser = false;
          _initialized = true;
        }
        Future<_PrepResult> saveConfig() async {
          final token = _clearToken
              ? ''
              : (_token.text.trim().isEmpty
                  ? cfg.apiToken
                  : _token.text.trim());
          final user = _clearUser
              ? ''
              : (_user.text.trim().isEmpty ? cfg.userKey : _user.text.trim());
          if (token.isNotEmpty != user.isNotEmpty) {
            return const _PrepResult.fail(
              'Enter both the API token and user key.',
            );
          }
          final cfg2 = PushoverTransportConfig(
            apiToken: token,
            userKey: user,
            device: _device.text.trim().isEmpty ? null : _device.text.trim(),
            priority: cfg.priority,
          );
          await ref.read(pushoverTransportConfigProvider.notifier).save(cfg2);
          _token.clear();
          _user.clear();
          _clearToken = false;
          _clearUser = false;
          return const _PrepResult.ok();
        }

        return SettingsSection(
          title: 'Pushover',
          children: [
            _SecretFieldRow(
              icon: LucideIcons.key,
              title: 'API token',
              controller: _token,
              hasStoredValue: cfg.apiToken.isNotEmpty,
              isMobile: widget.isMobile,
              hint: 'Pushover application token',
              onChanged: (_) => _clearToken = false,
              onClear: () => setState(() => _clearToken = true),
            ),
            _SecretFieldRow(
              icon: LucideIcons.user,
              title: 'User key',
              controller: _user,
              hasStoredValue: cfg.userKey.isNotEmpty,
              isMobile: widget.isMobile,
              hint: 'Pushover user / group key',
              onChanged: (_) => _clearUser = false,
              onClear: () => setState(() => _clearUser = true),
            ),
            _row(LucideIcons.smartphone, 'Device (optional)', _device),
            SettingRow(
              icon: LucideIcons.save,
              title: 'Save Pushover config',
              trailing: _SaveButton(
                successMessage: 'Pushover settings saved',
                onSave: saveConfig,
              ),
            ),
            SettingRow(
              icon: LucideIcons.send,
              title: 'Test Pushover',
              trailing: _TestSendButton(
                kind: NotificationTransportKind.pushover,
                onBeforeSend: saveConfig,
              ),
              isLast: true,
            ),
          ],
        );
      },
    );
  }

  Widget _row(IconData icon, String title, TextEditingController c,
      {bool obscure = false}) {
    return SettingRow(
      icon: icon,
      title: title,
      trailing: settingsTrailingTextInput(
        context: context,
        controller: c,
        isMobile: widget.isMobile,
        obscure: obscure,
      ),
    );
  }
}

// Telegram
