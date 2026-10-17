// Responsive widget tests for the onboarding wizard shell.
//
// Pumps the full OnboardingScreen at the three reference phone sizes in BOTH
// orientations and asserts: no RenderFlex overflow, the primary action is
// present and reachable, the wizard reflows to a single column (the wide
// step-sidebar is NOT rendered on a phone), and the primary action meets the
// 48 px touch-target floor.
//
// See docs/plans/2026-06-01-mobile-responsive-standard.md.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/onboarding/onboarding_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

SkotiqDatabase _newDb() =>
    SkotiqDatabase.forTesting(NativeDatabase.memory());

/// The three reference phone sizes from the responsive standard, portrait.
const _phoneSizes = <(String, Size)>[
  ('small 360x640', Size(360, 640)),
  ('modern 390x844', Size(390, 844)),
  ('large 430x932', Size(430, 932)),
];

Future<ProviderContainer> _pumpWizard(
  WidgetTester tester, {
  required SkotiqDatabase db,
  required Size size,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  late ProviderContainer container;
  final router = GoRouter(
    initialLocation: '/onboarding',
    routes: [
      GoRoute(
        path: '/onboarding',
        builder: (ctx, _) => const OnboardingScreen(),
      ),
      GoRoute(
        path: '/dashboard',
        builder: (ctx, _) => const Scaffold(body: Text('dashboard stub')),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        // Keep the welcome step's profile watch from pulling the default
        // backend's recurring FFI timers into the widget test (they leak past
        // tear-down and stall the runner). See onboarding_steps_test.dart.
        allProfilesProvider.overrideWith((ref) => const Stream.empty()),
      ],
      child: Consumer(builder: (ctx, ref, _) {
        container = ProviderScope.containerOf(ctx);
        return MaterialApp.router(
          theme: SkotiqTheme.dark,
          routerConfig: router,
        );
      }),
    ),
  );
  await container.read(onboardingDraftProvider.notifier).loaded;
  await tester.pumpAndSettle();
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final (name, portrait) in _phoneSizes) {
    final landscape = Size(portrait.height, portrait.width);

    for (final entry in <(String, Size)>[
      ('portrait', portrait),
      ('landscape', landscape),
    ]) {
      final (orientation, size) = entry;

      // The wizard now tiers on DEVICE CLASS, not raw width: a phone is a phone
      // in either orientation (Responsive.isPhone uses the orientation-stable
      // short edge on a mobile platform — the test binding defaults to Android).
      // So a reference phone rotated to landscape (e.g. 844x390 / 932x430) still
      // gets the single-column phone wizard, NOT the desktop step-sidebar that
      // would clip the ~410 px height. Both orientations must lay out cleanly.
      final isPhoneColumn =
          (size.shortestSide < BreakpointTokens.breakpointPhone) ||
              (size.width < BreakpointTokens.breakpointPhone);

      testWidgets('onboarding fits $name $orientation without overflow',
          (tester) async {
        final db = _newDb();
        addTearDown(db.close);

        await _pumpWizard(tester, db: db, size: size);

        // No RenderFlex/overflow exceptions were thrown during layout.
        expect(tester.takeException(), isNull);

        // Welcome step is the entry point: its headline renders and the
        // primary "Next" action is present and reachable in both layouts.
        expect(find.text('Welcome to Skotiq'), findsOneWidget);
        expect(find.text('Next'), findsOneWidget);

        if (isPhoneColumn) {
          // Phone reflow: the wide step-sidebar label list is collapsed to a
          // progress bar, so the sidebar-only "Drivers" label is absent.
          expect(find.text('Drivers'), findsNothing);
          expect(find.byType(LinearProgressIndicator), findsOneWidget);
        } else {
          // ≥ 600 px wide: the sidebar layout. "Drivers" is near the top of the
          // step list, so it is built even when the sidebar's ListView is short
          // and the lower steps are scrolled off.
          expect(find.text('Drivers'), findsOneWidget);
          expect(find.byType(LinearProgressIndicator), findsNothing);
        }
      });

      if (isPhoneColumn) {
        testWidgets(
            'onboarding primary action meets touch target $name '
            '$orientation', (tester) async {
          final db = _newDb();
          addTearDown(db.close);

          await _pumpWizard(tester, db: db, size: size);

          final primary = find.byKey(phonePrimaryActionKey);
          expect(primary, findsOneWidget);
          // The primary action and the "Next" label live in the same region.
          expect(
            find.descendant(of: primary, matching: find.text('Next')),
            findsOneWidget,
          );
          final box = tester.renderObject<RenderBox>(primary);
          expect(
            box.size.height,
            greaterThanOrEqualTo(48.0 - 0.5),
            reason:
                'Onboarding primary action below 48px at $name $orientation',
          );
        });
      }
    }
  }

  testWidgets('phone column works in a short landscape-shaped viewport',
      (tester) async {
    // A narrow-but-landscape viewport (width < 600, width > height) — e.g. a
    // foldable inner-screen split or a very small phone rotated. The phone
    // column must still lay out without overflow and keep the primary action
    // reachable at the 48 px floor.
    final db = _newDb();
    addTearDown(db.close);

    await _pumpWizard(tester, db: db, size: const Size(560, 320));

    expect(tester.takeException(), isNull);
    expect(find.text('Welcome to Skotiq'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    final primary = find.byKey(phonePrimaryActionKey);
    expect(primary, findsOneWidget);
    final box = tester.renderObject<RenderBox>(primary);
    expect(box.size.height, greaterThanOrEqualTo(48.0 - 0.5));
  });

  testWidgets('wide viewport still renders the step sidebar (no regression)',
      (tester) async {
    final db = _newDb();
    addTearDown(db.close);

    await _pumpWizard(tester, db: db, size: const Size(1280, 900));

    // The wide layout keeps the step sidebar with its full label list.
    expect(find.text('Optical train'), findsOneWidget);
    expect(find.text('Welcome to Skotiq'), findsOneWidget);
    // The compact phone progress bar is NOT used on the wide layout.
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });
}
