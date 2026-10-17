/// Where the night's artifacts are delivered, and what happened to each file.
///
/// [ArtifactDestination] maps 1:1 to a row of the raw-DDL `delivery_targets`
/// table and [DeliveryJournalEntry] to a row of `delivery_journal` (see
/// `SkotiqDatabase._createDarkroomTables`); both are read/written through
/// the plain [DeliveryTargetsDao] / [DeliveryJournalDao].
///
/// Naming: `PushDeliveryTargets` in `skotiq_remote_protocol` is a
/// phone-reachability struct for FCM/APNs NOTIFICATIONS. This type is about
/// moving FILES, so it is a destination, not a push target.
library;

import 'dart:convert';

import 'recipe.dart' show DarkroomWireFormatException;

/// Transport an [ArtifactDestination] delivers over.
///
/// Stored as the wire string in `delivery_targets.kind`, constrained by a
/// `CHECK` on the column.
enum ArtifactDestinationKind {
  /// Any local or already-mounted path — the NAS/SMB/NFS case the OS has
  /// already solved.
  watchedFolder('watched_folder'),

  /// SFTP over SSH to a host the rig can reach.
  sftp('sftp'),

  /// Another Skotiq install. The remote protocol serves artifacts by GET
  /// only, so this destination is pulled by the paired desktop from a manifest
  /// the rig publishes; the rig never uploads to a peer.
  peer('peer');

  const ArtifactDestinationKind(this.wire);

  /// The wire string stored in the DB.
  final String wire;

  /// Parse a stored kind string, throwing [DarkroomWireFormatException] on a
  /// value outside the column's `CHECK` constraint.
  static ArtifactDestinationKind fromWire(String? value) {
    switch (value) {
      case 'watched_folder':
        return ArtifactDestinationKind.watchedFolder;
      case 'sftp':
        return ArtifactDestinationKind.sftp;
      case 'peer':
        return ArtifactDestinationKind.peer;
      default:
        throw DarkroomWireFormatException('delivery_targets.kind', value);
    }
  }
}

/// One class of artifact a destination may be selected to receive.
///
/// The per-destination selection is stored as a JSON array of these wire
/// strings in `delivery_targets.content_json`, always written in enum
/// declaration order so the same selection serializes to the same bytes.
enum ArtifactContent {
  /// The per-filter linear master FITS — the irreplaceable data-half output.
  linearMasters('linear_masters'),

  /// The rendered first-draft image.
  draftRender('draft_render'),

  /// FITS rendered at an intermediate recipe step.
  stageExports('stage_exports'),

  /// The night report.
  nightReport('night_report');

  const ArtifactContent(this.wire);

  /// The wire string stored inside `content_json`.
  final String wire;

  /// Parse one stored content string, throwing [DarkroomWireFormatException]
  /// on an unknown value.
  static ArtifactContent fromWire(String? value) {
    switch (value) {
      case 'linear_masters':
        return ArtifactContent.linearMasters;
      case 'draft_render':
        return ArtifactContent.draftRender;
      case 'stage_exports':
        return ArtifactContent.stageExports;
      case 'night_report':
        return ArtifactContent.nightReport;
      default:
        throw DarkroomWireFormatException(
          'delivery_targets.content_json',
          value,
        );
    }
  }

  /// Serialize a selection in enum declaration order, so a given set always
  /// produces identical bytes regardless of how the caller built it.
  static String encodeSelection(Set<ArtifactContent> selection) {
    final ordered = ArtifactContent.values
        .where(selection.contains)
        .map((c) => c.wire)
        .toList(growable: false);
    return jsonEncode(ordered);
  }

  /// Parse a stored `content_json` array.
  ///
  /// Throws [FormatException] when the column does not hold a JSON array, and
  /// [DarkroomWireFormatException] when it holds an unknown member.
  static Set<ArtifactContent> decodeSelection(String contentJson) {
    final decoded = jsonDecode(contentJson);
    if (decoded is! List) {
      throw FormatException(
        'delivery_targets.content_json must be a JSON array',
        contentJson,
      );
    }
    return decoded
        .map((entry) => ArtifactContent.fromWire(entry as String?))
        .toSet();
  }
}

/// Outcome of one file's delivery to one destination.
///
/// Stored as the wire string in `delivery_journal.state`, constrained by a
/// `CHECK` on the column.
enum DeliveryAttemptState {
  /// The file arrived and its checksum verified.
  delivered,

  /// Every attempt is spent; the file did not arrive.
  failed,

  /// In flight, or waiting for the next backoff window.
  retrying;

  /// The lowercase wire string stored in the DB.
  String get wire => name;

  /// True for a state no further attempt changes.
  bool get isTerminal =>
      this == DeliveryAttemptState.delivered ||
      this == DeliveryAttemptState.failed;

  /// Parse a stored state string, throwing [DarkroomWireFormatException] on a
  /// value outside the column's `CHECK` constraint.
  static DeliveryAttemptState fromWire(String? value) {
    switch (value) {
      case 'delivered':
        return DeliveryAttemptState.delivered;
      case 'failed':
        return DeliveryAttemptState.failed;
      case 'retrying':
        return DeliveryAttemptState.retrying;
      default:
        throw DarkroomWireFormatException('delivery_journal.state', value);
    }
  }
}

/// A destination config carried something that belongs in the keyring.
class DeliveryConfigSecretException implements Exception {
  /// The offending JSON keys, sorted, so the message is identical for the same
  /// config regardless of key order.
  final List<String> keys;

