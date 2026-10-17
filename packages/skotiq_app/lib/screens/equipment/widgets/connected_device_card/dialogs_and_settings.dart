part of '../connected_device_card.dart';

extension _ConnectedDeviceDialogsAndSettings on _ConnectedDeviceCardState {
  // Canonical meridian-flip warning-window bounds, mirroring
  // MeridianFlipSettings.validate (0..120 minutes). Kept as a named constant so
  // the field hint, validation, and tests reference one source of truth.
  static const int _minFlipMinutes = 0;
  static const int _maxFlipMinutes = 120;

  void _showMountSettingsDialog() async {
    late final AppSettingsState settings;
    try {
      settings = await ref.read(appSettingsProvider.future);
    } catch (e) {
      if (mounted) {
        context.showErrorSnackBar('Could not load mount settings: $e');
      }
      return;
    }
    if (!mounted) return;

    bool enableFlip = settings.enableMeridianFlip;
    var flipMinutesText = settings.meridianFlipMinutes.toString();
    // Capture the State's context up front: the Save handler is async and the
    // success snackbar must not use the dialog's (popped) context after the
    // await.
    final pageContext = context;
    bool isSaving = false;
    String? errorText;

    await _showEquipmentDialog(
        context: context,
        builder: (ctx) {
          return StatefulBuilder(builder: (context, setState) {
            final colors = SkotiqColors.of(context);
            return SkotiqDialog(
              title: 'Mount configuration',
              icon: LucideIcons.compass,
              width: 400,
              actions: [
                SkotiqButton(
                  onPressed: isSaving ? null : () => Navigator.pop(context),
                  label: 'Cancel',
                  variant: ButtonVariant.ghost,
                  size: ButtonSize.small,
                ),
                SkotiqButton(
                  onPressed: isSaving
                      ? null
                      : () async {
                          // Re-entrancy guard: the disabled state only takes
                          // effect on the next rebuild, so a rapid double-tap
                          // could otherwise re-enter before setState lands.
                          if (isSaving) return;
                          final raw = flipMinutesText.trim();
                          final minutes = int.tryParse(raw);
                          if (minutes == null) {
                            setState(() =>
                                errorText = 'Enter a whole number of minutes.');
                            return;
                          }
                          if (minutes < _minFlipMinutes ||
                              minutes > _maxFlipMinutes) {
                            setState(() => errorText =
                                'Minutes must be between $_minFlipMinutes '
                                    'and $_maxFlipMinutes.');
                            return;
                          }
                          setState(() {
                            errorText = null;
                            isSaving = true;
                          });
                          try {
                            await ref
                                .read(appSettingsProvider.notifier)
                                .setMeridianFlipConfig(
                                  enableFlip: enableFlip,
                                  minutes: minutes,
                                );
                            if (!context.mounted) return;
                            Navigator.pop(context);
                            if (pageContext.mounted) {
                              pageContext.showSuccessSnackBar(
                                  'Mount settings updated');
                            }
                          } catch (e) {
                            if (!context.mounted) return;
                            setState(() {
                              isSaving = false;
                              errorText = 'Failed to save: $e';
                            });
                          }
                        },
                  label: isSaving ? 'Saving...' : 'Save',
                  variant: ButtonVariant.primary,
                  size: ButtonSize.small,
                ),
              ],
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Auto Meridian Flip',
                          style: SkotiqTypography.body
                              .copyWith(color: colors.textPrimary)),
                      Switch(
                        value: enableFlip,
                        onChanged: isSaving
                            ? null
                            : (val) {
                                setState(() {
                                  enableFlip = val;
                                });
                              },
                        activeThumbColor: colors.primary,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    initialValue: flipMinutesText,
                    onChanged: (value) => flipMinutesText = value,
                    enabled: !isSaving,
                    keyboardType: TextInputType.number,
                    style: SkotiqTypography.body
                        .copyWith(color: colors.textPrimary),
                    decoration: InputDecoration(
                      labelText:
                          'Meridian Flip Minutes ($_minFlipMinutes - $_maxFlipMinutes)',
                      labelStyle: SkotiqTypography.bodySm
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
                      style:
                          SkotiqTypography.bodySm.copyWith(color: colors.error),
                    ),
                  ],
                ],
              ),
            );
          });
        });
  }

  // Canonical backlash-compensation bounds, mirroring the autofocus backlash
  // IN/OUT fields and the driver step limit (0..10000 steps). The coefficient
  // is only required to be finite: it is legitimately negative (default -12
  // steps/°C) and zero is the documented "track but do not move" state, so no
  // narrow range is imposed.
  static const int _minBacklashSteps = 0;
  static const int _maxBacklashSteps = 10000;

  void _showFocuserSettingsDialog() async {
    late final AppSettingsState settings;
    try {
      settings = await ref.read(appSettingsProvider.future);
    } catch (e) {
      if (mounted) {
        context.showErrorSnackBar('Could not load focuser settings: $e');
      }
      return;
    }
    if (!mounted) return;

    bool tempComp = settings.tempCompensation;
    var coefficientText = settings.tempCoefficient.toString();
    // `afBacklashIn`, the figure every path to the focuser actually reads;
    // `backlashCompensation` is persisted and displayed but operationally
    // unread. See the note in `_BacklashSettingRow`.
    var backlashText = settings.afBacklashIn.toString();
    // Bumped when a measured figure is adopted, so the field's key changes and
    // it rebuilds showing the new `initialValue`. A controller would be the
    // obvious alternative, but nothing here outlives the dialog's exit
    // transition to dispose it on. The field MUST follow the adopted number:
    // writing the setting while the input still showed the old one would be
    // exactly the silent replacement this feature exists to avoid.
    var backlashFieldGeneration = 0;
    final pageContext = context;
    bool isSaving = false;
    String? errorText;

    await _showEquipmentDialog(
        context: context,
        builder: (ctx) {
          return StatefulBuilder(builder: (context, setState) {
            final colors = SkotiqColors.of(context);
            return SkotiqDialog(
              title: 'Focuser configuration',
              icon: LucideIcons.focus,
              width: 400,
              actions: [
                SkotiqButton(
                  onPressed: isSaving ? null : () => Navigator.pop(context),
                  label: 'Cancel',
                  variant: ButtonVariant.ghost,
                  size: ButtonSize.small,
                ),
                SkotiqButton(
                  onPressed: isSaving
                      ? null
                      : () async {
                          if (isSaving) return;
                          final coeff = double.tryParse(coefficientText.trim());
                          if (coeff == null || !coeff.isFinite) {
                            setState(() => errorText =
                                'Temp coefficient must be a finite number.');
                            return;
                          }
                          final backlash = int.tryParse(backlashText.trim());
                          if (backlash == null) {
                            setState(() => errorText =
                                'Backlash must be a whole number of steps.');
                            return;
                          }
                          if (backlash < _minBacklashSteps ||
                              backlash > _maxBacklashSteps) {
                            setState(() => errorText =
                                'Backlash must be between $_minBacklashSteps '
                                    'and $_maxBacklashSteps steps.');
                            return;
                          }
                          setState(() {
                            errorText = null;
                            isSaving = true;
                          });
                          try {
                            final notifier = ref.read(
                              appSettingsProvider.notifier,
                            );
                            await notifier.setAfBacklashIn(backlash);
                            await notifier.setFocuserCompensationConfig(
                              tempCompensation: tempComp,
                              tempCoefficient: coeff,
                              backlashCompensation: backlash,
                            );
                            if (!context.mounted) return;
                            Navigator.pop(context);
                            if (pageContext.mounted) {
                              pageContext.showSuccessSnackBar(
                                  'Focuser settings updated');
                            }
                          } catch (e) {
                            if (!context.mounted) return;
                            setState(() {
                              isSaving = false;
                              errorText = 'Failed to save: $e';
                            });
                          }
                        },
                  label: isSaving ? 'Saving...' : 'Save',
                  variant: ButtonVariant.primary,
                  size: ButtonSize.small,
                ),
              ],
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          'Temperature Compensation',
                          style: SkotiqTypography.body
                              .copyWith(color: colors.textPrimary),
                        ),
                      ),
                      Switch(
                        value: tempComp,
                        onChanged: isSaving
                            ? null
                            : (val) {
                                setState(() {
                                  tempComp = val;
                                });
                              },
                        activeThumbColor: colors.primary,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    initialValue: coefficientText,
                    onChanged: (value) => coefficientText = value,
                    enabled: !isSaving,
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true, signed: true),
                    style: SkotiqTypography.body
                        .copyWith(color: colors.textPrimary),
                    decoration: InputDecoration(
                      labelText: 'Temp Coefficient (steps/C)',
                      labelStyle: SkotiqTypography.bodySm
                          .copyWith(color: colors.textMuted),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: colors.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: colors.primary),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    key: ValueKey<int>(backlashFieldGeneration),
                    initialValue: backlashText,
                    onChanged: (value) => backlashText = value,
                    enabled: !isSaving,
                    keyboardType: TextInputType.number,
                    style: SkotiqTypography.body
                        .copyWith(color: colors.textPrimary),
                    decoration: InputDecoration(
                      labelText:
                          'Backlash Compensation ($_minBacklashSteps - $_maxBacklashSteps steps)',
                      labelStyle: SkotiqTypography.bodySm
                          .copyWith(color: colors.textMuted),
                      enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: colors.border),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: colors.primary),
                      ),
                    ),
                  ),
                  const SizedBox(height: SkotiqTokens.spaceSm),
                  // Where the number in force came from, and the way to
                  // measure a new one. Same widget as the Equipment settings
                  // card, so the two surfaces cannot disagree about which
                  // value is active.
                  EffectiveBacklashReadout(
                    onUseMeasured: isSaving
                        ? null
                        : (steps) => setState(() {
                              backlashText = '$steps';
                              backlashFieldGeneration++;
                            }),
                  ),
                  if (errorText != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      errorText!,
                      style:
                          SkotiqTypography.bodySm.copyWith(color: colors.error),
                    ),
                  ],
                ],
              ),
            );
          });
        });
  }

  void _showRotatorSettingsDialog() async {
    final rotatorState = ref.read(rotatorStateProvider);
    final originalReversed = rotatorState.isReversed;
    bool reversed = rotatorState.isReversed;
    bool isSaving = false;
    final pageContext = context;

    // Only expose the reverse toggle when the driver advertises reverse support
    // (IRotatorV3 CanReverse / Alpaca canreverse). Await the capability query:
    // reading valueOrNull synchronously disabled a supported rotator whenever
    // the dialog was opened before the async probe happened to finish.
    var canReverse = false;
    final deviceId = rotatorState.deviceId;
    if (deviceId != null && deviceId.isNotEmpty) {
      try {
        final caps = await ref.read(
          equipmentRotatorCapabilitiesProvider(deviceId).future,
        );
        canReverse = caps?.canReverse ?? false;
      } catch (_) {
        canReverse = false;
      }
    }
    if (!mounted) return;

    await _showEquipmentDialog(
        context: context,
        builder: (ctx) {
          return StatefulBuilder(builder: (context, setState) {
            final colors = SkotiqColors.of(context);
            return SkotiqDialog(
              title: 'Rotator configuration',
              icon: LucideIcons.rotateCw,
              width: 400,
              actions: [
                SkotiqButton(
                  onPressed: isSaving ? null : () => Navigator.pop(context),
                  label: 'Cancel',
                  variant: ButtonVariant.ghost,
                  size: ButtonSize.small,
                ),
                SkotiqButton(
                  onPressed: isSaving
                      ? null
                      : () async {
                          if (reversed == originalReversed) {
                            Navigator.pop(context);
                            return;
                          }
                          setState(() => isSaving = true);
                          try {
                            await ref
                                .read(deviceServiceProvider)
                                .setRotatorReversed(reversed);
                            if (!context.mounted) return;
                            Navigator.pop(context);
                            if (pageContext.mounted) {
                              pageContext.showSuccessSnackBar(
                                'Rotator settings updated',
                              );
                            }
                          } catch (e) {
                            if (!context.mounted) return;
                            setState(() => isSaving = false);
                            context.showErrorSnackBar(
                              'Failed to set reverse direction: $e',
                            );
                          }
                        },
                  label: isSaving ? 'Saving...' : 'Save',
                  variant: ButtonVariant.primary,
                  size: ButtonSize.small,
                ),
              ],
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Reverse Direction',
                          style: SkotiqTypography.body
                              .copyWith(color: colors.textPrimary)),
                      Switch(
                        value: reversed,
                        onChanged: canReverse && !isSaving
                            ? (val) => setState(() => reversed = val)
                            : null,
                        activeThumbColor: colors.primary,
                      ),
                    ],
                  ),
                  if (!canReverse) ...[
                    const SizedBox(height: 8),
                    Text(
                      'This rotator does not report reverse-direction support.',
                      style: SkotiqTypography.bodySm
                          .copyWith(color: colors.textMuted),
                    ),
                  ],
                ],
              ),
            );
          });
        });
  }

  void _showDomeSettingsDialog() async {
    final domeState = ref.read(domeStateProvider);
    final originalSlaved = domeState.isSlaved;
    bool slaved = domeState.isSlaved;
    bool isSaving = false;
    // Capture the State's context up front: the Save handler is async and
    // snackbars must not use the dialog's (popped) context after the await.
    final pageContext = context;

    await _showEquipmentDialog(
        context: context,
        builder: (ctx) {
          return StatefulBuilder(builder: (context, setState) {
            final colors = SkotiqColors.of(context);
            return SkotiqDialog(
              title: 'Dome configuration',
              icon: LucideIcons.home,
              width: 400,
              actions: [
                SkotiqButton(
                  onPressed: isSaving ? null : () => Navigator.pop(context),
                  label: 'Cancel',
                  variant: ButtonVariant.ghost,
                  size: ButtonSize.small,
                ),
                SkotiqButton(
                  onPressed: isSaving
                      ? null
                      : () async {
                          if (slaved == originalSlaved) {
                            Navigator.pop(context);
                            return;
                          }
                          final deviceId = domeState.deviceId;
                          if (deviceId == null || deviceId.isEmpty) {
                            context.showErrorSnackBar('Dome is not connected');
                            return;
                          }
                          setState(() => isSaving = true);
                          try {
                            await ref
                                .read(backendProvider)
                                .domeSetSlaved(deviceId, slaved);
                            ref
                                .read(domeStateProvider.notifier)
                                .setSlaved(slaved);
                            if (!context.mounted) return;
                            Navigator.pop(context);
                            if (pageContext.mounted) {
                              pageContext.showSuccessSnackBar(
                                slaved
                                    ? 'Dome slaved to mount'
                                    : 'Dome unslaved',
                              );
                            }
                          } catch (e) {
                            if (!context.mounted) return;
                            setState(() => isSaving = false);
                            context.showErrorSnackBar(
                              'Dome slave failed: $e',
                            );
                          }
                        },
                  label: isSaving ? 'Saving...' : 'Save',
                  variant: ButtonVariant.primary,
                  size: ButtonSize.small,
                ),
              ],
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Slave to Mount (Follow Mount)',
                          style: SkotiqTypography.body
                              .copyWith(color: colors.textPrimary)),
                      Switch(
                        value: slaved,
                        onChanged: isSaving
                            ? null
                            : (val) => setState(() => slaved = val),
                        activeThumbColor: colors.primary,
                      ),
                    ],
                  ),
                ],
              ),
            );
          });
        });
  }

  void _showCoverCalibratorSettingsDialog() async {
    final state = ref.read(coverCalibratorStateProvider);
    final deviceId = state.deviceId;
    if (deviceId == null ||
        state.connectionState != DeviceConnectionState.connected) {
      if (mounted) {
        context.showErrorSnackBar('Calibrator is not connected');
      }
      return;
    }
    CoverCalibratorCapabilitySnapshot? capabilities;
    try {
      capabilities = await ref.read(
        equipmentCoverCalibratorCapabilitiesProvider(deviceId).future,
      );
    } catch (e) {
      if (mounted) {
        context.showErrorSnackBar('Could not read calibrator capabilities: $e');
      }
      return;
    }
    if (!mounted ||
        ref.read(coverCalibratorStateProvider).deviceId != deviceId) {
      return;
    }
    if (capabilities == null ||
        !capabilities.calibratorPresent ||
        capabilities.maxBrightness <= 0) {
      context.showErrorSnackBar(
        'This device does not report a controllable calibrator light.',
      );
      return;
    }
    final maxBrightness = capabilities.maxBrightness;
    final currentBrightness = capabilities.brightness ?? 0;
    var brightnessText = (currentBrightness > 0
            ? currentBrightness
            : (maxBrightness / 2).round().clamp(1, maxBrightness))
        .toString();
    final pageContext = context;
    bool isSaving = false;
    String? errorText;

    await _showEquipmentDialog(
        context: context,
        builder: (ctx) {
          return StatefulBuilder(builder: (context, setState) {
            final colors = SkotiqColors.of(context);
            return SkotiqDialog(
              title: 'Calibrator configuration',
              icon: LucideIcons.lamp,
              width: 400,
              actions: [
                SkotiqButton(
                  onPressed: isSaving ? null : () => Navigator.pop(context),
                  label: 'Cancel',
                  variant: ButtonVariant.ghost,
                  size: ButtonSize.small,
                ),
                SkotiqButton(
                  onPressed: isSaving
                      ? null
                      : () async {
                          if (isSaving) return;
                          final target = int.tryParse(brightnessText.trim());
                          if (target == null) {
                            setState(() => errorText =
                                'Brightness must be a whole number.');
                            return;
                          }
                          if (target < 0 || target > maxBrightness) {
                            setState(() =>
                                errorText = 'Brightness must be between 0 and '
                                    '$maxBrightness.');
                            return;
                          }
                          setState(() {
                            errorText = null;
                            isSaving = true;
                          });
                          try {
                            // Awaited here so the dialog stays open and busy
                            // until the driver confirms; only then does it
                            // close. A failure keeps the typed value on screen
                            // and re-enables Save for a retry.
                            await _applyCalibratorBrightness(target);
                            if (!context.mounted) return;
                            Navigator.pop(context);
                            if (pageContext.mounted) {
                              pageContext.showSuccessSnackBar(
                                  'Calibrator brightness updated to $target');
                            }
                          } catch (e) {
                            if (!context.mounted) return;
                            setState(() {
                              isSaving = false;
                              errorText = 'Failed to set brightness: $e';
                            });
                          }
                        },
                  label: isSaving ? 'Saving...' : 'Save',
                  variant: ButtonVariant.primary,
                  size: ButtonSize.small,
                ),
              ],
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Calibrator Brightness (0 - $maxBrightness):',
                      style: SkotiqTypography.bodySm
                          .copyWith(color: colors.textSecondary)),
                  const SizedBox(height: 12),
                  TextFormField(
                    initialValue: brightnessText,
                    onChanged: (value) => brightnessText = value,
                    enabled: !isSaving,
                    keyboardType: TextInputType.number,
                    style: SkotiqTypography.body
                        .copyWith(color: colors.textPrimary),
                    decoration: InputDecoration(
                      hintText: 'Brightness',
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
                      style:
                          SkotiqTypography.bodySm.copyWith(color: colors.error),
                    ),
                  ],
                ],
              ),
            );
          });
        });
  }

  /// Apply a calibrator brightness to the hardware and mirror it into state.
  ///
  /// Throws on any failure (missing device id or a backend error) so the
  /// caller — the awaited calibrator dialog — can keep the dialog open, show
  /// the failure inline, and offer a retry. It deliberately shows NO snackbar
  /// of its own: the dialog owns the single success/failure surface, avoiding
  /// the double-snackbar the old fire-and-forget handler produced.
  Future<void> _applyCalibratorBrightness(int brightness) async {
    final deviceId = ref.read(coverCalibratorStateProvider).deviceId;
    if (deviceId == null || deviceId.isEmpty) {
      throw StateError('Calibrator is not connected');
    }
    final capabilities = await ref.read(
      equipmentCoverCalibratorCapabilitiesProvider(deviceId).future,
    );
    if (capabilities == null || !capabilities.calibratorPresent) {
      throw StateError('This device has no controllable calibrator light');
    }
    if (brightness < 0 || brightness > capabilities.maxBrightness) {
      throw RangeError.range(
        brightness,
        0,
        capabilities.maxBrightness,
        'brightness',
      );
    }
    final backend = ref.read(backendProvider);
    await backend.calibratorOn(deviceId, brightness);
    if (!mounted ||
        !identical(ref.read(backendProvider), backend) ||
        ref.read(coverCalibratorStateProvider).deviceId != deviceId) {
      return;
    }
    final notifier = ref.read(coverCalibratorStateProvider.notifier);
    notifier.updateBrightness(brightness);
    notifier.updateCalibratorStatus(CalibratorStatus.notReady);
    ref.invalidate(equipmentCoverCalibratorCapabilitiesProvider(deviceId));
  }
}
