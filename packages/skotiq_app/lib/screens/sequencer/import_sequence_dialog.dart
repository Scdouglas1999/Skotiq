import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../utils/snackbar_helper.dart';
import 'dialogs/import_summary_dialog.dart';

typedef SequenceImportFilePicker = Future<file_selector.XFile?> Function();

Future<file_selector.XFile?> _pickSequenceImportFile() {
  return file_selector.openFile(
    acceptedTypeGroups: const [
      file_selector.XTypeGroup(
        label: 'Sequences & target lists',
        extensions: ['json', 'sgf', 'csv', 'ics'],
      ),
      file_selector.XTypeGroup(
        label: 'NINA / SGP sequence',
        extensions: ['json', 'sgf'],
      ),
      file_selector.XTypeGroup(
        label: 'Telescopius / Astrobin CSV',
        extensions: ['csv'],
      ),
      file_selector.XTypeGroup(
        label: 'Skotiq observing list',
        extensions: ['json'],
      ),
      file_selector.XTypeGroup(
        label: 'iCalendar',
        extensions: ['ics'],
      ),
    ],
  );
}

final sequenceImportFilePickerProvider =
    Provider<SequenceImportFilePicker>((ref) => _pickSequenceImportFile);

/// Top-level entry point for importing a NINA / SGP sequence.
///
/// Flow:
///   1. Open a file picker (.json / .sgf).
///   2. Read the file, detect format, parse + map (strict).
///   3. If [UnsupportedNodeError]: ask the user if they want to force-import
///      (which drops the unsupported nodes). If yes, retry in force mode.
///   4. Show [ImportSummaryDialog]. On confirm, persist to library +
///      optionally load into editor.
class ImportSequenceFlow {
  ImportSequenceFlow._();

  static bool _running = false;

  /// Run the full flow. Returns `true` if a sequence was imported (and saved
  /// and/or loaded into the editor), `false` if the user cancelled or an
  /// error occurred.
  static Future<bool> run(BuildContext context, WidgetRef ref) async {
    if (_running) return false;
    _running = true;
    try {
      return await _run(context, ref);
    } finally {
      _running = false;
    }
  }