  const DeliveryConfigSecretException(this.keys);

  @override
  String toString() =>
      'delivery_targets.config_json may not carry key material '
      '(${keys.join(', ')}); store it in SecretsStore and reference it from '
      'secret_ref.';
}

/// Substrings that mark a JSON key as key material. Checked case-insensitively
/// against every key in a destination config. Order is fixed so the scan is
/// deterministic.
const List<String> kSecretKeyMarkers = <String>[
  'apikey',
  'api_key',
  'credential',
  'passphrase',
  'password',
  'privatekey',
  'private_key',
  'secret',
  'token',
];

/// Throw [DeliveryConfigSecretException] when [configJson] carries key
/// material anywhere in its object graph.
///
/// Key material belongs in `SecretsStore` (`services/notification/
/// secrets_store.dart`) — the keyring-backed store that already holds the
/// WebDAV password, the S3 secret key, and the TNS API key. `config_json` is
/// plaintext in the profile database, which rides export and backup, so an
/// SFTP password written here would leave the machine with the backup.
/// [ArtifactDestination.secretRef] holds the `SecretField`-style key naming the
/// keyring entry instead; the transport integration that reads it lands with
/// the delivery service.
///
/// Throws [FormatException] when [configJson] is not a JSON object.
void assertNoSecretsInConfig(String configJson) {
  final decoded = jsonDecode(configJson);
  if (decoded is! Map) {
    throw FormatException(
      'delivery_targets.config_json must be a JSON object',
      configJson,
    );
  }
  final offenders = <String>{};
  void scan(Object? node) {
    if (node is Map) {
      for (final entry in node.entries) {
        final key = entry.key.toString();
        final lowered = key.toLowerCase();
        if (kSecretKeyMarkers.any(lowered.contains)) {
          offenders.add(key);
        }
        scan(entry.value);
      }
    } else if (node is List) {
      for (final item in node) {
        scan(item);
      }
    }
  }

  scan(decoded);
  if (offenders.isNotEmpty) {
    throw DeliveryConfigSecretException(offenders.toList()..sort());
  }
}

/// One configured place the night's artifacts are delivered to.
class ArtifactDestination {
  /// DB primary key (`delivery_targets.id`). Null for an unsaved record.
  final int? id;

  /// Operator-facing name, e.g. `office-pc`. What the morning report names.
  final String name;

  /// Transport this destination delivers over.
  final ArtifactDestinationKind kind;

  /// Non-secret transport configuration as a JSON object: a path for
  /// [ArtifactDestinationKind.watchedFolder], host/port/user/remote-dir for
  /// [ArtifactDestinationKind.sftp], the paired install's identity for
  /// [ArtifactDestinationKind.peer]. Never key material — see
  /// [assertNoSecretsInConfig].
  final String configJson;

  /// Whether delivery to this destination is currently on.
  final bool enabled;

  /// Which classes of artifact this destination receives.
  final Set<ArtifactContent> content;

  /// The `SecretsStore` field key holding this destination's key material, or
  /// null when the transport needs none.
  final String? secretRef;

  /// When the destination row was created (UTC).
  final DateTime createdAt;

  /// When the destination row was last updated (UTC).
  final DateTime updatedAt;

  const ArtifactDestination({
    this.id,
    required this.name,
    required this.kind,
    required this.configJson,
    required this.enabled,
    required this.content,
    this.secretRef,
    required this.createdAt,
    required this.updatedAt,
  });

  /// True when this destination is on and has something selected to receive.
  bool get deliversAnything => enabled && content.isNotEmpty;

  @override
  String toString() =>
      'ArtifactDestination(id=$id, name=$name, ${kind.wire}, '
      'enabled=$enabled, content=${content.length})';
}

/// One file's delivery record for one destination on one job.
class DeliveryJournalEntry {
  /// DB primary key (`delivery_journal.id`). Null for an unsaved record.
  final int? id;

  /// The `delivery_targets.id` this file was sent to. `ON DELETE CASCADE`.
  final int targetId;

  /// The `darkroom_jobs.id` whose run produced this delivery. `ON DELETE
  /// CASCADE` — the journal is a per-run record.
  final int jobId;

  /// Absolute source path of the delivered file.
  final String filePath;

  /// Size of the source file in bytes, or 0 before it is known.
  final int bytes;

  /// Checksum of the delivered bytes, or null before one is computed.
  final String? checksum;

  /// Outcome so far.
  final DeliveryAttemptState state;

  /// How many delivery attempts this file has had.
  final int attempts;

  /// The most recent attempt's failure reason, or null. Retained after a later
  /// success so the report can say the delivery recovered.
  final String? lastError;

  /// When the journal row was created (UTC).
  final DateTime createdAt;

  /// When the journal row was last updated (UTC).
  final DateTime updatedAt;

  /// When the file was confirmed delivered (UTC), or null until it is.
  final DateTime? deliveredAt;

  const DeliveryJournalEntry({
    this.id,
    required this.targetId,
    required this.jobId,
    required this.filePath,
    required this.bytes,
    this.checksum,
    required this.state,
    required this.attempts,
    this.lastError,
    required this.createdAt,
    required this.updatedAt,
    this.deliveredAt,
  });

  @override
  String toString() =>
      'DeliveryJournalEntry(target=$targetId, job=$jobId, file=$filePath, '
      '${state.wire}, attempts=$attempts)';
}
