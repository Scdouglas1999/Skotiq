import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import '../../harness/in_memory_database.dart';

/// Hours after the run started, where the app's clock stands.
final _now = DateTime.utc(2026, 11, 16, 4, 47);
final _runStart = DateTime.utc(2026, 11, 15, 23, 40);

class _Clock implements Clock {
  const _Clock();

  @override
  DateTime now() => _now;

  @override
  DateTime nowUtc() => _now;

  @override
  Duration get utcOffset => Duration.zero;

  @override
  DateTime fromUtc(DateTime utc) => utc;
}

class _Session extends SessionStateNotifier {
  _Session(super.ref) {
    state = SessionState(isActive: true, startTime: _runStart);
  }
}

class _Armed extends ArmedStartController {
  _Armed(this._at);
  final DateTime? _at;

  @override
  DateTime? build() => _at;
}

ProviderContainer _container({
  required SequenceExecutionState lifecycle,
  DateTime? armedAt,
}) {
  final exposures = ExposureNode(name: 'Lum', durationSecs: 60, count: 4);
  final root = InstructionSetNode(name: 'Root');
  final sequence = Sequence.create(
    name: 'test',
    rootNodeId: root.id,
    nodes: {
      exposures.id: exposures.copyWith(parentId: root.id),
      root.id: root.copyWith(childIds: [exposures.id]),
    },
  );
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      clockProvider.overrideWithValue(const _Clock()),
      appObserverLocationProvider.overrideWithValue(null),
      sequencerOverheadConfigProvider.overrideWithValue(
        SequenceTimeEstimator.defaultEstimatorOverhead,
      ),
      currentSequenceProvider.overrideWith((ref) {
        final notifier = CurrentSequenceNotifier();
        // ignore: invalid_use_of_protected_member
        notifier.state = sequence;
        return notifier;
      }),
      runRecordProvider.overrideWith(
        (ref) => RunRecordNotifier(ref, RunRecord(lifecycle: lifecycle)),
      ),
      sessionStateProvider.overrideWith(_Session.new),
      nightArmedStartProvider.overrideWith(() => _Armed(armedAt)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('a running plan is timed from the run start, not from now', () {
    final container = _container(lifecycle: SequenceExecutionState.running);

    expect(container.read(planStartProvider), _runStart);
    expect(container.read(currentPlanTimingProvider)!.start, _runStart);
  });

  test('an armed plan is timed from the armed start', () {
    final armedAt = DateTime.utc(2026, 11, 16, 23, 30);
    final container = _container(
      lifecycle: SequenceExecutionState.idle,
      armedAt: armedAt,
    );

    expect(container.read(currentPlanTimingProvider)!.start, armedAt);
  });

  test('a plan nothing fixes is timed from the app clock\'s now', () {
    final container = _container(lifecycle: SequenceExecutionState.idle);

    expect(container.read(planStartProvider), isNull);
    expect(container.read(currentPlanTimingProvider)!.start.toUtc(), _now);
  });
}
