import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/equipment/widgets/backend_protocol_colors.dart';
import 'package:skotiq_app/screens/imaging/widgets/annotation_status_colors.dart';
import 'package:skotiq_app/widgets/annotation_overlay/annotation_type_colors.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  group('BackendProtocolColors', () {
    test('maps each backend to a distinct semantic hue', () {
      const colors = SkotiqColors.dark;

      expect(
        BackendProtocolColors.forBackend(DriverType.native, colors),
        colors.success,
      );
      expect(
        BackendProtocolColors.forBackend(DriverType.ascom, colors),
        colors.info,
      );
      expect(
        BackendProtocolColors.forBackend(DriverType.alpaca, colors),
        colors.warning,
      );
      expect(
        BackendProtocolColors.forBackend(DriverType.indi, colors),
        BackendProtocolColors.indi,
      );
      expect(
        BackendProtocolColors.forBackend(DriverType.simulator, colors),
        colors.textMuted,
      );
    });
  });

  group('AnnotationTypeColors', () {
    test('maps catalog types to theme-aligned colors', () {
      const colors = SkotiqColors.dark;

      expect(
        AnnotationTypeColors.forType(ObjectType.nebula, colors),
        AnnotationTypeColors.nebula,
      );
      expect(
        AnnotationTypeColors.forType(ObjectType.unknown, colors),
        colors.textMuted,
      );
    });
  });

  group('AnnotationStatusColors', () {
    test('derives status colors from theme semantics', () {
      const colors = SkotiqColors.dark;

      expect(
        AnnotationStatusColors.background(AnnotationStatus.complete, colors),
        isNot(Colors.transparent),
      );
      expect(
        AnnotationStatusColors.border(AnnotationStatus.error, colors),
        colors.error.withValues(alpha: 0.5),
      );
      expect(
        AnnotationStatusColors.background(AnnotationStatus.idle, colors),
        Colors.transparent,
      );
    });
  });
}