  static Future<bool> _run(BuildContext context, WidgetRef ref) async {
    final authority = ref.read(backendProvider);
    final file_selector.XFile? file;
    try {
      file = await ref.read(sequenceImportFilePickerProvider)();
    } catch (e) {
      if (!context.mounted) return false;
      if (!_requireCurrentAuthority(context, ref, authority)) return false;
      context.showErrorSnackBar('Could not open the file picker: $e');
      return false;
    }
    // Dismissing a platform file picker is the conventional Cancel action.
    if (file == null) return false;
    if (!context.mounted) return false;
    if (!_requireCurrentAuthority(context, ref, authority)) return false;

    final String content;
    try {
      content = await file.readAsString();
    } catch (e) {
      if (!context.mounted) return false;
      if (!_requireCurrentAuthority(context, ref, authority)) return false;
      context.showErrorSnackBar('Could not read "${file.name}": $e');
      return false;
    }
    if (!context.mounted) return false;
    if (!_requireCurrentAuthority(context, ref, authority)) return false;
    final importer = ref.read(sequenceImporterProvider);
    final defaultName = _basename(file.name);

    if (!context.mounted) return false;

    // Route async formats (Astrobin needs catalog lookup, ICS publishes its
    // own unresolved list) through their dedicated entrypoints so we can
    // surface format-specific summaries (e.g. "12 resolved, 3 unresolved").
    // For everything else, fall through to the standard synchronous
    // importFromString pipeline.
    ImportResult? result;
    try {
      final detected = importer.detectFormatOrNull(content);
      if (detected == SourceFormat.astrobinCsv) {
        result = await _importAstrobinWithRetry(
          context,
          importer,
          content,
          defaultName,
        );
      } else if (detected == SourceFormat.icsCalendar) {
        result = await _importIcsWithRetry(
          context,
          importer,
          content,
          defaultName,
        );
      } else {
        result = await _parseWithRetry(context, importer, content, defaultName);
      }
    } catch (e) {
      if (!context.mounted) return false;
      if (!_requireCurrentAuthority(context, ref, authority)) return false;
      context.showErrorSnackBar('Import failed unexpectedly: $e');
      return false;
    }
    if (result == null) return false;
    if (!context.mounted) return false;
    if (!_requireCurrentAuthority(context, ref, authority)) return false;

    final decision = await ImportSummaryDialog.show(context, result: result);
    if (decision == null || decision.cancelled) return false;
    if (!context.mounted) return false;
    if (!_requireCurrentAuthority(context, ref, authority)) return false;

    var sequence = result.sequence;
    final requestedName = decision.sequenceName.trim();
    if (requestedName.isNotEmpty && requestedName != sequence.name) {
      sequence = sequence.copyWith(name: requestedName);
    }

    // Record dropped/unsupported nodes in the sequence description so the
    // information survives the import (the summary dialog is transient).
    // Without this, a force-import silently discarded nodes with no
    // persisted trace of what was lost.
    final droppedSummary = _buildDroppedNodesSummary(result);
    if (droppedSummary.isNotEmpty) {
      final combined = [sequence.description, droppedSummary]
          .where((s) => s.isNotEmpty)
          .join('\n\n');
      sequence = sequence.copyWith(description: combined);
    }

    var discardUnsaved = false;
    if (decision.destination == ImportDestination.openInEditor) {
      if (!ref.read(canEditSequenceProvider)) {
        context.showErrorSnackBar(
          'Stop the active sequence before opening an imported sequence.',
        );
        return false;
      }
      final editor = ref.read(currentSequenceProvider.notifier);
      if (editor.isDirty) {
        final currentName =
            ref.read(currentSequenceProvider)?.name ?? 'Current sequence';
        if (!context.mounted) return false;
        final confirmed = await _confirmDiscardUnsaved(
          context,
          UnsavedChangesException(
            attemptedOperation: 'open imported sequence',
            currentSequenceName: currentName,
          ),
        );
        if (confirmed != true || !context.mounted) return false;
        if (!_requireCurrentAuthority(context, ref, authority)) return false;
        discardUnsaved = true;
      }
    }

    // Persist to library. Both destinations save — the only difference is
    // whether we also load the imported sequence into the editor.
    if (!context.mounted) return false;
    if (!_requireCurrentAuthority(context, ref, authority)) return false;
    final repo = ref.read(sequenceRepositoryProvider);
    final int dbId;
    try {
      dbId = await repo.saveSequence(sequence);
      sequence = sequence.copyWith(databaseId: dbId);
      if (!context.mounted) return true;
      if (!identical(ref.read(backendProvider), authority)) {
        context.showWarningSnackBar(
          'The sequence was saved to the previous host, but the imaging host '
          'changed before the editor could be updated.',
        );
        return true;
      }
      notifySequenceCatalogChanged(
        ref,
        sequenceId: dbId,
        action: 'created',
        name: sequence.name,
      );
    } catch (e) {
      if (!context.mounted) return false;
      if (!_requireCurrentAuthority(context, ref, authority)) return false;
      context.showErrorSnackBar('Failed to save imported sequence: $e');
      return false;
    }

    final fmt = result.sourceFormat.displayName;
    if (!context.mounted) return true;
    switch (decision.destination!) {
      case ImportDestination.openInEditor:
        final loaded = await _loadSequenceWithDirtyCheck(
          context,
          ref,
          sequence,
          discardUnsaved: discardUnsaved,
          authority: authority,
        );
        if (!loaded) {
          if (context.mounted) {
            context.showWarningSnackBar(
              'Imported "${sequence.name}" to the library, but the editor '
              'could not be replaced.',
            );
          }
          return true;
        }
        if (!context.mounted) return true;
        context.showSuccessSnackBar(
            'Imported "${sequence.name}" ($fmt) and opened in editor');
        break;
      case ImportDestination.saveToLibrary:
        if (!context.mounted) return true;
        context
            .showSuccessSnackBar('Saved "${sequence.name}" ($fmt) to library');
        break;
    }
    return true;
  }

