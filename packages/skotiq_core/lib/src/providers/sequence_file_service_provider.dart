import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'sequence_provider.dart' show currentSequenceProvider;
import 'settings_provider.dart';
import '../services/sequence_file_service.dart';

/// Provider for the sequence file service.
///
/// An opened file is not refused for naming filters the active profile lacks:
/// it loads, and the sequence checks flag those nodes ("Filter Not in Wheel")
/// so they can be renamed in the editor, as for a starter.
final sequenceFileServiceProvider = Provider<SequenceFileService>((ref) {
  return SequenceFileService(
    // Read at dialog-open time so changing Settings → File Paths → Sequences
    // takes effect immediately without rebuilding every service dependent.
    defaultDirectoryProvider: () {
      try {
        return ref.read(appSettingsProvider).valueOrNull?.sequencesPath ?? '';
      } catch (_) {
        // Unit tests may construct the service without a settings database.
        return '';
      }
    },
    onExportSaved: (exported) {
      // Reach into the sequence editor and clear the dirty flag. The
      // export wrote the canonical bytes for the in-memory sequence, so
      // any subsequent createSequence/loadSequence should no longer
      // prompt "discard unsaved changes?" — the user just saved.
      //
      // Read (not watch) — this is a one-shot side effect inside an
      // async write path, not a reactive subscription.
      try {
        final editor = ref.read(currentSequenceProvider.notifier);
        editor.markSavedIfCurrent(exported);
      } catch (_) {
        // Tests may construct this provider without the sequence
        // notifier. Failing silent is acceptable here because the
        // editor is the only place that cares about the flag — a missing
        // notifier means there's no editor to dirty.
      }
    },
  );
});
