import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../backend/remote_host.dart';
import '../../../models/sequence/active_plan_owner.dart';
import '../../../models/sequence/sequence_models.dart';
import '../../../services/open_plan_service.dart';
import '../../../services/sequence_file_service.dart';
import '../../backend_provider.dart';
import '../../sequence/remote_sequence_editor_sync.dart';
import '../../sequence_provider.dart';
import '../../ui_notification_provider.dart';
import '../runtime_mirror_channel.dart';
import '../../sequence_file_service_provider.dart';

/// The plan open in the editor, with what a document of it needs.
typedef OpenPlan = ({
  Sequence? sequence,
  bool unsaved,
  ActivePlanOwner owner,
  SequenceFileService files,
});

final openPlanProvider = Provider<OpenPlan>(
  (ref) => (
    sequence: ref.watch(currentSequenceProvider),
    unsaved: ref.watch(sequenceHasUnsavedChangesProvider),
    owner: ref.watch(activePlanOwnerProvider),
    files: ref.watch(sequenceFileServiceProvider),
  ),
);

/// The plan open in the host's editor, saved or not, and who owns it.
///
/// A client shows the host's plan from the moment it links and follows every
/// change, whoever made it: the host's operator, an automated planner, or
/// another client. A client's own edits go to the host as a command
/// (`remoteSequenceEditorSyncProvider`), which the host can refuse while a
/// run holds the plan; the two edit one plan and the last writer wins.
class OpenPlanChannel extends RuntimeMirrorChannel<OpenPlan> {
  const OpenPlanChannel();

  @override
  String get key => 'openPlan';

  @override
  get source => openPlanProvider;

  /// One document for a burst of edits.
  @override
  Duration get minInterval => const Duration(milliseconds: 400);

  /// A write the host refused leaves this client showing a plan the host
  /// does not hold; the next re-read shows the host's again.
  @override
  bool get reappliesOnReread => true;

  @override
  Map<String, dynamic>? encode(OpenPlan value) {
    final sequence = value.sequence;
    if (sequence == null) return null;
    return openPlanDocument(
      value.files,
      sequence,
      unsaved: value.unsaved,
      owner: value.owner,
    );
  }

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    if (context.networkBackend == null) return;
    final editor = context.read(currentSequenceProvider.notifier);
    final sync = context.read(remoteEditorSyncStateProvider);
    final files = context.read(sequenceFileServiceProvider);
    final current = context.read(currentSequenceProvider);

    Sequence? incoming;
    if (value != null) {
      final document = value['sequence'];
      if (document is! Map) {
        throw const FormatException('Open plan without a sequence');
      }
      try {
        incoming = files.parseFromMap(Map<String, dynamic>.from(document));
      } on Object catch (e) {
        throw FormatException('Open plan could not be read: $e');
      }
      final databaseId = value['databaseId'];
      if (databaseId is int) {
        incoming = incoming.copyWith(databaseId: databaseId);
      }
    }
    final incomingFingerprint = sequenceFingerprint(files, incoming);
    final currentFingerprint = sequenceFingerprint(files, current);

    // While a run holds the editor the host's running plan is shown, so a
    // client that joined mid-run sees what is running.
    if (!editor.isEditableNow) {
      if (incoming == null || incomingFingerprint == currentFingerprint) return;
      sync.appliedFromHost = incoming;
      sync.hostFingerprint = incomingFingerprint;
      editor.showHostRunningSequence(incoming);
      editor.adoptOwner(ActivePlanOwnerWire.fromWire(value?['activePlanOwner']));
      return;
    }

    // Unsaved edits the host has not seen yet are on their way to it, and
    // replace its plan when they land.
    final holdsUnsentEdits =
        editor.isDirty &&
        currentFingerprint != sync.lastWrittenFingerprint &&
        currentFingerprint != sync.hostFingerprint;
    if (sync.writePending || holdsUnsentEdits) return;

    final owner = incoming == null
        ? ActivePlanOwner.manual
        : ActivePlanOwnerWire.fromWire(value?['activePlanOwner']);
    sync.hostFingerprint = incomingFingerprint;
    // The plan already shown is not loaded again, so selection and undo
    // survive.
    if (incomingFingerprint == currentFingerprint) {
      editor.adoptOwner(owner);
      return;
    }

    final replacesOwnWrite =
        current != null && currentFingerprint == sync.lastWrittenFingerprint;
    sync.appliedFromHost = incoming;
    // Clean here: the host's unsaved flag is the host's to act on, and a
    // dirty plan here would be saved to the library by this client.
    editor.applyPeerEdit(incoming, dirty: false);
    editor.adoptOwner(owner);
    if (replacesOwnWrite && incoming != null) {
      final host =
          context.read(backendProvider).remoteHost?.link.serverHost ??
          'the host';
      context
          .read(uiNotificationProvider.notifier)
          .showInfo(
            'The plan was changed on $host after your last edit; showing its '
            'version.',
            title: 'Plan updated',
          );
    }
  }
}
