part of '../notification_routing_settings.dart';

// Home Assistant MQTT auto-discovery settings. Lives next to the MQTT
// broker section because it reuses that broker connection — discovery
// publishes retained HA config/state topics over the same host.

class _HomeAssistantSection extends ConsumerStatefulWidget {
  final bool isMobile;
  const _HomeAssistantSection({required this.isMobile});

  @override
  ConsumerState<_HomeAssistantSection> createState() =>
      _HomeAssistantSectionState();
}

class _HomeAssistantSectionState extends ConsumerState<_HomeAssistantSection> {
  final _deviceName = TextEditingController();
  bool _initialized = false;

  /// Bumped whenever the publish toggle is refused, to rebuild the switch.
  ///
  /// [SettingsSwitch] flips optimistically and only re-reads `value` when a
  /// write is in flight, so a handler that simply returns leaves the switch
  /// drawn ON while the stored config stays OFF — the user then presses Save,
  /// is told "Home Assistant config saved", and finds discovery still off on
  /// the next visit. Changing the switch's key forces a fresh State whose
  /// initState reads the real value back.
  int _refusedFlips = 0;

  @override
  void dispose() {
    _deviceName.dispose();
    super.dispose();
  }

  Future<void> _save(
      HomeAssistantDiscoveryConfig Function(HomeAssistantDiscoveryConfig)
          change) async {
    final current = ref.read(homeAssistantConfigProvider).valueOrNull ??
        const HomeAssistantDiscoveryConfig();
    await ref.read(homeAssistantConfigProvider.notifier).save(change(current));
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(backendProvider) is NetworkBackend) {
      return const _RemoteHomeAssistantSection();
    }
    final cfgAsync = ref.watch(homeAssistantConfigProvider);
    final mqttCfg = ref.watch(mqttTransportConfigProvider).valueOrNull;
    final brokerConfigured = (mqttCfg?.host ?? '').isNotEmpty;

    return cfgAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (e, _) => const SkotiqInlineBanner(
        message: 'Could not load Home Assistant routing configuration.',
        severity: SkotiqAlertSeverity.error,
      ),
      data: (cfg) {
        if (!_initialized) {
          _deviceName.text = cfg.deviceName;
          _initialized = true;
        }
        return SettingsSection(
          title: 'Home Assistant',
          children: [
            SettingRow(
              icon: LucideIcons.home,
              title: 'Publish to Home Assistant',
              subtitle: brokerConfigured
                  ? 'Auto-discover this observatory as a Home Assistant '
                      'device (uses the MQTT broker above)'
                  : 'Configure the MQTT broker above first',
              trailing: SettingsSwitch(
                key: ValueKey('ha-publish-$_refusedFlips'),
                value: cfg.enabled,
                onChanged: (v) {
                  if (v && !brokerConfigured) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text(
                              'Set an MQTT broker host above before enabling '
                              'Home Assistant discovery')),
                    );
                    setState(() => _refusedFlips++);
                    return;
                  }
                  _save((c) => c.copyWith(enabled: v));
                },
              ),
            ),
            SettingRow(
              icon: LucideIcons.tag,
              title: 'Device name',
              subtitle: 'Blank = "Skotiq Observatory <profile>"',
              trailing: settingsTrailingTextInput(
                context: context,
                controller: _deviceName,
                hint: 'Skotiq Observatory',
                isMobile: widget.isMobile,
              ),
            ),
            SettingRow(
              icon: LucideIcons.shieldAlert,
              title: 'Allow control from Home Assistant',
              subtitle: 'Lets HA pause/resume and abort the running sequence. '
                  'Off = read-only sensors.',
              trailing: SettingsSwitch(
                value: cfg.allowControl,
                onChanged: (v) => _save((c) => c.copyWith(allowControl: v)),
              ),
            ),
            SettingRow(
              icon: LucideIcons.save,
              title: 'Save Home Assistant config',
              trailing: SkotiqButton(
                label: 'Save',
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                onPressed: () async {
                  await _save(
                      (c) => c.copyWith(deviceName: _deviceName.text.trim()));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Home Assistant config saved')),
                  );
                },
              ),
              isLast: true,
            ),
          ],
        );
      },
    );
  }
}

