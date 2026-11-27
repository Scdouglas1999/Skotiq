// The plan's timing warnings print their times on the clock the run's step
// times print on (Settings > Location timezone), not this machine's zone.

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

void main() {
  final startAfter = DateTime.utc(2026, 11, 20, 3, 15);
  final scheduled = startAfter.subtract(const Duration(hours: 1));
  // Three hours ahead of this machine, whatever zone it runs in.
  final siteOffset =
      startAfter.toLocal().timeZoneOffset + const Duration(hours: 3);
  String onSite(DateTime instant) =>
      ClockFormat.hm(instant.toUtc().add(siteOffset));

  late ProviderContainer container;

  setUp(() {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sequencerOverheadConfigProvider.overrideWithValue(
          const SequenceOverheadConfig(),
        ),
        autofocusSettingsProvider.overrideWithValue(const AutofocusSettings()),
        clockProvider.overrideWithValue(
          FixedOffsetClock(utcOffset: siteOffset, label: 'Site'),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
  });

  test('a step before its target start time is named on the site clock', () {
    final target = TargetHeaderNode(
      id: 'target',
      name: 'M31',
      targetName: 'M31',
      raHours: 0.7,
      decDegrees: 41.3,
      startAfter: startAfter.toLocal(),
    );
    final sequence = Sequence.create(
      name: 'Plan',
      nodes: {
        'target': target,
        'exposure': ExposureNode(
          id: 'exposure',
          name: 'Lights',
          parentId: 'target',
          durationSecs: 300,
        ),
      },
    );

    final conflicts = container
        .read(planTimerProvider)
        .estimator
        .findTimingConflicts(
          [
            NodeTiming(
              nodeId: 'exposure',
              nodeName: 'Lights',
              nodeType: 'TakeExposure',
              estimatedStart: scheduled,
              estimatedEnd: scheduled.add(const Duration(minutes: 5)),
              duration: const Duration(minutes: 5),
              targetHeaderId: 'target',
            ),
          ],
          {
            'target': TargetWindow(
              targetId: 'target',
              targetName: 'M31',
              isCircumpolar: true,
            ),
          },
          sequence,
        );

    expect(
      conflicts.single,
      'M31: "Lights" scheduled at ${onSite(scheduled)} before target start '
      'time ${onSite(startAfter)}',
    );
  });
}
