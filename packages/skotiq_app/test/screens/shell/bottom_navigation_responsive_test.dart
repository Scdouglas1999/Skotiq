// Responsive widget tests for the shell bottom navigation.
//
// The bottom nav hosts exactly five fixed-width slots — four routes plus the
// More overflow (04-shell §3.3). They must all fit without overflow or
// horizontal scroll at the three reference phone sizes in BOTH orientations,
// keep their tap targets at the touch-target floor, and honor SafeArea (the
// home indicator).
//
// See docs/plans/2026-06-01-mobile-responsive-standard.md.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/widgets/skotiq_bottom_navigation.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

const _phoneSizes = <(String, Size)>[
  ('small 360x640', Size(360, 640)),
  ('modern 390x844', Size(390, 844)),
  ('large 430x932', Size(430, 932)),
];

Future<void> _pumpNav(
  WidgetTester tester, {
  required Size size,
  EdgeInsets viewPadding = EdgeInsets.zero,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    MaterialApp(
      theme: SkotiqTheme.dark,
      home: MediaQuery(
        // Simulate a home-indicator inset so SafeArea handling is exercised.
        data: MediaQueryData(
            size: size, viewPadding: viewPadding, padding: viewPadding),
        child: Scaffold(
          bottomNavigationBar: SkotiqBottomNavigation(
            currentRoute: '/dashboard',
            onRouteSelected: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final (name, portrait) in _phoneSizes) {
    final landscape = Size(portrait.height, portrait.width);

    for (final entry in <(String, Size)>[
      ('portrait', portrait),
      ('landscape', landscape),
    ]) {
      final (orientation, size) = entry;

      testWidgets('bottom nav fits $name $orientation without overflow',
          (tester) async {
        await _pumpNav(
          tester,
          size: size,
          viewPadding: const EdgeInsets.only(bottom: 34),
        );

        expect(tester.takeException(), isNull);

        // All five slots lay out at once (no horizontal scroll). Plan,
        // Equipment and Weather are behind More now, which is what buys the
        // remaining slots room for their full labels.
        expect(find.byType(SkotiqBottomNavigation), findsOneWidget);
        expect(find.text('Tonight'), findsOneWidget);
        expect(find.text('Guiding'), findsOneWidget);
        expect(find.text('More'), findsOneWidget);
        expect(find.text('Plan'), findsNothing,
            reason: 'Plan reaches the phone through the More sheet');
        expect(find.byType(Scrollable), findsNothing);
      });

      testWidgets('bottom nav tap targets are adequate $name $orientation',
          (tester) async {
        await _pumpNav(tester, size: size);

        final inkWells = tester.widgetList<InkWell>(find.byType(InkWell));
        expect(inkWells, isNotEmpty);
        for (final inkWell in inkWells) {
          final context = tester.element(find.byWidget(inkWell));
          final box = context.findRenderObject() as RenderBox?;
          if (box == null || !box.hasSize) continue;
          expect(
            box.size.height,
            greaterThanOrEqualTo(SkotiqTokens.minTouchTarget - 1),
            reason: 'Bottom nav tap target too short at $name $orientation',
          );
        }
      });
    }
  }
}
