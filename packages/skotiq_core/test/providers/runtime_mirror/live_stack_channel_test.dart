// A linked client shows the host's live stack, whoever armed it: the
// 2026-11-22 harness drive found a client never showed a host-started stack,
// and polled only the host's default filter.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import 'mirror_link.dart';

/// The host's stacker as a linked client reaches it.
class _HostStacker extends LiveStackingService {
  _HostStacker(super.ref);

  final List<String?> fetched = [];
  int stops = 0;

  @override
  bool get readsHost => true;

  @override
  Future<LiveStackingResult> getCurrentResult({String? filterKey}) async {
    fetched.add(filterKey);
    return LiveStackingResult(
      width: 2,
      height: 2,
      data: const [5, 6, 7, 8],
      filterKey: filterKey ?? kDefaultLiveStackFilterKey,
      stats: const LiveStackingStats(stackedFrameCount: 4),
    );
  }

  @override
  Future<void> stop({String? filterKey}) async => stops++;
}

LiveStackSlotSummary _slot(String key, int revision, int frames) =>
    LiveStackSlotSummary(
      filterKey: key,
      stats: LiveStackingStats(
        stackedFrameCount: frames,
        totalFramesAttempted: frames,
        filter: key,
      ),
      width: 2,
      height: 2,
      channels: 1,
      revision: revision,
    );

HostRuntimeUpdate _update(int revision, LiveStackSummary? stack) =>
    HostRuntimeUpdate(
      channel: 'liveStack',
      revision: revision,
      value: stack?.toJson(),
    );

void main() {
  late _HostStacker stacker;
  late List<HostRuntimeUpdate> hostHolds;

  MirrorClient linked() => mirrorClient(
    null,
    snapshot: () => hostHolds,
    overrides: [
      liveStackingServiceProvider.overrideWith(
        (ref) => stacker = _HostStacker(ref),
      ),
    ],
  );

  test('a client shows a stack the host started, each filter by its own '
      'pixels', () async {
    hostHolds = [
      _update(
        1,
        LiveStackSummary(
          running: true,
          armed: true,
          slots: [_slot('L', 3, 3), _slot('R', 2, 2)],
        ),
      ),
    ];
    final client = linked();
    client.container.read(liveStackingServiceProvider);

    await hydrateHostRuntimeState(client.container, client.backend);
    await settle();

    final shown = client.container.read(liveStackingProvider);
    expect(shown.status, LiveStackingStatus.running);
    expect(shown.isArmed, isTrue);
    expect(shown.availableFilters, ['L', 'R']);
    expect(shown.filterStacks['R']!.stats.stackedFrameCount, 2);
    expect(stacker.fetched, ['L'], reason: 'the viewed slot, by its key');
    expect(shown.previewData, [5, 6, 7, 8]);

    client.container.read(liveStackingProvider.notifier).selectFilter('R');
    await settle();
    expect(stacker.fetched, ['L', 'R']);

    // The host stacked another L frame while R is viewed: L's count follows
    // and no pixels are fetched.
    hostHolds = [
      _update(
        2,
        LiveStackSummary(
          running: true,
          armed: true,
          slots: [_slot('L', 4, 4), _slot('R', 2, 2)],
        ),
      ),
    ];
    await hydrateHostRuntimeState(client.container, client.backend);
    await settle();
    expect(stacker.fetched, ['L', 'R']);
    expect(
      client.container
          .read(liveStackingProvider)
          .filterStacks['L']!
          .stats
          .stackedFrameCount,
      4,
    );
  });

  test('when the host stack ends the client view ends without a stop sent '
      'back', () async {
    hostHolds = [
      _update(
        1,
        LiveStackSummary(running: true, armed: true, slots: [_slot('L', 1, 1)]),
      ),
    ];
    final client = linked();
    client.container.read(liveStackingServiceProvider);
    await hydrateHostRuntimeState(client.container, client.backend);
    await settle();
    expect(
      client.container.read(liveStackingProvider).status,
      LiveStackingStatus.running,
    );

    hostHolds = [_update(2, null)];
    await hydrateHostRuntimeState(client.container, client.backend);

    expect(
      client.container.read(liveStackingProvider).status,
      LiveStackingStatus.idle,
    );
    expect(stacker.stops, 0);
  });

  test('Stop on a client reaches a stack the host started', () async {
    hostHolds = [
      _update(
        1,
        LiveStackSummary(running: true, armed: true, slots: [_slot('L', 1, 1)]),
      ),
    ];
    final client = linked();
    client.container.read(liveStackingServiceProvider);
    await hydrateHostRuntimeState(client.container, client.backend);
    await settle();

    await client.container.read(liveStackingProvider.notifier).stop();

    expect(stacker.stops, 1);
    expect(
      client.container.read(liveStackingProvider).status,
      LiveStackingStatus.idle,
    );
  });

  test('an armed host stack with no frame yet is not polled', () async {
    hostHolds = [
      _update(1, const LiveStackSummary(running: true, armed: true, slots: [])),
    ];
    final client = linked();
    client.container.read(liveStackingServiceProvider);
    await hydrateHostRuntimeState(client.container, client.backend);
    await settle();

    final shown = client.container.read(liveStackingProvider);
    expect(shown.status, LiveStackingStatus.running);
    expect(shown.isArmed, isTrue);
    expect(stacker.fetched, isEmpty);
  });

  test('the summary of a host stack survives its JSON form', () {
    const state = LiveStackingState(
      status: LiveStackingStatus.running,
      isArmed: true,
      filterStacks: {
        'Ha': FilterStackSnapshot(
          filterKey: 'Ha',
          stats: LiveStackingStats(
            stackedFrameCount: 7,
            totalFramesAttempted: 9,
            rejectedAlignmentFailures: 2,
            totalIntegrationSecs: 2100,
            filter: 'Ha',
          ),
          previewWidth: 640,
          previewHeight: 480,
          revision: 9,
        ),
      },
    );
    final summary = LiveStackSummary.of(state)!;
    final back = LiveStackSummary.fromJson(summary.toJson());
    expect(back.toJson(), summary.toJson());
    expect(back.slots.single.stats.totalIntegrationSecs, 2100);
    expect(LiveStackSummary.of(const LiveStackingState()), isNull);
  });
}
