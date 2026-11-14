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
      final order = inferMosaicCaptureOrder(
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
          startCorner: Value(order.startCorner.name),
          serpentine: Value(order.serpentine),
        ),
      );
    }
  }
}
