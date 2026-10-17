part of '../mobile_widgets.dart';

// NOTE (design tokens): the `Colors.white*` / `Colors.black*` literals in this
// file are canvas-absolute HUD colors for the mobile planetarium view/slew
// controls drawn over the sky. The planetarium is wrapped in
// `_NightVisionFilter` (luminance→red conversion for dark adaptation), so they
// are intentionally NOT mapped to the theme-relative semantic palette.

class MobileViewControls extends ConsumerWidget {
  final SkotiqColors colors;
  final bool showFOV;
  final VoidCallback onToggleFOV;

  const MobileViewControls({
    super.key,
    required this.colors,
    required this.showFOV,
    required this.onToggleFOV,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewState = ref.watch(skyViewStateProvider);
    final dividerWidth = _mobileTouchInner(context) * 0.75;

    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MobileControlButton(
            icon: SkotiqIcons.add,
            onTap: ref.read(skyViewStateProvider.notifier).zoomIn,
          ),
          Container(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              viewState.fieldOfView.toStringAsFixed(0),
              style: const TextStyle(
                fontSize: SkotiqTypography.fontSize9,
                color: Colors.white70,
                fontFeatures: [ui.FontFeature.tabularFigures()],
              ),
            ),
          ),
          MobileControlButton(
            icon: SkotiqIcons.remove,
            onTap: ref.read(skyViewStateProvider.notifier).zoomOut,
          ),
          Container(
            height: 1,
            width: dividerWidth,
            margin: const EdgeInsets.symmetric(vertical: 6),
            color: Colors.white24,
          ),
          MobileControlButton(
            icon: SkotiqIcons.home,
            onTap: () {
              // Home = the observer's zenith, not the fixed point RA 0h/Dec 0
              // (which is usually below the horizon). See
              // [skyViewHomeCenterProvider].
              // Null with no site on record: the zenith is the point over the
              // observer, so the equatorial centre is left where it is.
              final home = ref.read(skyViewHomeCenterProvider);
              if (home != null) {
                ref
                    .read(skyViewStateProvider.notifier)
                    .setCenter(home.$1, home.$2);
              }
              ref
                  .read(skyViewStateProvider.notifier)
                  .setHorizontalCenter(0, 90);
              ref.read(skyViewStateProvider.notifier).setFieldOfView(60);
            },
          ),
          const SizedBox(height: 4),
          MobileControlButton(
            key: PlanetariumTutorialKeys.fovToggle,
            icon: SkotiqIcons.frame,
            isActive: showFOV,
            onTap: onToggleFOV,
          ),
          // Gyroscope aim button - only on mobile platforms
          if (defaultTargetPlatform == TargetPlatform.iOS ||
              defaultTargetPlatform == TargetPlatform.android) ...[
            Container(
              height: 1,
              width: dividerWidth,
              margin: const EdgeInsets.symmetric(vertical: 6),
              color: Colors.white24,
            ),
            Consumer(
              builder: (context, ref, _) {
                final isEnabled = ref.watch(gyroscopeAimingEnabledProvider);
                final gyroOuter = _mobileTouchOuter(context) * 0.82;
                final gyroInner = _mobileTouchInner(context);
                final orientation = ref.watch(deviceOrientationProvider);
                final mountSyncActive = ref.watch(gyroscopeMountSyncProvider);
                final mountConnected =
                    ref.watch(mountStateProvider).connectionState ==
                        DeviceConnectionState.connected;

                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Gyroscope aim toggle
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _handleGyroscopeToggle(context, ref),
                      child: SizedBox(
                        width: gyroOuter,
                        height: gyroOuter,
                        child: Center(
                          child: Container(
                            width: gyroInner,
                            height: gyroInner,
                            decoration: isEnabled
                                ? SkotiqDecorations.selectedSurface(
                                    colors.info,
                                    borderRadius: BorderRadius.circular(
                                        SkotiqTokens.radiusInline4),
                                  )
                                : null,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                Icon(
                                  SkotiqIcons.compass,
                                  size: gyroInner * 0.54,
                                  color:
                                      isEnabled ? colors.info : Colors.white70,
                                ),
                                // Compass accuracy indicator dot
                                if (isEnabled && orientation.isActive)
                                  Positioned(
                                    bottom: 1,
                                    right: 1,
                                    child: Container(
                                      width: 5,
                                      height: 5,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: _accuracyColor(
                                          orientation.compassAccuracy,
                                          colors,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    // Sync Mount toggle - only visible when gyroscope is active
                    // and a mount is connected via NetworkBackend
                    if (isEnabled && mountConnected) ...[
                      const SizedBox(height: 4),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          ref.read(gyroscopeMountSyncProvider.notifier).state =
                              !mountSyncActive;
                        },
                        child: SizedBox(
                          width: gyroOuter,
                          height: gyroOuter,
                          child: Center(
                            child: Container(
                              width: gyroInner,
                              height: gyroInner,
                              decoration: mountSyncActive
                                  ? SkotiqDecorations.selectedSurface(
                                      colors.warning,
                                      borderRadius: BorderRadius.circular(
                                          SkotiqTokens.radiusInline4),
                                    )
                                  : null,
                              child: Icon(
                                SkotiqIcons.star,
                                size: gyroInner * 0.54,
                                color: mountSyncActive
                                    ? colors.warning
                                    : Colors.white70,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  void _handleGyroscopeToggle(BuildContext context, WidgetRef ref) {
    final isEnabled = ref.read(gyroscopeAimingEnabledProvider);

    if (!isEnabled) {
      // Turning on: check if calibration has been acknowledged this session
      final calibrated = ref.read(compassCalibrationAcknowledgedProvider);
      if (!calibrated) {
        _showCalibrationDialog(context, ref);
        return;
      }
    } else {
      // Turning off: also disable mount sync
      ref.read(gyroscopeMountSyncProvider.notifier).state = false;
    }

    ref.read(gyroscopeAimingEnabledProvider.notifier).state = !isEnabled;
  }

  void _showCalibrationDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (context) => const CompassCalibrationDialog(),
    ).then((result) {
      if (result == true) {
        ref.read(compassCalibrationAcknowledgedProvider.notifier).state = true;
        ref.read(gyroscopeAimingEnabledProvider.notifier).state = true;
      }
    });
  }

  static Color _accuracyColor(
    CompassAccuracy accuracy,
    SkotiqColors colors,
  ) {
    switch (accuracy) {
      case CompassAccuracy.high:
        return colors.success;
      case CompassAccuracy.medium:
        return colors.warning;
      case CompassAccuracy.low:
        return colors.warning;
      case CompassAccuracy.unreliable:
        return colors.error;
      case CompassAccuracy.unknown:
        return colors.textMuted;
    }
  }
}

/// Compact slew controls for mobile
class MobileSlewControls extends ConsumerWidget {
  final SkotiqColors colors;
  final bool slewMode;
  final VoidCallback onToggleSlewMode;
  final VoidCallback onStopSlew;

  const MobileSlewControls({
    super.key,
    required this.colors,
    required this.slewMode,
    required this.onToggleSlewMode,
    required this.onStopSlew,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mountState = ref.watch(mountStateProvider);
    final isConnected =
        mountState.connectionState == DeviceConnectionState.connected;
    final isSlewing = mountState.isSlewing;

    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: slewMode ? Border.all(color: colors.warning, width: 2) : null,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          MobileControlButton(
            key: PlanetariumTutorialKeys.slewBtn,
            icon: SkotiqIcons.move,
            isActive: slewMode,
            isEnabled: isConnected,
            onTap: isConnected ? onToggleSlewMode : null,
            activeColor: colors.warning,
          ),
          const SizedBox(height: 4),
          MobileControlButton(
            icon: LucideIcons.octagon,
            isEnabled: isConnected && isSlewing,
            onTap: isConnected && isSlewing ? onStopSlew : null,
            activeColor: colors.error,
          ),
        ],
      ),
    );
  }
}

/// Compact control button for mobile view/slew controls
/// Uses 44px touch target with smaller visual appearance
class MobileControlButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final bool isActive;
  final bool isEnabled;
  final Color? activeColor;

  const MobileControlButton({
    super.key,
    required this.icon,
    this.onTap,
    this.isActive = false,
    this.isEnabled = true,
    this.activeColor,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final color = isActive ? (activeColor ?? colors.success) : Colors.white70;
    final outer = _mobileTouchOuter(context) * 0.82;
    final inner = _mobileTouchInner(context);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: isEnabled ? onTap : null,
      child: SizedBox(
        width: outer,
        height: outer,
        child: Center(
          child: Container(
            width: inner,
            height: inner,
            decoration: BoxDecoration(
              color:
                  isActive ? color.withValues(alpha: 0.2) : Colors.transparent,
              borderRadius:
                  BorderRadius.circular(SkotiqTokens.radiusInline4),
            ),
            child: Icon(
              icon,
              size: inner * 0.54,
              color: isEnabled ? color : Colors.white24,
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact bottom info bar for mobile
