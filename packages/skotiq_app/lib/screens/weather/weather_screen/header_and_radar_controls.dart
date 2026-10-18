part of '../weather_screen.dart';

/// The page header: `cloud-sun` · "Weather" · safety chip · refresh · settings.
///
/// The chip rides in [PageHeader.actions] rather than beside the title because
/// `PageHeader` takes only a `String context` there; see notes.md deviation 1.
class _WeatherHeader extends StatelessWidget {
  final WeatherSafetyStatus status;
  final bool monitoring;
  final VoidCallback onRefresh;
  final VoidCallback onSettingsTap;
  final bool isLoading;

  const _WeatherHeader({
    required this.status,
    required this.monitoring,
    required this.onRefresh,
    required this.onSettingsTap,
    required this.isLoading,
  });

  @override
  Widget build(BuildContext context) {
    final chip = SkotiqChip(
      label: weatherSafetyChipLabel(status: status, monitoring: monitoring),
      tone: weatherSafetyChipTone(status: status, monitoring: monitoring),
      dot: true,
    );
    // Flexible only where the chip can run out of room: "Not monitored" plus
    // two 32 px buttons plus the title does not fit 360 px, and a header that
    // overflows is worse than a label that shortens. On a wide header a
    // Flexible chip splits the free space with the title's Expanded, so the
    // chip and both buttons sat mid-header instead of at its right edge.
    final narrow = MediaQuery.sizeOf(context).width <
        ShellChromeMetrics.shellLayoutBreakpoint;
    return SafeArea(
      bottom: false,
      child: PageHeader(
        icon: SkotiqIcons.weather,
        title: 'Weather',
        actions: [
          if (narrow) Flexible(child: chip) else chip,
          SkotiqIconButton(
            key: WeatherTutorialKeys.refreshBtn,
            icon: SkotiqIcons.refresh,
            tooltip: 'Refresh radar data',
            onPressed: isLoading ? null : onRefresh,
          ),
          SkotiqIconButton(
            icon: SkotiqIcons.settings,
            tooltip: 'Weather settings',
            onPressed: onSettingsTap,
          ),
        ],
      ),
    );
  }
}

/// The screen's ONE banner slot.
///
/// A stale fetch outranks a stranded auto-park policy: the first means the
/// numbers on screen may be wrong, the second means a policy will not fire.
/// Everything else the screen has to say about safety is said by the header
/// chip and the conditions HUD, so it never becomes a second banner.
class _WeatherBanner extends StatelessWidget {
  final bool showFetchFailure;
  final bool autoParkStranded;
  final VoidCallback onRetry;
  final VoidCallback onOpenSettings;

  const _WeatherBanner({
    required this.showFetchFailure,
    required this.autoParkStranded,
    required this.onRetry,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    if (!showFetchFailure && !autoParkStranded) {
      return const SizedBox.shrink();
    }

    final banner = showFetchFailure
        ? SkotiqBanner(
            title: 'Weather data unavailable',
            message: 'Conditions may be out of date. Check your connection.',
            tone: BannerTone.error,
            action: SkotiqButton(
              label: 'Retry',
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: onRetry,
            ),
          )
        : SkotiqBanner(
            title: 'Auto-park will not fire',
            message: 'It also needs "Park on unsafe weather" in Automation '
                '& safety, which is off.',
            tone: BannerTone.warning,
            action: SkotiqButton(
              label: 'Open settings',
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: onOpenSettings,
            ),
          );

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SkotiqTokens.space2xl,
        SkotiqTokens.spaceMd,
        SkotiqTokens.space2xl,
        0,
      ),
      child: banner,
    );
  }
}

/// The radar control bar that floats over the bottom of the map.
///
/// One glass element carrying everything the loop needs: the satellite legend
/// (wide only), the transport and scrub track, the frame's time, the playback
/// speed, and a toggle that reveals the opacity and contrast sliders in place
/// rather than opening a fifth glass panel.
class _RadarControlBar extends StatelessWidget {
  /// Wide enough for the legend and one row of controls. Below it the legend
  /// goes and the readouts move under the transport.
  final bool wide;
  final List<RadarFrame> frames;
  final int currentIndex;
  final ValueChanged<int> onFrameChanged;
  final bool isPlaying;
  final VoidCallback onPlayPauseToggle;
  final double playbackSpeed;
  final ValueChanged<double> onSpeedChanged;
  final double opacity;
  final double contrast;
  final ValueChanged<double> onOpacityChanged;
  final ValueChanged<double> onContrastChanged;
  final bool displayControlsOpen;
  final VoidCallback onDisplayControlsToggle;

