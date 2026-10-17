part of '../notification_routing_settings.dart';

class _MqttTransportSection extends ConsumerStatefulWidget {
  final bool isMobile;
  const _MqttTransportSection({required this.isMobile});

  @override
  ConsumerState<_MqttTransportSection> createState() =>
      _MqttTransportSectionState();
}

class _MqttTransportSectionState extends ConsumerState<_MqttTransportSection> {
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _topic = TextEditingController();
  final _clientId = TextEditingController();
  int _qos = 0;
  bool _retain = false;
  bool _tls = false;
  bool _initialized = false;
  bool _clearPassword = false;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _pass.dispose();
    _topic.dispose();
    _clientId.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cfgAsync = ref.watch(mqttTransportConfigProvider);
    return cfgAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (e, _) {
        _initialized = false;
        return _transportErrorSection(
          title: 'MQTT broker',
          error: e,
          onRetry: () => ref.invalidate(mqttTransportConfigProvider),
        );
      },
      data: (cfg) {
        if (!_initialized) {
          _host.text = cfg.host;
          _port.text = cfg.port.toString();
          _user.text = cfg.username ?? '';
          _pass.clear();
          _topic.text = cfg.topic;
          _clientId.text = cfg.clientId;
          // QoS 2 was exposed by older builds but the publisher only ever
          // delivered it as QoS 1. Keep hand-built/legacy config values from
          // breaking the two-item dropdown and show the effective behavior.
          _qos = cfg.qos == 1 || cfg.qos == 2 ? 1 : 0;
          _retain = cfg.retain;
          _tls = cfg.useTls;
          _clearPassword = false;
          _initialized = true;
        }
        Future<_PrepResult> saveConfig() async {
          final parsedPort = _parsePortField(_port.text, defaultPort: 1883);
          if (parsedPort.error != null) {
            return _PrepResult.fail(parsedPort.error);
          }
          final host = _host.text.trim();
          final topic = _topic.text.trim();
          if (host.isNotEmpty && topic.isEmpty) {
            return const _PrepResult.fail('Enter an MQTT topic.');
          }
          final username = _user.text.trim().isEmpty ? null : _user.text.trim();
          final password = _clearPassword
              ? null
              : (_pass.text.isEmpty ? cfg.password : _pass.text);
          if ((password ?? '').isNotEmpty && username == null) {
            return const _PrepResult.fail(
              'Enter a username when an MQTT password is configured.',
            );
          }
          final cfg2 = MqttTransportConfig(
            host: host,
            port: parsedPort.port!,
            username: username,
            password: password,
            topic: topic,
            qos: _qos,
            retain: _retain,
            useTls: _tls,
            clientId: _clientId.text.trim().isEmpty
                ? 'skotiq'
                : _clientId.text.trim(),
          );
          await ref.read(mqttTransportConfigProvider.notifier).save(cfg2);
          _pass.clear();
          _clearPassword = false;
          return const _PrepResult.ok();
        }

        return SettingsSection(
          title: 'MQTT broker',
          children: [
            _row(LucideIcons.server, 'Broker host', _host, 'mqtt.example.com'),
            _row(LucideIcons.hash, 'Port', _port, '1883', isNumber: true),
            _row(LucideIcons.user, 'Username (optional)', _user, ''),
            _SecretFieldRow(
              icon: LucideIcons.key,
              title: 'Password (optional)',
              controller: _pass,
              hasStoredValue: (cfg.password ?? '').isNotEmpty,
              isMobile: widget.isMobile,
              hint: 'broker password',
              onChanged: (_) => _clearPassword = false,
              onClear: () => setState(() => _clearPassword = true),
            ),
            _row(LucideIcons.hash, 'Topic', _topic, 'skotiq/notifications'),
            _row(LucideIcons.tag, 'Client ID', _clientId, 'skotiq'),
            SettingRow(
              icon: LucideIcons.lock,
              title: 'Use TLS',
              trailing: SettingsSwitch(
                value: _tls,
                onChanged: (v) => setState(() => _tls = v),
              ),
            ),
            SettingRow(
              icon: LucideIcons.shield,
              title: 'QoS',
              trailing: AccessibleDropdown<int>(
                value: _qos,
                items: const [
                  DropdownMenuItem(value: 0, child: Text('0 (at most once)')),
                  DropdownMenuItem(value: 1, child: Text('1 (at least once)')),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _qos = v);
                },
              ),
            ),
            SettingRow(
              icon: LucideIcons.archive,
              title: 'Retain',
              trailing: SettingsSwitch(
                value: _retain,
                onChanged: (v) => setState(() => _retain = v),
              ),
            ),
            SettingRow(
              icon: LucideIcons.save,
              title: 'Save MQTT config',
              trailing: _SaveButton(
                successMessage: 'MQTT config saved',
                onSave: saveConfig,
              ),
            ),
            SettingRow(
              icon: LucideIcons.send,
              title: 'Test MQTT publish',
              trailing: _TestSendButton(
                kind: NotificationTransportKind.mqtt,
                onBeforeSend: saveConfig,
              ),
              isLast: true,
            ),
          ],
        );
      },
    );
  }

  Widget _row(IconData icon, String title, TextEditingController c, String hint,
      {bool obscure = false, bool isNumber = false}) {
    return SettingRow(
      icon: icon,
      title: title,
      trailing: settingsTrailingTextInput(
        context: context,
        controller: c,
        hint: hint,
        isMobile: widget.isMobile,
        obscure: obscure,
      ),
    );
  }
}
