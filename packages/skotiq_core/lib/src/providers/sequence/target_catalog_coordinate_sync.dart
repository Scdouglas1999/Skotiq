import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../database/daos/targets_dao.dart';
import '../../database/database.dart' show Target;
import '../../models/sequence/sequence_models.dart';
import '../database_provider.dart';

/// Keeps the catalog row a Target node images pointed where the operator
/// pointed it.
///
/// The scheduler scores the `targets` table, never the builder's tree, so the
/// two are separate copies of "where is this object" and both must be moved
/// together. The run path re-points the row when the sequence is STARTED
/// (`SequenceExecutor._refreshCatalogCoordinates`); this reconciles them at
/// EDIT time, so an evaluation between the edit and the next run scores the
/// coordinates the operator can see.
///
/// Deliberately conservative:
///   * it only ever UPDATES an existing catalog row — editing the builder never
///     litters the target library with new rows (creation stays with the run
///     path, where the target is actually being imaged);
///   * an unset (0, 0) node never blanks a stored position;
///   * sub-arcsecond differences are float round-trip noise, not a re-point;
///   * only the coordinates move — priority, altitude floor, goals, and notes
///     belong to the library.
class TargetCatalogCoordinateSync {
  TargetCatalogCoordinateSync(this._ref);

  final Ref _ref;

  /// One arcsecond in each axis.
  static const double raEpsilonHours = 1.0 / 54000.0;
  static const double decEpsilonDegrees = 1.0 / 3600.0;

  /// Push [header]'s coordinates onto its catalog row.
  ///
  /// Returns true when a row was actually updated. Never throws: a failed sync
  /// must not take the editor down with it.
  Future<bool> syncHeader(TargetHeaderNode header) async {
    if (header.raHours == 0.0 && header.decDegrees == 0.0) return false;
    try {
      final dao = _ref.read(targetsDaoProvider);
      final row = await _resolveRow(dao, header);
      if (row == null) return false;
      if ((row.ra - header.raHours).abs() < raEpsilonHours &&
          (row.dec - header.decDegrees).abs() < decEpsilonDegrees) {
        return false;
      }
      await dao.updateTarget(
        row.copyWith(
          ra: header.raHours,
          dec: header.decDegrees,
          updatedAt: DateTime.now(),
        ),
      );
      developer.log(
        'Target "${row.name}" re-pointed in the builder to '
        'RA ${header.raHours}h / Dec ${header.decDegrees}°; the scheduler now '
        'evaluates it there.',
        name: 'TargetCatalogCoordinateSync',
        level: 800, // INFO
      );
      return true;
    } catch (e) {
      developer.log(
        'Could not re-point the catalog row for "${header.targetName}": $e',
        name: 'TargetCatalogCoordinateSync',
        level: 900, // WARNING
        error: e,
      );
      return false;
    }
  }

  /// The catalog row this node images: its bound id when it has one, otherwise
  /// the row with the same (trimmed, case-insensitive) name — the identity
  /// `TargetsDao.findOrCreateByName` uses at run start, so both paths agree on
  /// which row a hand-typed target belongs to.
  Future<Target?> _resolveRow(TargetsDao dao, TargetHeaderNode header) async {
    final boundId = header.catalogTargetId;
    if (boundId != null) return dao.getTargetById(boundId);
    final name = header.targetName.trim();
    if (name.isEmpty) return null;
    final matches = await dao.searchTargets(name);
    for (final row in matches) {
      if (row.name.trim().toLowerCase() == name.toLowerCase()) return row;
    }
    return null;
  }
}

final targetCatalogCoordinateSyncProvider =
    Provider<TargetCatalogCoordinateSync>(
      (ref) => TargetCatalogCoordinateSync(ref),
    );
