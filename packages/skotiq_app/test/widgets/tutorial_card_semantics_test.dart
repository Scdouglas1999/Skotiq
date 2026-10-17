// The tutorial overlay card must not publish itself as interactive-but-dead —
// `panel: Tutorial step 1 of 12: Welcome to Dashboard [DISABLED]`, at any step.
// A tree dump prints [DISABLED] on a panel only when the node is
// focusable/selectable/checkable WITHOUT an enabled state, and this card is
// focusable by construction: a `Focus(autofocus: true)` takes the keyboard for
// the whole tour so Enter/Space/Backspace/Escape drive it. Undeclared, the
// overlay claims your keyboard and announces that it is dead — the same
// focusable-without-enabled shape as the planetarium readout strip.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/widgets/tutorial_overlay.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../harness/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the tutorial card announces an enabled state', (tester) async {
    final handle = tester.ensureSemantics();
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1280, 900);
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
      initialLocation: '/settings',
      routes: [
        ShellRoute(
          builder: (context, state, child) => TutorialOverlay(child: child),
          routes: [
            GoRoute(
              path: '/settings',
              builder: (_, __) => const Scaffold(body: Text('SETTINGS')),
            ),
            GoRoute(
              path: '/equipment',
              builder: (_, __) => const Scaffold(body: Text('EQUIPMENT')),
            ),
          ],
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
    await tester.pumpAndSettle(const Duration(seconds: 2));

    await container
        .read(tutorialProvider.notifier)
        .restartTutorial(TutorialCategory.equipmentSetup);
    // Not pumpAndSettle: the spotlight ring repeats for as long as a tour runs.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final cards = <SemanticsData>[];
    void visit(SemanticsNode node) {
      final data = node.getSemanticsData();
      if (data.label.startsWith('Tutorial step ')) cards.add(data);
      node.visitChildren((child) {
        visit(child);
        return true;
      });
    }

    // ignore: deprecated_member_use
    visit(tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!);

    expect(cards, isNotEmpty, reason: 'the tour card names itself');
    for (final card in cards) {
      expect(
        card.hasFlag(SemanticsFlag.hasEnabledState),
        isTrue,
        reason: 'a focusable node with no enabled state reads as [DISABLED]',
      );
      expect(card.hasFlag(SemanticsFlag.isEnabled), isTrue);
    }

    await container.read(tutorialProvider.notifier).completeTutorial();
    await tester.pump(const Duration(milliseconds: 100));
    handle.dispose();
  });
}
