import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/darkroom/delivery.dart';
import '../../models/darkroom/recipe.dart' show DarkroomWireFormatException;
import '../../providers/database_provider.dart';
import '../database.dart';

/// A destination row was addressed by an id that has no row.
class ArtifactDestinationMissingException implements Exception {
  final int destinationId;

  const ArtifactDestinationMissingException(this.destinationId);

  @override
  String toString() => 'Delivery target $destinationId does not exist';
}

/// A `delivery_targets` row this build cannot turn into an
/// [ArtifactDestination].
///
/// Carried out of the read instead of thrown, because one such row used to
/// take the whole table with it: [ArtifactDestination] is built per row, so
/// the first undecodable row aborted the list, delivery reported its
/// destination list as unreadable and sent NOTHING — to any destination — and
/// the settings page rendered its error state instead of the destinations
/// that decode. The row is its own failure: it is named, its reason is
/// stated, and the destinations either side of it are untouched.
class UndecodableDeliveryTarget {
  /// The row's `id`, or null when that column itself did not read as an int.
  final int? id;

  /// The row's `name`, or null when that column did not read as a string.
  final String? name;

  /// One sentence naming the column, the stored value, and what rejected it.
  final String reason;

  const UndecodableDeliveryTarget({
    required this.id,
    required this.name,
    required this.reason,
  });

  /// How this row is addressed on screen and in the morning report.
  ///
  /// The stored name when there is one, because that is what the operator
  /// configured it as; otherwise the row id, which is what they can still find
  /// it by. Never a made-up name.
  String get label {
    final named = name;
    if (named != null && named.trim().isNotEmpty) return named.trim();
    final row = id;
    return row == null
        ? 'A delivery destination row'
        : 'Delivery destination #$row';
  }
}

/// The destination rows, split into the ones this build can read and the ones
/// it cannot.
class DeliveryTargetsRead {
  /// The rows that decoded, in the query's order.
  final List<ArtifactDestination> destinations;

  /// The rows that did not, each naming itself and why.
  final List<UndecodableDeliveryTarget> undecodable;

  const DeliveryTargetsRead({
    required this.destinations,
    required this.undecodable,
  });
}

/// Data-access object for the v58 `delivery_targets` table — the configured
/// places the night's artifacts are delivered to.
///
/// The table is managed with raw DDL (see
/// [SkotiqDatabase._createDarkroomTables]) rather than a drift `Table`
/// class, so this DAO is a plain class that reads/writes through the database's
/// `customSelect`/`customInsert`/`customStatement` APIs — mirroring
/// [MosaicProjectsDao] and [CampaignsDao]. It is deliberately NOT a
/// `@DriftAccessor`.
///
/// NO SECRETS IN `config_json`. Every write runs [assertNoSecretsInConfig],
/// which throws [DeliveryConfigSecretException] when the config carries key
/// material anywhere in its object graph. That column is plaintext in the
/// profile database, which rides export and backup; an SFTP password written
/// there would leave the machine with the backup. Key material belongs in
/// `SecretsStore` (`services/notification/secrets_store.dart`), the
/// keyring-backed store that already holds the WebDAV password, the S3 secret
/// key, and the TNS API key. [ArtifactDestination.secretRef] names the keyring
/// entry; reading it belongs to the delivery service, in a later workstream.
class DeliveryTargetsDao {
  DeliveryTargetsDao(this._db);

  final SkotiqDatabase _db;

  static const String _columns =
      'id, name, kind, config_json, enabled, content_json, secret_ref, '
      'created_at, updated_at';

  /// Insert a destination row and return its id.
  ///
  /// Throws [DeliveryConfigSecretException] when [configJson] carries key
  /// material, and [FormatException] when it is not a JSON object.
  Future<int> create({
    required String name,
    required ArtifactDestinationKind kind,
    String configJson = '{}',
    bool enabled = true,
    Set<ArtifactContent> content = const <ArtifactContent>{},
    String? secretRef,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    if (name.isEmpty) {
      throw ArgumentError.value(
        name,
        'name',
        'a delivery target needs the name the morning report will use',
      );
    }
    assertNoSecretsInConfig(configJson);

    final created = _toEpochSeconds(createdAt ?? DateTime.now());
    final updated = updatedAt == null ? created : _toEpochSeconds(updatedAt);
    return _db.customInsert(
      'INSERT INTO delivery_targets('
      'name, kind, config_json, enabled, content_json, secret_ref, '
      'created_at, updated_at'
      ') VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      variables: [
        Variable<String>(name),
        Variable<String>(kind.wire),
        Variable<String>(configJson),
        Variable<int>(enabled ? 1 : 0),
        Variable<String>(ArtifactContent.encodeSelection(content)),
        Variable<String>(secretRef),
        Variable<int>(created),
        Variable<int>(updated),
      ],
    );
  }