/// Host-owned Home Assistant configuration shown by a remote controller.
///
/// Notification transports above remain intentionally per-device. This form
/// is separate because Home Assistant discovery runs continuously on the
/// desktop/headless imaging host and must survive the phone disconnecting.
class _RemoteHomeAssistantSection extends ConsumerWidget {
  const _RemoteHomeAssistantSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hostAsync = ref.watch(remoteHomeAssistantHostSettingsProvider);
    return hostAsync.when(
      loading: () => const SettingsSection(
        title: 'Home Assistant (imaging host)',
        children: [
          SettingRow(
            icon: LucideIcons.loader,
            title: 'Loading host configuration…',
            trailing: SizedBox.shrink(),
            isLast: true,
          ),
        ],
      ),
      error: (_, __) => SettingsSection(
        title: 'Home Assistant (imaging host)',
        children: [
          SettingRow(
            icon: LucideIcons.alertTriangle,
            title: 'Host configuration unavailable',
            subtitle: 'Reconnect to the imaging host and try again.',
            trailing: SkotiqButton(
              label: 'Retry',
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: () =>
                  ref.invalidate(remoteHomeAssistantHostSettingsProvider),
            ),
            isLast: true,
          ),
        ],
      ),
      data: (settings) => settings == null
          ? const SizedBox.shrink()
          : _RemoteHomeAssistantForm(settings: settings),
    );
  }
}

class _RemoteHomeAssistantForm extends ConsumerStatefulWidget {
  final HomeAssistantHostSettings settings;

  const _RemoteHomeAssistantForm({required this.settings});

  @override
  ConsumerState<_RemoteHomeAssistantForm> createState() =>
      _RemoteHomeAssistantFormState();
}

