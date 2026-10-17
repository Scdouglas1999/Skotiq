import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:file_selector/file_selector.dart';

import '../../../utils/snackbar_helper.dart';
import '../../../widgets/remote_host_path_dialog.dart';
import 'settings_widgets.dart';

enum CalibrationFileType { flat, bias, dark }

typedef CalibrationFilePicker = Future<String?> Function(
  BuildContext context, {
  required CalibrationFileType fileType,
  required bool isRemote,
  required String? currentPath,
});

typedef CalibrationFileWriter = Future<void> Function(
  CalibrationFileType fileType,
  String path,
);

Future<String?> _pickCalibrationFile(
  BuildContext context, {
  required CalibrationFileType fileType,
  required bool isRemote,
  required String? currentPath,
}) async {
  if (isRemote) {
    return RemoteHostPathDialog.show(
      context,
      title: 'Master frame on host',
      initialPath: currentPath,
    );
  }

  const fitsGroup = XTypeGroup(
    label: 'FITS/XISF images',
    extensions: ['fits', 'fit', 'fts', 'xisf'],
  );
  return (await openFile(acceptedTypeGroups: [fitsGroup]))?.path;
}

final calibrationFilePickerProvider =
    Provider<CalibrationFilePicker>((ref) => _pickCalibrationFile);

final calibrationFileWriterProvider = Provider<CalibrationFileWriter>((ref) {
  return (fileType, path) async {
    final notifier = ref.read(calibrationSettingsProvider.notifier);
    switch (fileType) {
      case CalibrationFileType.flat:
        await notifier.setMasterFlatPath(path);
      case CalibrationFileType.bias:
        await notifier.setMasterBiasPath(path);
      case CalibrationFileType.dark:
        await notifier.setManualDarkPath(path);
    }
  };
});

class CalibrationSettingsPage extends ConsumerWidget {
  final bool isMobile;

  const CalibrationSettingsPage({
    super.key,
    this.isMobile = false,
  });

  Future<void> _saveSwitch(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (error) {
      if (context.mounted) {
        context.showErrorSnackBar(
          'Could not update calibration settings: $error',
        );
      }
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final calSettings = ref.watch(calibrationSettingsProvider);
    final darkLibraryStats = ref.watch(darkLibraryStatsProvider);

    if (calSettings.isLoading) {
      return SettingsLoadingState(isMobile: isMobile);
    }
    final loadError = calSettings.loadError;
    if (loadError != null) {
      return SettingsErrorState(
        isMobile: isMobile,
        error: loadError,
        onRetry: () => ref.invalidate(calibrationSettingsProvider),
      );
    }

    return SettingsPage(
      title: 'Calibration',
      description: 'Configure automatic image calibration pipeline',
      isMobile: isMobile,
      hideHeader: isMobile,
      children: [
        // Auto-calibrate toggle
        SettingsSection(
          title: 'Auto-Calibration',
          isMobile: isMobile,
          children: [
            SettingRow(
              icon: LucideIcons.zap,
              title: 'Auto-calibrate light frames',
              subtitle:
                  'Apply dark, flat, and bias correction to captured images automatically',
              trailing: SettingsSwitch(
                value: calSettings.autoCalibrate,
                onChanged: (value) {
                  return _saveSwitch(
                    context,
                    () => ref
                        .read(calibrationSettingsProvider.notifier)
                        .setAutoCalibrate(value),
                  );
                },
              ),
              isMobile: isMobile,
            ),
          ],
        ),

        const SizedBox(height: 16),

        // Calibration frame status overview
        SettingsSection(
          title: 'Calibration frame status',
          isMobile: isMobile,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  _CalStatusCard(
                    label: 'Dark',
                    available: _isDarkAvailable(calSettings, darkLibraryStats),
                    detail: _darkDetail(calSettings, darkLibraryStats),
                    icon: LucideIcons.moon,
                  ),
                  const SizedBox(width: 12),
                  _CalStatusCard(
                    label: 'Flat',
                    available: calSettings.masterFlatPath != null &&
                        calSettings.masterFlatPath!.isNotEmpty,
                    detail: calSettings.masterFlatPath != null &&
                            calSettings.masterFlatPath!.isNotEmpty
                        ? _fileName(calSettings.masterFlatPath!)
                        : 'Not set',
                    icon: LucideIcons.sun,
                  ),
                  const SizedBox(width: 12),
                  _CalStatusCard(
                    label: 'Bias',
                    available: calSettings.masterBiasPath != null &&
                        calSettings.masterBiasPath!.isNotEmpty,
                    detail: calSettings.masterBiasPath != null &&
                            calSettings.masterBiasPath!.isNotEmpty
                        ? _fileName(calSettings.masterBiasPath!)
                        : 'Not set',
                    icon: LucideIcons.zap,
                  ),
                ],
              ),
            ),
          ],
        ),

        const SizedBox(height: 16),

