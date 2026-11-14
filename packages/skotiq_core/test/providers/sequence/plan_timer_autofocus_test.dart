// An Autofocus step that uses the Autofocus settings runs the settings'
// sweep, so the plan's time for it is that sweep's, not the step's own
// (unsent) fields.

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

Sequence _plan(AutofocusNode af) => Sequence.create(
  name: 'Focus',
  rootNodeId: 'root',
  nodes: {
    'root': InstructionSetNode(
      id: 'root',
      name: 'Root',
      childIds: const ['af'],
    ),
    'af': af,
  },
);

void main() {
  late ProviderContainer container;

  setUp(() {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sequencerOverheadConfigProvider.overrideWithValue(
          const SequenceOverheadConfig(downloadOverheadPerExposureSecs: 2),
        ),
        autofocusSettingsProvider.overrideWithValue(
          const AutofocusSettings(
            initialOffsetSteps: 3,
            exposureTime: 5,
            exposuresPerPoint: 2,
            focuserSettleTimeMs: 1000,
          ),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
  });

  Duration afTime(AutofocusNode af) => container
      .read(planTimerProvider)
      .time(_plan(af), DateTime.utc(2026, 11, 13, 2))
      .of('af')!
      .duration;

  test('a step on the Autofocus settings takes the settings\' sweep', () {
    // 7 positions x (1 s settle + 2 x (5 s + 2 s download)).
    expect(
      afTime(AutofocusNode(id: 'af', name: 'AF', parentId: 'root')),
      const Duration(seconds: 105),
    );
  });

  test(
    'a step with its own sweep takes its own, with the settings\' settle',
    () {
      // 5 positions x (1 s settle + 1 x (3 s + 2 s download)).
      expect(
        afTime(
          AutofocusNode(
            id: 'af',
            name: 'AF',
            parentId: 'root',
            useSettingsDefaults: false,
            stepsOut: 2,
            exposuresPerPoint: 1,
            exposureDuration: 3,
          ),
        ),
        const Duration(seconds: 30),
      );
    },
  );
}
