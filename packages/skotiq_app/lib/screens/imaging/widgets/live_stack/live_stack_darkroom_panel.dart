import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../../utils/darkroom_navigation.dart';
import '../../../../utils/snackbar_helper.dart';
import '../panel_widgets.dart';
import 'live_stack_darkroom_provider.dart';
import 'live_stack_formatters.dart';

/// Live Darkroom side-panel section for the Live Stack workspace.
///
/// Drives the real native Darkroom recipe engine (`background_extract`,
/// `denoise`, `color_calibrate`, `stretch`, `saturation`, `star_reduce`)
/// directly over the selected per-filter live stack in memory, and promotes
/// the live stack + recipe straight into the full `/darkroom` editor in one
/// click.
class LiveStackDarkroomPanel extends ConsumerStatefulWidget {
  const LiveStackDarkroomPanel({super.key, required this.colors});

  final SkotiqColors colors;

  @override
  ConsumerState<LiveStackDarkroomPanel> createState() =>
      _LiveStackDarkroomPanelState();
}

class _LiveStackDarkroomPanelState
    extends ConsumerState<LiveStackDarkroomPanel> {
  bool _isPromoting = false;

  Future<void> _openInFullDarkroom(String filterKey) async {
    if (_isPromoting) return;
    final refusal = darkroomHostOnlyRefusal(ref);
    if (refusal != null) {
      context.showInfoSnackBar(refusal);
      return;
    }
    setState(() => _isPromoting = true);
    try {
      final promoted = await promoteLiveStackToDarkroom(
        ref: ref,
        filterKey: filterKey,
      );
      if (!mounted) return;
      final location = promoted.recipeId != null
          ? darkroomEditLocation(
              masterId: promoted.masterId,
              recipeId: promoted.recipeId,
            )
          : darkroomEditLocation(masterId: promoted.masterId);
      unawaited(context.push(location));
    } catch (error) {
      if (!mounted) return;
      await ErrorDialog.show(
        context,
        title: 'Could not open live stack in Darkroom',
        message: 'The stack is still running. Try saving the master manually '
            'or try again once a frame has stacked.',
        technicalDetails: '$error',
      );
    } finally {
      if (mounted) setState(() => _isPromoting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final isRemoteClient = ref.watch(isRemoteClientProvider);
    final stack = ref.watch(liveStackingProvider);
    final dr = ref.watch(liveStackDarkroomProvider);
    final drNotifier = ref.read(liveStackDarkroomProvider.notifier);

    if (isRemoteClient) {
      return const EmptyState.compact(
        icon: SkotiqIcons.aperture,
        title: 'Live Darkroom runs on the host',
        body: kDarkroomHostOnlyRefusal,
      );
    }

    final activeSnap = stack.activeFilterStack;
    final hasPixels = (activeSnap?.hasPixels ?? false) ||
        (stack.previewData != null &&
            stack.previewWidth > 0 &&
            stack.previewHeight > 0);
    final filterKey = activeSnap?.filterKey ??
        stack.selectedFilterKey ??
        kDefaultLiveStackFilterKey;
    final isColor = activeSnap != null
        ? activeSnap.channels >= 3
        : (stack.previewData != null &&
            stack.previewWidth * stack.previewHeight > 0 &&
            stack.previewData!.length >=
                stack.previewWidth * stack.previewHeight * 3);
    final settings = dr.settingsFor(filterKey);
    final rendered = dr.renderFor(filterKey);

    if (!hasPixels) {
      return const EmptyState.compact(
        icon: SkotiqIcons.aperture,
        title: 'Waiting for stacked pixels',
        body: 'Start or arm a live stack to develop it in real time with '
            'background extraction, hyperbolic stretch, denoise, and star '
            'reduction.',
      );
    }

    void update(LiveDarkroomRecipeSettings next) {
      drNotifier.updateSettings(filterKey, next);
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SectionTitle(
            icon: SkotiqIcons.aperture,
            title: 'Live Darkroom · ${liveStackFilterDisplayName(filterKey)}',
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),

          if (dr.error != null) ...<Widget>[
            SkotiqBanner(
              title: 'Live Darkroom',
              message: dr.error!,
              tone: BannerTone.warning,
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
          ],

          // Pipeline control panel
          SkotiqPanel(
            head: PanelHead(
              label: 'Pipeline',
              trailing: <Widget>[
                if (dr.isRendering)
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.8,
                      color: colors.primary,
                    ),
                  ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SkotiqSwitchRow(
                  label: 'Live Darkroom processing',
                  subtitle: 'Re-renders non-destructively as frames stack',
                  value: dr.enabled,
                  onChanged: (v) => drNotifier.setEnabled(v),
                ),
                const SizedBox(height: SkotiqTokens.spaceMd),
                Wrap(
                  spacing: SkotiqTokens.spaceSm,
                  runSpacing: SkotiqTokens.spaceSm,
                  children: <Widget>[
                    SkotiqButton(
                      key: const ValueKey('live_darkroom_auto_develop'),
                      label:
                          dr.isAutoDeveloping ? 'Measuring...' : 'Auto-develop',
                      icon: SkotiqIcons.sparkle,
                      size: ButtonSize.small,
                      variant: ButtonVariant.secondary,
                      isLoading: dr.isAutoDeveloping,
                      onPressed: dr.isAutoDeveloping
                          ? null
                          : () => drNotifier.autoDevelop(filterKey),
                    ),
                    if (dr.enabled)
                      SkotiqButton(
                        key: const ValueKey('live_darkroom_compare_toggle'),
                        label: dr.compareBeforeAfter
                            ? 'Showing raw STF'
                            : 'Compare raw',
                        icon: SkotiqIcons.visible,
                        size: ButtonSize.small,
                        variant: ButtonVariant.ghost,
                        onPressed: drNotifier.toggleCompareBeforeAfter,
                      ),
                    if (settings.hasAnyActiveStep)
                      SkotiqButton(
                        label: 'Reset',
                        icon: SkotiqIcons.refresh,
                        size: ButtonSize.small,
                        variant: ButtonVariant.ghost,
                        onPressed: () =>
                            drNotifier.resetFilterSettings(filterKey),
                      ),
                  ],
                ),
                const SizedBox(height: SkotiqTokens.spaceMd),
                SkotiqButton(
                  key: const ValueKey('live_darkroom_open_full_editor'),
                  label: _isPromoting
                      ? 'Preparing Darkroom...'
                      : 'Open in Darkroom',
                  icon: SkotiqIcons.aperture,
                  size: ButtonSize.small,
                  isLoading: _isPromoting,
                  onPressed: _isPromoting
                      ? null
                      : () => _openInFullDarkroom(filterKey),
                ),
              ],
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),

          // Background extraction (linear)
          SkotiqPanel(
            head: const PanelHead(label: 'Background extraction'),
            child: Column(
              children: <Widget>[
                SkotiqSwitchRow(
                  label: 'Remove sky gradient',
                  subtitle: 'Polynomial surface fit over star-free lattice',
                  value: settings.backgroundExtractEnabled,
                  onChanged: (v) => update(
                    settings.copyWith(backgroundExtractEnabled: v),
                  ),
                ),
                if (settings.backgroundExtractEnabled) ...<Widget>[
                  const SizedBox(height: SkotiqTokens.spaceMd),
                  SliderRowInteractive(
                    label: 'Poly order',
                    value: settings.bgModelOrder.toDouble(),
                    min: 1.0,
                    max: 4.0,
                    suffix: '',
                    colors: colors,
                    onChanged: (v) =>
                        update(settings.copyWith(bgModelOrder: v.round())),
                  ),
                  const SizedBox(height: SkotiqTokens.spaceSm),
                  SliderRowInteractive(
                    label: 'Grid spacing',
                    value: settings.bgSampleSpacing,
                    min: 24.0,
                    max: 256.0,
                    suffix: 'px',
                    colors: colors,
                    onChanged: (v) =>
                        update(settings.copyWith(bgSampleSpacing: v)),
                  ),
                  const SizedBox(height: SkotiqTokens.spaceSm),
                  SliderRowInteractive(
                    label: 'Dark fraction',
                    value: settings.bgExclusionPercentile,
                    min: 0.35,
                    max: 0.95,
                    suffix: '',
                    colors: colors,
                    onChanged: (v) =>
                        update(settings.copyWith(bgExclusionPercentile: v)),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),

          // Generalised Hyperbolic Stretch
          SkotiqPanel(
            head: const PanelHead(label: 'Hyperbolic stretch'),
            child: Column(
              children: <Widget>[
                SkotiqSwitchRow(
                  label: 'Custom GHS stretch',
                  subtitle: 'Override auto STF with tunable hyperbolic curve',
                  value: settings.stretchEnabled,
                  onChanged: (v) =>
                      update(settings.copyWith(stretchEnabled: v)),
                ),
                if (settings.stretchEnabled) ...<Widget>[
                  const SizedBox(height: SkotiqTokens.spaceSm),
                  SkotiqSwitchRow(
                    label: 'Auto-adapt as frames stack',
                    subtitle:
                        'Re-anchor stretch as noise drops with integration',
                    value: settings.autoAdaptStretch,
                    onChanged: (v) =>
                        update(settings.copyWith(autoAdaptStretch: v)),
                  ),
                  const SizedBox(height: SkotiqTokens.spaceMd),
                  SliderRowInteractive(
                    label: 'Intensity (D)',
                    value: settings.stretchD.clamp(0.0, 20.0),
                    min: 0.0,
                    max: 20.0,
                    suffix: '',
                    colors: colors,
                    onChanged: (v) => update(
                      settings.copyWith(stretchD: v, autoAdaptStretch: false),
                    ),
                  ),
                  const SizedBox(height: SkotiqTokens.spaceSm),
                  SliderRowInteractive(
                    label: 'Local shape (b)',
                    value: settings.stretchB.clamp(-2.0, 8.0),
                    min: -2.0,
                    max: 8.0,
                    suffix: '',
                    colors: colors,
                    onChanged: (v) => update(
                      settings.copyWith(stretchB: v, autoAdaptStretch: false),
                    ),
                  ),
                  const SizedBox(height: SkotiqTokens.spaceSm),
                  SliderRowInteractive(
                    label: 'Symmetry',
                    value: settings.stretchSymmetryPoint.clamp(0.0, 0.5),
                    min: 0.0,
                    max: 0.5,
                    suffix: '',
                    colors: colors,
                    onChanged: (v) => update(
                      settings.copyWith(
                        stretchSymmetryPoint: v,
                        autoAdaptStretch: false,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),

          // Wavelet denoise
          SkotiqPanel(
            head: const PanelHead(label: 'Wavelet denoise'),
            child: Column(
              children: <Widget>[
                SkotiqSwitchRow(
                  label: 'Starlet denoise',
                  subtitle: 'Shrinks fine-scale noise while keeping structure',
                  value: settings.denoiseEnabled,
                  onChanged: (v) =>
                      update(settings.copyWith(denoiseEnabled: v)),
                ),
                if (settings.denoiseEnabled) ...<Widget>[
                  const SizedBox(height: SkotiqTokens.spaceMd),
                  SliderRowInteractive(
                    label: 'Strength',
                    value: settings.denoiseStrength,
                    min: 0.0,
                    max: 1.0,
                    suffix: '',
                    colors: colors,
                    onChanged: (v) =>
                        update(settings.copyWith(denoiseStrength: v)),
                  ),
                  const SizedBox(height: SkotiqTokens.spaceSm),
                  SliderRowInteractive(
                    label: 'Threshold',
                    value: settings.denoiseThresholdSigma,
                    min: 0.5,
                    max: 6.0,
                    suffix: 'σ',
                    colors: colors,
                    onChanged: (v) =>
                        update(settings.copyWith(denoiseThresholdSigma: v)),
                  ),
                  if (isColor) ...<Widget>[
                    const SizedBox(height: SkotiqTokens.spaceSm),
                    SliderRowInteractive(
                      label: 'Chroma',
                      value: settings.denoiseChromaStrength,
                      min: 0.0,
                      max: 1.0,
                      suffix: '',
                      colors: colors,
                      onChanged: (v) =>
                          update(settings.copyWith(denoiseChromaStrength: v)),
                    ),
                  ],
                ],
              ],
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),

          // Color balance & saturation (3-channel stacks only)
          if (isColor) ...<Widget>[
            SkotiqPanel(
              head: const PanelHead(label: 'Color & saturation'),
              child: Column(
                children: <Widget>[
                  SkotiqSwitchRow(
                    label: 'Channel balance',
                    subtitle: 'Manual RGB white-balance scales',
                    value: settings.colorBalanceEnabled,
                    onChanged: (v) =>
                        update(settings.copyWith(colorBalanceEnabled: v)),
                  ),
                  if (settings.colorBalanceEnabled) ...<Widget>[
                    const SizedBox(height: SkotiqTokens.spaceSm),
                    SliderRowInteractive(
                      label: 'Red',
                      value: settings.colorRedScale,
                      min: 0.5,
                      max: 2.0,
                      suffix: '×',
                      colors: colors,
                      onChanged: (v) =>
                          update(settings.copyWith(colorRedScale: v)),
                    ),
                    const SizedBox(height: SkotiqTokens.spaceSm),
                    SliderRowInteractive(
                      label: 'Green',
                      value: settings.colorGreenScale,
                      min: 0.5,
                      max: 2.0,
                      suffix: '×',
                      colors: colors,
                      onChanged: (v) =>
                          update(settings.copyWith(colorGreenScale: v)),
                    ),
                    const SizedBox(height: SkotiqTokens.spaceSm),
                    SliderRowInteractive(
                      label: 'Blue',
                      value: settings.colorBlueScale,
                      min: 0.5,
                      max: 2.0,
                      suffix: '×',
                      colors: colors,
                      onChanged: (v) =>
                          update(settings.copyWith(colorBlueScale: v)),
                    ),
                  ],
                  const SizedBox(height: SkotiqTokens.spaceMd),
                  SkotiqSwitchRow(
                    label: 'Saturation boost',
                    subtitle: 'Highlight-protected chroma enhancement',
                    value: settings.saturationEnabled,
                    onChanged: (v) =>
                        update(settings.copyWith(saturationEnabled: v)),
                  ),
                  if (settings.saturationEnabled) ...<Widget>[
                    const SizedBox(height: SkotiqTokens.spaceSm),
                    SliderRowInteractive(
                      label: 'Amount',
                      value: settings.saturationAmount,
                      min: -1.0,
                      max: 2.0,
                      suffix: '',
                      colors: colors,
                      onChanged: (v) =>
                          update(settings.copyWith(saturationAmount: v)),
                    ),
                    const SizedBox(height: SkotiqTokens.spaceSm),
                    SliderRowInteractive(
                      label: 'Protection',
                      value: settings.saturationProtection,
                      min: 0.0,
                      max: 1.0,
                      suffix: '',
                      colors: colors,
                      onChanged: (v) =>
                          update(settings.copyWith(saturationProtection: v)),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
          ],

          // Star reduction
          SkotiqPanel(
            head: const PanelHead(label: 'Star reduction'),
            child: Column(
              children: <Widget>[
                SkotiqSwitchRow(
                  label: 'De-emphasize stars',
                  subtitle: 'Morphological pull so faint nebulosity stands out',
                  value: settings.starReduceEnabled,
                  onChanged: (v) =>
                      update(settings.copyWith(starReduceEnabled: v)),
                ),
                if (settings.starReduceEnabled) ...<Widget>[
                  const SizedBox(height: SkotiqTokens.spaceMd),
                  SliderRowInteractive(
                    label: 'Amount',
                    value: settings.starReduceAmount,
                    min: 0.0,
                    max: 1.0,
                    suffix: '',
                    colors: colors,
                    onChanged: (v) =>
                        update(settings.copyWith(starReduceAmount: v)),
                  ),
                  const SizedBox(height: SkotiqTokens.spaceSm),
                  SliderRowInteractive(
                    label: 'Mask σ',
                    value: settings.starReduceThresholdSigma,
                    min: 2.0,
                    max: 12.0,
                    suffix: 'σ',
                    colors: colors,
                    onChanged: (v) => update(
                      settings.copyWith(starReduceThresholdSigma: v),
                    ),
                  ),
                ],
              ],
            ),
          ),

          // Transparent step outcomes from the Rust Darkroom engine
          if (rendered != null && rendered.stepOutcomes.isNotEmpty) ...<Widget>[
            const SizedBox(height: SkotiqTokens.spaceMd),
            SkotiqPanel(
              head: const PanelHead(label: 'Pipeline report'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (var i = 0;
                      i < rendered.stepOutcomes.length;
                      i++) ...<Widget>[
                    if (i > 0) const SizedBox(height: 6),
                    _StepOutcomeRow(
                      step: rendered.stepOutcomes[i],
                      colors: colors,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StepOutcomeRow extends StatelessWidget {
  const _StepOutcomeRow({required this.step, required this.colors});

  final LiveDarkroomStepOutcome step;
  final SkotiqColors colors;

  @override
  Widget build(BuildContext context) {
    final applied = step.outcome.toLowerCase() == 'applied';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: StatusDot(color: applied ? colors.success : colors.warning),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '${step.opId} · ${step.outcome}',
                style: SkotiqTypography.monoCaption.copyWith(
                  color: colors.textPrimary,
                ),
              ),
              if (step.reason != null && step.reason!.isNotEmpty)
                Text(
                  step.reason!,
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textMuted,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
