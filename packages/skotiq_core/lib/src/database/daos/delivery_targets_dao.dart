import 'package:drift/drift.dart';

import '../../models/darkroom/delivery.dart';
import '../../models/darkroom/recipe.dart' show DarkroomWireFormatException;
import '../database.dart';
import '../epoch_seconds.dart';

part 'delivery_targets_dao.g.dart';

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

/// Reads and writes for `delivery_targets`: the configured places the night's
/// artifacts are delivered to.
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
@DriftAccessor(include: {'../schema/darkroom.drift'})
class DeliveryTargetsDao extends DatabaseAccessor<SkotiqDatabase>
    with _$DeliveryTargetsDaoMixin {
  DeliveryTargetsDao(super.db);

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

    final created = toEpochSeconds(createdAt ?? DateTime.now());
    final updated = updatedAt == null ? created : toEpochSeconds(updatedAt);
    return into(deliveryTargets).insert(
      DeliveryTargetsCompanion.insert(
        name: name,
        kind: kind.wire,
        configJson: Value(configJson),
        enabled: Value(enabled ? 1 : 0),
        contentJson: Value(ArtifactContent.encodeSelection(content)),
        secretRef: Value(secretRef),
        createdAt: created,
        updatedAt: updated,
      ),
    );
  }

  Future<ArtifactDestination?> getById(int id) async {
    final row = await (select(
      deliveryTargets,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _map(row);
  }

  /// All destinations, in configuration order (oldest first), with the rows
  /// this build cannot decode named separately rather than raised.
  Future<DeliveryTargetsRead> readAll() async {
    return _read(
      await _rawRows(
        'SELECT * FROM delivery_targets ORDER BY created_at ASC, id ASC',
      ),
    );
  }

  /// The destinations delivery should actually visit tonight, in configuration
  /// order, with the undecodable rows named separately rather than raised.
  Future<DeliveryTargetsRead> readEnabled() async {
    return _read(
      await _rawRows(
        'SELECT * FROM delivery_targets WHERE enabled = 1 '
        'ORDER BY created_at ASC, id ASC',
      ),
    );
  }

  /// Update the fields a caller passes and leave the rest alone, bumping
  /// `updated_at`. Returns the destination as it now stands.
  ///
  /// Throws [ArtifactDestinationMissingException] when the row is gone, and
  /// [DeliveryConfigSecretException] when a new [configJson] carries key
  /// material.
  Future<ArtifactDestination> updateDestination(
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

    final at = toEpochSeconds(now ?? DateTime.now());
    await _write(
      id,
      DeliveryTargetsCompanion(
        name: Value.absentIfNull(name),
        configJson: Value.absentIfNull(configJson),
        contentJson: Value.absentIfNull(
          content == null ? null : ArtifactContent.encodeSelection(content),
        ),
        secretRef: Value.absentIfNull(secretRef),
        enabled: Value.absentIfNull(enabled == null ? null : (enabled ? 1 : 0)),
        updatedAt: Value(at),
      ),
    );
    return _require(id);
  }

  /// Clear this destination's keyring reference — the row keeps its transport
  /// config and stops claiming to hold key material. [updateDestination] reads a null
  /// argument as "leave it", so clearing has its own call.
  Future<ArtifactDestination> clearSecretRef(int id, {DateTime? now}) async {
    await _require(id);
    final at = toEpochSeconds(now ?? DateTime.now());
    await _write(
      id,
      DeliveryTargetsCompanion(
        secretRef: const Value(null),
        updatedAt: Value(at),
      ),
    );
    return _require(id);
  }

  /// The keyring entry this row names, or null when it names none.
  ///
  /// Reads that one column instead of the whole destination, so the keyring
  /// entry of a row that will not decode can still be found and removed with
  /// it — otherwise deleting an unreadable destination would leave its private
  /// key in the keyring under a name nothing points at any more.
  Future<String?> secretRefOf(int id) {
    final secretRef = deliveryTargets.secretRef;
    return (selectOnly(deliveryTargets)
          ..addColumns([secretRef])
          ..where(deliveryTargets.id.equals(id))
          ..limit(1))
        .map((row) => row.read(secretRef))
        .getSingleOrNull();
  }

  /// Delete a destination by id. Its `delivery_journal` rows cascade. Returns
  /// the number of rows changed.
  Future<int> deleteTarget(int id) =>
      (delete(deliveryTargets)..where((t) => t.id.equals(id))).go();

  Future<ArtifactDestination> _require(int id) async {
    final destination = await getById(id);
    if (destination == null) throw ArtifactDestinationMissingException(id);
    return destination;
  }

  /// The rows [sql] selects from `delivery_targets`, not yet decoded.
  ///
  /// SQL text on purpose: drift's typed select decodes every row inside the
  /// query, so one row with an unreadable column (a hand-edited `created_at`,
  /// say) would fail the whole list. [_read] decodes each row on its own
  /// through the table's generated mapper instead.
  Future<List<QueryRow>> _rawRows(String sql) =>
      customSelect(sql, readsFrom: {deliveryTargets}).get();

  Future<int> _write(int id, DeliveryTargetsCompanion changes) =>
      (update(deliveryTargets)..where((t) => t.id.equals(id))).write(changes);

  /// Decode each row on its own, so an undecodable one costs only itself.
  DeliveryTargetsRead _read(List<QueryRow> rows) {
    final destinations = <ArtifactDestination>[];
    final undecodable = <UndecodableDeliveryTarget>[];
    for (final row in rows) {
      try {
        destinations.add(_map(deliveryTargets.map(row.data)));
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
  /// `schema/darkroom.drift`). [DarkroomWireFormatException] says "the column
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

  ArtifactDestination _map(DeliveryTargetRow row) {
    return ArtifactDestination(
      id: row.id,
      name: row.name,
      kind: ArtifactDestinationKind.fromWire(row.kind),
      configJson: row.configJson,
      enabled: row.enabled != 0,
      content: ArtifactContent.decodeSelection(row.contentJson),
      secretRef: row.secretRef,
      createdAt: fromEpochSeconds(row.createdAt),
      updatedAt: fromEpochSeconds(row.updatedAt),
    );
  }
}