  /// Parse [content]. If the strict parse fails with [UnsupportedNodeError],
  /// prompt the user to force-import (dropping the unsupported nodes) and
  /// retry in force mode. Returns `null` if the user cancelled or the file
  /// was otherwise unimportable.
  static Future<ImportResult?> _parseWithRetry(
    BuildContext context,
    SequenceImporter importer,
    String content,
    String defaultName, {
    bool forceUnsupported = false,
    bool forceImport = false,
  }) async {
    try {
      return importer.importFromString(
        content,
        forceUnsupported: forceUnsupported,
        forceImport: forceImport,
        sequenceName: defaultName,
      );
    } on UnknownFormatError catch (e) {
      if (context.mounted) {
        context
            .showErrorSnackBar('Could not identify file format: ${e.message}');
      }
      return null;
    } on MalformedSourceError catch (e) {
      if (context.mounted) {
        context.showErrorSnackBar('File is malformed: ${e.message}');
      }
      return null;
    } on UnsupportedNodeError catch (e) {
      if (!context.mounted) return null;
      final force = await _confirmForceImport(context, e.unsupported);
      if (force != true) return null;
      if (!context.mounted) return null;
      // Retry in force-unsupported mode, preserving any prior force-
      // import-validation decision the caller had passed in.
      return _parseWithRetry(
        context,
        importer,
        content,
        defaultName,
        forceUnsupported: true,
        forceImport: forceImport,
      );
    } on SequenceImportValidationFailedException catch (e) {
      // The file parsed fine but the unified validator surfaced
      // ERROR-severity issues. Show a structured dialog with the issue
      // list and let the user accept the import via `forceImport: true`.
      if (!context.mounted) return null;
      final accept = await _confirmForceValidation(context, e);
      if (accept != true) return null;
      if (!context.mounted) return null;
      return _parseWithRetry(
        context,
        importer,
        content,
        defaultName,
        forceUnsupported: forceUnsupported,
        forceImport: true,
      );
    }
  }

