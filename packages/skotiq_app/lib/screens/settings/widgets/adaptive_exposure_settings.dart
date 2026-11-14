// Sky-brightness adaptive exposure global defaults UI.
//
// Surfaces the master toggle, reference sky brightness, min/max clamp,
// and per-filter overrides for the global default config that the Rust
// executor's `RuntimeConfig.default_adaptive_exposure` reads at sequence
// start. Per-node `ExposureNode.adaptiveExposure` overrides still win at
// runtime; this page only tunes the *default* the executor uses when a
// node has no own block.
//
// The settings are persisted via `AppSettingsNotifier.setAdaptiveExposure*`;
// the run configuration (`RunConfigSync`) carries them to the executor, as
// no default at all when the master toggle is off.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'settings_widgets.dart';

class AdaptiveExposureSettings extends ConsumerStatefulWidget {
  const AdaptiveExposureSettings({
    super.key,
  });

  @override
  ConsumerState<AdaptiveExposureSettings> createState() =>
      _AdaptiveExposureSettingsState();
}

class _AdaptiveExposureSettingsState
    extends ConsumerState<AdaptiveExposureSettings> {
  final _minSecsController = TextEditingController();
  final _maxSecsController = TextEditingController();
  String? _globalBoundsError;
  int _globalBoundsSaveGeneration = 0;

  @override
  void dispose() {
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
          _globalBoundsError =
              'Could not save exposure bounds: ${userFacingError(error)}';
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
      loading: () => const SettingsLoadingState(),
      error: (e, _) => SettingsErrorState(
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
          children: [
            SettingsSection(
              title: 'Global default',
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
                      authoritativeValue: settings.adaptiveExposureReferenceMag,
                      authorityKey: authority,
                      suffix: 'mag',
                      min: 14,
                      max: 24,
                      decimals: 2,
                      onChanged: notifier.setAdaptiveExposureReferenceMag,
                    ),
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
                children: [
                  Padding(
                    padding: EdgeInsets.all(
                      SettingsFormScope.narrowOf(context)
                          ? 12
                          : SkotiqTokens.spaceLg,
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
                decoration: SkotiqDecorations.chip(colors, tone: colors.info),
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
              : 'Could not save per-filter exposure bounds: ${userFacingError(error)}';
        });
      }
      // The message above tells the operator; this puts the field back.
      throw SettingWriteHandled(error);
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
              value: minMap[filter],
              onChanged: (v) {
                if (v == null) {
                  minMap.remove(filter);
                } else {
                  minMap[filter] = v;
                }
                return _commitBounds(minMap, maxMap);
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _OverrideField(
              key: ValueKey('adaptiveExposure.$filter.max'),
              label: 'max s',
              value: maxMap[filter],
              onChanged: (v) {
                if (v == null) {
                  maxMap.remove(filter);
                } else {
                  maxMap[filter] = v;
                }
                return _commitBounds(minMap, maxMap);
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// A per-filter exposure bound: empty means "use the global bound".
class _OverrideField extends StatelessWidget {
  const _OverrideField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final double? value;
  final FutureOr<void> Function(double? value) onChanged;

  static const _codec = OptionalCodec(
    NumberCodec(
      min: 0.1,
      max: 3600,
      decimals: 1,
      unit: 's',
      fixedDecimals: true,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return SettingRowLabel(
      title: label,
      child: SettingsValueField<double?>(
        codec: _codec,
        value: value,
        onChanged: onChanged,
        builder: (context, parts) => TextField(
          controller: parts.controller,
          focusNode: parts.focusNode,
          style: SkotiqTypography.caption.copyWith(color: colors.textPrimary),
          decoration: InputDecoration(
            labelText: label,
            labelStyle:
                SkotiqTypography.captionSm.copyWith(color: colors.textMuted),
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          ),
          keyboardType: parts.keyboardType,
          inputFormatters: parts.inputFormatters,
          onChanged: parts.onChanged,
          onSubmitted: parts.onSubmitted,
        ),
      ),
    );
  }
}
