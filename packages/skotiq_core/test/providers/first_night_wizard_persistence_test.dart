import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/tutorial_dao.dart';
import 'package:skotiq_core/src/database/daos/tutorial_progress_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/providers/tutorial_provider.dart';

class _FakeTutorialDao extends TutorialDao {
  _FakeTutorialDao(super.progressDao);

  int resumeIndex = 0;
  bool failLoad = false;
  bool failWrites = false;
  final List<int> savedIndices = [];

  @override
  Future<int> getLastStepIndex() async {
    if (failLoad) throw StateError('load failed');
    return resumeIndex;
  }

  @override
  Future<void> saveFirstNightProgress(int stepIndex) async {
    if (failWrites) throw StateError('write failed');
    savedIndices.add(stepIndex);
  }

  @override
  Future<void> markFirstNightCompleted() async {
    if (failWrites) throw StateError('write failed');
  }

  @override
  Future<void> dismissFirstNightForever() async {
    if (failWrites) throw StateError('write failed');
  }

  @override
  Future<void> resetFirstNight() async {
    if (failWrites) throw StateError('write failed');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase database;
  late _FakeTutorialDao dao;

  setUp(() {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    dao = _FakeTutorialDao(TutorialProgressDao(database));
  });

  tearDown(() => database.close());

  test('a load failure falls back to a usable first step', () async {
    dao.failLoad = true;
    final notifier = FirstNightWizardNotifier(dao);
    addTearDown(notifier.dispose);

    await Future<void>.delayed(Duration.zero);

    expect(notifier.state.isLoaded, isTrue);
    expect(notifier.state.currentStepIndex, 0);
  });

  test(
    'failed navigation persistence leaves the visible step unchanged',
    () async {
      final notifier = FirstNightWizardNotifier(dao);
      addTearDown(notifier.dispose);
      await Future<void>.delayed(Duration.zero);
      dao.failWrites = true;

      await expectLater(notifier.next(), throwsStateError);

      expect(notifier.state.currentStepIndex, 0);
    },
  );

  test(
    'rapid navigation mutations persist and apply in invocation order',
    () async {
      final notifier = FirstNightWizardNotifier(dao);
      addTearDown(notifier.dispose);
      await Future<void>.delayed(Duration.zero);

      await Future.wait([notifier.next(), notifier.back()]);

      expect(dao.savedIndices, [1, 0]);
      expect(notifier.state.currentStepIndex, 0);
    },
  );
}
