part of '../object_details_panel.dart';

extension _ObjectDetailsPanelCatalogSections on ObjectDetailsPanel {
  Widget _buildCoordinatesSection(Color txtColor) {
    final raHours = object.coordinates.ra.floor();
    final raMinutes = ((object.coordinates.ra - raHours) * 60).floor();
    final raSeconds =
        ((object.coordinates.ra - raHours - raMinutes / 60) * 3600)
            .toStringAsFixed(1);

    final decSign = object.coordinates.dec >= 0 ? '+' : '';
    final decDegrees = object.coordinates.dec.abs().floor();
    final decMinutes = ((object.coordinates.dec.abs() - decDegrees) * 60)
        .floor();
    final decSeconds =
        ((object.coordinates.dec.abs() - decDegrees - decMinutes / 60) * 3600)
            .toStringAsFixed(0);

    final constellation = _getConstellation();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Coordinates',
          style: TextStyle(
            color: txtColor.withValues(alpha: 0.7),
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        _buildInfoRow(
          'RA',
          '${raHours}h ${raMinutes}m ${raSeconds}s',
          txtColor,
        ),
        _buildInfoRow(
          'Dec',
          '$decSign$decDegrees° $decMinutes\' $decSeconds"',
          txtColor,
        ),
        if (constellation != null)
          _buildInfoRow('Constellation', constellation, txtColor),
      ],
    );
  }

  Widget _buildCatalogSection(Color txtColor, Color accent) {
    final catalogIds = _getCatalogIds();
    if (catalogIds.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Catalog Designations',
          style: TextStyle(
            color: txtColor.withValues(alpha: 0.7),
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: catalogIds.map((id) {
            final isMessier = id.startsWith('M');
            final isNgc = id.startsWith('NGC');
            final isIc = id.startsWith('IC');

            Color tagColor;
            if (isMessier) {
              tagColor = Colors.amber;
            } else if (isNgc) {
              tagColor = Colors.blue;
            } else if (isIc) {
              tagColor = Colors.purple;
            } else {
              tagColor = txtColor;
            }

            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: tagColor.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: tagColor.withValues(alpha: 0.3)),
              ),
              child: Text(
                id,
                style: TextStyle(
                  color: tagColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildPhysicalPropertiesSection(Color txtColor) {
    final properties = <Widget>[];

    if (object is DeepSkyObject) {
      final dso = object as DeepSkyObject;
      if (dso.sizeArcMin != null) {
        final sizeStr = dso.minorAxisArcMin != null
            ? '${dso.sizeArcMin!.toStringAsFixed(1)}\' × ${dso.minorAxisArcMin!.toStringAsFixed(1)}\''
            : '${dso.sizeArcMin!.toStringAsFixed(1)}\'';
        properties.add(_buildInfoRow('Size', sizeStr, txtColor));
      }
      if (dso.positionAngle != null) {
        properties.add(
          _buildInfoRow(
            'PA',
            '${dso.positionAngle!.toStringAsFixed(0)}°',
            txtColor,
          ),
        );
      }
    }

    if (object is Star) {
      final star = object as Star;
      if (star.spectralType != null) {
        properties.add(_buildInfoRow('Spectral', star.spectralType!, txtColor));
      }
    }

    if (properties.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Physical Properties',
          style: TextStyle(
            color: txtColor.withValues(alpha: 0.7),
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        ...properties,
      ],
    );
  }
}
