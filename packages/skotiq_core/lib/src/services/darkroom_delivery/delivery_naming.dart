/// The rig identity every delivered file name carries.
///
/// Delivery preserves the rig's own file name, and the rig's own file name is
/// not unique across rigs: two installs that image the same night write
/// `job_1_report.json`, `job_1_master_1_draft.jpg` and a `session_L_master_*`
/// per filter, and the job counter on each rig starts at 1. Point both at one
/// NAS share or one SFTP incoming directory and the second rig's file finds the
/// first rig's file already sitting at that name with different bytes. Delivery
/// copies and never overwrites, so the second rig's night is refused with
/// [DeliveryFailureKind.destinationConflict] — terminal, and no later attempt
/// changes it.
///
/// The fix is a rig-identity component on the delivered name:
/// `<rigId>-<the rig's own file name>`.
///
/// **Why a name prefix and not a per-rig subdirectory.** A subdirectory would
/// have to be created, and neither transport is allowed to create one: a
/// watched folder treats a missing directory as an unmounted share precisely so
/// it never fills the boot drive, and the SFTP batch is the exact command set a
/// real sshd validated. A prefix needs no new operation on any transport.
///
/// **Config (`delivery_targets.config_json`).** The optional key `rigId` is the
/// per-destination override:
///
/// ```json
/// {"path": "/mnt/nas/skotiq", "rigId": "shed-rig"}
/// ```
///
///   * absent — the component is this host's name, sanitized. One rig per host
///     is the identity that is true without anybody configuring anything.
///   * a name — that name, sanitized, is the component. This is what two rigs
///     on one host, or a rig whose host name is not what the operator calls it,
///     set.
///   * `""` — no component at all, and delivered names are exactly the rig's
///     own. The opt-out for a single-rig folder whose downstream scripts match
///     on the bare names.
///
/// **What this does to a folder that is already in use.** Nothing already
/// delivered is touched or renamed — delivery copies. Only deliveries made from
/// here on carry the component, so a folder holding both is a folder holding
/// last night's bare names beside tonight's namespaced ones. One consequence is
/// worth naming: a journal row written before this and retried after it looks
/// for the namespaced name, does not find the bare copy it already landed, and
/// delivers a second copy under the new name. That is a duplicate file, never a
/// lost or overwritten one.
library;

import 'dart:io';

import '../../models/darkroom/delivery.dart';
import 'delivery_failure.dart';

/// `config_json` key naming this destination's rig-identity component.
const String kDeliveryRigIdKey = 'rigId';

/// How one destination names the files it receives.
class DeliveryNaming {
  /// The rig-identity component, already reduced to name-safe characters.
  /// Empty when the destination asked for no component.
  final String rigId;

  const DeliveryNaming(this.rigId);

  /// Read the naming [config] describes.
  ///
  /// Throws [DeliveryFailure] with [DeliveryFailureKind.configurationInvalid]
  /// when `rigId` is present but is not a string, and when it is absent and
  /// this host cannot say what it is called. Neither is guessed at: a delivery
  /// that silently dropped the component would put this rig's files back on a
  /// collision course with the other rig's.
  static DeliveryNaming of(Map<String, Object?> config) {
    if (!config.containsKey(kDeliveryRigIdKey)) {
      return DeliveryNaming(_hostRigId());
    }
    final configured = config[kDeliveryRigIdKey];
    if (configured is! String) {
      throw DeliveryFailure(
        DeliveryFailureKind.configurationInvalid,
        '"$kDeliveryRigIdKey" on this destination is $configured, which is not '
        'a name. Give it the rig\'s name, or "" to deliver under the file '
        'names the rig writes',
      );
    }
    return DeliveryNaming(sanitizeRigId(configured));
  }

  /// The naming [destination]'s `config_json` describes.
  ///
  /// For the callers that hold the row rather than the decoded map — the peer
  /// manifest, which names files it never writes itself.
  static DeliveryNaming forDestination(ArtifactDestination destination) {
    return of(
      decodeDeliveryConfig(
        destination,
        what: '${destination.kind.wire} destination',
      ),
    );
  }

  /// The name [sourceFileName] is written under on this destination.
  String nameFor(String sourceFileName) =>
      rigId.isEmpty ? sourceFileName : '$rigId-$sourceFileName';

  /// This host's name as a delivered-name component.
  static String _hostRigId() {
    final String host;
    try {
      host = Platform.localHostname;
    } on OSError catch (error) {
      throw DeliveryFailure(
        DeliveryFailureKind.configurationInvalid,
        'This host\'s name could not be read (${error.message}), so a '
        'delivered file cannot say which rig wrote it. Set '
        '"$kDeliveryRigIdKey" on this destination to name the rig, or "" to '
        'deliver under the file names the rig writes',
        cause: error,
      );
    }
    final sanitized = sanitizeRigId(host);
    if (sanitized.isEmpty) {
      throw const DeliveryFailure(
        DeliveryFailureKind.configurationInvalid,
        'This host reports an empty name, so a delivered file cannot say '
        'which rig wrote it. Set "$kDeliveryRigIdKey" on this destination to '
        'name the rig, or "" to deliver under the file names the rig writes',
      );
    }
    return sanitized;
  }
}

/// [raw] reduced to the characters a file name carries on every filesystem
/// Skotiq delivers to.
///
/// The character class is the one `SyncService.sanitizeMachineName` already
/// applies to the same identity when it becomes a remote directory name; the
/// empty answer differs on purpose, because here an empty component is the
/// documented opt-out rather than a name to substitute for.
String sanitizeRigId(String raw) =>
    raw.trim().replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');
