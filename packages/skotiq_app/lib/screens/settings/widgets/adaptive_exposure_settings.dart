// Sky-brightness adaptive exposure global defaults UI.
//
// Surfaces the master toggle, reference sky brightness, min/max clamp,
// and per-filter overrides for the global default config that the Rust
// executor's `RuntimeConfig.default_adaptive_exposure` reads at sequence
// start. Per-node `ExposureNode.adaptiveExposure` overrides still win at
// runtime; this page only tunes the *default* the executor uses when a
// node has no own block.
//
// The settings are persisted via `AppSettingsNotifier.setAdaptiveExposure*`
// and pushed to the executor via
// `backend.sequencerUpdateDefaultAdaptiveExposure` (or the clear
// equivalent when the master toggle is off).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'settings_widgets.dart';

class AdaptiveExposureSettings extends ConsumerStatefulWidget {
  final bool isMobile;

  const AdaptiveExposureSettings({
    super.key,
    this.isMobile = false,
  });

  @override
  ConsumerState<AdaptiveExposureSettings> createState() =>
      _AdaptiveExposureSettingsState();
}

class _AdaptiveExposureSettingsState
    extends ConsumerState<AdaptiveExposureSettings> {
  final _refMagController = TextEditingController();
  final _minSecsController = TextEditingController();
  final _maxSecsController = TextEditingController();
  String? _globalBoundsError;
  int _globalBoundsSaveGeneration = 0;

  @override
  void dispose() {
    _refMagController.dispose();
    _minSecsController.dispose();
    _maxSecsController.dispose();
    super.dispose();
  }

  Future<void> _commitGlobalBounds(AppSettingsNotifier notifier) async {
    final minSecs = double.tryParse(_minSecsController.text.trim());
    final maxSecs = double.tryParse(_maxSecsController.text.trim());
    String? validationError;
    if (minSecs == null || !minSecs.isFinite || minSecs <= 0) {
      validationError = 'Minimum exposure must be a positive number.';
    } else if (maxSecs == null || !maxSecs.isFinite || maxSecs <= 0) {
      validationError = 'Maximum exposure must be a positive number.';
    } else if (minSecs > maxSecs) {
      validationError = 'Minimum exposure cannot exceed maximum exposure.';
    }
    if (validationError != null) {
      if (mounted) setState(() => _globalBoundsError = validationError);
      throw StateError(validationError);
    }

    final generation = ++_globalBoundsSaveGeneration;
    if (mounted) setState(() => _globalBoundsError = null);
    try {
      await notifier.setAdaptiveExposureBounds(
        minSecs: minSecs!,
        maxSecs: maxSecs!,
      );
    } catch (error) {
      if (mounted && generation == _globalBoundsSaveGeneration) {
        setState(() {
          _globalBoundsError = 'Could not save exposure bounds: $error';
        });
      }
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final settingsAsync = ref.watch(appSettingsProvider);

    // Built on SettingsPage / SettingsSection / SettingRow like every other
    // leaf: the desktop host mounts leaves with NO padding of its own, so a
    // bare Column renders without cards and with its controls sliced off by the
    // window edge.
    return settingsAsync.when(
      loading: () => SettingsLoadingState(isMobile: widget.isMobile),
      error: (e, _) => SettingsErrorState(
        isMobile: widget.isMobile,
        error: e,
        onRetry: () => ref.invalidate(appSettingsProvider),
      ),
      data: (settings) {
        final authority = ref.watch(backendProvider);
        final notifier = ref.read(appSettingsProvider.notifier);
        final enabled = settings.adaptiveExposureEnabled;
        return SettingsPage(
          title: 'Adaptive exposure',
          description:
              'Lengthens or shortens each frame automatically when the sky is '
              'brighter or darker than your reference, so signal-to-noise stays '
              'roughly constant as conditions change. A capture step that '
              'carries its own adaptive settings always wins; this page sets the '
              'default for steps that do not.',
          isMobile: widget.isMobile,
          hideHeader: widget.isMobile,
          children: [
            SettingsSection(
              title: 'Global default',
              isMobile: widget.isMobile,
              children: [
                SettingRow(
                  icon: LucideIcons.barChart3,
                  title: 'Enable global default',
                  subtitle:
                      'Apply adaptive exposure to capture steps that have no '
                      'settings of their own',
                  trailing: SettingsSwitch(
                    value: enabled,
                    onChanged: (v) async {
                      await notifier.setAdaptiveExposureEnabled(v);
                    },
                  ),
                  isMobile: widget.isMobile,
                  isLast: !enabled,
                ),
                // Target SNR control hidden until the native executor honors
                // target_snr; compute_adaptive_exposure ignores it today.
                if (enabled) ...[
                  SettingRow(
                    icon: LucideIcons.moon,
                    title: 'Reference sky brightness',
                    subtitle:
                        'The darkness your planned exposures were chosen for, '
                        'in mag/arcsec²',
                    trailing: SettingsNumberInput(
                      key: const ValueKey('adaptive-reference-mag'),
                      controller: _refMagController,
                      authoritativeValue: settings.adaptiveExposureReferenceMag,
                      authorityKey: authority,
                      suffix: 'mag',
                      min: 14,
                      max: 24,
                      decimals: 2,
                      onChanged: notifier.setAdaptiveExposureReferenceMag,
                    ),
                    isMobile: widget.isMobile,
                  ),
                  SettingRow(
                    icon: LucideIcons.arrowDownNarrowWide,
                    title: 'Shortest exposure',
                    subtitle: 'Adaptive exposure never goes below this',
                    trailing: SettingsNumberInput(
                      key: const ValueKey('adaptive-global-min-secs'),
                      controller: _minSecsController,
                      authoritativeValue: settings.adaptiveExposureMinSecs,
                      authorityKey: authority,
                      suffix: 's',
                      min: 0.1,
                      max: 86400,
                      decimals: 1,
                      onChanged: (_) => _commitGlobalBounds(notifier),
                    ),
                    isMobile: widget.isMobile,
                  ),
                  SettingRow(
                    icon: LucideIcons.arrowUpNarrowWide,
                    title: 'Longest exposure',
                    subtitle: 'Adaptive exposure never goes above this',
                    trailing: SettingsNumberInput(
                      key: const ValueKey('adaptive-global-max-secs'),
                      controller: _maxSecsController,
                      authoritativeValue: settings.adaptiveExposureMaxSecs,
                      authorityKey: authority,
                      suffix: 's',
                      min: 0.1,
                      max: 86400,
                      decimals: 1,
                      onChanged: (_) => _commitGlobalBounds(notifier),
                    ),
                    isMobile: widget.isMobile,
                    isLast: true,
                  ),
                ],
              ],
            ),
            if (_globalBoundsError != null) ...[
              Padding(
                padding: const EdgeInsets.only(
                  bottom: SkotiqTokens.spaceLg,
                ),
                child: Text(
                  _globalBoundsError!,
                  style: SkotiqTypography.captionSm.copyWith(
                    color: colors.error,
                  ),
                ),
              ),
            ],
            if (enabled) ...[
              SettingsSection(
                title: 'Per-filter overrides',
                isMobile: widget.isMobile,
                children: [
                  Padding(
                    padding: EdgeInsets.all(
                      widget.isMobile ? 12 : SkotiqTokens.spaceLg,
                    ),
                    child: _PerFilterEditor(
                      settings: settings,
                      notifier: notifier,
                    ),
                  ),
                ],
              ),
              Container(
                padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
                decoration:
                    SkotiqDecorations.chip(colors, tone: colors.info),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(LucideIcons.info, size: 14, color: colors.info),
                    const SizedBox(width: SkotiqTokens.spaceSm),
                    Expanded(
                      child: Text(
                        'How it works: Skotiq compares the live sky '
                        'brightness with your reference and scales the planned '
                        'exposure so the sky-limited signal-to-noise stays about '
                        'the same. Per-filter overrides are respected, and the '
                        'shortest/longest limits stop runaway exposures.',
                        style: SkotiqTypography.caption.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _PerFilterEditor extends ConsumerStatefulWidget {
  const _PerFilterEditor({
    required this.settings,
    required this.notifier,
  });
  final AppSettingsState settings;
  final AppSettingsNotifier notifier;

  @override
  ConsumerState<_PerFilterEditor> createState() => _PerFilterEditorState();
}

class _PerFilterEditorState extends ConsumerState<_PerFilterEditor> {
  String? _boundsError;
  int _saveGeneration = 0;

  void _showBoundsError(String message) {
    if (mounted) setState(() => _boundsError = message);
  }

  Future<void> _commitBounds(
    Map<String, double> minMap,
    Map<String, double> maxMap,
  ) async {
    final generation = ++_saveGeneration;
    if (mounted) setState(() => _boundsError = null);
    try {
      await widget.notifier.setAdaptiveExposurePerFilterBounds(
        minSecs: minMap,
        maxSecs: maxMap,
      );
    } catch (error) {
      if (mounted && generation == _saveGeneration) {
        setState(() {
          _boundsError = error is ArgumentError
              ? error.message.toString()
              : 'Could not save per-filter exposure bounds: $error';
        });
      }
    }
  }

  Future<void> _commitEnabled(Map<String, bool> enabledMap) async {
    try {
      await widget.notifier.setAdaptiveExposurePerFilterEnabled(enabledMap);
    } catch (error) {
      _showBoundsError('Could not save per-filter enablement: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    // Same source of truth the rest of the app uses for "which filters exist":
    // the connected wheel's names when it is online, otherwise the active
    // profile's. Reading only the profile made this page claim there was no
    // filter wheel while Autofocus (which reads the live wheel) listed seven.
    final filterNames = ref.watch(effectiveFiltersProvider);
    if (filterNames.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
        decoration: SkotiqDecorations.chip(colors, tone: colors.warning),
        child: Row(
          children: [
            Icon(LucideIcons.alertTriangle, size: 14, color: colors.warning),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Expanded(
              child: Text(
                'No filter wheel connected and no filters on the active '
                'profile — adaptive applies to every capture (mono camera '
                'assumption).',
                style: SkotiqTypography.caption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final enabledMap = Map<String, bool>.from(
        widget.settings.adaptiveExposurePerFilterEnabled);
    final minMap = Map<String, double>.from(
        widget.settings.adaptiveExposurePerFilterMinSecs);
    final maxMap = Map<String, double>.from(
        widget.settings.adaptiveExposurePerFilterMaxSecs);

    // The section title lives on the enclosing SettingsSection now, so this
    // widget renders only its own explanation + rows.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'A filter left blank follows the settings above. Tick a filter to opt '
          'it into adaptive exposure, and set its own shortest/longest limits to '
          'override them.',
          style: SkotiqTypography.captionSm.copyWith(
            color: colors.textMuted,
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        ...filterNames.map((filter) =>
            _filterRow(filter, filterNames, enabledMap, minMap, maxMap)),
        if (_boundsError != null) ...[
          const SizedBox(height: SkotiqTokens.spaceXs),
          Text(
            _boundsError!,
            style: SkotiqTypography.captionSm.copyWith(
              color: colors.error,
            ),
          ),
        ],
      ],
    );
  }

  Widget _filterRow(
    String filter,
    List<String> allFilters,
    Map<String, bool> enabledMap,
    Map<String, double> minMap,
    Map<String, double> maxMap,
  ) {
    final colors = SkotiqColors.of(context);
    final enabled = enabledMap[filter] ?? enabledMap.isEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 60,
            child: Text(
              filter,
              style: SkotiqTypography.readoutXs.copyWith(
                color: colors.textPrimary,
              ),
            ),
          ),
          SkotiqCheckbox(
            value: enabled,
            onChanged: (v) {
              // An empty map means "all filters enabled". Materialize that
              // implicit state before changing one checkbox; otherwise the
              // first unchecked filter makes every absent filter disabled.
              if (enabledMap.isEmpty) {
                for (final known in allFilters) {
                  enabledMap[known] = true;
                }
              }
              enabledMap[filter] = v ?? false;
              unawaited(_commitEnabled(enabledMap));
            },
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _OverrideField(
              key: ValueKey('adaptiveExposure.$filter.min'),
              label: 'min s',
              initial: minMap[filter],
              onChanged: (v) {
                if (v == null) {
                  minMap.remove(filter);
                } else {
                  minMap[filter] = v;
                }
                unawaited(_commitBounds(minMap, maxMap));
              },
              onInvalid: _showBoundsError,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _OverrideField(
              key: ValueKey('adaptiveExposure.$filter.max'),
              label: 'max s',
              initial: maxMap[filter],
              onChanged: (v) {
                if (v == null) {
                  maxMap.remove(filter);
                } else {
                  maxMap[filter] = v;
                }
                unawaited(_commitBounds(minMap, maxMap));
              },
              onInvalid: _showBoundsError,
            ),
          ),
        ],
      ),
    );
  }
}

class _OverrideField extends StatefulWidget {
  const _OverrideField({
    super.key,
    required this.label,
    required this.initial,
    required this.onChanged,
    required this.onInvalid,
  });
  final String label;
  final double? initial;
  final ValueChanged<double?> onChanged;
  final ValueChanged<String> onInvalid;

  @override
  State<_OverrideField> createState() => _OverrideFieldState();
}

class _OverrideFieldState extends State<_OverrideField> {
  late TextEditingController _controller;
  final _focusNode = FocusNode();
  late String _lastSubmitted;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.initial == null ? '' : widget.initial!.toStringAsFixed(1),
    );
    _lastSubmitted = _controller.text;
    _focusNode.addListener(_onFocusChange);
  }

  void _onFocusChange() {
    // Persist on blur, not only on Enter, so an override edit survives leaving
    // the field without submitting.
    if (!_focusNode.hasFocus) {
      _submit(_controller.text);
    }
  }

  void _submit(String v) {
    final text = v.trim();
    if (text == _lastSubmitted) return;
    _lastSubmitted = text;
    if (text.isEmpty) {
      widget.onChanged(null);
      return;
    }
    final parsed = double.tryParse(text);
    if (parsed == null || !parsed.isFinite || parsed <= 0) {
      widget.onInvalid('${widget.label} must be a positive number.');
      return;
    }
    widget.onChanged(parsed);
  }

  @override
  void didUpdateWidget(_OverrideField old) {
    super.didUpdateWidget(old);
    if (widget.initial != old.initial) {
      _controller.text =
          widget.initial == null ? '' : widget.initial!.toStringAsFixed(1);
      _lastSubmitted = _controller.text;
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      focusNode: _focusNode,
      style: SkotiqTypography.caption.copyWith(
        color: SkotiqColors.of(context).textPrimary,
      ),
      decoration: InputDecoration(
        labelText: widget.label,
        labelStyle: SkotiqTypography.captionSm.copyWith(
          color: SkotiqColors.of(context).textMuted,
        ),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      ),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      onSubmitted: _submit,
    );
  }
}
