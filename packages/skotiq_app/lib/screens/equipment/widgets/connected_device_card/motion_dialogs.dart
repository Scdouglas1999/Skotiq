// ignore_for_file: invalid_use_of_protected_member
// Move, rotate and dome-slew command dialogs.
part of '../connected_device_card.dart';

extension _ConnectedDeviceMotionDialogs on _ConnectedDeviceCardState {
  // Dialogs

  void _showMoveDialog(BuildContext context) async {
    final focuserState = ref.read(focuserStateProvider);
    final reportedMax = focuserState.maxPosition;
    final maxPosition =
        reportedMax != null && reportedMax > 0 ? reportedMax : null;
    var positionText = focuserState.position?.toString() ?? '0';
    var isMoving = false;
    var isHalting = false;
    String? errorText;
    final pageContext = context;

    await _showEquipmentDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) {
          final colors = SkotiqColors.of(dialogContext);
          Future<void> haltMove() async {
            if (!isMoving || isHalting) return;
            setState(() {
              isHalting = true;
              errorText = null;
            });
            try {
              await ref.read(deviceServiceProvider).haltFocuser();
              if (!dialogContext.mounted) return;
              Navigator.pop(dialogContext);
              if (pageContext.mounted) {
                pageContext.showInfoSnackBar('Focuser halted');
              }
            } catch (e) {
              if (!dialogContext.mounted) return;
              setState(() {
                isHalting = false;
                errorText = 'Failed to halt focuser: $e';
              });
            }
          }

          return PopScope(
            canPop: !isMoving,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop && isMoving) {
                unawaited(haltMove());
              }
            },
            child: SkotiqDialog(
              title: 'Move focuser',
              icon: LucideIcons.focus,
              width: 400,
              actions: [
                if (!isMoving)
                  SkotiqButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    label: 'Cancel',
                    variant: ButtonVariant.ghost,
                    size: ButtonSize.small,
                  )
                else
                  SkotiqButton(
                    onPressed: isHalting ? null : haltMove,
                    label: isHalting ? 'Stopping...' : 'Stop',
                    isLoading: isHalting,
                    variant: ButtonVariant.destructive,
                    size: ButtonSize.small,
                  ),
                SkotiqButton(
                  onPressed: isMoving
                      ? null
                      : () async {
                          if (isMoving) return;
                          final position = int.tryParse(positionText.trim());
                          if (position == null) {
                            setState(() => errorText =
                                'Enter a whole-number focuser position.');
                            return;
                          }
                          if (position < 0) {
                            setState(() =>
                                errorText = 'Position cannot be negative.');
                            return;
                          }
                          if (maxPosition != null && position > maxPosition) {
                            setState(() => errorText =
                                'Position must be between 0 and $maxPosition.');
                            return;
                          }

                          setState(() {
                            errorText = null;
                            isMoving = true;
                          });
                          try {
                            await ref
                                .read(deviceServiceProvider)
                                .moveFocuserTo(position);
                            if (!dialogContext.mounted) return;
                            Navigator.pop(dialogContext);
                            if (pageContext.mounted) {
                              pageContext.showSuccessSnackBar(
                                'Focuser moved to $position',
                              );
                            }
                          } catch (e) {
                            if (!dialogContext.mounted) return;
                            setState(() {
                              isMoving = false;
                              errorText = 'Failed to move focuser: $e';
                            });
                          }
                        },
                  label: isMoving ? 'Moving...' : 'Move',
                  variant: ButtonVariant.primary,
                  size: ButtonSize.small,
                ),
              ],
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    maxPosition == null
                        ? 'Enter a target position of 0 or greater. '
                            'The driver did not report a maximum.'
                        : 'Enter target position (0 - $maxPosition):',
                    style: SkotiqTypography.bodySm
                        .copyWith(color: colors.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    initialValue: positionText,
                    onChanged: (value) => positionText = value,
                    enabled: !isMoving,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    style: SkotiqTypography.body
                        .copyWith(color: colors.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'Position',
                      hintStyle: SkotiqTypography.bodySm
                          .copyWith(color: colors.textMuted),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: colors.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: colors.primary),
                      ),
                    ),
                  ),
                  if (errorText != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      errorText!,
                      style: SkotiqTypography.bodySm
                          .copyWith(color: colors.error),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showRotateDialog(BuildContext context) async {
    final rotatorState = ref.read(rotatorStateProvider);
    var angleText = rotatorState.position?.toStringAsFixed(1) ?? '0.0';

    // Resolve the rotator's valid absolute-angle range from its reported
    // capabilities (mirrors rotator_panel.dart). Fall back to a full 0..360
    // turn when the driver does not advertise bounds, and treat an inverted
    // or degenerate range (min >= max) as missing data — also 0..360.
    RotatorCapabilities? caps;
    final rotatorId = rotatorState.deviceId;
    if (rotatorId != null && rotatorId.isNotEmpty) {
      try {
        caps = await ref.read(
          equipmentRotatorCapabilitiesProvider(rotatorId).future,
        );
      } catch (_) {
        // Unknown bounds fall back to the full mechanical turn below.
      }
    }
    if (!context.mounted) {
      return;
    }
    final rawMin = caps?.minAngleDeg ?? 0.0;
    final rawMax = caps?.maxAngleDeg ?? 360.0;
    final hasValidRange = rawMin.isFinite && rawMax.isFinite && rawMin < rawMax;
    final minAngle = hasValidRange ? rawMin : 0.0;
    final maxAngle = hasValidRange ? rawMax : 360.0;
    final canHalt = caps?.canHalt == true;
    String formatBound(double value) => value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
    var isRotating = false;
    var isHalting = false;
    String? errorText;
    final pageContext = context;

    await _showEquipmentDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) {
          final dialogColors = SkotiqColors.of(dialogContext);
          Future<void> haltRotation() async {
            if (!isRotating || isHalting || !canHalt) return;
            setState(() {
              isHalting = true;
              errorText = null;
            });
            try {
              await ref.read(deviceServiceProvider).haltRotator();
              if (!dialogContext.mounted) return;
              Navigator.pop(dialogContext);
              if (pageContext.mounted) {
                pageContext.showInfoSnackBar('Rotator halted');
              }
            } catch (e) {
              if (!dialogContext.mounted) return;
              setState(() {
                isHalting = false;
                errorText = 'Failed to halt rotator: $e';
              });
            }
          }

          return PopScope(
            canPop: !isRotating,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop && isRotating && canHalt) {
                unawaited(haltRotation());
              }
            },
            child: SkotiqDialog(
              title: 'Rotate To Angle',
              icon: LucideIcons.rotateCcw,
              width: 400,
              actions: [
                if (!isRotating)
                  SkotiqButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    label: 'Cancel',
                    variant: ButtonVariant.ghost,
                    size: ButtonSize.small,
                  )
                else if (canHalt)
                  SkotiqButton(
                    onPressed: isHalting ? null : haltRotation,
                    label: isHalting ? 'Stopping...' : 'Stop',
                    isLoading: isHalting,
                    variant: ButtonVariant.destructive,
                    size: ButtonSize.small,
                  ),
                SkotiqButton(
                  onPressed: isRotating
                      ? null
                      : () async {
                          if (isRotating) return;
                          final angle = double.tryParse(angleText.trim());
                          if (angle == null || !angle.isFinite) {
                            setState(() =>
                                errorText = 'Enter a finite angle in degrees.');
                            return;
                          }
                          if (angle < minAngle || angle > maxAngle) {
                            setState(() => errorText = 'Angle must be between '
                                '${formatBound(minAngle)} and '
                                '${formatBound(maxAngle)} degrees.');
                            return;
                          }

                          setState(() {
                            errorText = null;
                            isRotating = true;
                          });
                          try {
                            await ref
                                .read(deviceServiceProvider)
                                .moveRotatorTo(angle);
                            if (!dialogContext.mounted) return;
                            Navigator.pop(dialogContext);
                            if (pageContext.mounted) {
                              pageContext.showSuccessSnackBar(
                                'Rotated to ${angle.toStringAsFixed(1)} degrees',
                              );
                            }
                          } catch (e) {
                            if (!dialogContext.mounted) return;
                            setState(() {
                              isRotating = false;
                              errorText = 'Failed to rotate: $e';
                            });
                          }
                        },
                  label: isRotating ? 'Rotating...' : 'Rotate',
                  variant: ButtonVariant.primary,
                  size: ButtonSize.small,
                ),
              ],
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Enter target angle (${formatBound(minAngle)} - '
                    '${formatBound(maxAngle)} degrees):',
                    style: SkotiqTypography.bodySm
                        .copyWith(color: dialogColors.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    initialValue: angleText,
                    onChanged: (value) => angleText = value,
                    enabled: !isRotating,
                    autofocus: true,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    style: SkotiqTypography.body
                        .copyWith(color: dialogColors.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'Angle',
                      suffixText: 'degrees',
                      suffixStyle: SkotiqTypography.bodySm
                          .copyWith(color: dialogColors.textMuted),
                      hintStyle: SkotiqTypography.bodySm
                          .copyWith(color: dialogColors.textMuted),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: dialogColors.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: dialogColors.primary),
                      ),
                    ),
                  ),
                  if (errorText != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      errorText!,
                      style: SkotiqTypography.bodySm
                          .copyWith(color: dialogColors.error),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showDomeSlewDialog(BuildContext context) async {
    final domeState = ref.read(domeStateProvider);
    var azimuthText = domeState.azimuth?.toStringAsFixed(0) ?? '0';
    var isSending = false;
    String? errorText;
    final pageContext = context;

    await _showEquipmentDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setState) {
          final colors = SkotiqColors.of(dialogContext);
          return PopScope(
            canPop: !isSending,
            child: SkotiqDialog(
              title: 'Slew Dome To Azimuth',
              icon: LucideIcons.navigation,
              width: 400,
              actions: [
                SkotiqButton(
                  onPressed:
                      isSending ? null : () => Navigator.pop(dialogContext),
                  label: 'Cancel',
                  variant: ButtonVariant.ghost,
                  size: ButtonSize.small,
                ),
                SkotiqButton(
                  onPressed: isSending
                      ? null
                      : () async {
                          if (isSending) return;
                          final azimuth = double.tryParse(azimuthText.trim());
                          if (azimuth == null || !azimuth.isFinite) {
                            setState(() => errorText =
                                'Enter a finite azimuth in degrees.');
                            return;
                          }
                          if (azimuth < 0 || azimuth > 360) {
                            setState(() => errorText =
                                'Azimuth must be between 0 and 360 degrees.');
                            return;
                          }
                          final deviceId = domeState.deviceId;
                          if (deviceId == null || deviceId.isEmpty) {
                            setState(() =>
                                errorText = 'No dome is currently connected.');
                            return;
                          }

                          setState(() {
                            errorText = null;
                            isSending = true;
                          });
                          try {
                            await ref
                                .read(backendProvider)
                                .domeSlewToAzimuth(deviceId, azimuth);
                            if (!dialogContext.mounted) return;
                            Navigator.pop(dialogContext);
                            if (pageContext.mounted) {
                              pageContext.showSuccessSnackBar(
                                'Dome slew command sent for '
                                '${azimuth.toStringAsFixed(1)} degrees',
                              );
                            }
                          } catch (e) {
                            if (!dialogContext.mounted) return;
                            setState(() {
                              isSending = false;
                              errorText = 'Dome slew failed: $e';
                            });
                          }
                        },
                  label: isSending ? 'Sending...' : 'Slew',
                  variant: ButtonVariant.primary,
                  size: ButtonSize.small,
                ),
              ],
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Enter target azimuth (0 - 360 degrees):',
                    style: SkotiqTypography.bodySm
                        .copyWith(color: colors.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    initialValue: azimuthText,
                    onChanged: (value) => azimuthText = value,
                    enabled: !isSending,
                    autofocus: true,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    style: SkotiqTypography.body
                        .copyWith(color: colors.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'Azimuth',
                      suffixText: 'degrees',
                      suffixStyle: SkotiqTypography.bodySm
                          .copyWith(color: colors.textMuted),
                      hintStyle: SkotiqTypography.bodySm
                          .copyWith(color: colors.textMuted),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: colors.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: colors.primary),
                      ),
                    ),
                  ),
                  if (errorText != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      errorText!,
                      style: SkotiqTypography.bodySm
                          .copyWith(color: colors.error),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
