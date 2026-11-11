import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/remote_host.dart';
import '../models/sequence/active_plan_owner.dart';
import '../models/sequence/sequence_models.dart';
import '../providers/backend_provider.dart';
import '../providers/database_provider.dart';
import '../providers/sequence_provider.dart';
import 'sequence_file_service.dart';
import 'sequence_repository.dart';

/// Settings key holding the plan open in the editor: its document, the saved
/// plan it belongs to, and whether it has unsaved changes.
const String kOpenPlanKey = 'editor.open_plan';

/// Where builds before the open plan was kept wrote an unsaved plan. Read
/// once at restore, then cleared.
const String kLegacyEditorDraftKey = 'editor.unsaved_draft';

/// How often the open plan is compared with what was last written. Edits are
/// also written shortly after they are made; this catches what changes
/// without an edit (a save clears the unsaved flag).
const Duration kOpenPlanInterval = Duration(seconds: 10);

/// How long after an edit the open plan is written.
const Duration kOpenPlanDebounce = Duration(seconds: 1);

/// True once this process has decided what to do with the plan a previous
/// run left open ([restoreOpenPlan]). Nothing is written before that: an
/// editor that is still empty at launch would otherwise erase the plan it is
/// about to get back.
final openPlanRestoreDecidedProvider = StateProvider<bool>((ref) => false);

/// Keeps the plan open in the editor in the settings store, saved or not, so
/// a restart (an update, a crash, a reboot of the rig) brings the same plan
/// back. On a host only: a linked client shows the host's plan and follows it
/// again when it reconnects.
final openPlanLifecycleProvider = Provider<void>((ref) {
  if (ref.watch(backendProvider).remoteHost != null) return;
  String? written;
  Future<void> persist() async {
    if (!ref.read(openPlanRestoreDecidedProvider)) return;
    // A plan the scheduler or a mosaic put in the editor is theirs to bring
    // back; the operator's own plan is what is kept.
    if (ref.read(activePlanOwnerProvider) != ActivePlanOwner.manual) return;
    final document = openPlanJson(ref.read) ?? '';
    if (document == written) return;
    final dao = ref.read(settingsDaoProvider);
    written ??= await dao.getSetting(kOpenPlanKey) ?? '';
    if (document == written) return;
    await dao.setSetting(kOpenPlanKey, document);
    written = document;
  }

  void persistQuietly() => unawaited(persist().catchError((Object _) {}));

  Timer? debounce;
  ref.listen<Sequence?>(currentSequenceProvider, (_, _) {
    debounce?.cancel();
    debounce = Timer(kOpenPlanDebounce, persistQuietly);
  });
  ref.listen<bool>(openPlanRestoreDecidedProvider, (_, decided) {
    if (decided) persistQuietly();
  });
  final timer = Timer.periodic(kOpenPlanInterval, (_) => persistQuietly());
  ref.onDispose(() {
    timer.cancel();
    debounce?.cancel();
  });
});

/// The plan open in the editor as the document to keep, or null when no plan
/// is open. The same shape `/api/sequencer/editor-sequence` carries.
String? openPlanJson(T Function<T>(ProviderListenable<T>) read) {
  final sequence = read(currentSequenceProvider);
  if (sequence == null) return null;
  return jsonEncode({
    'sequence': read(sequenceFileServiceProvider).sequenceToMap(sequence),
    if (sequence.databaseId != null) 'databaseId': sequence.databaseId,
    'isDirty': read(currentSequenceProvider.notifier).isDirty,
  });
}

/// A plan [restoreOpenPlan] put back in the editor.
typedef RestoredOpenPlan = ({Sequence sequence, bool unsaved});

/// Puts back the plan that was open when Skotiq last stopped, when the editor
/// is empty. Returns it, or null when there was nothing to restore.
///
/// A plan that had unsaved changes comes back unsaved. A saved plan comes
/// back as the library holds it now; if it has since been deleted there, the
/// kept copy comes back as an unsaved plan, so it is not lost.
///
/// Call it once per launch on a host, after anything that may load a plan of
/// its own (the checkpoint prompt). The open plan starts being kept only
/// after this has run.
Future<RestoredOpenPlan?> restoreOpenPlan(
  T Function<T>(ProviderListenable<T>) read,
) async {
  if (read(backendProvider).remoteHost != null) return null;
  try {
    if (read(currentSequenceProvider) != null) return null;
    final kept = await _keptPlan(read);
    if (kept == null || read(currentSequenceProvider) != null) return null;
    read(
      currentSequenceProvider.notifier,
    ).applyPeerEdit(kept.sequence, dirty: kept.unsaved);
    return kept;
  } finally {
    read(openPlanRestoreDecidedProvider.notifier).state = true;
  }
}

Future<RestoredOpenPlan?> _keptPlan(
  T Function<T>(ProviderListenable<T>) read,
) async {
  final dao = read(settingsDaoProvider);
  final files = read(sequenceFileServiceProvider);

  final raw = await dao.getSetting(kOpenPlanKey);
  if (raw == null || raw.isEmpty) {
    final legacy = await dao.getSetting(kLegacyEditorDraftKey);
    if (legacy == null || legacy.isEmpty) return null;
    await dao.setSetting(kLegacyEditorDraftKey, '');
    try {
      return (
        sequence: files.parseFromMap(
          jsonDecode(legacy) as Map<String, dynamic>,
        ),
        unsaved: true,
      );
    } catch (_) {
      return null;
    }
  }

  final Sequence kept;
  final bool unsaved;
  final int? databaseId;
  try {
    final document = jsonDecode(raw) as Map<String, dynamic>;
    databaseId = document['databaseId'] as int?;
    unsaved = document['isDirty'] as bool? ?? false;
    kept = files
        .parseFromMap(Map<String, dynamic>.from(document['sequence'] as Map))
        .copyWith(databaseId: databaseId);
  } catch (_) {
    // A document that no longer reads is dropped rather than tried forever.
    await dao.setSetting(kOpenPlanKey, '');
    return null;
  }
  if (unsaved || databaseId == null) return (sequence: kept, unsaved: true);

  final Sequence? saved;
  try {
    saved = await read(sequenceRepositoryProvider).loadSequence(databaseId);
  } catch (_) {
    return (sequence: kept, unsaved: false);
  }
  if (saved != null) return (sequence: saved, unsaved: false);
  // Deleted from the library since: what was open is all that is left of it.
  return (sequence: kept.copyWith(databaseId: null), unsaved: true);
}
