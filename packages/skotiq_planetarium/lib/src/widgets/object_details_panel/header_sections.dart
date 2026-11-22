part of '../object_details_panel.dart';

extension _ObjectDetailsPanelHeaderSections on ObjectDetailsPanel {
  Widget _buildHeader(Color txtColor, Color accent) {
    final iconData = _getObjectIcon();
    final typeColor = _getTypeColor();

    return Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: typeColor.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
          ),
          child: Icon(iconData, color: typeColor, size: 24),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                object.name,
                style: TextStyle(
                  color: txtColor,
                  fontSize: SkotiqTypography.fontSize18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                _getTypeString(),
                style: TextStyle(
                  color: typeColor,
                  fontSize: SkotiqTypography.fontSize12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        if (object.magnitude != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: txtColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
            ),
            child: Text(
              'Mag ${object.magnitude!.toStringAsFixed(1)}',
              style: TextStyle(
                color: txtColor,
                fontSize: SkotiqTypography.fontSize12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildHeaderWithThumbnail(
    Color txtColor,
    Color accent,
    DeepSkyObject dso,
  ) {
    final typeColor = _getTypeColor();

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildThumbnail(dso),
        const SizedBox(width: 12),
        // Name and details
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                object.name,
                style: TextStyle(
                  color: txtColor,
                  fontSize: SkotiqTypography.fontSize18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _getTypeString(),
                style: TextStyle(
                  color: typeColor,
                  fontSize: SkotiqTypography.fontSize12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),
              // Magnitude and size in a row
              Row(
                children: [
                  if (object.magnitude != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: txtColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(
                          SkotiqTokens.radiusXs,
                        ),
                      ),
                      child: Text(
                        'Mag ${object.magnitude!.toStringAsFixed(1)}',
                        style: TextStyle(
                          color: txtColor,
                          fontSize: SkotiqTypography.fontSize10,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  if (object.magnitude != null && dso.sizeString != null)
                    const SizedBox(width: 6),
                  if (dso.sizeString != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: txtColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(
                          SkotiqTokens.radiusXs,
                        ),
                      ),
                      child: Text(
                        dso.sizeString!,
                        style: TextStyle(
                          color: txtColor,
                          fontSize: SkotiqTypography.fontSize10,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  IconData _getObjectIcon() => switch (object) {
    Star() => LucideIcons.sparkles,
    DeepSkyObject(:final type) => dsoTypeIcon(type),
    _ => LucideIcons.star,
  };

  Color _getTypeColor() => switch (object) {
    Star() => SkyPlotColors.star,
    DeepSkyObject(:final type) => SkyPlotColors.forDsoType(type),
    _ => SkyPlotColors.unknown,
  };

  String _getTypeString() {
    if (object is Star) {
      return 'Star';
    } else if (object is DeepSkyObject) {
      return (object as DeepSkyObject).type.displayName;
    }
    return 'Celestial Object';
  }

  String? _getConstellation() {
    if (object is Star) {
      return (object as Star).constellation;
    } else if (object is DeepSkyObject) {
      return (object as DeepSkyObject).constellation;
    }
    return null;
  }

  List<String> _getCatalogIds() {
    final ids = <String>[object.id];
    if (object.name != object.id) {
      ids.add(object.name);
    }
    if (object is Star) {
      ids.addAll((object as Star).catalogIds);
    } else if (object is DeepSkyObject) {
      ids.addAll((object as DeepSkyObject).catalogIds);
    }
    return ids.toSet().toList(); // Remove duplicates
  }

  /// Build a survey thumbnail for DSOs with icon fallback on network/load errors.
  Widget _buildThumbnail(DeepSkyObject dso) {
    final fov = _thumbnailFovDeg(dso).toStringAsFixed(6);
    // CDS hips2fits cutout of the DSS2 red survey.
    final thumbnailUrl =
        Uri.https('alasky.cds.unistra.fr', '/hips-image-services/hips2fits', {
          'ra': (dso.coordinates.ra * 15.0).toStringAsFixed(6),
          'dec': dso.coordinates.dec.toStringAsFixed(6),
          'fov': fov,
          'width': '256',
          'height': '256',
          'format': 'jpg',
          'hips': 'CDS/P/DSS2/red',
        }).toString();

    return Container(
      width: 80,
      height: 80,
      decoration: BoxDecoration(
        color: SkotiqColors.dark.well,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
        border: Border.all(color: ImageOverlayColors.divider),
      ),
      child: ClipRRect(
        borderRadius: SkotiqTokens.borderRadiusLg,
        child: Image.network(
          thumbnailUrl,
          fit: BoxFit.cover,
          loadingBuilder: (context, child, loadingProgress) {
            if (loadingProgress == null) return child;
            return const Center(
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          },
          errorBuilder: (context, error, stackTrace) {
            return Center(
              child: Icon(
                dsoTypeIcon(dso.type),
                color: SkyPlotColors.forDsoType(dso.type),
                size: 32,
              ),
            );
          },
        ),
      ),
    );
  }

  double _thumbnailFovDeg(DeepSkyObject dso) {
    final majorArcMin = dso.sizeArcMin;
    final minorArcMin = dso.minorAxisArcMin;
    final largestArcMin = math.max(majorArcMin ?? 0.0, minorArcMin ?? 0.0);
    if (largestArcMin <= 0) {
      return 1.5;
    }

    // Frame the target with margin while avoiding very small/very large cutouts.
    return (largestArcMin * 3.0 / 60.0).clamp(0.25, 3.0);
  }
}
