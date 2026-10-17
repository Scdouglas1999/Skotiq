// Magnitude, size, altitude and moon-separation range controls plus sort/reset chips.
part of '../planner_screen.dart';

class _MagnitudeRangeControl extends ConsumerWidget {
  final SkotiqColors colors;
  final (double, double)? bounds;
  final double? min;
  final double? max;

  const _MagnitudeRangeControl({
    required this.colors,
    required this.bounds,
    required this.min,
    required this.max,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = min != null || max != null;
    String label;
    if (active) {
      final lo = min?.toStringAsFixed(1) ?? 'any';
      final hi = max?.toStringAsFixed(1) ?? 'any';
      label = 'Mag $lo–$hi';
    } else {
      label = 'Magnitude: any';
    }

    return _ControlChip(
      colors: colors,
      icon: LucideIcons.sparkles,
      label: label,
      active: active,
      onTap: () async {
        final actualBounds = bounds ?? (-2.0, 18.0);
        final result = await showDialog<(double?, double?)>(
          context: context,
          builder: (dCtx) {
            double lo = min ?? actualBounds.$1;
            double hi = max ?? actualBounds.$2;
            return StatefulBuilder(
              builder: (dCtx, setDState) {
                return AlertDialog(
                  backgroundColor: colors.surface,
                  title: Text(
                    'Magnitude range',
                    style: SkotiqTypography.body
                        .copyWith(color: colors.textPrimary),
                  ),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Brighter ${lo.toStringAsFixed(1)} – Dimmer ${hi.toStringAsFixed(1)}',
                        style: SkotiqTypography.caption
                            .copyWith(color: colors.textSecondary),
                      ),
                      RangeSlider(
                        values: RangeValues(lo, hi),
                        min: actualBounds.$1,
                        max: actualBounds.$2,
                        divisions: 40,
                        labels: RangeLabels(
                          lo.toStringAsFixed(1),
                          hi.toStringAsFixed(1),
                        ),
                        onChanged: (v) {
                          setDState(() {
                            lo = v.start;
                            hi = v.end;
                          });
                        },
                      ),
                    ],
                  ),
                  actions: [
                    SkotiqButton(
                      label: 'Clear',
                      variant: ButtonVariant.ghost,
                      size: ButtonSize.small,
                      onPressed: () => Navigator.of(dCtx).pop((null, null)),
                    ),
                    SkotiqButton(
                      label: 'Apply',
                      variant: ButtonVariant.primary,
                      size: ButtonSize.small,
                      onPressed: () => Navigator.of(dCtx).pop((lo, hi)),
                    ),
                  ],
                );
              },
            );
          },
        );
        if (result != null) {
          final notifier = ref.read(suggestionFilterProvider.notifier);
          notifier.state = notifier.state.copyWith(
            minMagnitude: () => result.$1,
            maxMagnitude: () => result.$2,
          );
          ref.read(_plannerVisibleCountProvider.notifier).state =
              _kPlannerPageSize;
        }
      },
    );
  }
}

/// Sensible default bounds for the size slider when the data-derived range
/// is unavailable (e.g. before suggestions resolve). Covers planetary nebulae
/// (sub-arcminute) up to the largest M-class targets (~600').
const double _kSizeFilterMinArcmin = 0.1;
const double _kSizeFilterMaxArcmin = 600.0;

class _SizeRangeControl extends ConsumerWidget {
  final SkotiqColors colors;
  final (double, double)? bounds;
  final double? min;
  final double? max;

