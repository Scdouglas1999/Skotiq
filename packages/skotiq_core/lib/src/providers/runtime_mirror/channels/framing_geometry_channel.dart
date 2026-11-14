import 'package:flutter/foundation.dart';
import 'package:skotiq_astro/skotiq_astro.dart' show MosaicStartCorner;

import '../../framing_provider.dart';
import '../../../models/framing_models.dart';
import '../runtime_mirror_channel.dart';
import '../runtime_mirror_codec.dart';

/// The frame rotation and mosaic layout on the Framing screen.
@immutable
class FramingGeometry {
  const FramingGeometry({
    required this.rotation,
    required this.mosaicEnabled,
    required this.mosaic,
  });

  factory FramingGeometry.of(FramingState state) => FramingGeometry(
    rotation: state.rotation,
    mosaicEnabled: state.mosaicEnabled,
    mosaic: state.mosaicConfig,
  );

  final double rotation;
  final bool mosaicEnabled;
  final FramingMosaicConfig mosaic;

  @override
  bool operator ==(Object other) =>
      other is FramingGeometry &&
      other.rotation == rotation &&
      other.mosaicEnabled == mosaicEnabled &&
      sameMosaic(other.mosaic, mosaic);

  static bool sameMosaic(FramingMosaicConfig a, FramingMosaicConfig b) =>
      a.columns == b.columns &&
      a.rows == b.rows &&
      a.overlapPercent == b.overlapPercent &&
      a.serpentine == b.serpentine &&
      a.startCorner == b.startCorner &&
      a.panelRotation == b.panelRotation;

  @override
  int get hashCode => Object.hash(
    rotation,
    mosaicEnabled,
    mosaic.columns,
    mosaic.rows,
    mosaic.overlapPercent,
    mosaic.serpentine,
    mosaic.startCorner,
    mosaic.panelRotation,
  );
}

/// Rotation and mosaic on the Framing screen, the same on both ends of a
/// link. Each window kept its own, so a 2x2 mosaic at 90 degrees laid out on
/// the client showed as a single frame at 0 degrees on the host. The target
/// travels separately, on the `framingTarget` channel.
class FramingGeometryChannel extends SharedStateChannel<FramingGeometry> {
  const FramingGeometryChannel();

  @override
  String get key => 'framingGeometry';

  @override
  get source => framingProvider.select(FramingGeometry.of);

  /// A rotation drag reports every pointer move.
  @override
  Duration get minInterval => const Duration(milliseconds: 150);

  @override
  Map<String, dynamic>? encode(FramingGeometry value) => {
    'rotation': finiteOrNull(value.rotation),
    'mosaicEnabled': value.mosaicEnabled,
    'columns': value.mosaic.columns,
    'rows': value.mosaic.rows,
    'overlapPercent': finiteOrNull(value.mosaic.overlapPercent),
    'serpentine': value.mosaic.serpentine,
    'startCorner': value.mosaic.startCorner.name,
    if (value.mosaic.panelRotation != null)
      'panelRotation': finiteOrNull(value.mosaic.panelRotation),
  };

  @override
  FramingGeometry decode(Map<String, dynamic>? json) {
    if (json == null) throw const FormatException('No framing geometry');
    return FramingGeometry(
      rotation: requireDouble(json, 'rotation'),
      mosaicEnabled: json['mosaicEnabled'] == true,
      mosaic: FramingMosaicConfig(
        columns: requireInt(json, 'columns'),
        rows: requireInt(json, 'rows'),
        overlapPercent: requireDouble(json, 'overlapPercent'),
        serpentine: json['serpentine'] == true,
        startCorner:
            MosaicStartCorner.values.asNameMap()[json['startCorner']] ??
            (throw const FormatException('Unknown mosaic start corner')),
        panelRotation: jsonDouble(json['panelRotation']),
      ),
    );
  }

  @override
  void write(RuntimeApplyContext context, FramingGeometry value) {
    final notifier = context.read(framingProvider.notifier);
    final current = FramingGeometry.of(context.read(framingProvider));
    if (current.rotation != value.rotation) {
      notifier.setRotation(value.rotation);
    }
    if (!FramingGeometry.sameMosaic(current.mosaic, value.mosaic)) {
      notifier.setMosaicConfig(value.mosaic);
    }
    if (current.mosaicEnabled != value.mosaicEnabled) {
      notifier.setMosaicEnabled(value.mosaicEnabled);
    }
  }
}
