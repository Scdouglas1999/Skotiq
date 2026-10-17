import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/tutorial_overlay.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _FailingProgressDao extends TutorialProgressDao {
  _FailingProgressDao(super.db);

  bool failSave = false;

  @override
  Future<void> saveProgress(String category, int stepIndex) {
    if (failSave) throw StateError('progress write failed');
    return super.saveProgress(category, stepIndex);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('failed Next remains on the current step and offers retry',
      (tester) async {
    final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() async => database.close());
    final dao = _FailingProgressDao(database);
    final notifier = TutorialNotifier(dao);
    await notifier.startTutorial(TutorialCategory.equipmentSetup);
    dao.failSave = true;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          tutorialProvider.overrideWith((ref) => notifier),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: TutorialOverlay(
            child: Scaffold(
              body: Container(color: Colors.black),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Equipment profiles'), findsOneWidget);
    await tester.tap(find.text('Next'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Equipment profiles'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);
    expect(
      find.text('Could not save tutorial progress. Please try again.'),
      findsOneWidget,
    );
    expect(notifier.state.currentStepIndex, 0);
    expect(tester.takeException(), isNull);
  });
}
