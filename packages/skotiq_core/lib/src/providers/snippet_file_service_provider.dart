import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'settings_provider.dart';
import '../services/snippet_file_service.dart';

/// Provider for the snippet file service.
///
/// Resolves the default directory from `Settings → File Paths →
/// Sequences` so snippet exports/imports land beside sequence files by
/// default. Falls back to the OS-picked default when settings are
/// unavailable (e.g. in unit tests with no database).
final snippetFileServiceProvider = Provider<SnippetFileService>((ref) {
  String defaultDir = '';
  try {
    final settings = ref.read(appSettingsProvider).valueOrNull;
    defaultDir = settings?.sequencesPath ?? '';
  } catch (_) {
    defaultDir = '';
  }
  return SnippetFileService(defaultDirectory: defaultDir);
});
