import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../services/host_folders.dart';
import '../../../utils/snackbar_helper.dart';

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
      final result = await ref.read(hostFoldersProvider).pickUsable(
            context,
            title: ref.read(isRemoteModeProvider)
                ? 'Select host flat-frame folder'
                : 'Select flat-frame folder',
            initialPath: current,
          );
      if (!_isCurrentBrowse(generation, authority)) return;
      if (result != null) _pathController.text = result;
    } catch (error) {
      if (mounted && _isCurrentBrowse(generation, authority)) {
        context.showErrorSnackBar(
            'Could not choose a save folder: ${userFacingError(error)}');
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
        ref.backendScopeOver(authority).isCurrent;
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

    return SkotiqDialog(
      title: 'Folder for flats',
      showCloseButton: false,
      actions: [
        SkotiqButton(
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
          variant: ButtonVariant.ghost,
        ),
        SkotiqButton(
          label: 'Use this folder',
          onPressed: _pathController.text.isNotEmpty ? _confirm : null,
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: SkotiqTextField(
                  controller: _pathController,
                  hint: 'Select a folder',
                  prefixIcon: LucideIcons.folder,
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              SkotiqButton(
                label: 'Browse',
                onPressed: _isBrowsing ? null : _browsePath,
                variant: ButtonVariant.secondary,
                isLoading: _isBrowsing,
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          SkotiqSwitchRow(
            label: 'A folder for each date',
            subtitle: 'Such as ${ClockFormat.date(DateTime.now())}',
            value: _createDateSubfolder,
            onChanged: (v) => setState(() => _createDateSubfolder = v),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          SkotiqSwitchRow(
            label: 'A folder for each filter',
            subtitle: 'Such as L, R, G, B',
            value: _createFilterSubfolders,
            onChanged: (v) => setState(() => _createFilterSubfolders = v),
          ),
        ],
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
