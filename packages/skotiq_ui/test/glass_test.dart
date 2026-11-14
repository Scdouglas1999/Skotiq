import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

const _sceneKey = ValueKey('scene');
const _contentKey = ValueKey('content');

Future<Uint8List> _paintPanel(
  WidgetTester tester, {
  required ThemeData theme,
  required Color stripe,
  required bool blur,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Center(
        child: RepaintBoundary(
          key: _sceneKey,
          child: SizedBox(
            width: 160,
            height: 100,
            child: Stack(
              children: [
                Positioned.fill(child: CustomPaint(painter: _Stripes(stripe))),
                Center(
                  child: Glass(
                    blurBackground: blur,
                    padding: const EdgeInsets.all(8),
                    child: const SizedBox(
                      key: _contentKey,
                      width: 80,
                      height: 40,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_sceneKey),
  );
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage();
    try {
      return await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    } finally {
      image.dispose();
    }
  });
  return bytes!.buffer.asUint8List();
}

Color _pixel(Uint8List bytes, int x, int y) {
  final offset = (y * 160 + x) * 4;
  return Color.fromARGB(
    bytes[offset + 3],
    bytes[offset],
    bytes[offset + 1],
    bytes[offset + 2],
  );
}

void _expectColor(Color actual, Color expected) {
  for (final pair in [
    (actual.r, expected.r),
    (actual.g, expected.g),
    (actual.b, expected.b),
    (actual.a, expected.a),
  ]) {
    expect(pair.$1, closeTo(pair.$2, 2 / 255));
  }
}

void main() {
  for (final (name, theme, colors, stripe) in [
    ('dark', SkotiqTheme.dark, SkotiqColors.dark, Colors.white),
    ('light', SkotiqTheme.light, SkotiqColors.light, Colors.white),
    ('red night', SkotiqTheme.redNight, SkotiqColors.redNight, Colors.red),
  ]) {
    testWidgets('unblurred glass preserves tint and rounded clip in $name', (
      tester,
    ) async {
      final bytes = await _paintPanel(
        tester,
        theme: theme,
        stripe: stripe,
        blur: false,
      );
      final tint = SkotiqDecorations.glass(colors).color!;
      _expectColor(_pixel(bytes, 66, 50), Color.alphaBlend(tint, stripe));
      _expectColor(_pixel(bytes, 74, 50), Color.alphaBlend(tint, Colors.black));

      final panel = tester.getRect(find.byType(Glass));
      final scene = tester.getRect(find.byKey(_sceneKey));
      final x = (panel.left - scene.left).floor() + 1;
      final y = (panel.top - scene.top).floor() + 1;
      _expectColor(
        _pixel(bytes, x, y),
        (x ~/ 8).isEven ? stripe : Colors.black,
      );
    });
  }

  testWidgets(
    'disabling blur keeps layout and preserves sharper image detail',
    (tester) async {
      final blurred = await _paintPanel(
        tester,
        theme: SkotiqTheme.dark,
        stripe: Colors.white,
        blur: true,
      );
      final panelRect = tester.getRect(find.byType(Glass));
      final contentRect = tester.getRect(find.byKey(_contentKey));
      final sharp = await _paintPanel(
        tester,
        theme: SkotiqTheme.dark,
        stripe: Colors.white,
        blur: false,
      );
      expect(tester.getRect(find.byType(Glass)), panelRect);
      expect(tester.getRect(find.byKey(_contentKey)), contentRect);
      final sharpContrast = (_pixel(sharp, 66, 50).r - _pixel(sharp, 74, 50).r)
          .abs();
      final blurredContrast =
          (_pixel(blurred, 66, 50).r - _pixel(blurred, 74, 50).r).abs();
      expect(sharpContrast, greaterThan(blurredContrast + 0.1));
    },
  );
}

class _Stripes extends CustomPainter {
  const _Stripes(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
    for (var x = 0.0; x < size.width; x += 16) {
      canvas.drawRect(
        Rect.fromLTWH(x, 0, 8, size.height),
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_Stripes oldDelegate) => color != oldDelegate.color;
}
