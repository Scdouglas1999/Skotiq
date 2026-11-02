import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/network_backend.dart';
import '../models/sequence/sequence_models.dart';
import '../providers/backend_provider.dart';
import '../providers/database_provider.dart';
import '../providers/sequence_provider.dart';
import 'sequence_file_service.dart';

/// Settings key holding the plan being edited while it has unsaved changes.
const String kEditorDraftKey = 'editor.unsaved_draft';

/// How often the unsaved plan is written down.
const Duration kEditorDraftInterval = Duration(seconds: 10);

/// Keeps the plan open in the Builder, while it has unsaved changes, in the
/// settings store, and clears it once the plan is saved or closed. A crash or
/// a killed process then costs at most the last few seconds of editing, not
/// the plan. A remote client keeps no draft: the host holds its plan.
final editorDraftLifecycleProvider = Provider<void>((ref) {
  if (ref.watch(backendProvider) is NetworkBackend) return;
  String? written;
  Future<void> persist() async {
    final draft = editorDraftJson(ref.read);
    if (draft == written) return;
    final dao = ref.read(settingsDaoProvider);
    await dao.setSetting(kEditorDraftKey, draft ?? '');
    written = draft;
  }

  final timer = Timer.periodic(kEditorDraftInterval, (_) {
    unawaited(persist().catchError((Object _) {}));
  });
  ref.onDispose(timer.cancel);
});

/// The draft to keep for the editor right now: the open plan as JSON while it
/// has unsaved changes, otherwise null.
String? editorDraftJson(T Function<T>(ProviderListenable<T>) read) {
  final sequence = read(currentSequenceProvider);
  if (sequence == null || !read(currentSequenceProvider.notifier).isDirty) {
    return null;
  }
  return jsonEncode(read(sequenceFileServiceProvider).sequenceToMap(sequence));
}

/// Put back the unsaved plan a previous session left, when the Builder is
/// empty. Returns the restored plan, or null when there was nothing to
/// restore. The restored plan stays unsaved.
Future<Sequence?> restoreEditorDraft(
  T Function<T>(ProviderListenable<T>) read,
) async {
  if (read(backendProvider) is NetworkBackend) return null;
  if (read(currentSequenceProvider) != null) return null;
  final dao = read(settingsDaoProvider);
  final raw = await dao.getSetting(kEditorDraftKey);
  if (raw == null || raw.isEmpty) return null;
  try {
    final sequence = read(
      sequenceFileServiceProvider,
    ).parseFromMap(jsonDecode(raw) as Map<String, dynamic>);
    if (read(currentSequenceProvider) != null) return null;
    read(currentSequenceProvider.notifier).applyPeerEdit(sequence, dirty: true);
    return sequence;
  } catch (_) {
    // A draft that no longer reads is dropped rather than offered forever.
    await dao.setSetting(kEditorDraftKey, '');
    return null;
  }
}
