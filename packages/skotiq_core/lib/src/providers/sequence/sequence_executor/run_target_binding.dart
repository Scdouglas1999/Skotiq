import '../../../database/daos/targets_dao.dart' show TargetsDao;
import '../../../models/sequence/sequence_models.dart';
import '../../../services/logging_service.dart';
import 'frame_attribution.dart' show enclosingTargetHeader;

/// Binds each Target node of the running sequence to its `targets` row, so
/// the frames it produces are attributed to it.
///
/// Only sequences generated from the library carry `catalogTargetId`; a target
/// typed into the builder gets its row here, when it is first imaged rather
/// than when the node is added, so editing a draft does not fill the library.
class RunTargetBinding {
  RunTargetBinding({
    required TargetsDao Function() targetsDao,
    required LoggingService Function() logger,
  }) : _targetsDao = targetsDao,
       _logger = logger;

  final TargetsDao Function() _targetsDao;
  final LoggingService Function() _logger;

  /// `targets.id` per Target node id, rebuilt by every [bind].
  final Map<String, int> _targetIds = <String, int>{};

  /// Bind every target of [sequence]. A target that cannot be bound is logged
  /// and its frames are recorded without a target id; an unnamed target is
  /// left unbound rather than given a library entry called "".
  Future<void> bind(Sequence sequence) async {
    _targetIds.clear();
    final dao = _targetsDao();
    for (final header in sequence.targetHeaders) {
      final existing = header.catalogTargetId;
      if (existing != null) {
        _targetIds[header.id] = existing;
        // A library-bound node can be re-pointed in the builder too.
        try {
          await _refreshCoordinates(dao, existing, header);
        } catch (e) {
          _logger().warning(
            'Could not update the catalog coordinates for '
            '"${header.targetName}": $e',
            source: 'SequenceExecutor',
          );
        }
        continue;
      }
      final name = header.targetName.trim();
      if (name.isEmpty) continue;
      try {
        final targetId = await dao.findOrCreateByName(
          name: name,
          raHours: header.raHours,
          decDegrees: header.decDegrees,
        );
        _targetIds[header.id] = targetId;
        await _refreshCoordinates(dao, targetId, header);
      } catch (e) {
        _logger().warning(
          'Could not bind target "$name" to a targets row; its frames will be '
          'recorded without a target id: $e',
          source: 'SequenceExecutor',
        );
      }
    }
  }

  /// `targets.id` for the frame produced by [nodeId]; null when the node sits
  /// outside any target.
  int? targetIdFor(Sequence sequence, String nodeId) {
    final header = enclosingTargetHeader(sequence, nodeId);
    if (header == null) return null;
    return header.catalogTargetId ?? _targetIds[header.id];
  }

  /// Move the row's coordinates to where the run is imaging. The row matches
  /// by name alone and is what the scheduler evaluates, so a re-pointed target
  /// must not keep its old position. Only coordinates change, never from an
  /// unset (0, 0) node, and a sub-arcsecond difference is round-trip noise.
  Future<void> _refreshCoordinates(
    TargetsDao dao,
    int targetId,
    TargetHeaderNode header,
  ) async {
    if (header.raHours == 0.0 && header.decDegrees == 0.0) return;
    final row = await dao.getTargetById(targetId);
    if (row == null) return;
    const raEpsilonHours = 1.0 / 54000.0;
    const decEpsilonDegrees = 1.0 / 3600.0;
    if ((row.ra - header.raHours).abs() < raEpsilonHours &&
        (row.dec - header.decDegrees).abs() < decEpsilonDegrees) {
      return;
    }
    await dao.updateTarget(
      row.copyWith(
        ra: header.raHours,
        dec: header.decDegrees,
        updatedAt: DateTime.now(),
      ),
    );
    _logger().info(
      'Target "${row.name}" re-pointed to RA ${header.raHours}h / '
      'Dec ${header.decDegrees}°; the scheduler now evaluates it there.',
      source: 'SequenceExecutor',
    );
  }
}
