import 'package:skotiq_astro/format.dart';

import '../models/annotation_data.dart';

/// The text formats a frame's annotated objects can be exported in.
enum AnnotationExportFormat {
  /// One row per object, for a spreadsheet or an observing log.
  csv(
    menuLabel: 'Export CSV',
    fileTypeLabel: 'CSV files',
    extension: 'csv',
    subject: 'Annotation CSV',
  ),

  /// A SAOImage DS9 region file in FK5 degrees, which DS9, Siril and Aladin
  /// overlay on any plate-solved image of the same field.
  ds9Region(
    menuLabel: 'Export DS9 regions',
    fileTypeLabel: 'DS9 region files',
    extension: 'reg',
    subject: 'DS9 region file',
  );

  const AnnotationExportFormat({
    required this.menuLabel,
    required this.fileTypeLabel,
    required this.extension,
    required this.subject,
  });

  final String menuLabel;
  final String fileTypeLabel;
  final String extension;

  /// What the exported file is, in the words a share sheet or message shows.
  final String subject;

  /// [objects] in this format.
  String render(Iterable<CelestialObjectAnnotation> objects) => switch (this) {
    csv => _csv(objects),
    ds9Region => _ds9Region(objects),
  };
}

String _csv(Iterable<CelestialObjectAnnotation> objects) {
  final buffer = StringBuffer()
    ..writeln(
      'Name,Common name,Catalog ID,Type,RA J2000 (deg),Dec J2000 (deg),'
      'RA J2000,Dec J2000,Magnitude,Size (arcmin)',
    );
  for (final object in objects) {
    buffer.writeln(
      [
        object.name,
        object.commonName ?? '',
        object.catalogId ?? '',
        _typeName(object.type),
        object.ra.toStringAsFixed(6),
        object.dec.toStringAsFixed(6),
        CoordinateFormat.raReadoutFromDegrees(object.ra),
        CoordinateFormat.decReadout(object.dec),
        object.magnitude?.toStringAsFixed(2) ?? '',
        object.size?.toStringAsFixed(2) ?? '',
      ].map(_csvField).join(','),
    );
  }
  return buffer.toString();
}

/// An object with no catalog size gets a 30" circle: big enough to see around
/// a star at any common image scale, small enough not to swallow neighbors.
const double _defaultRegionRadiusArcsec = 30;

String _ds9Region(Iterable<CelestialObjectAnnotation> objects) {
  final buffer = StringBuffer()
    ..writeln('# Region file format: DS9 version 4.1')
    ..writeln('global color=green width=1 font="helvetica 10 normal roman"')
    ..writeln('fk5');
  for (final object in objects) {
    final size = object.size;
    // Catalog sizes are diameters in arcminutes.
    final radiusArcsec = size != null && size > 0
        ? size * 60 / 2
        : _defaultRegionRadiusArcsec;
    // DS9 ends the text at the first closing brace.
    final label = (object.commonName ?? object.name).replaceAll(
      RegExp('[{}]'),
      '',
    );
    buffer.writeln(
      'circle(${object.ra.toStringAsFixed(6)},${object.dec.toStringAsFixed(6)},'
      '${radiusArcsec.toStringAsFixed(1)}") '
      '# color=${_ds9Color(object.type)} text={$label}',
    );
  }
  return buffer.toString();
}

String _csvField(String value) {
  if (value.contains(',') || value.contains('"') || value.contains('\n')) {
    return '"${value.replaceAll('"', '""')}"';
  }
  return value;
}

String _typeName(ObjectType type) => switch (type) {
  ObjectType.galaxy => 'Galaxy',
  ObjectType.nebula => 'Nebula',
  ObjectType.starCluster => 'Star cluster',
  ObjectType.planetaryNebula => 'Planetary nebula',
  ObjectType.star => 'Star',
  ObjectType.doubleStar => 'Double star',
  ObjectType.asterism => 'Asterism',
  ObjectType.unknown => 'Unknown',
};

String _ds9Color(ObjectType type) => switch (type) {
  ObjectType.galaxy => 'yellow',
  ObjectType.nebula => 'magenta',
  ObjectType.planetaryNebula => 'cyan',
  ObjectType.starCluster => 'green',
  ObjectType.star || ObjectType.doubleStar => 'white',
  ObjectType.asterism || ObjectType.unknown => 'red',
};