  const _SizeRangeControl({
    required this.colors,
    required this.bounds,
    required this.min,
    required this.max,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = min != null || max != null;
    final label = active
        ? 'Size ${_formatSizeLabel(min)}–${_formatSizeLabel(max)}'
        : 'Size: any';

    return _ControlChip(
      colors: colors,
      icon: LucideIcons.ruler,
      label: label,
      active: active,
      onTap: () async {
        // Clamp the data-derived bounds into the slider's hard limits so the
        // RangeSlider doesn't assert when the catalog reports outliers.
        final dataLo = bounds?.$1 ?? _kSizeFilterMinArcmin;
        final dataHi = bounds?.$2 ?? _kSizeFilterMaxArcmin;
        final sliderLo =
            dataLo.clamp(_kSizeFilterMinArcmin, _kSizeFilterMaxArcmin);
        final sliderHi =
            dataHi.clamp(_kSizeFilterMinArcmin, _kSizeFilterMaxArcmin);
        final actualBounds = (
          sliderLo < _kSizeFilterMaxArcmin ? sliderLo : _kSizeFilterMinArcmin,
          sliderHi > sliderLo ? sliderHi : _kSizeFilterMaxArcmin,
        );

        final result = await showDialog<(double?, double?)>(
          context: context,
          builder: (dCtx) {
            double lo = (min ?? actualBounds.$1)
                .clamp(actualBounds.$1, actualBounds.$2);
            double hi = (max ?? actualBounds.$2)
                .clamp(actualBounds.$1, actualBounds.$2);
            return StatefulBuilder(
              builder: (dCtx, setDState) {
                return AlertDialog(
                  backgroundColor: colors.surface,
                  title: Text(
                    'Angular size range',
                    style: SkotiqTypography.body
                        .copyWith(color: colors.textPrimary),
                  ),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '${_formatSizeLabel(lo)} – ${_formatSizeLabel(hi)}',
                        style: SkotiqTypography.caption
                            .copyWith(color: colors.textSecondary),
                      ),
                      RangeSlider(
                        values: RangeValues(lo, hi),
                        min: actualBounds.$1,
                        max: actualBounds.$2,
                        divisions: 60,
                        labels: RangeLabels(
                          _formatSizeLabel(lo),
                          _formatSizeLabel(hi),
                        ),
                        onChanged: (v) {
                          setDState(() {
                            lo = v.start;
                            hi = v.end;
                          });
                        },
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'Targets without recorded size data are excluded '
                          'while this filter is active.',
                          style: SkotiqTypography.caption
                              .copyWith(color: colors.textMuted),
                        ),
                      ),
                    ],
                  ),
                  actions: [
                    SkotiqButton(
                      label: 'Clear',
                      variant: ButtonVariant.ghost,
                      size: ButtonSize.small,
                      onPressed: () => Navigator.of(dCtx).pop((null, null)),
                    ),
                    SkotiqButton(
                      label: 'Apply',
                      variant: ButtonVariant.primary,
                      size: ButtonSize.small,
                      onPressed: () => Navigator.of(dCtx).pop((lo, hi)),
                    ),
                  ],
                );
              },
            );
          },
        );
        if (result != null) {
          final notifier = ref.read(suggestionFilterProvider.notifier);
          notifier.state = notifier.state.copyWith(
            minSizeArcmin: () => result.$1,
            maxSizeArcmin: () => result.$2,
          );
          ref.read(_plannerVisibleCountProvider.notifier).state =
              _kPlannerPageSize;
        }
      },
    );
  }
}

/// Format an arcminute value for compact display in size chips/labels.
/// Sub-arcminute → arcseconds (`45"`); >=1' → arcminutes with one decimal
/// (`12.4'`). Nulls and non-positive values render as "any".
String _formatSizeLabel(double? arcmin) {
  if (arcmin == null || arcmin <= 0) return 'any';
  if (arcmin < 1.0) {
    final arcsec = arcmin * 60.0;
    return '${arcsec.toStringAsFixed(0)}"';
  }
  return "${arcmin.toStringAsFixed(1)}'";
}

/// The altitude a target is at RIGHT NOW — which is an angle measured from the
/// observer's own site, so with no site set there is no altitude to filter on
/// and the chip says so instead of opening a slider.
class _MinAltitudeControl extends ConsumerWidget {
  final SkotiqColors colors;
  final double? value;

  const _MinAltitudeControl({required this.colors, required this.value});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = value != null;
    final label =
        active ? 'Alt now ≥ ${value!.toStringAsFixed(0)}°' : 'Alt now: any';
    final siteUnset = plannerSiteUnset(ref.watch(appObserverLocationProvider));

    return _ControlChip(
      colors: colors,
      icon: LucideIcons.mountain,
      label: label,
      active: active,
      unavailableReason: siteUnset ? kPlannerSiteFilterRefusal : null,
      onTap: () async {
        // Why: derive a sensible default from the user's horizon profile so
        // first-time users land on something that matches their site.
        final horizonProfile = ref.read(horizonProfileProvider);
        double seed = value ?? 0.0;
        if (!active && !horizonProfile.isFlat) {
          // Pick the maximum horizon obstruction as a starting guess.
          double maxAlt = 0.0;
          for (int az = 0; az < 360; az += 15) {
            final h = horizonProfile.altitudeAtAzimuth(az.toDouble());
            if (h > maxAlt) maxAlt = h;
          }
          seed = maxAlt;
        }
        final result = await _showAngleSlider(
          context: context,
          colors: colors,
          title: 'Minimum altitude right now',
          unit: '°',
          initial: seed,
          min: 0,
          max: 89,
          isSet: active,
        );
        if (result != null) {
          final notifier = ref.read(suggestionFilterProvider.notifier);
          notifier.state = notifier.state.copyWith(
            minCurrentAltitude: () => result.isNaN ? null : result,
          );
          ref.read(_plannerVisibleCountProvider.notifier).state =
              _kPlannerPageSize;
        }
      },
    );
  }
}

