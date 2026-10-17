// Regression tests for the Android system back gesture inside the onboarding
// wizard.
//
// `/onboarding` is the app's only route presented ABOVE the shell, so the
// shell's back dispatcher (app_shell.dart) never sees it. The wizard renders
// its own "Back" button — a valid back destination exists — but the system
// gesture was not wired to it, so an edge swipe on step 2 of 13 dropped a
// first-run user straight to the launcher mid-setup.

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/onboarding/onboarding_screen.dart';
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

SkotiqDatabase _newDb() =>
    SkotiqDatabase.forTesting(NativeDatabase.memory());

/// Records whether the engine was asked to leave the app.
class _SystemExitRecorder {
  bool exited = false;

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemNavigator.pop') exited = true;
      return null;
    });
  }

  void restore() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  }
}

Future<ProviderContainer> _pumpWizard(
  WidgetTester tester, {
  Size size = const Size(411, 914),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final db = _newDb();
  addTearDown(db.close);
  late ProviderContainer container;
  final router = GoRouter(
    initialLocation: '/onboarding',
    routes: [
      GoRoute(
        path: '/onboarding',
        builder: (_, __) => const OnboardingScreen(),
      ),
      GoRoute(
        path: '/dashboard',
        builder: (_, __) => const Scaffold(body: Text('Dashboard')),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        allProfilesProvider.overrideWith((ref) => const Stream.empty()),
        unifiedDiscoveryProvider.overrideWith(_NoopDiscoveryNotifier.new),
      ],
      child: Consumer(builder: (context, ref, _) {
        container = ProviderScope.containerOf(context);
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

/// Drives the platform back gesture the way the engine does: hand the pop to
/// the binding's observers and fall through to `SystemNavigator.pop` when none
/// of them claims it.
Future<void> _systemBack(WidgetTester tester) async {
  // ignore: invalid_use_of_protected_member
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('system back on a middle step returns to the previous step', (
    tester,
  ) async {
    final container = await _pumpWizard(tester);
    final exit = _SystemExitRecorder();
    addTearDown(exit.restore);

    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(
      container.read(onboardingDraftProvider).currentStep,
      OnboardingStep.drivers,
      reason: 'Precondition: the wizard is on step 2 of the flow.',
    );

    // The wizard ignores input for one cooldown after a transition; let it
    // expire so the gesture below is the thing under test.
    await tester.pump(const Duration(milliseconds: 400));

    exit.install();
    await _systemBack(tester);

    expect(
      exit.exited,
      isFalse,
      reason: 'The back gesture must not drop a first-run user to the '
          'launcher from the middle of the setup wizard.',
    );
    expect(
      container.read(onboardingDraftProvider).currentStep,
      OnboardingStep.welcome,
      reason: 'The back gesture must run the wizard\'s own Back action.',
    );
  });

  testWidgets('system back on the first step asks before leaving setup', (
    tester,
  ) async {
    final container = await _pumpWizard(tester);
    final exit = _SystemExitRecorder();
    addTearDown(exit.restore);
    expect(
      container.read(onboardingDraftProvider).currentStep,
      OnboardingStep.welcome,
    );

    exit.install();
    await _systemBack(tester);

    expect(
      exit.exited,
      isFalse,
      reason: 'The first step has no previous step, but silently exiting the '
          'app mid-setup is not the answer either.',
    );
    expect(
      find.text('Leave setup?'),
      findsOneWidget,
      reason: 'The wizard must confirm before abandoning first-run setup.',
    );
    expect(
      container.read(onboardingDraftProvider).currentStep,
      OnboardingStep.welcome,
      reason: 'Dismissing nothing yet — the wizard stays put until answered.',
    );

    await tester.tap(find.text('Leave setup'));
    await tester.pumpAndSettle();
    expect(
      find.text('Dashboard'),
      findsOneWidget,
      reason: 'Confirming leaves for the dashboard, not the launcher.',
    );
    expect(exit.exited, isFalse);
  });

  testWidgets('cancelling the leave prompt keeps the user in the wizard', (
    tester,
  ) async {
    final container = await _pumpWizard(tester);
    final exit = _SystemExitRecorder();
    addTearDown(exit.restore);

    exit.install();
    await _systemBack(tester);
    expect(find.text('Leave setup?'), findsOneWidget);

    await tester.tap(find.text('Keep setting up'));
    await tester.pumpAndSettle();

    expect(find.text('Dashboard'), findsNothing);
    expect(exit.exited, isFalse);
    expect(
      container.read(onboardingDraftProvider).currentStep,
      OnboardingStep.welcome,
    );
  });

  testWidgets('the leave prompt fits the narrowest supported phone', (
    tester,
  ) async {
    final overflows = <String>[];
    final previousOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.toString().contains('overflowed')) {
        overflows.add(details.toString());
        return;
      }
      previousOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = previousOnError);

    await _pumpWizard(tester, size: const Size(320, 568));
    final exit = _SystemExitRecorder();
    addTearDown(exit.restore);

    exit.install();
    await _systemBack(tester);

    expect(find.text('Leave setup?'), findsOneWidget);
    expect(find.text('Keep setting up'), findsOneWidget);
    expect(find.text('Leave setup'), findsOneWidget);
    expect(
      overflows,
      isEmpty,
      reason: 'The leave prompt must fit a 320 dp phone.',
    );
  });
}
