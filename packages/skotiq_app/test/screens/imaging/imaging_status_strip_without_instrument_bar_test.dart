// Imaging carries its own status strip exactly where the shell has no
// instrument bar. A phone held sideways and a tablet had neither: the strip
// followed the window width, the instrument bar the shell's navigation.
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/imaging_screen.dart';
import 'package:skotiq_app/screens/imaging/widgets/guiding_active_chip.dart';
import 'package:skotiq_app/screens/imaging/widgets/imaging_status_strip.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/utils.dart' show DeviceTraits;

import '../../harness/pump_app_screen.dart';

CapturedImageData _frame() => CapturedImageData(
      width: 64,
      height: 48,
      displayData: Uint8List(64 * 48 * 4),
      histogram: List<int>.filled(256, 0),
      stats: const ImageStats(mean: 0, stdDev: 0),
      capturedAt: DateTime.utc(2026, 11, 27, 22),
      settings: const ExposureSettings(exposureTime: 10, gain: 100, offset: 10),
      filePath: '/tmp/light_layout.fits',
    );

void main() {
  const layouts = <(String, Size, DeviceTraits, bool)>[
    ('phone portrait', Size(390, 844), DeviceTraits.phone, true),
    ('phone landscape', Size(844, 390), DeviceTraits.phone, true),
    ('tablet landscape', Size(1024, 768), DeviceTraits.phone, true),
    ('narrow desktop window', Size(700, 900), DeviceTraits.desktop, true),
    ('desktop', Size(1440, 900), DeviceTraits.desktop, false),
  ];

  for (final (name, size, traits, strip) in layouts) {
    testWidgets(
        '$name: ${strip ? 'the strip, not the frame chip' : 'no strip'}',
        (tester) async {
      DeviceTraits.debugOverride = traits;
      addTearDown(() => DeviceTraits.debugOverride = null);
      final handle = await pumpAppScreen(
        tester,
        const ImagingScreen(),
        size: size,
        settle: false,
      );
      handle.container.read(currentImageProvider.notifier).state = _frame();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(
        find.byType(ImagingStatusStrip),
        strip ? findsOneWidget : findsNothing,
      );
      // The guiding RMS has one place: the strip, or the chip on the frame.
      expect(
        find.byType(GuidingActiveChip),
        strip ? findsNothing : findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