/// The separation between a target and the moon, as the candidate's own
/// visibility record measures it — from the observing site, like the altitude
/// beside it. No site, no separation, so the chip carries the reason rather
/// than a live slider.
class _MoonSeparationControl extends ConsumerWidget {
  final SkotiqColors colors;
  final double? value;

  const _MoonSeparationControl({required this.colors, required this.value});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = value != null;
    final label = active ? 'Moon ≥ ${value!.toStringAsFixed(0)}°' : 'Moon: any';
    final siteUnset = plannerSiteUnset(ref.watch(appObserverLocationProvider));

    return _ControlChip(
      colors: colors,
      icon: LucideIcons.moon,
      label: label,
      active: active,
      unavailableReason: siteUnset ? kPlannerSiteFilterRefusal : null,
      onTap: () async {
        final result = await _showAngleSlider(
          context: context,
          colors: colors,
          title: 'Minimum moon separation',
          unit: '°',
          initial: value ?? 30.0,
          min: 0,
          max: 180,
          isSet: active,
        );
        if (result != null) {
          final notifier = ref.read(suggestionFilterProvider.notifier);
          notifier.state = notifier.state.copyWith(
            minMoonDistance: () => result.isNaN ? null : result,
          );
          ref.read(_plannerVisibleCountProvider.notifier).state =
              _kPlannerPageSize;
        }
      },
    );
  }
}

class _SortDropdown extends ConsumerWidget {
  final SkotiqColors colors;
  final PlannerSortMode value;

  const _SortDropdown({required this.colors, required this.value});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const labels = {
      PlannerSortMode.score: 'Score',
      PlannerSortMode.altitude: 'Altitude',
      PlannerSortMode.magnitude: 'Magnitude',
      PlannerSortMode.size: 'Size (largest)',
      PlannerSortMode.constellation: 'Constellation',
      PlannerSortMode.objectType: 'Object type',
      PlannerSortMode.catalogId: 'Catalog ID',
    };

    // The mockup right-aligns this as prose, not a control pill: a muted
    // "Sort:" and the current mode in `textPrimary`, with the menu behind it.
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          context.l10n.text('plannerSortPrefix'),
          style: SkotiqTypography.bodySm.copyWith(
            color: colors.textMuted,
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceXs),
        DropdownButtonHideUnderline(
          child: AccessibleDropdown<PlannerSortMode>(
            value: value,
            items: [
              for (final m in PlannerSortMode.values)
                DropdownMenuItem(value: m, child: Text(labels[m]!)),
            ],
            isDense: true,
            style: SkotiqTypography.buttonSm.copyWith(
              color: colors.textPrimary,
            ),
            dropdownColor: colors.surfaceElevated,
            iconSize: SkotiqTokens.iconSm,
            onChanged: (v) {
              if (v == null) return;
              final notifier = ref.read(suggestionFilterProvider.notifier);
              notifier.state = notifier.state.copyWith(plannerSort: () => v);
            },
          ),
        ),
      ],
    );
  }
}

class _ResetChip extends StatelessWidget {
  final SkotiqColors colors;
  final VoidCallback onPressed;

  const _ResetChip({required this.colors, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return _ControlChip(
      colors: colors,
      icon: LucideIcons.rotateCcw,
      label: 'Reset filters',
      active: true,
      onTap: onPressed,
    );
  }
}

class _ControlChip extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  /// Why this filter cannot be applied, or null when it can.
  ///
  /// A chip with a reason is dead on the row: no tap, no sheet, and the reason
  /// rides on the accessible NAME as well as on the tooltip — the convention
  /// [unavailableControlName] documents, because the Linux AT-SPI bridge drops
  /// `tooltip:` and a reason only a pointer can reach is no reason at all.
  final String? unavailableReason;

  const _ControlChip({
    required this.colors,
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.unavailableReason,
  });

  @override
  Widget build(BuildContext context) {
    final reason = unavailableReason;
    final unavailable = reason != null;

    // Declare the chip. A bare tap target publishes a focusable node that
    // never sets isEnabled, and nothing in the subtree carries the on/off
    // state either, so a screen-reader user is told the filter row is dead and
    // is never told which filters are applied. The wrapper below is the
    // accessible node; the component's own Semantics is excluded so AT reads
    // one node, not two.
    final chip = Semantics(
      container: true,
      button: true,
      enabled: !unavailable,
      selected: active,
      label: unavailable ? unavailableControlName(label, reason) : label,
      onTap: unavailable ? null : onTap,
      child: ExcludeSemantics(
        child: SkotiqFilterChip(
          label: label,
          icon: icon,
          trailingIcon: unavailable ? null : LucideIcons.chevronDown,
          onTap: unavailable ? null : onTap,
        ),
      ),
    );
    // The tooltip is what a mouse user gets; the same words are in the name
    // above for everyone else.
    return unavailable ? Tooltip(message: reason, child: chip) : chip;
  }
}

