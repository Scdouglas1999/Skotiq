import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/snackbar_helper.dart';
import '../../../widgets/remote_directory_picker_dialog.dart';

Future<String?> chooseFlatWizardSavePath({
  required bool isRemote,
  required Future<String?> Function() pickLocal,
  required Future<String?> Function() pickRemote,
}) =>
    isRemote ? pickRemote() : pickLocal();

typedef FlatWizardSavePathPicker = Future<String?> Function({
  required BuildContext context,
  required bool isRemote,
  required String? currentPath,
});

final flatWizardSavePathPickerProvider = Provider<FlatWizardSavePathPicker>((
  ref,
) {
  return ({
    required BuildContext context,
    required bool isRemote,
    required String? currentPath,
  }) {
    return chooseFlatWizardSavePath(
      isRemote: isRemote,
      pickLocal: () => getDirectoryPath(
        confirmButtonText: 'Select',
        initialDirectory: currentPath,
      ),
      pickRemote: () => RemoteDirectoryPickerDialog.show(
        context,
        title: 'Select host flat-frame folder',
        initialPath: currentPath,
      ),
    );
  };
});

class SavePathDialog extends ConsumerStatefulWidget {
  final String? currentPath;
  final bool createDateSubfolder;
  final bool createFilterSubfolders;

  const SavePathDialog({
    super.key,
    this.currentPath,
    this.createDateSubfolder = true,
    this.createFilterSubfolders = true,
  });

  static Future<SavePathResult?> show(
    BuildContext context, {
    String? currentPath,
    bool createDateSubfolder = true,
    bool createFilterSubfolders = true,
  }) {
    return showDialog<SavePathResult>(
      context: context,
      barrierDismissible: false,
      builder: (context) => SavePathDialog(
        currentPath: currentPath,
        createDateSubfolder: createDateSubfolder,
        createFilterSubfolders: createFilterSubfolders,
      ),
    );
  }

  @override
  ConsumerState<SavePathDialog> createState() => _SavePathDialogState();
}

class _SavePathDialogState extends ConsumerState<SavePathDialog> {
  late TextEditingController _pathController;
  late bool _createDateSubfolder;
  late bool _createFilterSubfolders;
  bool _isBrowsing = false;
  int _browseGeneration = 0;

  @override
  void initState() {
    super.initState();
    _pathController = TextEditingController(text: widget.currentPath ?? '');
    _pathController.addListener(_handlePathChanged);
    _createDateSubfolder = widget.createDateSubfolder;
    _createFilterSubfolders = widget.createFilterSubfolders;
  }

  @override
  void dispose() {
    _pathController.removeListener(_handlePathChanged);
    _pathController.dispose();
    super.dispose();
  }

  void _handlePathChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _browsePath() async {
    if (_isBrowsing) return;
    final generation = ++_browseGeneration;
    final authority = ref.read(backendProvider);
    final current =
        _pathController.text.isNotEmpty ? _pathController.text : null;
    setState(() => _isBrowsing = true);
    try {
      final result = await ref.read(flatWizardSavePathPickerProvider)(
        context: context,
        isRemote: authority is NetworkBackend,
        currentPath: current,
      );
      if (!_isCurrentBrowse(generation, authority)) return;
      if (result != null) _pathController.text = result;
    } catch (error) {
      if (mounted && _isCurrentBrowse(generation, authority)) {
        context.showErrorSnackBar('Could not choose a save folder: $error');
      }
    } finally {
      if (_isCurrentBrowse(generation, authority)) {
        setState(() => _isBrowsing = false);
      }
    }
  }

  bool _isCurrentBrowse(int generation, SkotiqBackend authority) {
    return mounted &&
        generation == _browseGeneration &&
        identical(ref.read(backendProvider), authority);
  }

  void _confirm() {
    if (_pathController.text.isEmpty) return;

    Navigator.of(context).pop(SavePathResult(
      path: _pathController.text,
      createDateSubfolder: _createDateSubfolder,
      createFilterSubfolders: _createFilterSubfolders,
    ));
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
      if (!_isBrowsing || previous == null || identical(previous, next)) {
        return;
      }
      _browseGeneration++;
      setState(() => _isBrowsing = false);
    });

    final colors = SkotiqColors.of(context);

    return Dialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8)),
      child: ConstrainedBox(
        constraints: AdaptiveDialogConstraints.hybrid(
          context,
          designMaxWidth: 500,
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: SkotiqDecorations.tintedBadge(
                        colors.warning,
                        borderRadius:
                            BorderRadius.circular(SkotiqTokens.radiusLg),
                      ),
                      child: Icon(
                        LucideIcons.folderOpen,
                        color: colors.warning,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Save Location Required',
                            style: TextStyle(
                              fontSize: SkotiqTypography.fontSize18,
                              fontWeight: FontWeight.bold,
                              color: colors.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Choose where to save your flat frames',
                            style: TextStyle(
                              fontSize: SkotiqTypography.fontSize13,
                              color: colors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                // Path input
                Row(
                  children: [
                    Expanded(
                      child: SkotiqTextField(
                        controller: _pathController,
                        hint: 'Select a folder...',
                        prefixIcon: LucideIcons.folder,
                      ),
                    ),
                    const SizedBox(width: 12),
                    SkotiqButton(
                      label: 'Browse...',
                      onPressed: _isBrowsing ? null : _browsePath,
                      variant: ButtonVariant.outline,
                      isLoading: _isBrowsing,
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // Options
                _OptionCheckbox(
                  value: _createDateSubfolder,
                  onChanged: (v) {
                    if (v != null) {
                      setState(() => _createDateSubfolder = v);
                    }
                  },
                  label: 'Create date subfolder automatically',
                  description: 'e.g., /2026-01-07/',
                  colors: colors,
                ),
                const SizedBox(height: 12),
                _OptionCheckbox(
                  value: _createFilterSubfolders,
                  onChanged: (v) {
                    if (v != null) {
                      setState(() => _createFilterSubfolders = v);
                    }
                  },
                  label: 'Create filter subfolders',
                  description: 'e.g., /L/, /R/, /G/, /B/',
                  colors: colors,
                ),
                const SizedBox(height: 24),

                // Actions
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    SkotiqButton(
                      label: 'Cancel',
                      onPressed: () => Navigator.of(context).pop(),
                      variant: ButtonVariant.ghost,
                    ),
                    const SizedBox(width: 12),
                    SkotiqButton(
                      label: 'Continue',
                      onPressed:
                          _pathController.text.isNotEmpty ? _confirm : null,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _OptionCheckbox extends StatelessWidget {
  final bool value;
  final ValueChanged<bool?> onChanged;
  final String label;
  final String description;
  final SkotiqColors colors;

  const _OptionCheckbox({
    required this.value,
    required this.onChanged,
    required this.label,
    required this.description,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SkotiqCheckbox(
              value: value,
              onChanged: onChanged,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize13,
                      color: colors.textPrimary,
                    ),
                  ),
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize11,
                      color: colors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SavePathResult {
  final String path;
  final bool createDateSubfolder;
  final bool createFilterSubfolders;

  SavePathResult({
    required this.path,
    required this.createDateSubfolder,
    required this.createFilterSubfolders,
  });
}
