import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/sequence/active_plan_owner.dart';
import '../models/sequence/sequence_models.dart';
import 'backend_provider.dart';
import 'database_provider.dart';
import 'sequence_provider.dart';
import '../services/open_plan_service.dart';

/// Keeps the plan open in the editor in the settings store, saved or not, so
/// a restart (an update, a crash, a reboot of the rig) brings the same plan
/// back. On a host only: a linked client shows the host's plan and follows it
/// again when it reconnects.
final openPlanLifecycleProvider = Provider<void>((ref) {
  if (ref.watch(isRemoteModeProvider)) return;
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
