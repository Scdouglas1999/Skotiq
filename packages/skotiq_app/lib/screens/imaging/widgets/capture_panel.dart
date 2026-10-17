import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../../../services/mount_command_service.dart';
import '../../../utils/confirm_dialog.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../widgets/help/field_help_copy.dart';
import '../../../widgets/help/field_help_label.dart';
import '../../../widgets/remote_directory_picker_dialog.dart';
import '../../../widgets/tutorial_keys/imaging_keys.dart';
import 'panel_widgets.dart';

// Provider for park mount on end setting
final parkMountOnEndProvider = StateProvider<bool>((ref) => false);

typedef CaptureSavePathPicker = Future<String?> Function(
  BuildContext context, {
  required bool isRemote,
  required String? initialPath,
});

typedef CaptureSavePathWriter = Future<void> Function(String path);

Future<String?> _pickCaptureSavePath(
  BuildContext context, {
  required bool isRemote,
  required String? initialPath,
}) {
  if (isRemote) {
    return RemoteDirectoryPickerDialog.show(
      context,
      title: 'Select host capture folder',
      initialPath: initialPath,
    );
  }
  return getDirectoryPath(
    confirmButtonText: 'Select',
    initialDirectory: initialPath,
  );
}

final captureSavePathPickerProvider =
    Provider<CaptureSavePathPicker>((ref) => _pickCaptureSavePath);

final captureSavePathWriterProvider = Provider<CaptureSavePathWriter>((ref) {
  return ref.read(appSettingsProvider.notifier).setImageOutputPath;
});

class CapturePanel extends ConsumerWidget {
  final SkotiqColors colors;

  /// Duration / Snapshot / Loop cluster, pinned above the scrolling settings.
  ///
  /// Supplied only by the layouts that omit the persistent bottom capture bar
  /// (the landscape side-by-side split, where that bar would overflow the short
  /// height). Without them that band has no exposure-start control anywhere:
  /// this panel carries no Snapshot or Loop button of its own.
  final Widget? captureActions;

