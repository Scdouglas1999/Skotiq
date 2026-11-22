part of '../database.dart';

extension _SkotiqDatabaseMigrationV70 on SkotiqDatabase {
  /// Keep the numbering of existing panels, including projects created before
  /// the shared geometry switched from bottom-right rows to top-left snakes.
  Future<void> _upgradeSchemaV70(Migrator m, int from) async {
    if (from >= 70 || !await _tableExists(mosaicProjects.actualTableName)) {
      return;
    }
    final needsOrder = !await _columnExists(
      mosaicProjects.actualTableName,
      'start_corner',
    );
    for (final column in [
      mosaicProjects.startCorner,
      mosaicProjects.serpentine,
    ]) {
      if (!await _columnExists(mosaicProjects.actualTableName, column.name)) {
        await m.addColumn(mosaicProjects, column);
      }
    }
    if (!needsOrder) return;
    for (final project in await select(mosaicProjects).get()) {
      final panels = await (select(
        mosaicPanels,
      )..where((p) => p.projectId.equals(project.id))).get();
      final order = v70CaptureOrderOfStoredGrid(
        columns: project.cols,
        rows: project.rows,
        rotationDegrees: project.positionAngleDeg,
        panels: [
          for (final panel in panels)
            (
              index: panel.panelIndex,
              raHours: panel.centerRa,
              decDegrees: panel.centerDec,
            ),
        ],
      );
      await (update(
        mosaicProjects,
      )..where((p) => p.id.equals(project.id))).write(
        MosaicProjectsCompanion(
          startCorner: Value(order.startCorner),
          serpentine: Value(order.serpentine),
        ),
      );
    }
  }
}

/// The capture order a v69 grid was numbered with, recovered from its panel
/// centers: `inferMosaicCaptureOrder` from `skotiq_astro` as it was when this
/// migration was written, copied so a later change to the live geometry
/// cannot change what an old database upgrades to. [startCorner] is the
/// stored `start_corner` text.
@visibleForTesting
({String startCorner, bool serpentine}) v70CaptureOrderOfStoredGrid({
  required int columns,
  required int rows,
  required double rotationDegrees,
  required List<({int index, double raHours, double decDegrees})> panels,
}) {
  const corners = ['topLeft', 'topRight', 'bottomLeft', 'bottomRight'];
  const fallback = (startCorner: 'bottomRight', serpentine: false);
  final known = panels
      .where(
        (p) =>
            p.index >= 0 &&
            p.index < columns * rows &&
            p.raHours.isFinite &&
            p.decDegrees.isFinite,
      )
      .toList();
  if (known.length < 2) return fallback;
  final origin = known.first;
  final dec =
      known.map((p) => p.decDegrees).reduce((a, b) => a + b) / known.length;
  final cosDec = math.cos(dec * math.pi / 180);
  final angle = rotationDegrees * math.pi / 180;
  final cosAngle = math.cos(angle);
  final sinAngle = math.sin(angle);
  final offsets = known.map((p) {
    final east = ((p.raHours - origin.raHours + 12) % 24 - 12) * 15 * cosDec;
    final north = p.decDegrees - origin.decDegrees;
    return (
      x: east * cosAngle + north * sinAngle,
      y: -east * sinAngle + north * cosAngle,
    );
  }).toList();

  List<({int row, int col})> order(String startCorner, bool serpentine) {
    final fromBottom =
        startCorner == 'bottomLeft' || startCorner == 'bottomRight';
    final fromRight = startCorner == 'topRight' || startCorner == 'bottomRight';
    return [
      for (var pass = 0; pass < rows; pass++)
        for (var step = 0; step < columns; step++)
          (
            row: fromBottom ? rows - 1 - pass : pass,
            col: fromRight != (serpentine && pass.isOdd)
                ? columns - 1 - step
                : step,
          ),
    ];
  }

  double score(({String startCorner, bool serpentine}) choice) {
    final cells = order(choice.startCorner, choice.serpentine);
    return _v70AxisFitError(
          [for (final p in known) -cells[p.index].col.toDouble()],
          [for (final p in offsets) p.x],
        ) +
        _v70AxisFitError(
          [for (final p in known) -cells[p.index].row.toDouble()],
          [for (final p in offsets) p.y],
        );
  }

  var best = fallback;
  var bestScore = score(best);
  for (final corner in corners) {
    for (final serpentine in [false, true]) {
      final choice = (startCorner: corner, serpentine: serpentine);
      final error = score(choice);
      if (error < bestScore - 1e-6) {
        best = choice;
        bestScore = error;
      }
    }
  }
  return best;
}

double _v70AxisFitError(List<double> cells, List<double> positions) {
  final cellMean = cells.reduce((a, b) => a + b) / cells.length;
  final positionMean = positions.reduce((a, b) => a + b) / positions.length;
  var cellVariance = 0.0;
  var positionVariance = 0.0;
  var covariance = 0.0;
  for (var i = 0; i < cells.length; i++) {
    final cell = cells[i] - cellMean;
    final position = positions[i] - positionMean;
    cellVariance += cell * cell;
    positionVariance += position * position;
    covariance += cell * position;
  }
  if (positionVariance < 1e-12) return cellVariance < 1e-12 ? 0 : 1;
  if (cellVariance < 1e-12 || covariance <= 0) return 1;
  return 1 - covariance * covariance / (cellVariance * positionVariance);
}
