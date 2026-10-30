import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  test('image themes reuse their parent and retain unrelated extensions', () {
    final marker = _Marker();
    final parent = SkotiqTheme.light.copyWith(
      extensions: [...SkotiqTheme.light.extensions.values, marker],
    );
    final image = SkotiqTheme.imageSurface(parent);
    expect(identical(SkotiqTheme.imageSurface(parent), image), isTrue);
    expect(image.extension<_Marker>(), same(marker));
    expect(
      identical(SkotiqTheme.imageSurface(SkotiqTheme.dark), SkotiqTheme.dark),
      isTrue,
    );
  });

  for (final setting in ['dark', 'light', 'redNight']) {
    testWidgets('image controls retain $setting accent in both theme systems', (
      tester,
    ) async {
      final theme = resolveSkotiqThemeData(
        themeSetting: setting,
        accentColorHex: '#43B67A',
      );
      final expected = theme.extension<SkotiqColors>()!.primary;
      late ThemeData inner;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Glass(
              child: Builder(
                builder: (context) {
                  inner = Theme.of(context);
                  return SkotiqButton(label: 'Capture', onPressed: () {});
                },
              ),
            ),
          ),
        ),
      );
      expect(inner.extension<SkotiqColors>()!.primary, expected);
      expect(inner.colorScheme.primary, expected);
      expect(inner.brightness, Brightness.dark);
    });
  }
}

class _Marker extends ThemeExtension<_Marker> {
  @override
  _Marker copyWith() => this;
  @override
  _Marker lerp(covariant _Marker? other, double t) => this;
}
