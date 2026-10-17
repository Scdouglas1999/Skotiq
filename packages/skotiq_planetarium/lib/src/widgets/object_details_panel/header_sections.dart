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
            borderRadius: BorderRadius.circular(8),
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
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                _getTypeString(),
                style: TextStyle(
                  color: typeColor,
                  fontSize: 12,
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
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              'Mag ${object.magnitude!.toStringAsFixed(1)}',
              style: TextStyle(
                color: txtColor,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
      ],
    );
  }

  /// Build header with thumbnail for DSOs
  Widget _buildHeaderWithThumbnail(
    Color txtColor,
    Color accent,
    DeepSkyObject dso,
  ) {
    final typeColor = _getTypeColor();

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Thumbnail
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
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _getTypeString(),
                style: TextStyle(
                  color: typeColor,
                  fontSize: 12,
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
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'Mag ${object.magnitude!.toStringAsFixed(1)}',
                        style: TextStyle(
                          color: txtColor,
                          fontSize: 10,
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
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        dso.sizeString!,
                        style: TextStyle(
                          color: txtColor,
                          fontSize: 10,
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

  IconData _getObjectIcon() {
    if (object is Star) {
      return LucideIcons.sparkles;
    } else if (object is DeepSkyObject) {
      final dso = object as DeepSkyObject;
      return switch (dso.type) {
        DsoType.galaxy => LucideIcons.orbit,
        DsoType.nebula => LucideIcons.cloud,
        DsoType.openCluster => LucideIcons.asterisk,
        DsoType.globularCluster => LucideIcons.circle,
        DsoType.planetaryNebula => LucideIcons.circleSlash,
        _ => LucideIcons.star,
      };
    }
    return LucideIcons.star;
  }

  Color _getTypeColor() {
    if (object is Star) {
      return Colors.yellow;
    } else if (object is DeepSkyObject) {
      final dso = object as DeepSkyObject;
      return switch (dso.type) {
        DsoType.galaxy => Colors.purple,
        DsoType.nebula => Colors.red,
        DsoType.openCluster => Colors.blue,
        DsoType.globularCluster => Colors.orange,
        DsoType.planetaryNebula => Colors.cyan,
        _ => Colors.grey,
      };
    }
    return Colors.grey;
  }

  String _getTypeString() {
    if (object is Star) {
      return 'Star';
    } else if (object is DeepSkyObject) {
      final dso = object as DeepSkyObject;
      return switch (dso.type) {
        DsoType.galaxy => 'Galaxy',
        DsoType.nebula => 'Nebula',
        DsoType.openCluster => 'Open Cluster',
        DsoType.globularCluster => 'Globular Cluster',
        DsoType.planetaryNebula => 'Planetary Nebula',
        DsoType.supernova => 'Supernova Remnant',
        DsoType.starCloud => 'Star Cloud',
        DsoType.asterism => 'Asterism',
        _ => 'Deep Sky Object',
      };
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

  // Thumbnail widget

  /// Build a survey thumbnail for DSOs with icon fallback on network/load errors.
  Widget _buildThumbnail(DeepSkyObject dso) {
    final request = SurveyImageRequest(
      raDeg: dso.coordinates.ra * 15.0,
      decDeg: dso.coordinates.dec,
      fovWidth: _thumbnailFovDeg(dso),
      fovHeight: _thumbnailFovDeg(dso),
      pixelWidth: 256,
      pixelHeight: 256,
      source: SurveySource.dss2Red,
    );

    return Container(
      width: 80,
      height: 80,
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white24),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(7),
        child: Image.network(
          request.aladinUrl,
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
                _getDsoIcon(dso.type),
                color: _getDsoColor(dso.type),
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

  /// Get icon for DSO type (for thumbnail)
  IconData _getDsoIcon(DsoType type) {
    return switch (type) {
      DsoType.galaxy ||
      DsoType.galaxyPair ||
      DsoType.galaxyTriplet ||
      DsoType.galaxyGroup => LucideIcons.orbit,
      DsoType.nebula ||
      DsoType.emissionNebula ||
      DsoType.reflectionNebula ||
      DsoType.darkNebula ||
      DsoType.hiiRegion => LucideIcons.cloud,
      DsoType.openCluster ||
      DsoType.clusterWithNebulosity => LucideIcons.asterisk,
      DsoType.globularCluster => LucideIcons.circle,
      DsoType.planetaryNebula => LucideIcons.circleSlash,
      DsoType.supernova => LucideIcons.zap,
      DsoType.starCloud => LucideIcons.sparkles,
      DsoType.asterism => LucideIcons.shapes,
      _ => LucideIcons.star,
    };
  }

  /// Get color for DSO type (for thumbnail)
  Color _getDsoColor(DsoType type) {
    return switch (type) {
      DsoType.galaxy ||
      DsoType.galaxyPair ||
      DsoType.galaxyTriplet ||
      DsoType.galaxyGroup => Colors.purple,
      DsoType.nebula ||
      DsoType.emissionNebula ||
      DsoType.hiiRegion => Colors.red,
      DsoType.reflectionNebula => Colors.blue,
      DsoType.darkNebula => Colors.grey,
      DsoType.openCluster || DsoType.clusterWithNebulosity => Colors.blue,
      DsoType.globularCluster => Colors.orange,
      DsoType.planetaryNebula => Colors.cyan,
      DsoType.supernova => Colors.amber,
      DsoType.starCloud => Colors.lightBlue,
      _ => Colors.grey,
    };
  }
}