  const _RadarControlBar({
    required this.wide,
    required this.frames,
    required this.currentIndex,
    required this.onFrameChanged,
    required this.isPlaying,
    required this.onPlayPauseToggle,
    required this.playbackSpeed,
    required this.onSpeedChanged,
    required this.opacity,
    required this.contrast,
    required this.onOpacityChanged,
    required this.onContrastChanged,
    required this.displayControlsOpen,
    required this.onDisplayControlsToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (wide) ...[
              const SatelliteLegend(compact: true),
              const SizedBox(width: SkotiqTokens.spaceLg),
            ],
            Expanded(
              child: RadarTimelineScrubber(
                key: WeatherTutorialKeys.timeline,
                frames: frames,
                currentIndex: currentIndex,
                onFrameChanged: onFrameChanged,
                isPlaying: isPlaying,
                onPlayPauseToggle: onPlayPauseToggle,
                playbackSpeed: playbackSpeed,
                onSpeedChanged: onSpeedChanged,
                stacked: !wide,
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceSm),
            SkotiqIconButton(
              icon: SkotiqIcons.sliders,
              tooltip: 'Radar display',
              size: IconButtonSize.sm,
              selected: displayControlsOpen,
              onPressed: onDisplayControlsToggle,
            ),
          ],
        ),
        if (displayControlsOpen) ...[
          const SizedBox(height: SkotiqTokens.spaceSm),
          _RadarSliderRow(
            icon: SkotiqIcons.layers,
            label: 'Opacity',
            value: opacity,
            min: 0.0,
            max: 1.0,
            displayValue: '${(opacity * 100).toInt()}%',
            onChanged: onOpacityChanged,
          ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          _RadarSliderRow(
            icon: LucideIcons.contrast,
            label: 'Contrast',
            value: contrast,
            min: 0.0,
            max: 2.5,
            displayValue: _contrastLabel(contrast),
            onChanged: onContrastChanged,
          ),
        ],
      ],
    );
  }

  static String _contrastLabel(double value) {
    if (value <= 0.2) return 'Off';
    if (value <= 0.8) return 'Low';
    if (value <= 1.3) return 'Medium';
    if (value <= 1.8) return 'High';
    return 'Max';
  }
}

/// One labelled slider inside the control bar.
///
/// The label sits to the LEFT in a [FormRow] (05 §8), not above the control,
/// and the value reads out on the right so the slider itself keeps the width.
class _RadarSliderRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final double value;
  final double min;
  final double max;
  final String displayValue;
  final ValueChanged<double> onChanged;

  const _RadarSliderRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.displayValue,
    required this.onChanged,
  });

  /// Wide enough for "Medium" and "100%" at `readoutSm`.
  static const double _valueWidth = 56;

  /// The icon plus its gap, taken out of the `FormRow` label column so the
  /// slider tracks line up with each other.
  static const double _labelWidth =
      FormRow.defaultLabelWidth - SkotiqTokens.iconSm - SkotiqTokens.spaceSm;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Row(
      children: [
        Icon(icon, size: SkotiqTokens.iconSm, color: colors.textMuted),
        const SizedBox(width: SkotiqTokens.spaceSm),
        Expanded(
          child: FormRow(
            label: label,
            labelWidth: _labelWidth,
            child: Row(
              children: [
                Expanded(
                  child: SkotiqSlider(
                    value: value,
                    min: min,
                    max: max,
                    onChanged: onChanged,
                  ),
                ),
                const SizedBox(width: SkotiqTokens.spaceSm),
                SizedBox(
                  width: _valueWidth,
                  child: Text(
                    displayValue,
                    textAlign: TextAlign.end,
                    style: SkotiqTypography.readoutSm.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The single loading pattern for this screen.
class _WeatherLoadingBody extends StatelessWidget {
  const _WeatherLoadingBody();

  @override
  Widget build(BuildContext context) {
    return const Center(
        child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36));
  }
}

/// No observing site: the radar is the only thing that needs one.
///
/// A connected weather station or safety monitor reports without knowing where
/// it is, and hiding those readings behind a location setting they have nothing
/// to do with was the 2026-07-29 defect this layout keeps fixed. So the empty
/// state owns the body and the sensors follow only when a device is actually
/// connected.
class _NoLocationBody extends ConsumerWidget {
  const _NoLocationBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final hasSensors = ref.watch(weatherStateProvider).connectionState ==
            DeviceConnectionState.connected ||
        ref.watch(safetyMonitorStateProvider).connectionState ==
            DeviceConnectionState.connected;

    return Padding(
      padding: const EdgeInsets.all(SkotiqTokens.space2xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: DecoratedBox(
              decoration: SkotiqDecorations.well(colors),
              child: Center(
                child: EmptyState(
                  icon: SkotiqIcons.location,
                  title: 'No observing site',
                  body: 'Radar needs to know where you are before it can show '
                      'the sky above you.',
                  action: SkotiqButton(
                    label: 'Set your location',
                    variant: ButtonVariant.secondary,
                    size: ButtonSize.small,
                    onPressed: () => context.go('/settings?section=location'),
                  ),
                ),
              ),
            ),
          ),
          if (hasSensors) ...[
            const SizedBox(height: SkotiqTokens.spaceLg),
            const SkotiqPanel(
              head: PanelHead(
                icon: SkotiqIcons.weather,
                label: 'Conditions',
              ),
              child: _WeatherConditions(
                alert: null,
                motion: null,
                lastUpdate: null,
                cloudCoverPercent: null,
                alertRadiusKm: null,
                expanded: true,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The settings store could not be read, so no verdict can be trusted.
class _SettingsUnavailableBody extends StatelessWidget {
  final VoidCallback onRetry;

  const _SettingsUnavailableBody({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: EmptyState(
        icon: SkotiqIcons.warning,
        title: 'Weather settings unavailable',
        body: 'The observing location and weather configuration could not be '
            'loaded, so conditions are unknown.',
        action: SkotiqButton(
          label: 'Retry',
          icon: SkotiqIcons.refresh,
          variant: ButtonVariant.secondary,
          size: ButtonSize.small,
          onPressed: onRetry,
        ),
      ),
    );
  }
}
