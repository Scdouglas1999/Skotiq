import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../widgets/focuser_backlash/effective_backlash_readout.dart';

class EquipmentSettingsTab extends ConsumerWidget {
  const EquipmentSettingsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final settingsAsync = ref.watch(appSettingsProvider);

    return settingsAsync.when(
      // Skeleton grid mirrors the 4-card layout so the page doesn't reflow.
      loading: () => Padding(
        padding: const EdgeInsets.all(24),
        child: ResponsiveCardGrid(
          children: List.generate(4, (_) {
            return ShimmerLoading(
              child: Container(
                height: 180,
                decoration: BoxDecoration(
                  color: colors.well,
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline8),
                ),
              ),
            );
          }),
        ),
      ),
      error: (e, _) => Center(child: Text('Error loading settings: $e')),
      data: (settings) => SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        // No in-content title: both hosts (the desktop SkotiqDialog and
        // the phone AppBar) already render "Equipment Settings" directly
        // above this body, so repeating it cost a heading's worth of the
        // dialog's fixed 500 px height and said nothing new.
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ResponsiveCardGrid(
              children: [
                _CameraSettingsCard(settings: settings),
                _MountSettingsCard(settings: settings),
                _FocuserSettingsCard(settings: settings),
                const _BuiltinGuiderSettingsCard(),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CameraSettingsCard extends ConsumerWidget {
  final AppSettingsState settings;

  const _CameraSettingsCard({required this.settings});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final notifier = ref.read(appSettingsProvider.notifier);

    return SkotiqPanel(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Camera Settings',
              style: SkotiqTypography.sectionTitle
                  .copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: 16),
            _SettingRow(
              label: 'Default gain',
              child: _compactNumberField(
                context,
                initialValue: settings.defaultGain.toString(),
                onChanged: (value) {
                  final parsed = int.tryParse(value);
                  if (parsed != null) notifier.setDefaultGain(parsed);
                },
              ),
            ),
            const SizedBox(height: 12),
            _SettingRow(
              label: 'Default offset',
              child: _compactNumberField(
                context,
                initialValue: settings.defaultOffset.toString(),
                onChanged: (value) {
                  final parsed = int.tryParse(value);
                  if (parsed != null) notifier.setDefaultOffset(parsed);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MountSettingsCard extends ConsumerWidget {
  final AppSettingsState settings;

  const _MountSettingsCard({required this.settings});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final notifier = ref.read(appSettingsProvider.notifier);

    return SkotiqPanel(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Mount Settings',
              style: SkotiqTypography.sectionTitle
                  .copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: 16),
            SkotiqSwitchRow(
              label: 'Meridian flip',
              value: settings.enableMeridianFlip,
              onChanged: (value) => notifier.setEnableMeridianFlip(value),
            ),
            const SizedBox(height: 12),
            _SettingRow(
              label: 'Flip offset (min)',
              child: _compactNumberField(
                context,
                initialValue: settings.meridianFlipMinutes.toString(),
                onChanged: (value) {
                  final parsed = int.tryParse(value);
                  if (parsed != null) notifier.setMeridianFlipMinutes(parsed);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FocuserSettingsCard extends ConsumerWidget {
  final AppSettingsState settings;

  const _FocuserSettingsCard({required this.settings});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final notifier = ref.read(appSettingsProvider.notifier);

    // Gate the Temp Compensation row on whether the connected
    // focuser reports `tempCompAvailable`. The toggle is a Skotiq-side
    // controller (we re-issue moves based on a coefficient), but it
    // depends on the focuser publishing a temperature reading — drivers
    // without a probe will never provide one and the row would silently
    // do nothing. Use opacity-disable rather than visibility so the
    // setting remains discoverable; tooltip explains the reason.
    final focuserState = ref.watch(focuserStateProvider);
    final focuserCapsAsync = ref.watch(
        equipmentFocuserCapabilitiesProvider(focuserState.deviceId ?? ''));
    final tempCompAvailable = gateCapability<FocuserCapabilities>(
      focuserCapsAsync,
      (c) => c.tempCompAvailable,
      // While loading we keep the toggle live so existing setups don't
      // appear to lose their setting on every screen open.
      loadingDefault: true,
    );

    return SkotiqPanel(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Focuser Settings',
              style: SkotiqTypography.sectionTitle
                  .copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: 16),
            Tooltip(
              message: tempCompAvailable
                  ? ''
                  : 'Connected focuser does not report a temperature probe; '
                      'temp compensation cannot run.',
              child: Opacity(
                opacity: tempCompAvailable ? 1.0 : 0.5,
                child: IgnorePointer(
                  ignoring: !tempCompAvailable,
                  child: SkotiqSwitchRow(
                    label: 'Temperature compensation',
                    value: settings.tempCompensation,
                    onChanged: (value) => notifier.setTempCompensation(value),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _SettingRow(
              label: 'Temperature coefficient',
              child: _compactNumberField(
                context,
                initialValue: settings.tempCoefficient.toString(),
                onChanged: (value) {
                  final parsed = double.tryParse(value);
                  if (parsed != null) notifier.setTempCoefficient(parsed);
                },
              ),
            ),
            const SizedBox(height: 12),
            _BacklashSettingRow(settings: settings),
          ],
        ),
      ),
    );
  }
}

/// The backlash-compensation field, what the figure in force actually is, and
/// the way to measure a new one.
///
/// Stateful for the [TextEditingController]: adopting a measured figure has to
/// put the number IN the field, which an `initialValue`-only field cannot do.
/// Writing the setting while the field still showed the old number would be
/// the silent replacement this feature exists to avoid.
class _BacklashSettingRow extends ConsumerStatefulWidget {
  const _BacklashSettingRow({required this.settings});

  final AppSettingsState settings;

  @override
  ConsumerState<_BacklashSettingRow> createState() =>
      _BacklashSettingRowState();
}

class _BacklashSettingRowState extends ConsumerState<_BacklashSettingRow> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    // `afBacklashIn` and NOT `backlashCompensation`, which this field used to
    // edit. Nothing operational reads `backlashCompensation` — it is persisted,
    // synced to a remote client and displayed, and that is all; every path to
    // the focuser (`sequence_serializer`, `autofocus_controls`, the runtime
    // push-down) takes its figure from `afBacklashIn`. So the field was editing
    // a number that changed nothing, and it now sits beside a readout that
    // states the figure actually in force — two different numbers under one
    // label would be worse than either.
    _controller = TextEditingController(
      text: widget.settings.afBacklashIn.toString(),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _apply(String value) {
    final parsed = int.tryParse(value);
    if (parsed == null) return;
    final notifier = ref.read(appSettingsProvider.notifier);
    notifier.setAfBacklashIn(parsed);
    // Kept in step so the legacy setting cannot sit behind showing a
    // contradictory number anywhere it is still surfaced.
    notifier.setBacklashCompensation(parsed);
  }

  void _useMeasured(int steps) {
    _controller.text = steps.toString();
    _apply(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SettingRow(
          label: 'Backlash compensation',
          subtitle: 'Steps the gear train loses when a move reverses '
              'direction.',
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: dialogMaxWidth(context, 100)),
            child: SkotiqTextField(
              controller: _controller,
              keyboardType: TextInputType.number,
              onChanged: _apply,
            ),
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        EffectiveBacklashReadout(onUseMeasured: _useMeasured),
      ],
    );
  }
}

/// Settings card for the built-in multi-star guider.
///
/// The built-in guider runs entirely inside Skotiq (no second camera, no
/// PHD2 process) using star detection on the imaging camera and pulse-guide
/// pulses to the connected mount. Settings here apply to the Rust-side
/// [`GuiderConfig`] and persist for the duration of the app session.
///
/// The card is shown whenever the Equipment Settings dialog is open so users
/// can pre-configure the guider before assigning it to a profile. The Rust
/// `get_config`/`set_config` calls succeed regardless of whether the guider
/// is currently connected — they read/write the in-memory default config.
class _BuiltinGuiderSettingsCard extends ConsumerStatefulWidget {
  const _BuiltinGuiderSettingsCard();

  @override
  ConsumerState<_BuiltinGuiderSettingsCard> createState() =>
      _BuiltinGuiderSettingsCardState();
}

class _BuiltinGuiderSettingsCardState
    extends ConsumerState<_BuiltinGuiderSettingsCard> {
  late TextEditingController _exposureController;
  late TextEditingController _gainController;
  late TextEditingController _offsetController;
  late TextEditingController _binningController;
  late TextEditingController _calibrationMsController;
  late TextEditingController _minPulseController;
  late TextEditingController _maxPulseController;
  late TextEditingController _settleSleepController;

  bool _initialized = false;
  bool _loading = true;
  bool _saving = false;
  String? _loadError;
  BuiltinGuiderConfig _lastApplied = BuiltinGuiderConfig.defaults;
  int _backendGeneration = 0;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _exposureController = TextEditingController();
    _gainController = TextEditingController();
    _offsetController = TextEditingController();
    _binningController = TextEditingController();
    _calibrationMsController = TextEditingController();
    _minPulseController = TextEditingController();
    _maxPulseController = TextEditingController();
    _settleSleepController = TextEditingController();
    // Every field feeds the pending-edits check below. Without it the Apply
    // button looked identical whether or not anything was waiting to be sent,
    // and eight hand-typed numbers vanished silently when the dialog closed —
    // while every other section in this dialog had already saved on edit.
    for (final controller in _guiderControllers) {
      controller.addListener(_onGuiderFieldChanged);
    }
    ref.listenManual<SkotiqBackend>(backendProvider, (previous, next) {
      if (identical(previous, next)) return;
      _backendGeneration++;
      _loadGeneration++;
      setState(() {
        _initialized = false;
        _loading = true;
        _saving = false;
        _loadError = null;
      });
      _loadInitialConfig();
    });
    _loadInitialConfig();
  }

  Future<void> _loadInitialConfig() async {
    // The builtinGuiderConfigProvider only auto-fetches when the built-in
    // guider is connected. From the Equipment Settings dialog we want the
    // current config regardless of connection state, so we read it directly
    // through the backend. Rust returns the in-memory default when the
    // guider hasn't been connected, which is exactly what we want to show.
    final backend = ref.read(backendProvider);
    final backendGeneration = _backendGeneration;
    final loadGeneration = ++_loadGeneration;
    try {
      final config = await backend.builtinGuiderGetConfig();
      if (!_isCurrentBackend(
        backend,
        backendGeneration,
        loadGeneration: loadGeneration,
      )) {
        return;
      }
      _applyToControllers(config);
      setState(() {
        _lastApplied = config;
        _loading = false;
        _initialized = true;
      });
    } catch (e) {
      if (!_isCurrentBackend(
        backend,
        backendGeneration,
        loadGeneration: loadGeneration,
      )) {
        return;
      }
      setState(() {
        _loadError = e.toString();
        _loading = false;
      });
    }
  }

  void _retryLoad() {
    if (_loading || _saving) return;
    setState(() {
      _initialized = false;
      _loading = true;
      _loadError = null;
    });
    _loadInitialConfig();
  }

  bool _isCurrentBackend(
    SkotiqBackend backend,
    int backendGeneration, {
    int? loadGeneration,
  }) {
    return mounted &&
        backendGeneration == _backendGeneration &&
        (loadGeneration == null || loadGeneration == _loadGeneration) &&
        identical(backend, ref.read(backendProvider));
  }

  void _applyToControllers(BuiltinGuiderConfig config) {
    _exposureController.text = config.exposureSecs.toString();
    _gainController.text = config.gain.toString();
    _offsetController.text = config.offset.toString();
    _binningController.text = config.binning.toString();
    _calibrationMsController.text = config.calibrationMs.toString();
    _minPulseController.text = config.minPulseMs.toString();
    _maxPulseController.text = config.maxPulseMs.toString();
    _settleSleepController.text = config.settleSleepMs.toString();
  }

  List<TextEditingController> get _guiderControllers => [
        _exposureController,
        _gainController,
        _offsetController,
        _binningController,
        _calibrationMsController,
        _minPulseController,
        _maxPulseController,
        _settleSleepController,
      ];

  void _onGuiderFieldChanged() {
    // Pending-ness is derived in build from the fields vs [_lastApplied];
    // this just asks for the rebuild that re-derives it.
    if (mounted) setState(() {});
  }

  /// True when what is on screen differs from the config the guider is
  /// actually running. This block is the one part of Equipment Settings that
  /// does NOT save on edit — it pushes eight interdependent values to a guider
  /// that may be running right now, so it commits atomically on Apply — and
  /// that difference has to be visible rather than remembered.
  bool get _hasPendingEdits {
    final c = _lastApplied;
    return _differsNum(_exposureController, c.exposureSecs) ||
        _differsNum(_gainController, c.gain) ||
        _differsNum(_offsetController, c.offset) ||
        _differsNum(_binningController, c.binning) ||
        _differsNum(_calibrationMsController, c.calibrationMs) ||
        _differsNum(_minPulseController, c.minPulseMs) ||
        _differsNum(_maxPulseController, c.maxPulseMs) ||
        _differsNum(_settleSleepController, c.settleSleepMs);
  }

  /// Compare the field to the running value as a NUMBER, not as text.
  ///
  /// Three of these fields are doubles, so `_applyConfig` parses "1500" into
  /// 1500.0 and stores it — and a text-vs-`toString()` comparison then never
  /// agrees again. The card would go on warning "Not applied yet" about a
  /// value the guider is already running, with Apply live to re-send it, for
  /// the rest of the session. Text the user has not finished typing (empty, a
  /// bare "-") parses to null and counts as pending, which is what it is.
  static bool _differsNum(TextEditingController controller, num applied) {
    final typed = num.tryParse(controller.text.trim());
    return typed == null || typed != applied;
  }

  @override
  void dispose() {
    for (final controller in _guiderControllers) {
      controller.removeListener(_onGuiderFieldChanged);
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _applyConfig() async {
    if (_saving) return;
    final exposure = double.tryParse(_exposureController.text);
    final gain = int.tryParse(_gainController.text);
    final offset = int.tryParse(_offsetController.text);
    final binning = int.tryParse(_binningController.text);
    final calibrationMs = int.tryParse(_calibrationMsController.text);
    final minPulse = double.tryParse(_minPulseController.text);
    final maxPulse = double.tryParse(_maxPulseController.text);
    final settleSleep = int.tryParse(_settleSleepController.text);

    if (exposure == null ||
        gain == null ||
        offset == null ||
        binning == null ||
        calibrationMs == null ||
        minPulse == null ||
        maxPulse == null ||
        settleSleep == null) {
      context.showErrorSnackBar('Invalid built-in guider config value');
      return;
    }

    // Sanity bounds: reject the value and say so, rather than silently
    // coercing the user's input into range.
    if (exposure <= 0 || exposure > 30) {
      context.showErrorSnackBar('Exposure must be between 0 and 30 seconds');
      return;
    }
    if (binning < 1 || binning > 4) {
      context.showErrorSnackBar('Binning must be between 1 and 4');
      return;
    }
    if (calibrationMs < 50 || calibrationMs > 5000) {
      context.showErrorSnackBar('Calibration pulse must be 50–5000 ms');
      return;
    }
    if (minPulse < 0 || maxPulse <= minPulse) {
      context.showErrorSnackBar('Max pulse must be greater than min pulse');
      return;
    }

    final newConfig = BuiltinGuiderConfig(
      exposureSecs: exposure,
      gain: gain,
      offset: offset,
      binning: binning,
      calibrationMs: calibrationMs,
      minPulseMs: minPulse,
      maxPulseMs: maxPulse,
      settleSleepMs: settleSleep,
    );

    final backend = ref.read(backendProvider);
    final backendGeneration = _backendGeneration;
    setState(() => _saving = true);
    try {
      // When the built-in guider is connected, the riverpod notifier owns the
      // canonical state. Route through it so its cached AsyncValue stays in
      // sync. Otherwise call the backend directly.
      final isConnected = ref.read(isBuiltinGuiderProvider);
      if (isConnected) {
        await ref
            .read(builtinGuiderConfigProvider.notifier)
            .updateConfig(newConfig);
      } else {
        await backend.builtinGuiderSetConfig(newConfig);
      }
      if (!_isCurrentBackend(backend, backendGeneration)) return;
      setState(() => _lastApplied = newConfig);
    } catch (e) {
      if (!mounted || !_isCurrentBackend(backend, backendGeneration)) return;
      context.showErrorSnackBar('Failed to apply settings: $e');
    } finally {
      if (_isCurrentBackend(backend, backendGeneration)) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _resetDefaults() async {
    if (_saving) return;
    const defaults = BuiltinGuiderConfig.defaults;
    final backend = ref.read(backendProvider);
    final backendGeneration = _backendGeneration;
    setState(() => _saving = true);
    try {
      final isConnected = ref.read(isBuiltinGuiderProvider);
      if (isConnected) {
        await ref.read(builtinGuiderConfigProvider.notifier).resetToDefaults();
      } else {
        await backend.builtinGuiderSetConfig(defaults);
      }
      if (!_isCurrentBackend(backend, backendGeneration)) return;
      _applyToControllers(defaults);
      setState(() => _lastApplied = defaults);
    } catch (e) {
      if (!mounted || !_isCurrentBackend(backend, backendGeneration)) return;
      context.showErrorSnackBar('Failed to reset settings: $e');
    } finally {
      if (_isCurrentBackend(backend, backendGeneration)) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final isConnected = ref.watch(isBuiltinGuiderProvider);

    Widget body;
    if (_loading) {
      body = const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    } else if (_loadError != null) {
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Failed to load built-in guider config: $_loadError',
              style: SkotiqTypography.caption.copyWith(color: colors.error),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('builtin-guider-retry'),
              onPressed: _retryLoad,
              icon: const Icon(SkotiqIcons.refresh, size: 14),
              label: const Text('Retry'),
            ),
          ],
        ),
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SettingRow(
            label: 'Exposure (s)',
            subtitle:
                'Guide-frame length. Longer averages out seeing; shorter reacts faster.',
            child: _builtinNumberField(
              context,
              key: const ValueKey('builtin-guider-exposure'),
              controller: _exposureController,
              decimal: true,
            ),
          ),
          const SizedBox(height: 12),
          _SettingRow(
            label: 'Gain',
            subtitle: 'Guide-camera gain. Raise to find stars in poor seeing.',
            child: _builtinNumberField(
              context,
              key: const ValueKey('builtin-guider-gain'),
              controller: _gainController,
              decimal: false,
            ),
          ),
          const SizedBox(height: 12),
          _SettingRow(
            label: 'Offset',
            subtitle: 'Guide-camera offset (black-level pedestal).',
            child: _builtinNumberField(
              context,
              key: const ValueKey('builtin-guider-offset'),
              controller: _offsetController,
              decimal: false,
            ),
          ),
          const SizedBox(height: 12),
          _SettingRow(
            label: 'Binning',
            subtitle:
                'Combine pixels to boost star SNR at the cost of resolution.',
            child: _builtinNumberField(
              context,
              key: const ValueKey('builtin-guider-binning'),
              controller: _binningController,
              decimal: false,
            ),
          ),
          const SizedBox(height: 12),
          _SettingRow(
            label: 'Cal. Pulse (ms)',
            subtitle:
                'Mount move per calibration step. Longer for short focal lengths.',
            child: _builtinNumberField(
              context,
              key: const ValueKey('builtin-guider-calibration-ms'),
              controller: _calibrationMsController,
              decimal: false,
            ),
          ),
          const SizedBox(height: 12),
          _SettingRow(
            label: 'Min pulse (ms)',
            subtitle: 'Corrections shorter than this are skipped to avoid '
                'chasing seeing.',
            child: _builtinNumberField(
              context,
              key: const ValueKey('builtin-guider-min-pulse'),
              controller: _minPulseController,
              decimal: true,
            ),
          ),
          const SizedBox(height: 12),
          _SettingRow(
            label: 'Max pulse (ms)',
            subtitle: 'Corrections are clamped to this so one bad frame '
                'cannot lurch the mount.',
            child: _builtinNumberField(
              context,
              key: const ValueKey('builtin-guider-max-pulse'),
              controller: _maxPulseController,
              decimal: true,
            ),
          ),
          const SizedBox(height: 12),
          _SettingRow(
            label: 'Settle sleep (ms)',
            subtitle: 'Wait between settle checks after a dither or slew.',
            child: _builtinNumberField(
              context,
              key: const ValueKey('builtin-guider-settle-sleep'),
              controller: _settleSleepController,
              decimal: false,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const ValueKey('builtin-guider-reset'),
                  onPressed: _initialized && !_saving ? _resetDefaults : null,
                  icon: const Icon(SkotiqIcons.refresh, size: 14),
                  label:
                      const Text('Reset', style: SkotiqTypography.caption),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                // Disabled with nothing pending: an always-live Apply next to
                // sections that save on edit gave no way to tell "already
                // saved" from "typed and not sent".
                child: FilledButton.icon(
                  key: const ValueKey('builtin-guider-apply'),
                  onPressed: _initialized && !_saving && _hasPendingEdits
                      ? _applyConfig
                      : null,
                  icon: const Icon(SkotiqIcons.check, size: 14),
                  label:
                      const Text('Apply', style: SkotiqTypography.caption),
                ),
              ),
            ],
          ),
        ],
      );
    }

    return SkotiqPanel(
      key: const ValueKey('builtin-guider-settings-card'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Built-in Guider',
                    style: SkotiqTypography.sectionTitle
                        .copyWith(color: colors.textPrimary),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: SkotiqDecorations.tintedBadge(
                    isConnected ? colors.success : colors.textMuted,
                    borderRadius:
                        BorderRadius.circular(SkotiqTokens.radiusInline4),
                  ),
                  child: Text(
                    isConnected ? 'Active' : 'Standby',
                    style: SkotiqTypography.eyebrow.copyWith(
                      letterSpacing: 0,
                      color:
                          isConnected ? colors.success : colors.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Multi-star software guider that uses the imaging camera and mount '
              'pulse-guide. No second guide camera required. These values are '
              'sent to the guider together when you press Apply.',
              style: SkotiqTypography.caption
                  .copyWith(color: colors.textMuted),
            ),
            const SizedBox(height: 16),
            body,
            if (!_loading && _loadError == null) ...[
              const SizedBox(height: 10),
              if (_hasPendingEdits)
                Text(
                  key: const ValueKey('builtin-guider-pending'),
                  'Not applied yet — press Apply to send these to the guider.',
                  style: SkotiqTypography.caption.copyWith(
                      fontWeight: FontWeight.w600, color: colors.warning),
                ),
              Text(
                key: const ValueKey('builtin-guider-last-applied'),
                'Last applied: ${_describeConfig(_lastApplied)}',
                style: SkotiqTypography.caption
                    .copyWith(color: colors.textMuted),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _describeConfig(BuiltinGuiderConfig c) {
    return 'exp ${c.exposureSecs}s, gain ${c.gain}, bin ${c.binning}, '
        'cal ${c.calibrationMs}ms';
  }
}

Widget _builtinNumberField(
  BuildContext context, {
  Key? key,
  required TextEditingController controller,
  required bool decimal,
}) {
  return ConstrainedBox(
    constraints: BoxConstraints(maxWidth: dialogMaxWidth(context, 100)),
    child: TextField(
      key: key,
      controller: controller,
      keyboardType: TextInputType.numberWithOptions(decimal: decimal),
      inputFormatters: decimal
          ? <TextInputFormatter>[
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
            ]
          : <TextInputFormatter>[
              FilteringTextInputFormatter.allow(RegExp(r'[0-9\-]')),
            ],
      style: SkotiqTypography.bodySm,
      decoration: const InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        border: OutlineInputBorder(),
      ),
    ),
  );
}

/// Compact numeric field for equipment settings cards (design max 100px).
Widget _compactNumberField(
  BuildContext context, {
  required String initialValue,
  required ValueChanged<String> onChanged,
  String? suffix,
}) {
  return ConstrainedBox(
    constraints: BoxConstraints(maxWidth: dialogMaxWidth(context, 100)),
    child: SkotiqTextField(
      initialValue: initialValue,
      suffix: suffix,
      onChanged: onChanged,
    ),
  );
}

class _SettingRow extends StatelessWidget {
  final String label;

  /// Optional one-line, plain-language explanation rendered under the label.
  final String? subtitle;
  final Widget child;

  const _SettingRow({required this.label, this.subtitle, required this.child});

  Widget _labelColumn(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style:
              SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(
            subtitle!,
            style:
                SkotiqTypography.caption.copyWith(color: colors.textMuted),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final stackFields = constraints.maxWidth < 220;
        if (stackFields) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _labelColumn(context),
              const SizedBox(height: 8),
              child,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
              flex: 2,
              child: _labelColumn(context),
            ),
            const SizedBox(width: 12),
            Flexible(
              flex: 1,
              child: Align(
                alignment: Alignment.centerRight,
                child: child,
              ),
            ),
          ],
        );
      },
    );
  }
}
