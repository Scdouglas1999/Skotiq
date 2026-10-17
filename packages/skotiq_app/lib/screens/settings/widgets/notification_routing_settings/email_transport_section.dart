part of '../notification_routing_settings.dart';

class _EmailTransportSection extends ConsumerStatefulWidget {
  final bool isMobile;
  const _EmailTransportSection({required this.isMobile});

  @override
  ConsumerState<_EmailTransportSection> createState() =>
      _EmailTransportSectionState();
}

class _EmailTransportSectionState
    extends ConsumerState<_EmailTransportSection> {
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _from = TextEditingController();
  final _to = TextEditingController();
  bool _useTls = true;
  bool _initialized = false;
  bool _clearPassword = false;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _pass.dispose();
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cfgAsync = ref.watch(emailTransportConfigProvider);
    return cfgAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (e, _) {
        // Re-seed the controllers on the next successful load in case a retry
        // brings back a changed config.
        _initialized = false;
        return _transportErrorSection(
          title: 'Email (SMTP)',
          error: e,
          onRetry: () => ref.invalidate(emailTransportConfigProvider),
        );
      },
      data: (cfg) {
        if (!_initialized) {
          _host.text = cfg.smtpHost;
          _port.text = cfg.smtpPort.toString();
          _user.text = cfg.username;
          _pass.clear();
          _from.text = cfg.fromAddress;
          _to.text = cfg.toAddress;
          _useTls = cfg.useTls;
          _clearPassword = false;
          _initialized = true;
        }
        Future<_PrepResult> saveConfig() async {
          final parsedPort = _parsePortField(_port.text, defaultPort: 587);
          if (parsedPort.error != null) {
            return _PrepResult.fail(parsedPort.error);
          }
          final host = _host.text.trim();
          final from = _from.text.trim();
          final to = _to.text.trim();
          if (host.isNotEmpty || from.isNotEmpty || to.isNotEmpty) {
            if (host.isEmpty) {
              return const _PrepResult.fail('Enter an SMTP host.');
            }
            if (from.isEmpty || to.isEmpty) {
              return const _PrepResult.fail(
                'Enter both From and To email addresses.',
              );
            }
            final fromError = _validateEmailAddress(from);
            if (fromError != null) return _PrepResult.fail(fromError);
            final toError = _validateEmailAddress(to);
            if (toError != null) return _PrepResult.fail(toError);
          }
          final updated = EmailTransportConfig(
            smtpHost: host,
            smtpPort: parsedPort.port!,
            username: _user.text.trim(),
            password: _clearPassword
                ? ''
                : (_pass.text.isEmpty ? cfg.password : _pass.text),
            useTls: _useTls,
            fromAddress: from,
            toAddress: to,
          );
          await ref.read(emailTransportConfigProvider.notifier).save(updated);
          _pass.clear();
          _clearPassword = false;
          return const _PrepResult.ok();
        }

        return SettingsSection(
          title: 'Email (SMTP)',
          children: [
            _textRow(LucideIcons.server, 'SMTP host', _host,
                hint: 'smtp.gmail.com'),
            _textRow(LucideIcons.hash, 'SMTP port', _port,
                hint: '587', isNumber: true),
            _textRow(LucideIcons.user, 'Username', _user, hint: 'optional'),
            _SecretFieldRow(
              icon: LucideIcons.key,
              title: 'Password',
              subtitle: 'Stored securely in the OS keyring.',
              controller: _pass,
              hasStoredValue: cfg.password.isNotEmpty,
              isMobile: widget.isMobile,
              hint: 'app password / SMTP password',
              onChanged: (_) => _clearPassword = false,
              onClear: () => setState(() => _clearPassword = true),
            ),
            SettingRow(
              icon: LucideIcons.lock,
              title: 'Use STARTTLS',
              subtitle: 'Recommended for ports 25/587',
              trailing: SettingsSwitch(
                value: _useTls,
                onChanged: (v) => setState(() => _useTls = v),
              ),
            ),
            _textRow(LucideIcons.atSign, 'From address', _from,
                hint: 'you@example.com'),
            _textRow(LucideIcons.send, 'To address', _to,
                hint: 'you@example.com'),
            SettingRow(
              icon: LucideIcons.save,
              title: 'Save SMTP settings',
              trailing: _SaveButton(
                successMessage: 'Email config saved',
                onSave: saveConfig,
              ),
            ),
            SettingRow(
              icon: LucideIcons.send,
              title: 'Test email',
              subtitle: 'Send a test email through the configured SMTP server',
              trailing: _TestSendButton(
                kind: NotificationTransportKind.email,
                onBeforeSend: saveConfig,
              ),
              isLast: true,
            ),
          ],
        );
      },
    );
  }

  Widget _textRow(IconData icon, String title, TextEditingController c,
      {String? hint, bool obscure = false, bool isNumber = false}) {
    return SettingRow(
      icon: icon,
      title: title,
      trailing: settingsTrailingTextInput(
        context: context,
        controller: c,
        hint: hint ?? '',
        isMobile: widget.isMobile,
        obscure: obscure,
      ),
    );
  }
}

// Webhook
