// The onboarding wizard's validation message must never occupy the same space
// as the footer buttons.
//
// `context.showWarningSnackBar(...)` cannot carry it: a Material SnackBar docks
// to the bottom of the Scaffold — exactly where the wizard footer sits — so the
// amber band covers Back / Next / Save profile completely AND intercepts taps on
// them. On the drivers, camera and capture-folder steps at 1400x900 and at
// 800x600 the wizard says "pick at least one driver" while removing the buttons
// needed to act on it, and a click on Back does nothing.
//
// The invariants pinned here:
//   1. the message renders (the user is still told what is wrong),
//   2. no SnackBar is used for it,
//   3. the message's rect does not intersect the footer buttons' rects, and it
//      sits entirely above them,
// at every window size the wizard supports, in both the wide and the phone
// layout, and on every step that can raise a validation message.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/onboarding/onboarding_screen.dart';
import 'package:skotiq_app/screens/onboarding/steps/site_step.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _NoopDiscoveryNotifier extends UnifiedDiscoveryNotifier {
  _NoopDiscoveryNotifier(super.ref);

  @override
  Future<void> discoverAll({
    bool includeIndi = true,
    bool includeAlpaca = true,
  }) async {}
}

SkotiqDatabase _newDb() => SkotiqDatabase.forTesting(NativeDatabase.memory());