class _RemoteHomeAssistantFormState
    extends ConsumerState<_RemoteHomeAssistantForm> {
  final _deviceName = TextEditingController();
  final _discoveryPrefix = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _topic = TextEditingController();
  final _clientId = TextEditingController();

  late bool _enabled;
  late bool _allowControl;
  late bool _useTls;
  bool _dirty = false;
  bool _saving = false;
  String? _error;
  late bool _passwordConfigured;
  bool _replacePassword = false;

  @override
  void initState() {
    super.initState();
    _applySnapshot(widget.settings);
  }

  @override
  void didUpdateWidget(covariant _RemoteHomeAssistantForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dirty && !identical(oldWidget.settings, widget.settings)) {
      _applySnapshot(widget.settings);
    }
  }

  void _applySnapshot(HomeAssistantHostSettings snapshot) {
    final config = snapshot.config;
    final broker = snapshot.broker;
    _enabled = config.enabled;
    _allowControl = config.allowControl;
    _useTls = broker.useTls;
    _passwordConfigured = snapshot.brokerPasswordConfigured;
    _deviceName.text = config.deviceName;
    _discoveryPrefix.text = config.discoveryPrefix;
    _host.text = broker.host;
    _port.text = broker.port.toString();
    _username.text = broker.username ?? '';
    _password.clear();
    _replacePassword = false;
    _topic.text = broker.topic;
    _clientId.text = broker.clientId;
    _dirty = false;
  }

  void _markDirty([String? _]) {
    if (!_dirty) setState(() => _dirty = true);
  }

  void _markPasswordChanged(String _) {
    setState(() {
      _replacePassword = true;
      _dirty = true;
    });
  }

  @override
  void dispose() {
    _deviceName.dispose();
    _discoveryPrefix.dispose();
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    _topic.dispose();
    _clientId.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final parsedPort = _parsePortField(_port.text, defaultPort: 1883);
    if (parsedPort.error != null) {
      setState(() => _error = parsedPort.error);
      return;
    }
    final host = _host.text.trim();
    final topic = _topic.text.trim();
    final clientId = _clientId.text.trim();
    final prefix = _discoveryPrefix.text.trim();
    if (_enabled && (host.isEmpty || topic.isEmpty)) {
      setState(() {
        _error = 'Enter the imaging host MQTT broker and topic before '
            'enabling Home Assistant.';
      });
      return;
    }
    if (host.isNotEmpty && (topic.isEmpty || clientId.isEmpty)) {
      setState(() {
        _error = 'MQTT topic and client ID are required when a broker is set.';
      });
      return;
    }
    if (prefix.isEmpty || prefix.contains('#') || prefix.contains('+')) {
      setState(() => _error = 'Enter a valid MQTT discovery prefix.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final backend = ref.read(backendProvider);
      if (backend is! NetworkBackend) {
        throw StateError('The imaging host is no longer connected.');
      }
      final replacement = _password.text;
      final updated = await backend.updateHomeAssistantHostSettings(
        config: HomeAssistantDiscoveryConfig(
          enabled: _enabled,
          deviceName: _deviceName.text.trim(),
          allowControl: _allowControl,
          discoveryPrefix: prefix,
        ),
        broker: MqttTransportConfig(
          host: host,
          port: parsedPort.port!,
          username:
              _username.text.trim().isEmpty ? null : _username.text.trim(),
          topic: topic,
          qos: widget.settings.broker.qos,
          retain: widget.settings.broker.retain,
          useTls: _useTls,
          clientId: clientId,
        ),
        replacePassword: _replacePassword,
        replacementPassword: replacement,
      );
      if (!mounted) return;
      setState(() {
        _applySnapshot(updated);
        _saving = false;
      });
      ref.invalidate(remoteHomeAssistantHostSettingsProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Home Assistant configuration saved on imaging host'),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Could not save Home Assistant configuration on the imaging '
            'host. Check the connection and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final mobile =
        MediaQuery.sizeOf(context).width < SkotiqTokens.breakpointTablet;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceMd),
            child: SkotiqInlineBanner(
              message: _error!,
              severity: SkotiqAlertSeverity.error,
            ),
          ),
        SettingsSection(
          title: 'Home Assistant (imaging host)',
          children: [
            const SettingRow(
              icon: LucideIcons.server,
              title: 'Runs on the imaging host',
              subtitle: 'This broker is separate from notification MQTT on '
                  'this phone and remains active after the phone disconnects.',
              trailing: SizedBox.shrink(),
            ),
            SettingRow(
              icon: LucideIcons.home,
              title: 'Publish to Home Assistant',
              subtitle: 'Auto-discover this observatory over host-side MQTT',
              trailing: SettingsSwitch(
                value: _enabled,
                onChanged: (value) {
                  setState(() {
                    _enabled = value;
                    _dirty = true;
                  });
                },
              ),
            ),
            SettingRow(
              icon: LucideIcons.tag,
              title: 'Device name',
              subtitle: 'Blank = Skotiq Observatory and active profile',
              trailing: settingsTrailingTextInput(
                context: context,
                controller: _deviceName,
                hint: 'Skotiq Observatory',
                isMobile: mobile,
                onChanged: _markDirty,
              ),
            ),
            SettingRow(
              icon: LucideIcons.shieldAlert,
              title: 'Allow control from Home Assistant',
              subtitle: 'Permit pause, resume, and abort commands',
              trailing: SettingsSwitch(
                value: _allowControl,
                onChanged: (value) {
                  setState(() {
                    _allowControl = value;
                    _dirty = true;
                  });
                },
              ),
            ),
            SettingRow(
              icon: LucideIcons.server,
              title: 'Host MQTT broker',
              trailing: settingsTrailingTextInput(
                context: context,
                controller: _host,
                hint: 'homeassistant.local',
                isMobile: mobile,
                onChanged: _markDirty,
              ),
            ),
            SettingRow(
              icon: LucideIcons.hash,
              title: 'Broker port',
              trailing: settingsTrailingTextInput(
                context: context,
                controller: _port,
                hint: _useTls ? '8883' : '1883',
                isMobile: mobile,
                onChanged: _markDirty,
              ),
            ),
            SettingRow(
              icon: LucideIcons.user,
              title: 'Broker username',
              trailing: settingsTrailingTextInput(
                context: context,
                controller: _username,
                hint: 'optional',
                isMobile: mobile,
                onChanged: _markDirty,
              ),
            ),
            _SecretFieldRow(
              icon: LucideIcons.keyRound,
              title: 'Broker password',
              subtitle: 'Write-only secret stored on the imaging host.',
              controller: _password,
              hasStoredValue: _passwordConfigured,
              hint: 'Enter a replacement password',
              isMobile: mobile,
              onChanged: _markPasswordChanged,
            ),
            SettingRow(
              icon: LucideIcons.messageSquare,
              title: 'State topic',
              trailing: settingsTrailingTextInput(
                context: context,
                controller: _topic,
                hint: 'skotiq/notifications',
                isMobile: mobile,
                onChanged: _markDirty,
              ),
            ),
            SettingRow(
              icon: LucideIcons.fingerprint,
              title: 'MQTT client ID',
              trailing: settingsTrailingTextInput(
                context: context,
                controller: _clientId,
                hint: 'skotiq',
                isMobile: mobile,
                onChanged: _markDirty,
              ),
            ),
            SettingRow(
              icon: LucideIcons.lock,
              title: 'Use TLS',
              trailing: SettingsSwitch(
                value: _useTls,
                onChanged: (value) {
                  setState(() {
                    _useTls = value;
                    _dirty = true;
                  });
                },
              ),
            ),
            SettingRow(
              icon: LucideIcons.folderTree,
              title: 'Discovery prefix',
              trailing: settingsTrailingTextInput(
                context: context,
                controller: _discoveryPrefix,
                hint: 'homeassistant',
                isMobile: mobile,
                onChanged: _markDirty,
              ),
            ),
            SettingRow(
              icon: LucideIcons.save,
              title: _dirty ? 'Save host configuration' : 'Host is up to date',
              trailing: SkotiqButton(
                label: 'Save',
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                isLoading: _saving,
                onPressed: _saving || !_dirty ? null : _save,
              ),
              isLast: true,
            ),
          ],
        ),
      ],
    );
  }
}
