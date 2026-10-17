import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  group('SkotiqDecorations', () {
    test('iconChip applies subtle fill and border alpha', () {
      const color = Color(0xFF5B9EC4);
      final decoration = SkotiqDecorations.iconChip(color);

      expect(decoration.color, color.withValues(alpha: 0.1));
      expect(
        decoration.border,
        Border.all(color: color.withValues(alpha: 0.16)),
      );
    });

    test('emphasisSurface uses strong border alpha', () {
      const color = Color(0xFFD49A3A);
      final decoration = SkotiqDecorations.emphasisSurface(color);

      expect(decoration.color, color.withValues(alpha: 0.1));
      expect(
        decoration.border,
        Border.all(color: color.withValues(alpha: 0.3)),
      );
    });

    test('filledButtonColors lightens on hover', () {
      const base = Color(0xFF3DAA6D);
      final normal = SkotiqDecorations.filledButtonColors(
        base,
        isHovered: false,
        isDisabled: false,
      );
      final hovered = SkotiqDecorations.filledButtonColors(
        base,
        isHovered: true,
        isDisabled: false,
      );

      expect(normal.background, base);
      expect(hovered.background, Color.lerp(base, Colors.white, 0.04));
      expect(normal.border, Color.lerp(base, Colors.black, 0.12));
    });

    test('kpiBadge keeps its shape and drops its border', () {
      const color = Color(0xFF3DAA6D);
      final decoration = SkotiqDecorations.kpiBadge(color);

      expect(
        decoration.color,
        color.withValues(alpha: SkotiqTokens.opacityStatusFill),
      );
      // A chip has no border in this language: the fill is its boundary. The
      // SHAPE survives, because a circle and a rounded rect are not one box.
      expect(decoration.border, isNull);
      expect(decoration.shape, BoxShape.circle);
    });

    test('cardSelected uses a 4% tint and a 50% ring, without shadow', () {
      const accent = Color(0xFF5B9EC4);
      const background = Color(0xFF111418);
      final decoration = SkotiqDecorations.cardSelected(
        accent,
        background: background,
      );

      expect(
        decoration.color,
        Color.alphaBlend(accent.withValues(alpha: 0.04), background),
      );
      expect(decoration.boxShadow, isNull);
      expect(
        decoration.border,
        Border.all(
          color: accent.withValues(alpha: SkotiqTokens.opacitySelectedRing),
        ),
      );
    });

    test('dragFeedback is the popover decoration', () {
      const colors = SkotiqColors.dark;
      final decoration = SkotiqDecorations.dragFeedback(colors);

      expect(decoration, SkotiqDecorations.popover(colors));
      expect(decoration.boxShadow, isNotNull);
    });

    test('statusChip uses status fill alpha', () {
      const color = Color(0xFF3DAA6D);
      final decoration = SkotiqDecorations.statusChip(color);

      expect(
        decoration.color,
        color.withValues(alpha: SkotiqTokens.opacityStatusFill),
      );
    });

    testWidgets('SkotiqColors.of resolves theme extension', (tester) async {
      const colors = SkotiqColors.dark;
      late BuildContext context;

      await tester.pumpWidget(
        MaterialApp(
          theme: SkotiqTheme.dark,
          home: Builder(
            builder: (ctx) {
              context = ctx;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(SkotiqColors.of(context).primary, colors.primary);
    });
  });
}
