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

  /// One-shot guard for the legacy-credential adoption below. Set before the
  /// adopting write is scheduled and never reset, so a failed adoption cannot
  /// spin the provider in a rebuild loop.
  bool _legacyAdoptionScheduled = false;

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
    // Include legacy app settings while NotificationService still reads them.
    final legacySettings = ref.watch(appSettingsProvider).valueOrNull;
    final legacyToken = legacySettings?.pushoverKey.trim() ?? '';
    final legacyUser = legacySettings?.pushoverUser.trim() ?? '';
    final hasLegacy = legacyToken.isNotEmpty && legacyUser.isNotEmpty;
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
        // Adopt legacy plaintext credentials into the keyring-backed config the
        // router uses. Without this the single Pushover section would render
        // empty fields for a user whose Pushover is configured and firing.
        if (cfg.apiToken.isEmpty &&
            cfg.userKey.isEmpty &&
            hasLegacy &&
            !_legacyAdoptionScheduled) {
          _legacyAdoptionScheduled = true;
          Future.microtask(() async {
            if (!mounted) return;
            await ref.read(pushoverTransportConfigProvider.notifier).save(
                  cfg.copyWith(apiToken: legacyToken, userKey: legacyUser),
                );
          });
        }
        Future<_PrepResult> saveConfig() async {
          final storedToken = cfg.apiToken.isEmpty ? legacyToken : cfg.apiToken;
          final storedUser = cfg.userKey.isEmpty ? legacyUser : cfg.userKey;
          final token = _clearToken
              ? ''
              : (_token.text.trim().isEmpty ? storedToken : _token.text.trim());
          final user = _clearUser
              ? ''
              : (_user.text.trim().isEmpty ? storedUser : _user.text.trim());
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
          // Keep the legacy plaintext keys in step, but only when they already
          // hold values: `NotificationService` still reads them, so leaving
          // them stale would fan out with the credentials the user just
          // replaced. We never CREATE the plaintext copy — these are bearer
          // tokens and belong in the keyring, which `app_settings` (it rides
          // export/backup) is not.
          if (legacyToken.isNotEmpty || legacyUser.isNotEmpty) {
            final settingsNotifier = ref.read(appSettingsProvider.notifier);
            await settingsNotifier.setPushoverKey(token);
            await settingsNotifier.setPushoverUser(user);
          }
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
              hasStoredValue: cfg.apiToken.isNotEmpty || legacyToken.isNotEmpty,
              isMobile: widget.isMobile,
              hint: 'Pushover application token',
              onChanged: (_) => _clearToken = false,
              onClear: () => setState(() => _clearToken = true),
            ),
            _SecretFieldRow(
              icon: LucideIcons.user,
              title: 'User key',
              controller: _user,
              hasStoredValue: cfg.userKey.isNotEmpty || legacyUser.isNotEmpty,
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
