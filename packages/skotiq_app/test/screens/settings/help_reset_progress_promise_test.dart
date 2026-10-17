// "Reset All Progress" confirms that "you will see the welcome tour again", so
// the tour has to come back IN THIS SESSION.
//
// Deleting the rows from the database is not enough: the dismissed coach-mark
// set is held in memory and the first-launch tour's status is a cached future,
// so without invalidating both they keep saying "already seen".

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/settings/widgets/help_tutorials_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

Future<ProviderContainer> _pumpHelp(
  WidgetTester tester,
  SkotiqDatabase db,
) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 1600);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final container = ProviderContainer(
    overrides: [
      backendProvider.overrideWith(
        (ref) => TestBackendNotifier(ref, mockBackend()),
      ),
      databaseProvider.overrideWithValue(db),
      appVersionProvider.overrideWithValue(
        const AppVersionInfo(version: '0.0.0-test', buildNumber: 0),
      ),
    ],
  );
  addTearDown(container.dispose);

  final router = GoRouter(
    initialLocation: '/help',
    routes: [
      GoRoute(
        path: '/help',
        builder: (context, state) =>
            const Scaffold(body: HelpTutorialsSettings()),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: SkotiqTheme.dark,
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle(const Duration(seconds: 5));
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('resetting progress really does bring the welcome tour back',
      (tester) async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => db.close());

    final container = await _pumpHelp(tester, db);

    // The operator has been through the app once: a coach mark was dismissed
    // on the dashboard and the welcome tour was completed.
    final dismissed = container.read(dismissedTourPromptsProvider.notifier);
    await dismissed.ready;
    await dismissed.dismissPrompt('dashboard');
    await container.read(onboardingTourProvider.notifier).complete();
    await tester.pumpAndSettle();

    expect(container.read(dismissedTourPromptsProvider), contains('dashboard'));
    expect(
      await container.read(firstLaunchTourStatusProvider.future),
      isNot(FirstLaunchTourStatus.pending),
      reason: 'precondition: the welcome tour is not waiting to run',
    );

    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('Reset all progress'),
          matching: find.byType(SettingRow),
        ),
        matching: find.widgetWithText(SkotiqButton, 'Reset'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(SkotiqButton, 'Reset'),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      container.read(dismissedTourPromptsProvider),
      isEmpty,
      reason: 'a dismissed coach mark that survives the reset is a nudge the '
          'operator was told they would see again',
    );
    expect(
      await container.read(firstLaunchTourStatusProvider.future),
      FirstLaunchTourStatus.pending,
      reason: 'the dialog says "you will see the welcome tour again"',
    );
  });
}