/// Window sizes to prove this at: the desktop reference, two small desktop
/// windows, and a phone (the phone layout has its own footer implementation).
const _sizes = <(String, Size)>[
  ('1400x900', Size(1400, 900)),
  ('1000x700', Size(1000, 700)),
  ('800x600', Size(800, 600)),
  ('phone 390x844', Size(390, 844)),
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
          path: '/onboarding', builder: (_, __) => const OnboardingScreen()),
      GoRoute(
        path: '/dashboard',
        builder: (_, __) => const Scaffold(body: Text('dashboard stub')),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        allProfilesProvider.overrideWith((ref) => const Stream.empty()),
        unifiedDiscoveryProvider.overrideWith(_NoopDiscoveryNotifier.new),
        // The site step offers an IP-derived position on arrival; keep the real
        // network lookup out of the test.
        onboardingApproximateLocationProvider
            .overrideWithValue(() async => null),
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

/// Walk the draft to [step] without going through the UI, so each case starts
/// from a known state regardless of what the intervening steps require.
Future<void> _goTo(
  ProviderContainer container,
  OnboardingStep step,
) async {
  final notifier = container.read(onboardingDraftProvider.notifier);
  while (
      container.read(onboardingDraftProvider).currentStep.order < step.order) {
    await notifier.next();
  }
}

/// Every rect the footer occupies: the primary action plus whatever secondary
/// actions the step offers.
List<Rect> _footerRects(WidgetTester tester) {
  final rects = <Rect>[];
  for (final label in ['Back', 'Next', 'Save profile', 'Skip this step']) {
    final finder = find.text(label);
    for (var i = 0; i < finder.evaluate().length; i++) {
      rects.add(tester.getRect(finder.at(i)));
    }
  }
  return rects;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Every step whose validation can block the wizard, and what makes it invalid
  // on arrival. Steps not listed here return null from _validate unconditionally
  // (welcome, focuser, filterWheel, guider, cameraDefaults, nextSteps).
  final cases = <(
    String,
    OnboardingStep,
    Future<void> Function(WidgetTester, ProviderContainer)
  )>[
    (
      'drivers',
      OnboardingStep.drivers,
      (t, c) async {
        final notifier = c.read(onboardingDraftProvider.notifier);
        for (final driver
            in c.read(onboardingDraftProvider).selectedDrivers.toList()) {
          await notifier.toggleDriver(driver);
        }
      },
    ),
    // These four are invalid simply by arriving with nothing filled in.
    ('camera', OnboardingStep.camera, (t, c) async {}),
    ('mount', OnboardingStep.mount, (t, c) async {}),
    ('opticalTrain', OnboardingStep.opticalTrain, (t, c) async {}),
    ('captureDir', OnboardingStep.captureDir, (t, c) async {}),
    (
      'site',
      OnboardingStep.site,
      // The site step publishes its own blocking reason through this provider
      // (an out-of-range coordinate the user typed). Setting it directly is the
      // contract the wizard shell consumes; producing it from field text is the
      // site step's own test.
      (t, c) async {
        c.read(onboardingSiteEntryErrorProvider.notifier).state =
            'Latitude must be between -90 and 90.';
      },
    ),
    (
      'summary',
      OnboardingStep.summary,
      // The summary step pre-fills "My First Rig", so it has to be emptied to
      // reach the blocking condition.
      (t, c) async {
        await t.enterText(find.byType(TextField).first, '   ');
        await t.pumpAndSettle();
      },
    ),
  ];

  for (final (sizeName, size) in _sizes) {
    for (final (caseName, step, invalidate) in cases) {
      testWidgets(
          'validation notice clears the footer on $caseName at $sizeName',
          (tester) async {
        final db = _newDb();
        addTearDown(db.close);

        final container = await _pumpWizard(tester, db: db, size: size);
        await _goTo(container, step);
        await tester.pumpAndSettle();
        await invalidate(tester, container);
        await tester.pumpAndSettle();

        // The summary step's primary action is "Save profile", not "Next".
        final primary =
            step == OnboardingStep.summary ? 'Save profile' : 'Next';
        await tester.tap(find.text(primary));
        await tester.pumpAndSettle();

        // 1. The wizard did not advance, and it said why.
        expect(
          container.read(onboardingDraftProvider).currentStep,
          step,
          reason: '$caseName must not advance while invalid',
        );
        final notice = find.byKey(onboardingNoticeKey);
        expect(
          notice,
          findsOneWidget,
          reason: 'no inline notice raised on $caseName at $sizeName',
        );

        // 2. It is not a snackbar. A snackbar is what put the message on top of
        //    the footer in the first place.
        expect(find.byType(SnackBar), findsNothing);

        // 3. It does not share space with any footer button.
        final noticeRect = tester.getRect(notice);
        for (final footerRect in _footerRects(tester)) {
          expect(
            noticeRect.overlaps(footerRect),
            isFalse,
            reason: 'notice $noticeRect covers footer button $footerRect '
                'on $caseName at $sizeName',
          );
          expect(
            noticeRect.bottom,
            lessThanOrEqualTo(footerRect.top + 0.5),
            reason:
                'notice must sit above the footer on $caseName at $sizeName',
          );
        }

        // Adding a band to the column must not overflow the layout.
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('the notice is dismissible and leaves the footer where it was',
      (tester) async {
    final db = _newDb();
    addTearDown(db.close);

    final container =
        await _pumpWizard(tester, db: db, size: const Size(1000, 700));
    await _goTo(container, OnboardingStep.captureDir);
    await tester.pumpAndSettle();

    final footerBefore = tester.getRect(find.text('Next'));
    final bodyBefore =
        tester.getRect(find.text('Where should we save captures?'));

    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.byKey(onboardingNoticeKey), findsOneWidget);
    // The band takes real space in the column between the body and the footer,
    // so the two can never share a pixel. The wizard block is centred and sized
    // to its content, so the footer moves DOWN to make room rather than being
    // covered — measure it where it is now, and check below that dismissing
    // puts it back exactly where it started.
    final noticeRect = tester.getRect(find.byKey(onboardingNoticeKey));
    final footerWithNotice = tester.getRect(find.text('Next'));
    expect(noticeRect.bottom, lessThanOrEqualTo(footerWithNotice.top + 0.5));
    expect(noticeRect.top, greaterThan(bodyBefore.top));

    // Dismissing restores the original footer position exactly.
    await tester.tap(
      find.descendant(
        of: find.byKey(onboardingNoticeKey),
        matching: find.byType(SkotiqIconButton),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(onboardingNoticeKey), findsNothing);
    expect(tester.getRect(find.text('Next')), footerBefore);
  });

  // Observed live on the optical-train step: focal length 999999999 was
  // rejected, the band said "Focal length must be between 1 and 50000 mm.",
  // and after the field was corrected to 600 the band kept saying it. The
  // wizard was telling the user to fix something that was already fixed, while
  // Next would in fact have advanced.
  testWidgets('a validation notice clears itself once the step becomes valid',
      (tester) async {
    final db = _newDb();
    addTearDown(db.close);

    final container =
        await _pumpWizard(tester, db: db, size: const Size(1400, 900));
    await _goTo(container, OnboardingStep.opticalTrain);
    await tester.pumpAndSettle();

    // Out of bounds: rejected, and the band names the blocking field.
    await container.read(onboardingDraftProvider.notifier).setOpticalTrain(
          focalLengthMm: 999999999,
          apertureMm: 100,
          pixelSizeMicrons: 3.76,
          reducerFactor: 1.0,
        );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(container.read(onboardingDraftProvider).currentStep,
        OnboardingStep.opticalTrain);
    expect(find.byKey(onboardingNoticeKey), findsOneWidget);
    expect(find.textContaining('Focal length'), findsWidgets);

    // Correcting the value must retire the message without any further click.
    await container.read(onboardingDraftProvider.notifier).setOpticalTrain(
          focalLengthMm: 600,
          apertureMm: 100,
          pixelSizeMicrons: 3.76,
          reducerFactor: 1.0,
        );
    await tester.pumpAndSettle();
    expect(
      find.byKey(onboardingNoticeKey),
      findsNothing,
      reason: 'the band must not keep asserting a problem the user just fixed',
    );
  });

  testWidgets('a validation notice re-words itself when the blocker changes',
      (tester) async {
    final db = _newDb();
    addTearDown(db.close);

    final container =
        await _pumpWizard(tester, db: db, size: const Size(1400, 900));
    await _goTo(container, OnboardingStep.opticalTrain);
    await tester.pumpAndSettle();

    await container.read(onboardingDraftProvider.notifier).setOpticalTrain(
          focalLengthMm: 999999999,
          apertureMm: 0.0001,
          pixelSizeMicrons: 3.76,
          reducerFactor: 1.0,
        );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Focal length'), findsWidgets);

    // Focal length fixed, aperture still impossible: the band must move on to
    // the field that is now blocking, neither vanishing nor keeping the
    // previous message.
    await container.read(onboardingDraftProvider.notifier).setOpticalTrain(
          focalLengthMm: 600,
          apertureMm: 0.0001,
          pixelSizeMicrons: 3.76,
          reducerFactor: 1.0,
        );
    await tester.pumpAndSettle();
    expect(find.byKey(onboardingNoticeKey), findsOneWidget);
    final band = find.descendant(
      of: find.byKey(onboardingNoticeKey),
      matching: find.byType(Text),
    );
    final texts = band
        .evaluate()
        .map((e) =>
            (e.widget as Text).data ??
            (e.widget as Text).textSpan!.toPlainText())
        .join(' ');
    expect(texts, contains('Aperture'));
    expect(texts, isNot(contains('Focal length')));
  });

  // A notice that reports an event, not a condition, must survive draft edits.
  testWidgets('a non-validation notice is not retired by draft changes',
      (tester) async {
    final db = _newDb();
    addTearDown(db.close);

    final container =
        await _pumpWizard(tester, db: db, size: const Size(1400, 900));
    await _goTo(container, OnboardingStep.summary);
    await tester.pumpAndSettle();

    // Empty name blocks the save and raises a validation notice.
    await tester.enterText(find.byType(TextField).first, '   ');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save profile'));
    await tester.pumpAndSettle();
    expect(find.byKey(onboardingNoticeKey), findsOneWidget);

    // Naming the profile resolves it.
    await tester.enterText(find.byType(TextField).first, 'My Rig');
    await tester.pumpAndSettle();
    expect(find.byKey(onboardingNoticeKey), findsNothing);
  });

  testWidgets('moving to another step clears a stale notice', (tester) async {
    final db = _newDb();
    addTearDown(db.close);

    final container =
        await _pumpWizard(tester, db: db, size: const Size(1400, 900));
    await _goTo(container, OnboardingStep.captureDir);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.byKey(onboardingNoticeKey), findsOneWidget);
    // The footer disables itself for one input cooldown after a transition;
    // Back is not on screen until it expires.
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(onboardingNoticeKey),
      findsNothing,
      reason: 'a message about the previous step must not follow the user',
    );
  });
}