        // Dark frame source
        SettingsSection(
          title: 'Dark frame',
          isMobile: isMobile,
          children: [
            SettingRow(
              icon: LucideIcons.database,
              title: 'Auto-match from dark library',
              subtitle:
                  'Find the best matching dark frame based on exposure parameters',
              trailing: SettingsSwitch(
                value: calSettings.autoDarkFromLibrary,
                onChanged: (value) {
                  return _saveSwitch(
                    context,
                    () => ref
                        .read(calibrationSettingsProvider.notifier)
                        .setAutoDarkFromLibrary(value),
                  );
                },
              ),
              isMobile: isMobile,
            ),
            if (!calSettings.autoDarkFromLibrary)
              SettingRow(
                icon: LucideIcons.fileInput,
                title: 'Manual dark frame',
                subtitle: calSettings.manualDarkPath != null &&
                        calSettings.manualDarkPath!.isNotEmpty
                    ? calSettings.manualDarkPath!
                    : 'No manual dark selected',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (calSettings.manualDarkPath != null &&
                        calSettings.manualDarkPath!.isNotEmpty)
                      SkotiqIconButton(
                        icon: LucideIcons.x,
                        tooltip: 'Clear dark path',
                        onPressed: () => _clearPath(
                          context,
                          () => ref
                              .read(calibrationSettingsProvider.notifier)
                              .setManualDarkPath(null),
                        ),
                        size: IconButtonSize.sm,
                        color: colors.error,
                      ),
                    const SizedBox(width: 8),
                    CalibrationFileBrowseButton(
                      fileType: CalibrationFileType.dark,
                      currentPath: calSettings.manualDarkPath,
                    ),
                  ],
                ),
                isMobile: isMobile,
              ),
          ],
        ),

        const SizedBox(height: 16),

        // Master flat
        SettingsSection(
          title: 'Master flat',
          isMobile: isMobile,
          children: [
            SettingRow(
              icon: LucideIcons.sun,
              title: 'Master flat file',
              subtitle: calSettings.masterFlatPath != null &&
                      calSettings.masterFlatPath!.isNotEmpty
                  ? calSettings.masterFlatPath!
                  : 'No master flat selected',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (calSettings.masterFlatPath != null &&
                      calSettings.masterFlatPath!.isNotEmpty)
                    SkotiqIconButton(
                      icon: LucideIcons.x,
                      tooltip: 'Clear flat path',
                      onPressed: () => _clearPath(
                        context,
                        () => ref
                            .read(calibrationSettingsProvider.notifier)
                            .setMasterFlatPath(null),
                      ),
                      size: IconButtonSize.sm,
                      color: colors.error,
                    ),
                  const SizedBox(width: 8),
                  CalibrationFileBrowseButton(
                    fileType: CalibrationFileType.flat,
                    currentPath: calSettings.masterFlatPath,
                  ),
                ],
              ),
              isMobile: isMobile,
            ),
            if (calSettings.masterFlatPath != null &&
                calSettings.masterFlatPath!.isNotEmpty)
              _FileValidationRow(
                filePath: calSettings.masterFlatPath!,
              ),
          ],
        ),

        const SizedBox(height: 16),

        // Master bias
        SettingsSection(
          title: 'Master bias',
          isMobile: isMobile,
          children: [
            SettingRow(
              icon: LucideIcons.zap,
              title: 'Master bias file',
              subtitle: calSettings.masterBiasPath != null &&
                      calSettings.masterBiasPath!.isNotEmpty
                  ? calSettings.masterBiasPath!
                  : 'No master bias selected',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (calSettings.masterBiasPath != null &&
                      calSettings.masterBiasPath!.isNotEmpty)
                    SkotiqIconButton(
                      icon: LucideIcons.x,
                      tooltip: 'Clear bias path',
                      onPressed: () => _clearPath(
                        context,
                        () => ref
                            .read(calibrationSettingsProvider.notifier)
                            .setMasterBiasPath(null),
                      ),
                      size: IconButtonSize.sm,
                      color: colors.error,
                    ),
                  const SizedBox(width: 8),
                  CalibrationFileBrowseButton(
                    fileType: CalibrationFileType.bias,
                    currentPath: calSettings.masterBiasPath,
                  ),
                ],
              ),
              isMobile: isMobile,
            ),
            if (calSettings.masterBiasPath != null &&
                calSettings.masterBiasPath!.isNotEmpty)
              _FileValidationRow(
                filePath: calSettings.masterBiasPath!,
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _clearPath(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (error) {
      if (context.mounted) {
        context.showErrorSnackBar(
          'Could not clear calibration path: $error',
        );
      }
    }
  }

  bool _isDarkAvailable(
    CalibrationSettings settings,
    AsyncValue<DarkLibraryStats> statsAsync,
  ) {
    // Manual dark path is set
    if (!settings.autoDarkFromLibrary &&
        settings.manualDarkPath != null &&
        settings.manualDarkPath!.isNotEmpty) {
      return true;
    }
    // Auto dark from library - check if library has any darks
    if (settings.autoDarkFromLibrary) {
      return statsAsync.when(
        data: (stats) => stats.darkCount > 0 || stats.masterCount > 0,
        loading: () => false,
        error: (_, __) => false,
      );
    }
    return false;
  }

  String _darkDetail(
    CalibrationSettings settings,
    AsyncValue<DarkLibraryStats> statsAsync,
  ) {
    if (!settings.autoDarkFromLibrary) {
      if (settings.manualDarkPath != null &&
          settings.manualDarkPath!.isNotEmpty) {
        return _fileName(settings.manualDarkPath!);
      }
      return 'Manual - not set';
    }
    return statsAsync.when(
      data: (stats) {
        if (stats.darkCount == 0 && stats.masterCount == 0) {
          return 'Library empty';
        }
        return '${stats.darkCount} darks, ${stats.masterCount} masters';
      },
      loading: () => 'Loading...',
      error: (_, __) => 'Error',
    );
  }

  String _fileName(String path) {
    final parts = path.split(RegExp(r'[/\\]'));
    return parts.last;
  }
}