  /// Show a structured dialog listing every blocking validation issue
  /// from a [SequenceImportValidationFailedException]. Returns `true` if
  /// the user opts to import anyway, `false`/`null` if they cancel.
  static Future<bool?> _confirmForceValidation(
    BuildContext context,
    SequenceImportValidationFailedException error,
  ) {
    final colors = SkotiqColors.of(context);
    final errors = error.errors;
    final warnings = error.issues
        .where((i) => i.severity == ValidationSeverity.warning)
        .toList();
    final infos = error.issues
        .where((i) => i.severity == ValidationSeverity.info)
        .toList();

    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Row(
          children: [
            Icon(LucideIcons.alertOctagon, color: colors.error, size: 18),
            const SizedBox(width: 8),
            const Text('Sequence has validation errors'),
          ],
        ),
        content: ConstrainedBox(
          constraints: AdaptiveDialogConstraints.hybrid(
            ctx,
            designMaxWidth: 520,
            designMaxHeight: 440,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Importing this file would create a sequence with '
                  '${errors.length} blocking '
                  'error${errors.length == 1 ? '' : 's'}. Some features may '
                  "not work until you fix them.",
                  style: TextStyle(
                      fontSize: SkotiqTypography.fontSize13,
                      color: colors.textPrimary),
                ),
                const SizedBox(height: 12),
                if (errors.isNotEmpty) ...[
                  Text('Errors',
                      style: SkotiqTypography.h6
                          .copyWith(color: colors.error)),
                  const SizedBox(height: 4),
                  for (final issue in errors)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('- ${issue.title}',
                              style: SkotiqTypography.labelSm
                                  .copyWith(color: colors.textPrimary)),
                          Padding(
                            padding: const EdgeInsets.only(left: 12),
                            child: Text(issue.description,
                                style: TextStyle(
                                    fontSize: SkotiqTypography.fontSize11,
                                    color: colors.textSecondary)),
                          ),
                          if (issue.resolutionHint != null)
                            Padding(
                              padding: const EdgeInsets.only(left: 12),
                              child: Text('Fix: ${issue.resolutionHint!}',
                                  style: TextStyle(
                                      fontSize: SkotiqTypography.fontSize11,
                                      color: colors.textMuted,
                                      fontStyle: FontStyle.italic)),
                            ),
                        ],
                      ),
                    ),
                ],
                if (warnings.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('Warnings',
                      style: SkotiqTypography.h6
                          .copyWith(color: colors.warning)),
                  const SizedBox(height: 4),
                  for (final issue in warnings)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Text('- ${issue.title}: ${issue.description}',
                          style: TextStyle(
                              fontSize: SkotiqTypography.fontSize11,
                              color: colors.textSecondary)),
                    ),
                ],
                if (infos.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text('Info',
                      style:
                          SkotiqTypography.h6.copyWith(color: colors.info)),
                  const SizedBox(height: 4),
                  for (final issue in infos)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Text('- ${issue.title}',
                          style: TextStyle(
                              fontSize: SkotiqTypography.fontSize11,
                              color: colors.textMuted)),
                    ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Import anyway'),
          ),
        ],
      ),
    );
  }

  /// Astrobin imports need catalog lookup, so we call the dedicated async
  /// entrypoint. The wrapper handles the same typed-exception ladder as
  /// [_parseWithRetry]. After parsing, if some designations failed to
  /// resolve, we surface a brief snackbar mentioning the count so the user
  /// knows to fill in coordinates manually.
  static Future<ImportResult?> _importAstrobinWithRetry(
    BuildContext context,
    SequenceImporter importer,
    String content,
    String defaultName, {
    bool forceUnsupported = false,
    bool forceImport = false,
  }) async {
    try {
      final summary = await importer.importAstrobinAsync(
        content,
        forceUnsupported: forceUnsupported,
        forceImport: forceImport,
        sequenceName: defaultName,
      );
      if (summary.unresolved.isNotEmpty && context.mounted) {
        final n = summary.unresolved.length;
        final word = n == 1 ? 'designation' : 'designations';
        context.showSuccessSnackBar(
          'Astrobin: ${summary.resolvedRows} resolved, $n $word need '
          'manual coordinates (placeholders inserted).',
        );
      }
      return summary.importResult;
    } on UnknownFormatError catch (e) {
      if (context.mounted) {
        context.showErrorSnackBar(
            'Could not identify Astrobin file: ${e.message}');
      }
      return null;
    } on MalformedSourceError catch (e) {
      if (context.mounted) {
        context.showErrorSnackBar('Astrobin file is malformed: ${e.message}');
      }
      return null;
    } on UnsupportedNodeError catch (e) {
      if (!context.mounted) return null;
      final force = await _confirmForceImport(context, e.unsupported);
      if (force != true) return null;
      if (!context.mounted) return null;
      return _importAstrobinWithRetry(
        context,
        importer,
        content,
        defaultName,
        forceUnsupported: true,
        forceImport: forceImport,
      );
    } on SequenceImportValidationFailedException catch (e) {
      if (!context.mounted) return null;
      final accept = await _confirmForceValidation(context, e);
      if (accept != true) return null;
      if (!context.mounted) return null;
      return _importAstrobinWithRetry(
        context,
        importer,
        content,
        defaultName,
        forceUnsupported: forceUnsupported,
        forceImport: true,
      );
    }
  }

  /// ICS imports surface unresolved VEVENTs (no RA/Dec parsable from
  /// description) the same way Astrobin handles unresolved designations.
  static Future<ImportResult?> _importIcsWithRetry(
    BuildContext context,
    SequenceImporter importer,
    String content,
    String defaultName, {
    bool forceUnsupported = false,
    bool forceImport = false,
  }) async {
    try {
      final summary = await importer.importIcsAsync(
        content,
        forceUnsupported: forceUnsupported,
        forceImport: forceImport,
        sequenceName: defaultName,
      );
      if (summary.unresolved.isNotEmpty && context.mounted) {
        final n = summary.unresolved.length;
        context.showSuccessSnackBar(
          'Calendar: ${summary.totalEvents - n} events parsed, '
          '$n event${n == 1 ? '' : 's'} had no RA/Dec and '
          '${n == 1 ? 'was' : 'were'} skipped.',
        );
      }
      return summary.importResult;
    } on UnknownFormatError catch (e) {
      if (context.mounted) {
        context.showErrorSnackBar(
            'Could not identify calendar file: ${e.message}');
      }
      return null;
    } on MalformedSourceError catch (e) {
      if (context.mounted) {
        context.showErrorSnackBar('Calendar file is malformed: ${e.message}');
      }
      return null;
    } on UnsupportedNodeError catch (e) {
      if (!context.mounted) return null;
      final force = await _confirmForceImport(context, e.unsupported);
      if (force != true) return null;
      if (!context.mounted) return null;
      return _importIcsWithRetry(
        context,
        importer,
        content,
        defaultName,
        forceUnsupported: true,
        forceImport: forceImport,
      );
    } on SequenceImportValidationFailedException catch (e) {
      if (!context.mounted) return null;
      final accept = await _confirmForceValidation(context, e);
      if (accept != true) return null;
      if (!context.mounted) return null;
      return _importIcsWithRetry(
        context,
        importer,
        content,
        defaultName,
        forceUnsupported: forceUnsupported,
        forceImport: true,
      );
    }
  }

  /// Loads [sequence] into the editor via `loadSequence`. If the editor
  /// has unsaved edits, prompts the user before discarding them. Returns
  /// `true` on success, `false` if the user cancelled.
  static Future<bool> _loadSequenceWithDirtyCheck(
      BuildContext context, WidgetRef ref, Sequence sequence,
      {bool discardUnsaved = false,
      required SkotiqBackend authority}) async {
    final editor = ref.read(currentSequenceProvider.notifier);
    try {
      editor.loadSequence(sequence, discardUnsaved: discardUnsaved);
      return true;
    } on UnsavedChangesException catch (e) {
      if (!context.mounted) return false;
      final confirmed = await _confirmDiscardUnsaved(context, e);
      if (confirmed != true) return false;
      if (!context.mounted) return false;
      if (!_requireCurrentAuthority(context, ref, authority)) return false;
      editor.loadSequence(sequence, discardUnsaved: true);
      return true;
    } on SequenceLockedException catch (e) {
      if (context.mounted) {
        context
            .showErrorSnackBar('Cannot open imported sequence: ${e.message}');
      }
      return false;
    }
  }

  static Future<bool?> _confirmDiscardUnsaved(
    BuildContext context,
    UnsavedChangesException error,
  ) {
    final colors = SkotiqColors.of(context);
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Row(
          children: [
            Icon(LucideIcons.fileWarning, color: colors.warning, size: 18),
            const SizedBox(width: 8),
            const Text('Discard unsaved changes?'),
          ],
        ),
        content: ConstrainedBox(
          constraints: AdaptiveDialogConstraints.hybrid(
            ctx,
            designMaxWidth: 440,
          ),
          child: Text(
            '"${error.currentSequenceName}" has unsaved changes. Opening the '
            'imported sequence will discard them.',
            style: TextStyle(
                fontSize: SkotiqTypography.fontSize13,
                color: colors.textPrimary),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Discard and open'),
          ),
        ],
      ),
    );
  }

  /// Build a human-readable summary of nodes dropped during import, for
  /// persisting into the sequence description. Returns an empty string
  /// when nothing is dropped. [ImportResult.droppedNodes] already
  /// includes unsupported nodes (re-filed with [DropReason.unsupported]),
  /// so we summarize that single list to avoid double-counting.
  static String _buildDroppedNodesSummary(ImportResult result) {
    final dropped = result.droppedNodes;
    if (dropped.isEmpty) return '';
    final fmt = result.sourceFormat.displayName;
    final buffer = StringBuffer(
      'Imported from $fmt: dropped ${dropped.length} '
      'node${dropped.length == 1 ? '' : 's'} with no Skotiq equivalent:',
    );
    for (final d in dropped.take(20)) {
      buffer.write('\n- ${d.sourceType} "${d.name}" (${d.reason.name})');
    }
    if (dropped.length > 20) {
      buffer.write('\n- ... and ${dropped.length - 20} more');
    }
    return buffer.toString();
  }

  static String _basename(String path) {
    final lastSep = path.lastIndexOf(RegExp(r'[\\/]'));
    final base = lastSep >= 0 ? path.substring(lastSep + 1) : path;
    final dot = base.lastIndexOf('.');
    return dot > 0 ? base.substring(0, dot) : base;
  }

  static bool _requireCurrentAuthority(
    BuildContext context,
    WidgetRef ref,
    SkotiqBackend authority,
  ) {
    if (!context.mounted) return false;
    if (identical(ref.read(backendProvider), authority)) return true;
    context.showWarningSnackBar(
      'The imaging host changed while importing that sequence. Import it '
      'again for the current host.',
    );
    return false;
  }

  static Future<bool?> _confirmForceImport(
    BuildContext context,
    List<UnsupportedNodeRecord> unsupported,
  ) {
    final colors = SkotiqColors.of(context);
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Row(
          children: [
            Icon(LucideIcons.alertTriangle, color: colors.warning, size: 18),
            const SizedBox(width: 8),
            const Text('Unsupported nodes'),
          ],
        ),
        content: ConstrainedBox(
          constraints: AdaptiveDialogConstraints.hybrid(
            ctx,
            designMaxWidth: 480,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'This file uses ${unsupported.length} node '
                'type${unsupported.length == 1 ? '' : 's'} Skotiq '
                "doesn't support. Importing them as-is would leave your "
                'sequence incomplete.',
                style: TextStyle(
                    fontSize: SkotiqTypography.fontSize13,
                    color: colors.textPrimary),
              ),
              const SizedBox(height: 8),
              for (final u in unsupported.take(8))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Text('- ${u.sourceType} - ${u.name}',
                      style: TextStyle(
                          fontSize: SkotiqTypography.fontSize12,
                          color: colors.textSecondary)),
                ),
              if (unsupported.length > 8)
                Text('  ... and ${unsupported.length - 8} more',
                    style: TextStyle(
                        fontSize: SkotiqTypography.fontSize12,
                        color: colors.textMuted)),
              const SizedBox(height: 12),
              Text(
                'You can force-import anyway. Unsupported nodes will be '
                'dropped and listed in the summary so you can re-create them '
                'manually.',
                style: TextStyle(
                    fontSize: SkotiqTypography.fontSize12,
                    color: colors.textMuted),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Force import'),
          ),
        ],
      ),
    );
  }
}
