import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Pins the load-bearing [SkotiqIcons] semantic roles to their intended
/// Lucide glyphs. These are the canonical icon surface screens adopt during the
/// design-system migration; a silent re-point would shift every adopting call
/// site at once, so the key device/status/action roles are locked here.
///
/// Mapping table of record: docs/design/overhaul/archive/icon-migration-map.md.
void main() {
  group('SkotiqIcons device roles → Lucide glyphs', () {
    test('equipment roles are wired to their intended glyphs', () {
      expect(SkotiqIcons.camera, LucideIcons.camera);
      expect(SkotiqIcons.mount, LucideIcons.mountain);
      expect(SkotiqIcons.focuser, LucideIcons.focus);
      expect(SkotiqIcons.filterWheel, LucideIcons.disc);
      expect(SkotiqIcons.guider, LucideIcons.crosshair);
      expect(SkotiqIcons.rotator, LucideIcons.rotateCw);
      expect(SkotiqIcons.dome, LucideIcons.warehouse);
      expect(SkotiqIcons.cover, LucideIcons.doorOpen);
      expect(SkotiqIcons.switch_, LucideIcons.toggleLeft);
    });
  });

  group('SkotiqIcons status roles → Lucide glyphs', () {
    test('status roles are wired to their intended glyphs', () {
      expect(SkotiqIcons.warning, LucideIcons.alertTriangle);
      expect(SkotiqIcons.error, LucideIcons.xCircle);
      expect(SkotiqIcons.success, LucideIcons.checkCircle);
      expect(SkotiqIcons.info, LucideIcons.info);
    });

    test('status roles are distinct from one another', () {
      final glyphs = <int>{
        SkotiqIcons.warning.codePoint,
        SkotiqIcons.error.codePoint,
        SkotiqIcons.success.codePoint,
        SkotiqIcons.info.codePoint,
      };
      expect(glyphs.length, 4, reason: 'each status must read distinctly');
    });
  });

  group('SkotiqIcons action / navigation roles', () {
    test('common action roles are wired to their intended glyphs', () {
      expect(SkotiqIcons.add, LucideIcons.plus);
      expect(SkotiqIcons.delete, LucideIcons.trash2);
      expect(SkotiqIcons.edit, LucideIcons.pencil);
      expect(SkotiqIcons.refresh, LucideIcons.refreshCw);
      expect(SkotiqIcons.search, LucideIcons.search);
      expect(SkotiqIcons.close, LucideIcons.x);
      expect(SkotiqIcons.settings, LucideIcons.settings);
    });

    test('transport controls are wired to their intended glyphs', () {
      expect(SkotiqIcons.play, LucideIcons.play);
      expect(SkotiqIcons.pause, LucideIcons.pause);
      expect(SkotiqIcons.stop, LucideIcons.square);
    });

    test('disclosure chevrons are wired to their intended glyphs', () {
      expect(SkotiqIcons.chevronDown, LucideIcons.chevronDown);
      expect(SkotiqIcons.chevronUp, LucideIcons.chevronUp);
      expect(SkotiqIcons.chevronLeft, LucideIcons.chevronLeft);
      expect(SkotiqIcons.chevronRight, LucideIcons.chevronRight);
    });
  });

  group('SkotiqIcons weather / data roles', () {
    test('weather + data roles are wired to their intended glyphs', () {
      expect(SkotiqIcons.weather, LucideIcons.cloudSun);
      expect(SkotiqIcons.cloud, LucideIcons.cloud);
      expect(SkotiqIcons.moon, LucideIcons.moon);
      expect(SkotiqIcons.disk, LucideIcons.hardDrive);
      expect(SkotiqIcons.database, LucideIcons.database);
    });
  });
}
