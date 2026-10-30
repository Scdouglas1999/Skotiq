import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'golden/golden_harness.dart';

double contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return x > y ? (x + 0.05) / (y + 0.05) : (y + 0.05) / (x + 0.05);
}

void main() {
  setUpAll(() async {
    // Material controls also draw built-in checkmarks; load their real glyphs.
    var directory = File(Platform.resolvedExecutable).parent;
    while (directory.parent.path != directory.path) {
      final font = File(
        '${directory.path}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      );
      if (font.existsSync()) {
        await (FontLoader('MaterialIcons')..addFont(
              Future.value(ByteData.sublistView(font.readAsBytesSync())),
            ))
            .load();
        return;
      }
      directory = directory.parent;
    }
    throw StateError('Flutter Material icon font not found');
  });

  test('default red and saved violet resolve independently', () {
    expect(SkotiqTheme.dark.colorScheme.primary, const Color(0xFFE86A6A));
    expect(SkotiqTheme.light.colorScheme.primary, const Color(0xFFBC3838));
    expect(
      resolveSkotiqThemeData(
        themeSetting: 'dark',
        accentColorHex: '#A48CF2',
      ).colorScheme.primary,
      const Color(0xFFA48CF2),
    );
  });

  for (final mode in ['dark', 'light', 'redNight']) {
    final theme = resolveSkotiqThemeData(
      themeSetting: mode,
      accentColorHex: '#43B67A',
    );
    final colors = theme.extension<SkotiqColors>()!;
    test('$mode filters are readable and unknown filters stay neutral', () {
      for (final filter in ['L', 'R', 'G', 'B', 'Ha', 'OIII', 'SII', 'NII']) {
        final color = FilterColors.forName(filter, colors: colors);
        if (mode == 'redNight') {
          expect(color.r, greaterThan(color.g));
          expect(color.r, greaterThan(color.b));
        } else {
          expect(
            contrast(color, colors.surface),
            greaterThanOrEqualTo(4.5),
            reason: '$filter in $mode',
          );
        }
      }
      expect(
        FilterColors.forName('Custom', colors: colors),
        colors.textSecondary,
      );
      expect(FilterColors.knownColor('Hardware'), isNull);
      expect(FilterColors.knownColor('Ha 7nm'), FilterColors.hydrogenAlpha);
    });
    test('$mode Material controls use shared state colors', () {
      final selected = {WidgetState.selected};
      expect(
        theme.iconButtonTheme.style!.foregroundColor!.resolve(selected),
        colors.primary,
      );
      expect(
        theme.iconButtonTheme.style!.backgroundColor!.resolve(selected),
        colors.primary.withValues(alpha: SkotiqTokens.opacityAccentTint),
      );
      expect(
        theme.segmentedButtonTheme.style!.backgroundColor!.resolve(selected),
        colors.surfaceHover,
      );
      expect(
        theme.segmentedButtonTheme.style!.foregroundColor!.resolve(selected),
        colors.textPrimary,
      );
      expect(
        theme.iconButtonTheme.style!.foregroundColor!.resolve({
          WidgetState.disabled,
        }),
        colors.textSecondary.withValues(alpha: SkotiqTokens.opacityDisabled),
      );
      expect(theme.colorScheme.tertiary, colors.primary);
      if (mode != 'redNight') {
        expect(
          contrast(theme.colorScheme.onPrimary, colors.primary),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(theme.colorScheme.onError, colors.error),
          greaterThanOrEqualTo(4.5),
        );
      }
    });
    testWidgets('$mode shared and Material controls render together', (
      tester,
    ) async {
      final file = await GoldenHarness.capture(
        tester,
        fileName: 'shared-controls-$mode.png',
        theme: theme,
        size: const Size(900, 650),
        pixelRatio: 1,
        child: Material(
          color: colors.background,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Shared controls — $mode', style: SkotiqTypography.h2),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 12,
                  children: [
                    SkotiqButton(label: 'Capture', onPressed: () {}),
                    FilledButton(
                      onPressed: () {},
                      child: const Text('Capture'),
                    ),
                    OutlinedButton(
                      onPressed: () {},
                      child: const Text('Configure'),
                    ),
                    const FilledButton(
                      onPressed: null,
                      child: Text('Unavailable'),
                    ),
                    IconButton(
                      isSelected: true,
                      onPressed: () {},
                      icon: const Icon(Icons.star),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0, label: Text('Overview')),
                    ButtonSegment(value: 1, label: Text('Details')),
                  ],
                  selected: const {0},
                  onSelectionChanged: (_) {},
                ),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 12,
                  children: [
                    for (final filter in ['L', 'R', 'G', 'B', 'Ha'])
                      ChoiceChip(
                        label: Text(filter),
                        avatar: Icon(
                          Icons.circle,
                          color: FilterColors.forName(filter, colors: colors),
                          size: 12,
                        ),
                        selected: filter == 'Ha',
                        onSelected: (_) {},
                      ),
                  ],
                ),
                const SizedBox(height: 24),
                Glass(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Wrap(
                      spacing: 12,
                      children: [
                        SkotiqButton(label: 'Center target', onPressed: () {}),
                        FilledButton(
                          onPressed: () {},
                          child: const Text('Image controls'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      expect(file.existsSync(), isTrue);
      expect(tester.takeException(), isNull);
    });
  }
}