class CalibrationFileBrowseButton extends ConsumerStatefulWidget {
  final CalibrationFileType fileType;
  final String? currentPath;

  const CalibrationFileBrowseButton({
    super.key,
    required this.fileType,
    required this.currentPath,
  });

  @override
  ConsumerState<CalibrationFileBrowseButton> createState() =>
      _CalibrationFileBrowseButtonState();
}

class _CalibrationFileBrowseButtonState
    extends ConsumerState<CalibrationFileBrowseButton> {
  bool _busy = false;
  int _operationGeneration = 0;

  @override
  Widget build(BuildContext context) {
    ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
      if (_busy && previous != null && !identical(previous, next)) {
        _operationGeneration++;
        setState(() => _busy = false);
      }
    });

    return SkotiqButton(
      onPressed: _busy ? null : _selectFile,
      icon: _busy ? SkotiqIcons.loading : LucideIcons.folderOpen,
      label: _busy ? 'Selecting...' : 'Browse',
      variant: ButtonVariant.secondary,
      size: ButtonSize.small,
    );
  }

  Future<void> _selectFile() async {
    if (_busy) return;
    final generation = ++_operationGeneration;
    final authority = ref.read(backendProvider);
    final isRemote = ref.read(isRemoteModeProvider);
    setState(() => _busy = true);

    try {
      final path = await ref.read(calibrationFilePickerProvider)(
        context,
        fileType: widget.fileType,
        isRemote: isRemote,
        currentPath: widget.currentPath,
      );
      if (path == null || path.isEmpty || !_isCurrent(generation, authority)) {
        return;
      }

      await ref.read(calibrationFileWriterProvider)(widget.fileType, path);
    } catch (error) {
      if (!mounted || !_isCurrent(generation, authority)) return;
      context.showErrorSnackBar(
        'Could not update calibration settings: $error',
      );
    } finally {
      if (_isCurrent(generation, authority)) {
        setState(() => _busy = false);
      }
    }
  }

  bool _isCurrent(int generation, SkotiqBackend authority) {
    return mounted &&
        generation == _operationGeneration &&
        identical(ref.read(backendProvider), authority);
  }
}

/// Card showing availability status of a calibration frame type.
class _CalStatusCard extends StatelessWidget {
  final String label;
  final bool available;
  final String detail;
  final IconData icon;

  const _CalStatusCard({
    required this.label,
    required this.available,
    required this.detail,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: available
            ? SkotiqDecorations.emphasisSurface(
                colors.success,
                borderRadius:
                    BorderRadius.circular(SkotiqTokens.radiusInline8),
              )
            : BoxDecoration(
                color: colors.well,
                borderRadius:
                    BorderRadius.circular(SkotiqTokens.radiusInline8),
                border: Border.all(color: colors.border),
              ),
        child: Column(
          children: [
            Icon(
              icon,
              size: 20,
              color: available ? colors.success : colors.textMuted,
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  available ? LucideIcons.checkCircle : LucideIcons.circle,
                  size: 12,
                  color: available ? colors.success : colors.textMuted,
                ),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: SkotiqTypography.labelStrong.copyWith(
                      color: available ? colors.success : colors.textSecondary),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              detail,
              style: SkotiqTypography.captionSm.copyWith(
                color: colors.textMuted,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// Row that validates whether a calibration file exists on disk.
class _FileValidationRow extends ConsumerWidget {
  final String filePath;

  const _FileValidationRow({
    required this.filePath,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    if (ref.watch(isRemoteModeProvider)) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(
          children: [
            Icon(LucideIcons.server, size: 14, color: colors.textSecondary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Path is validated on the imaging host when calibrating',
                style: SkotiqTypography.caption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return FutureBuilder<bool>(
      future: File(filePath).exists(),
      builder: (context, snapshot) {
        final exists = snapshot.data ?? false;
        final isLoading = !snapshot.hasData;

        if (isLoading) {
          return const SizedBox.shrink();
        }

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: [
              Icon(
                exists ? LucideIcons.checkCircle : LucideIcons.alertTriangle,
                size: 14,
                color: exists ? colors.success : colors.error,
              ),
              const SizedBox(width: 8),
              Text(
                exists ? 'File found on disk' : 'File not found on disk',
                style: SkotiqTypography.caption.copyWith(
                  color: exists ? colors.success : colors.error,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