  const CapturePanel({
    super.key,
    required this.colors,
    this.captureActions,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final exposureSettings = ref.watch(exposureSettingsProvider);
    final namingPattern = ref.watch(namingPatternProvider);
    final sessionState = ref.watch(sessionStateProvider);
    final sessionImages = ref.watch(recentSessionFramesProvider);
    final isRemoteMode = ref.watch(isRemoteModeProvider);
    final cameraState = ref.watch(cameraStateProvider);
    final hostSuffix = isRemoteMode ? ' (host)' : '';

    // The Session card's "Captured" and "Integration" lines must come from the
    // SAME record or they can contradict each other. `recentSessionFramesProvider`
    // only holds frames captured in THIS app run, so after resuming an
    // interrupted session the card read "Captured 0 frames" directly above
    // "Integration 40m 0s". SessionService.recoverSession restores
    // completedExposures from the DB row alongside totalIntegrationSecs, so
    // prefer it whenever a session row is open; the in-run frame list is only
    // the fallback for captures taken with no session (dbSessionId == null).
    // ...and the fallback has to obey the same rule, which it did not. With no
    // session row open, the count came from `sessionImages` — which includes
    // frames the SEQUENCER captured this app run — while the integration below
    // came from `sessionState`, which only accumulates captures this screen
    // performed. Measured on 2026-08-10 after a ten-frame sequencer run at 8s:
    // the card read "Captured 10 frames / Integration 0s", and one 2s Snapshot
    // moved it to "11 frames / 2s". Eleven frames cannot total two seconds at
    // any exposure.
    //
    // So derive both from the same list here, exactly as the DB branch derives
    // both from the same row.
    final capturedCount = sessionState.dbSessionId != null
        ? sessionState.completedExposures
        : sessionImages.length;
    final integrationSecs = sessionState.dbSessionId != null
        ? sessionState.totalIntegrationSecs
        : sessionImages.fold<double>(
            0.0,
            (sum, image) => sum + image.settings.exposureTime,
          );

    // Get binning options based on connected camera's capabilities
    final binningOptions = ref.watch(
      cameraBinningOptionsProvider(cameraState.deviceId ?? ''),
    );

    // Ensure current binning value is valid for available options
    final currentBinning = binningOptions.contains(exposureSettings.binning)
        ? exposureSettings.binning
        : binningOptions.first;

    final diskFree = ref.watch(captureDirDiskSpaceProvider).valueOrNull;
    final savePathUnset = namingPattern.baseDir.trim().isEmpty ||
        namingPattern.baseDir.trim() == '.';

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (captureActions != null) ...[
            captureActions!,
            const SizedBox(height: SidePanel.sectionGap),
          ],
          SectionTitle(
            icon: SkotiqIcons.camera,
            title: 'Capture$hostSuffix',
            trailing: cameraState.temperature == null
                ? null
                : SkotiqChip(
                    label: '${cameraState.temperature!.toStringAsFixed(1)} °C',
                    tone: ChipTone.success,
                    dot: true,
                  ),
          ),
          FormRow(
            label: 'Exposure',
            child: InlineNumberField(
              value: exposureSettings.exposureTime.toStringAsFixed(1),
              suffix: 's',
              semanticLabel: 'Exposure seconds',
              onChanged: (value) {
                final parsed = double.tryParse(value);
                if (parsed != null && parsed > 0) {
                  ref.read(manualExposureSettingsUpdaterProvider).update(
                        exposureSettings.copyWith(exposureTime: parsed),
                      );
                }
              },
            ),
          ),
          const SizedBox(height: FormRow.rowGap),
          FormRow(
            label: 'Frame type',
            // The explanation rides behind the help glyph, not under the row: a
            // FormRow is one line, and a paragraph of prose between two fields
            // is the screen explaining itself on every visit.
            child: _WithHelp(
              helpId: FieldHelpId.captureFrameType,
              child: SkotiqDropdown(
                value: exposureSettings.frameType.displayName,
                items: FrameType.values.map((t) => t.displayName).toList(),
                isExpanded: true,
                onChanged: (value) {
                  if (value == null) return;
                  final type = FrameType.values.firstWhere(
                    (t) => t.displayName == value,
                    orElse: () => FrameType.light,
                  );
                  ref.read(manualExposureSettingsUpdaterProvider).update(
                        exposureSettings.copyWith(frameType: type),
                      );
                },
              ),
            ),
          ),
          const SizedBox(height: FormRow.rowGap),
          FormRow(
            label: 'Binning',
            child: _WithHelp(
              helpId: FieldHelpId.captureBinning,
              child: SkotiqDropdown(
                value: currentBinning,
                items: binningOptions,
                isExpanded: true,
                onChanged: (value) {
                  if (value == null) return;
                  final parts = value.split('x');
                  ref.read(manualExposureSettingsUpdaterProvider).update(
                        exposureSettings.copyWith(
                          binningX: int.parse(parts[0]),
                          binningY: int.parse(parts[1]),
                        ),
                      );
                },
              ),
            ),
          ),
          const SizedBox(height: FormRow.rowGap),
          FormRow(
            label: 'Gain / offset',
            child: Row(
              children: [
                Expanded(
                  child: InlineNumberField(
                    key: ImagingTutorialKeys.gainControl,
                    value: exposureSettings.gain.toString(),
                    semanticLabel: 'Gain',
                    onChanged: (value) {
                      final parsed = int.tryParse(value);
                      if (parsed != null && parsed >= 0) {
                        ref.read(manualExposureSettingsUpdaterProvider).update(
                              exposureSettings.copyWith(gain: parsed),
                            );
                      }
                    },
                  ),
                ),
                const SizedBox(width: SkotiqTokens.spaceSm - 2),
                Expanded(
                  child: InlineNumberField(
                    value: exposureSettings.offset.toString(),
                    semanticLabel: 'Offset',
                    onChanged: (value) {
                      final parsed = int.tryParse(value);
                      if (parsed != null && parsed >= 0) {
                        ref.read(manualExposureSettingsUpdaterProvider).update(
                              exposureSettings.copyWith(offset: parsed),
                            );
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: SidePanel.sectionGap),
          const SectionTitle(icon: SkotiqIcons.folder, title: 'Files'),
          FormRow(
            label: 'Format',
            child: ReadOnlyField(
              value: '$kCaptureImageFormat · $kCaptureBitDepth',
            ),
          ),
          const SizedBox(height: FormRow.rowGap),
          FormRow(
            // Remote paths live on the imaging host; browse via the API.
            label: isRemoteMode ? 'Save to (host)' : 'Save to',
            child: Row(
              children: [
                Expanded(
                  child: ReadOnlyField(
                    // An unset capture directory persists as '.' — surface it
                    // as an actionable prompt instead of a bare dot.
                    value: savePathUnset ? 'Not set' : namingPattern.baseDir,
                    mono: !savePathUnset,
                    muted: savePathUnset,
                  ),
                ),
                const SizedBox(width: SkotiqTokens.spaceSm - 2),
                CaptureSavePathButton(
                  colors: colors,
                  currentPath: namingPattern.baseDir,
                  isRemote: isRemoteMode,
                ),
              ],
            ),
          ),
          const SizedBox(height: FormRow.rowGap),
          FormRow(
            label: 'Name',
            child: ReadOnlyField(value: namingPattern.pattern, mono: true),
          ),
          const SizedBox(height: SidePanel.sectionGap),
          SectionTitle(
            icon: SkotiqIcons.activity,
            title: 'Session',
            trailing: sessionState.isActive
                ? const SkotiqChip(
                    label: 'Active',
                    tone: ChipTone.success,
                    dot: true,
                  )
                : null,
          ),
          ReadoutRow(
            // Not DeviceRow.readoutGap (18): ReadoutRow gives every child an
            // equal share of the row rather than its natural width, so in a
            // side panel the gap comes straight out of the widest label.
            gap: SkotiqTokens.spaceMd,
            children: [
              Readout(value: '$capturedCount', label: 'Captured'),
              Readout(
                value: formatIntegrationSeconds(integrationSecs),
                label: 'Integration',
              ),
              Readout(
                // Null while the poll is in flight or the path is unset, and a
                // readout renders that as an em dash rather than inventing a
                // number.
                value: diskFree == null
                    ? null
                    : (diskFree.freeBytes / (1024 * 1024 * 1024))
                        .toStringAsFixed(0),
                unit: 'GB',
                label: 'Free',
              ),
            ],
          ),
          if (sessionState.isActive && sessionState.duration != null) ...[
            const SizedBox(height: SkotiqTokens.spaceMd),
            KeyValueList(
              rows: [
                ('Running for', _formatSessionDuration(sessionState.duration!)),
              ],
            ),
          ],
          const SizedBox(height: SkotiqTokens.spaceMd),
          // Stacked, not side by side: "View quick captures" and "Clear
          // session" both ellipsized to nine characters when they shared a
          // 244 px panel.
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                // Ad-hoc Snapshot/Loop captures never open a database session
                // — only the sequencer calls startSession — so gating this
                // button on dbSessionId made it assert "no active session"
                // while the counter above it reported a real, non-zero frame
                // count. Those frames are not stranded: they are persisted as
                // standalone rows and Analytics renders them under "Quick
                // Capture". Route there instead of denying they exist.
                child: SkotiqButton(
                  label: sessionState.dbSessionId != null
                      ? 'View gallery'
                      : 'View quick captures',
                  icon: LucideIcons.galleryHorizontal,
                  variant: ButtonVariant.secondary,
                  size: ButtonSize.small,
                  onPressed: sessionState.dbSessionId != null ||
                          sessionImages.isNotEmpty
                      ? () {
                          final sessionId = sessionState.dbSessionId;
                          if (sessionId != null) {
                            context.push('/session-review?session=$sessionId');
                          } else {
                            context.push('/analytics?tab=session');
                          }
                        }
                      : null,
                ),
              ),
              const SizedBox(height: SkotiqTokens.spaceSm),
              Align(
                alignment: Alignment.centerLeft,
                child: SkotiqButton(
                  label: 'Clear session',
                  icon: SkotiqIcons.delete,
                  variant: ButtonVariant.ghost,
                  size: ButtonSize.small,
                  // Confirm before wiping: clearing drops the in-memory frame
                  // strip and integration stats shown here, which cannot be
                  // reconstructed from the UI. Captured files on disk are
                  // untouched.
                  onPressed: () async {
                    final confirmed = await ConfirmDialog.show(
                      context: context,
                      title: 'Clear the session view?',
                      message: 'This clears the session frame list and '
                          'integration stats shown here. Your captured files '
                          'stay on disk.',
                      confirmLabel: 'Clear',
                      isDestructive: true,
                    );
                    if (!confirmed || !context.mounted) return;
                    ref.read(sessionImagesProvider.notifier).clearSession();
                  },
                ),
              ),
            ],
          ),
          if (sessionState.isActive) ...[
            const SizedBox(height: SkotiqTokens.spaceSm),
            SkotiqButton(
              label: 'End session',
              icon: SkotiqIcons.stopCircle,
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: () => _showEndSessionDialog(context, ref, colors),
            ),
          ],
        ],
      ),
    );
  }

  String _formatSessionDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }

  void _showEndSessionDialog(
      BuildContext context, WidgetRef ref, SkotiqColors colors) {
    final sessionState = ref.read(sessionStateProvider);
    var isEnding = false;

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => PopScope(
          canPop: !isEnding,
          child: AlertDialog(
            title: Row(
              children: [
                Icon(SkotiqIcons.stopCircle, color: colors.warning),
                const SizedBox(width: 12),
                const Text('End Session'),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'This closes the session and stops counting frames into it.',
                  style: SkotiqTypography.bodySm.copyWith(
                    color: colors.textSecondary,
                  ),
                ),
                const SizedBox(height: SkotiqTokens.spaceLg),
                KeyValueList(
                  rows: [
                    ('Images captured', '${sessionState.completedExposures}'),
                    (
                      'Total integration',
                      formatIntegrationSeconds(
                        sessionState.totalIntegrationSecs,
                      ),
                    ),
                    (
                      'Duration',
                      // A session with no measured duration renders an em
                      // dash, never '--:--:--'.
                      sessionState.duration != null
                          ? _formatSessionDuration(sessionState.duration!)
                          : '\u2014',
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Consumer(
                  builder: (context, ref, child) {
                    final parkOnEnd = ref.watch(parkMountOnEndProvider);
                    final mountState = ref.watch(mountStateProvider);
                    final mountConnected = mountState.connectionState ==
                        DeviceConnectionState.connected;

                    return CheckboxListTile(
                      value: parkOnEnd,
                      onChanged: mountConnected
                          ? (value) {
                              ref.read(parkMountOnEndProvider.notifier).state =
                                  value ?? false;
                            }
                          : null,
                      title: Text(
                        'Park mount after ending session',
                        style: SkotiqTypography.body.copyWith(
                            color: mountConnected
                                ? colors.textPrimary
                                : colors.textSecondary),
                      ),
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      enabled: mountConnected,
                    );
                  },
                ),
              ],
            ),
            actions: [
              SkotiqButton(
                onPressed:
                    isEnding ? null : () => Navigator.of(dialogContext).pop(),
                label: 'Cancel',
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
              ),
              SkotiqButton(
                onPressed: isEnding
                    ? null
                    : () async {
                        setDialogState(() => isEnding = true);
                        final ended = await _endSession(ref, context);
                        if (!dialogContext.mounted) return;
                        if (ended) {
                          Navigator.of(dialogContext).pop();
                        } else {
                          setDialogState(() => isEnding = false);
                        }
                      },
                label: 'End session',
                variant: ButtonVariant.destructive,
                size: ButtonSize.small,
                isLoading: isEnding,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool> _endSession(WidgetRef ref, BuildContext context) async {
    final logger = ref.read(loggingServiceProvider);
    try {
      final parkOnEnd = ref.read(parkMountOnEndProvider);

      // End the session
      await ref.read(sessionStateProvider.notifier).endSession();

      // Park mount if requested (service handles connection check)
      if (parkOnEnd) {
        try {
          logger.info('[Imaging] Parking mount after session end...',
              source: 'CapturePanel');
          final result = await ref.read(mountCommandServiceProvider).park();
          if (context.mounted) {
            context.showCommandActionResult(result);
          }
          if (result.isSuccess) {
            logger.info('[Imaging] Mount parked successfully',
                source: 'CapturePanel');
          } else {
            logger.warning('[Imaging] Mount park failed: ${result.message}',
                source: 'CapturePanel');
          }
        } catch (e) {
          logger.error('[Imaging] Session ended but mount park failed: $e',
              source: 'CapturePanel', fields: {'error': e.toString()});
          if (context.mounted) {
            context.showErrorSnackBar('Session ended, but parking failed: $e');
          }
        }
      }
      return true;
    } catch (e) {
      logger.error('[Imaging] Error ending session: $e',
          source: 'CapturePanel', fields: {'error': e.toString()});
      if (context.mounted) {
        context.showErrorSnackBar('Failed to end session: $e');
      }
      return false;
    }
  }
}

/// Host-authoritative browse action for the capture output folder.
///
/// The picker can remain open while the operator reconnects to another host.
/// Its result therefore belongs to the backend that opened it, not whichever
/// backend happens to be active when the platform dialog eventually returns.
class CaptureSavePathButton extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final String currentPath;
  final bool isRemote;

  const CaptureSavePathButton({
    super.key,
    required this.colors,
    required this.currentPath,
    required this.isRemote,
  });

  @override
  ConsumerState<CaptureSavePathButton> createState() =>
      _CaptureSavePathButtonState();
}

class _CaptureSavePathButtonState extends ConsumerState<CaptureSavePathButton> {
  bool _busy = false;
  int _operationGeneration = 0;

  @override
  Widget build(BuildContext context) {
    ref.watch(backendProvider);
    ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
      if (_busy && previous != null && !identical(previous, next)) {
        _operationGeneration++;
        setState(() => _busy = false);
      }
    });

    return IconButton(
      tooltip: widget.isRemote
          ? 'Choose host capture folder'
          : 'Choose capture folder',
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      padding: EdgeInsets.zero,
      onPressed: _busy ? null : _choosePath,
      icon: _busy
          ? const SkotiqCircularProgress(
              value: 0,
              indeterminate: true,
              size: 14,
            )
          : Icon(
              SkotiqIcons.folderOpen,
              size: 14,
              color: widget.colors.textSecondary,
            ),
    );
  }

  Future<void> _choosePath() async {
    final generation = ++_operationGeneration;
    final authority = ref.read(backendProvider);
    // An unset capture directory persists as '.', which the label above
    // already renders as "Not set". Passing it through as a real starting
    // point sent the host picker to the appliance's process working
    // directory — on a systemd Pi, whatever directory the unit happened to
    // start in — and hid the curated "Host roots" listing the browse API
    // serves when no path is supplied.
    final initialPath = _normalizeInitialPath(widget.currentPath);
    setState(() => _busy = true);
    try {
      final result = await ref.read(captureSavePathPickerProvider)(
        context,
        isRemote: widget.isRemote,
        initialPath: initialPath,
      );
      if (result == null || !_isCurrent(generation, authority)) return;

      await ref.read(captureSavePathWriterProvider)(result);
    } catch (error) {
      if (!mounted ||
          generation != _operationGeneration ||
          !identical(ref.read(backendProvider), authority)) {
        return;
      }
      context.showErrorSnackBar('Could not update the capture folder: $error');
    } finally {
      if (mounted && generation == _operationGeneration) {
        setState(() => _busy = false);
      }
    }
  }

  /// The path the picker should open at, or null for "nowhere in particular".
  ///
  /// Both the empty string and '.' mean "no capture directory chosen yet".
  /// Returning null for either lets the remote picker ask the host for its
  /// root list instead of resolving '.' against the host's working directory.
  static String? _normalizeInitialPath(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed == '.') return null;
    return trimmed;
  }

  bool _isCurrent(int generation, SkotiqBackend authority) {
    return mounted &&
        generation == _operationGeneration &&
        identical(ref.read(backendProvider), authority);
  }
}

/// A form control with its explanation behind a help glyph.
///
/// `FormRow.help` renders the copy inline under the row, which turns a form of
/// one-line rows into a wall of prose. The glyph keeps the explanation one
/// hover away and the row one line tall.
class _WithHelp extends StatelessWidget {
  const _WithHelp({required this.helpId, required this.child});

  final FieldHelpId helpId;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final copy = helpFor(helpId);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(child: child),
        const SizedBox(width: SkotiqTokens.spaceSm),
        helpAffordance(
          context,
          title: copy.title,
          body: copy.body,
          position: SkotiqTooltipPosition.left,
        ),
      ],
    );
  }
}
