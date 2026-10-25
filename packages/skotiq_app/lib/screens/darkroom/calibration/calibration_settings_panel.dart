import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:file_selector/file_selector.dart';

import '../../../utils/snackbar_helper.dart';
import '../../../widgets/remote_host_path_dialog.dart';
import 'calibration_panel.dart';

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

/// How captured light frames are calibrated as they arrive, and which
/// masters that uses: the switches and files that used to live on the
/// Settings Calibration and Dark library pages.
class CalibrationSettingsPanel extends ConsumerWidget {
  const CalibrationSettingsPanel({super.key});

  static const List<String> toleranceChoices = [
    '0.5',
    '1.0',
    '1.5',
    '2.0',
    '3.0',
    '5.0',
  ];

  Future<void> _save(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (error) {
      if (context.mounted) {
        context.showErrorSnackBar(
          'Could not update the calibration settings: $error',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.skotiqColors;
    final cal = ref.watch(calibrationSettingsProvider);
    final library = ref.watch(darkLibrarySettingsProvider);
    final notifier = ref.read(calibrationSettingsProvider.notifier);

    final Widget body;
    if (cal.isLoading) {
      body = const Padding(
        padding: EdgeInsets.symmetric(vertical: SkotiqTokens.spaceXl),
        child: Center(child: SkotiqSpinner(size: 20)),
      );
    } else if (cal.loadError != null) {
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceMd),
        child: Row(
          children: [
            Icon(LucideIcons.alertTriangle, size: 14, color: colors.error),
            const SizedBox(width: SkotiqTokens.spaceSm),
            Expanded(
              child: Text(
                'Could not load the calibration settings: ${cal.loadError}',
                style: SkotiqTypography.bodySm.copyWith(color: colors.error),
              ),
            ),
            SkotiqButton(
              label: 'Retry',
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: () => ref.invalidate(calibrationSettingsProvider),
            ),
          ],
        ),
      );
    } else {
      final tolerance = library.valueOrNull?.temperatureTolerance;
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CalibrationRow(
            child: SkotiqSwitchRow(
              label: 'Calibrate frames as they are captured',
              subtitle:
                  'Subtracts the dark and bias and divides by the flat on '
                  'each new light frame, keeping the original.',
              value: cal.autoCalibrate,
              onChanged: (v) =>
                  _save(context, () => notifier.setAutoCalibrate(v)),
            ),
          ),
          CalibrationRow(
            child: SkotiqSwitchRow(
              label: 'Pick the dark from the library',
              subtitle:
                  'Matches exposure, gain, offset, binning and temperature. '
                  'Off uses the dark file below.',
              value: cal.autoDarkFromLibrary,
              onChanged: (v) =>
                  _save(context, () => notifier.setAutoDarkFromLibrary(v)),
            ),
          ),
          if (!cal.autoDarkFromLibrary)
            CalibrationFileRow(
              fileType: CalibrationFileType.dark,
              label: 'Dark file',
              path: cal.manualDarkPath,
              onClear: () =>
                  _save(context, () => notifier.setManualDarkPath(null)),
            ),
          CalibrationRow(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Dark temperature tolerance',
                        style: SkotiqTypography.label.copyWith(
                          color: colors.textPrimary,
                        ),
                      ),
                      Text(
                        'How far a dark\'s sensor temperature may be from '
                        'the light\'s.',
                        style: SkotiqTypography.caption.copyWith(
                          color: colors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: SkotiqTokens.spaceMd),
                SizedBox(
                  width: 96,
                  child: tolerance == null
                      ? Text(
                          library.hasError ? 'Unavailable' : '…',
                          style: SkotiqTypography.bodySm.copyWith(
                            color: colors.textMuted,
                          ),
                        )
                      : SkotiqDropdown(
                          dense: true,
                          value: _nearestChoice(tolerance),
                          items: toleranceChoices,
                          itemLabels: [
                            for (final c in toleranceChoices) '$c °C',
                          ],
                          onChanged: (v) {
                            if (v == null) return;
                            _save(
                              context,
                              () => ref
                                  .read(darkLibrarySettingsActionsProvider)
                                  .setTemperatureTolerance(double.parse(v)),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          CalibrationFileRow(
            fileType: CalibrationFileType.flat,
            label: 'Flat file',
            note: 'Used when no library flat matches the filter',
            path: cal.masterFlatPath,
            onClear: () =>
                _save(context, () => notifier.setMasterFlatPath(null)),
          ),
          CalibrationFileRow(
            fileType: CalibrationFileType.bias,
            label: 'Bias file',
            note: 'Used when no library bias matches',
            path: cal.masterBiasPath,
            last: true,
            onClear: () =>
                _save(context, () => notifier.setMasterBiasPath(null)),
          ),
        ],
      );
    }

    return CalibrationSection(title: 'While imaging', child: body);
  }

  static String _nearestChoice(double value) {
    var best = toleranceChoices.first;
    for (final c in toleranceChoices) {
      if ((double.parse(c) - value).abs() <
          (double.parse(best) - value).abs()) {
        best = c;
      }
    }
    return best;
  }
}

/// A master file chosen by hand: its name, whether it is on disk, and
/// Browse / Clear.
class CalibrationFileRow extends StatelessWidget {
  const CalibrationFileRow({
    super.key,
    required this.fileType,
    required this.label,
    required this.path,
    required this.onClear,
    this.note,
    this.last = false,
  });

  final CalibrationFileType fileType;
  final String label;
  final String? note;
  final String? path;
  final VoidCallback onClear;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final set = path != null && path!.isNotEmpty;
    return CalibrationRow(
      last: last,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: SkotiqTypography.label.copyWith(
                        color: colors.textPrimary,
                      ),
                    ),
                    Text(
                      set
                          ? path!.split(RegExp(r'[/\\]')).last
                          : (note ?? 'None chosen'),
                      style: (set
                              ? SkotiqTypography.monoXs
                              : SkotiqTypography.caption)
                          .copyWith(
                        color: set ? colors.textSecondary : colors.textMuted,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (set)
                SkotiqIconButton(
                  icon: LucideIcons.x,
                  tooltip: 'Clear the ${label.toLowerCase()}',
                  size: IconButtonSize.sm,
                  onPressed: onClear,
                ),
              const SizedBox(width: SkotiqTokens.spaceXs),
              CalibrationFileBrowseButton(
                  fileType: fileType, currentPath: path),
            ],
          ),
          if (set) CalibrationFileCheck(filePath: path!),
        ],
      ),
    );
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

/// Row that validates whether a calibration file exists on disk.
class CalibrationFileCheck extends ConsumerWidget {
  final String filePath;

  const CalibrationFileCheck({
    super.key,
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