  /// Fetch a destination by id, or null when absent.
  Future<ArtifactDestination?> getById(int id) async {
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM delivery_targets WHERE id = ? LIMIT 1',
          variables: [Variable<int>(id)],
        )
        .get();
    if (rows.isEmpty) return null;
    return _map(rows.first);
  }

  /// All destinations, in configuration order (oldest first), with the rows
  /// this build cannot decode named separately rather than raised.
  Future<DeliveryTargetsRead> readAll() async {
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM delivery_targets '
          'ORDER BY created_at ASC, id ASC',
        )
        .get();
    return _read(rows);
  }

  /// The destinations delivery should actually visit tonight, in configuration
  /// order, with the undecodable rows named separately rather than raised.
  Future<DeliveryTargetsRead> readEnabled() async {
    final rows = await _db
        .customSelect(
          'SELECT $_columns FROM delivery_targets WHERE enabled = 1 '
          'ORDER BY created_at ASC, id ASC',
        )
        .get();
    return _read(rows);
  }

  /// Update the fields a caller passes and leave the rest alone, bumping
  /// `updated_at`. Returns the destination as it now stands.
  ///
  /// Throws [ArtifactDestinationMissingException] when the row is gone, and
  /// [DeliveryConfigSecretException] when a new [configJson] carries key
  /// material.
  Future<ArtifactDestination> update(
    int id, {
    String? name,
    String? configJson,
    Set<ArtifactContent>? content,
    String? secretRef,
    bool? enabled,
    DateTime? now,
  }) async {
    if (configJson != null) assertNoSecretsInConfig(configJson);
    await _require(id);

    final at = _toEpochSeconds(now ?? DateTime.now());
    await _db.customUpdate(
      'UPDATE delivery_targets SET '
      'name = COALESCE(?, name), '
      'config_json = COALESCE(?, config_json), '
      'content_json = COALESCE(?, content_json), '
      'secret_ref = COALESCE(?, secret_ref), '
      'enabled = COALESCE(?, enabled), '
      'updated_at = ? WHERE id = ?',
      variables: [
        Variable<String>(name),
        Variable<String>(configJson),
        Variable<String>(
          content == null ? null : ArtifactContent.encodeSelection(content),
        ),
        Variable<String>(secretRef),
        Variable<int>(enabled == null ? null : (enabled ? 1 : 0)),
        Variable<int>(at),
        Variable<int>(id),
      ],
      updateKind: UpdateKind.update,
    );
    return _require(id);
  }

  /// Clear this destination's keyring reference — the row keeps its transport
  /// config and stops claiming to hold key material. `COALESCE` in [update]
  /// cannot express a null, so clearing has its own call.
  Future<ArtifactDestination> clearSecretRef(int id, {DateTime? now}) async {
    await _require(id);
    final at = _toEpochSeconds(now ?? DateTime.now());
    await _db.customUpdate(
      'UPDATE delivery_targets SET secret_ref = NULL, updated_at = ? '
      'WHERE id = ?',
      variables: [Variable<int>(at), Variable<int>(id)],
      updateKind: UpdateKind.update,
    );
    return _require(id);
  }

  /// The keyring entry this row names, or null when it names none.
  ///
  /// Reads that one column instead of the whole destination, so the keyring
  /// entry of a row that will not decode can still be found and removed with
  /// it — otherwise deleting an unreadable destination would leave its private
  /// key in the keyring under a name nothing points at any more.
  Future<String?> secretRefOf(int id) async {
    final rows = await _db
        .customSelect(
          'SELECT secret_ref FROM delivery_targets WHERE id = ? LIMIT 1',
          variables: [Variable<int>(id)],
        )
        .get();
    if (rows.isEmpty) return null;
    return rows.first.readNullable<String>('secret_ref');
  }

  /// Delete a destination by id. Its `delivery_journal` rows cascade. Returns
  /// the number of rows changed.
  Future<int> deleteTarget(int id) {
    return _db.customUpdate(
      'DELETE FROM delivery_targets WHERE id = ?',
      variables: [Variable<int>(id)],
      updateKind: UpdateKind.delete,
    );
  }

  Future<ArtifactDestination> _require(int id) async {
    final destination = await getById(id);
    if (destination == null) throw ArtifactDestinationMissingException(id);
    return destination;
  }

  /// Decode each row on its own, so an undecodable one costs only itself.
  DeliveryTargetsRead _read(List<QueryRow> rows) {
    final destinations = <ArtifactDestination>[];
    final undecodable = <UndecodableDeliveryTarget>[];
    for (final row in rows) {
      try {
        destinations.add(_map(row));
      } on Object catch (error) {
        // The id and the name are read straight off the row map rather than
        // through `_map`, which is the thing that just refused: whichever
        // column is unreadable, the two that name the row for the operator are
        // usually still there.
        final id = row.data['id'];
        final name = row.data['name'];
        undecodable.add(
          UndecodableDeliveryTarget(
            id: id is int ? id : null,
            name: name is String ? name : null,
            reason: _decodeRefusal(error),
          ),
        );
      }
    }
    return DeliveryTargetsRead(
      destinations: destinations,
      undecodable: undecodable,
    );
  }

  /// Why one row would not decode, in the words of the constraint that
  /// actually rejected the value.
  ///
  /// `kind` and `enabled` carry SQLite `CHECK` constraints on this table;
  /// `content_json` does NOT — it is free text the DAO writes from
  /// [ArtifactContent] and reads back through it (see
  /// `_createDarkroomTables`). [DarkroomWireFormatException] says "the column
  /// is CHECK-constrained, so this row is corrupt" about every darkroom
  /// column it is raised for, which for a `content_json` value points the
  /// operator at a database constraint that never ran and calls a row corrupt
  /// that SQLite accepted exactly as written. Each column is answered here
  /// with its own constraint.
  static String _decodeRefusal(Object error) {
    if (error is DarkroomWireFormatException) {
      final value = error.value == null ? '<null>' : '"${error.value}"';
      switch (error.column) {
        case 'delivery_targets.kind':
          final kinds = ArtifactDestinationKind.values
              .map((kind) => kind.wire)
              .join(', ');
          return 'its transport is $value, which is not one this build '
              'delivers over ($kinds) and which the column\'s CHECK '
              'constraint does not allow';
        case 'delivery_targets.content_json':
          final classes = ArtifactContent.values
              .map((content) => content.wire)
              .join(', ');
          return 'the artifact classes it receives include $value, which is '
              'not one this build produces ($classes). The column holds free '
              'text — no database constraint rejected it — so the row was '
              'written by a build that knows a class this one does not, or '
              'edited by hand';
      }
      return '$error';
    }
    if (error is FormatException) {
      return 'the artifact classes it receives are not a JSON array: '
          '${error.message}';
    }
    return '$error';
  }

  ArtifactDestination _map(QueryRow row) {
    return ArtifactDestination(
      id: row.read<int>('id'),
      name: row.read<String>('name'),
      kind: ArtifactDestinationKind.fromWire(row.read<String>('kind')),
      configJson: row.read<String>('config_json'),
      enabled: row.read<int>('enabled') != 0,
      content: ArtifactContent.decodeSelection(
        row.read<String>('content_json'),
      ),
      secretRef: row.readNullable<String>('secret_ref'),
      createdAt: _fromEpochSeconds(row.read<int>('created_at')),
      updatedAt: _fromEpochSeconds(row.read<int>('updated_at')),
    );
  }

  static int _toEpochSeconds(DateTime when) =>
      when.toUtc().millisecondsSinceEpoch ~/ 1000;

  static DateTime _fromEpochSeconds(int seconds) =>
      DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);
}

/// Riverpod provider for [DeliveryTargetsDao].
final deliveryTargetsDaoProvider = Provider<DeliveryTargetsDao>((ref) {
  return DeliveryTargetsDao(ref.watch(databaseProvider));
});