/// [isSet] tells the sheet whether the filter it edits is currently ACTIVE.
///
/// When it is not, the sheet must not present [initial] as if the user had
/// chosen it. The moon chip read "Moon: any" while this dialog opened with the
/// slider parked at 30 deg and the readout showing "30°", so pressing Apply
/// without touching anything silently changed the filter — live, the chip flipped
/// to "Moon >= 30" and the candidate count dropped from 1202 to 1174 on a value
/// the user never picked. [initial] is still honoured as the slider's STARTING
/// POSITION (a useful hint, and for altitude it is derived from the horizon
/// profile), but until the slider is actually moved the readout says "Any" and
/// Apply is disabled, so the only way to set a value is to choose one.
Future<double?> _showAngleSlider({
  required BuildContext context,
  required SkotiqColors colors,
  required String title,
  required String unit,
  required double initial,
  required double min,
  required double max,
  required bool isSet,
}) async {
  return showDialog<double>(
    context: context,
    builder: (dCtx) {
      double val = initial.clamp(min, max);
      // An already-set filter may be re-applied unchanged (a harmless no-op), so
      // only an UNSET one starts untouched.
      bool touched = isSet;
      return StatefulBuilder(
        builder: (dCtx, setDState) {
          return AlertDialog(
            backgroundColor: colors.surface,
            title: Text(title,
                style:
                    SkotiqTypography.body.copyWith(color: colors.textPrimary)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  touched ? '${val.toStringAsFixed(0)}$unit' : 'Any',
                  style: SkotiqTypography.sectionTitle.copyWith(
                    color: touched ? colors.textPrimary : colors.textMuted,
                  ),
                ),
                Slider(
                  value: val,
                  min: min,
                  max: max,
                  divisions: (max - min).round(),
                  label: '${val.toStringAsFixed(0)}$unit',
                  onChanged: (v) => setDState(() {
                    val = v;
                    touched = true;
                  }),
                ),
                if (!touched)
                  Text(
                    'No limit is set. Drag the slider to choose one.',
                    style: SkotiqTypography.caption.copyWith(
                      color: colors.textMuted,
                    ),
                  ),
              ],
            ),
            actions: [
              SkotiqButton(
                label: 'Clear',
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
                onPressed: () => Navigator.of(dCtx).pop(-1.0),
              ),
              SkotiqButton(
                label: 'Apply',
                variant: ButtonVariant.primary,
                size: ButtonSize.small,
                // Disabled until there is a real choice to apply, so Apply can
                // never commit a value the sheet invented.
                onPressed: touched ? () => Navigator.of(dCtx).pop(val) : null,
              ),
            ],
          );
        },
      );
    },
  ).then((value) {
    if (value == null) return null;
    // -1 sentinel from the Clear button → NaN tells the caller to clear the
    // filter, distinct from a null barrier-dismiss which is a no-op.
    if (value < 0) return double.nan;
    return value;
  });
}

/// Test-only seam exposing the two filter chips that need an observing site.
///
/// Same rationale as [showAngleSliderForTest]: they are private widgets inside
/// a `part` file, and pumping the whole `PlannerScreen` runs a 1 s periodic sky
/// clock that never settles. Both are built unset, which is the state a fresh
/// install shows them in. Nothing in production calls this.
@visibleForTesting
Widget plannerSiteFilterChipsForTest(SkotiqColors colors) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _MinAltitudeControl(colors: colors, value: null),
        _MoonSeparationControl(colors: colors, value: null),
      ],
    );

/// Test-only seam exposing the shared angle-filter sheet.
///
/// The sheet is what regressed (it applied a value the user never chose), but it
/// is a private helper inside a `part` file, so the only other way to exercise it
/// is to pump the whole `PlannerScreen` — which runs a 1 s periodic sky clock and
/// therefore never settles, making such a test slow and flaky rather than
/// trustworthy. Driving the sheet from a bare host gives a fast, deterministic
/// test of the exact behaviour. Nothing in production calls this.
@visibleForTesting
Future<double?> showAngleSliderForTest({
  required BuildContext context,
  required SkotiqColors colors,
  required String title,
  required String unit,
  required double initial,
  required double min,
  required double max,
  required bool isSet,
}) {
  return _showAngleSlider(
    context: context,
    colors: colors,
    title: title,
    unit: unit,
    initial: initial,
    min: min,
    max: max,
    isSet: isSet,
  );
}
