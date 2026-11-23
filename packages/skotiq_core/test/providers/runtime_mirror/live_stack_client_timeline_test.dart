// What a linked client shows of the host's live stack over time, and which
// pixels it fetches: only a slot whose revision the host's liveStack channel
// says changed, never between revisions.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import 'mirror_link.dart';

/// The host's stacker as a linked client reaches it. A fetch returns the
/// slot's newest pixels when the download ends: one sample, revision x 10.
class _HostStacker extends LiveStackingService {
  _HostStacker(super.logger);

  final Map<String, int> revisions = {};
  final List<String?> fetched = [];
  Duration download = Duration.zero;
  Duration startTakes = Duration.zero;
  Duration stopTakes = Duration.zero;
  bool failStart = false;
  int failNext = 0;

  @override
  bool get readsHost => true;

  @override
  Future<LiveStackingStats> start({
    String? referenceImagePath,
    LiveStackingConfig config = const LiveStackingConfig(),
    String? filterKey,
  }) async {
    await Future<void>.delayed(startTakes);
    if (failStart) throw StateError('host refused');
    return const LiveStackingStats();
  }

  @override
  Future<LiveStackingResult> getCurrentResult({String? filterKey}) async {
    fetched.add(filterKey);
    await Future<void>.delayed(download);
    if (failNext > 0) {
      failNext--;
      throw StateError('link lost');
    }
    final key = filterKey ?? revisions.keys.firstOrNull;
    if (key == null) {
      throw const ServerError(
        code: 'no_active_stack',
        message: 'Live stacking is not running.',
        httpStatus: 404,
      );
    }
    final revision = revisions[key]!;
    return LiveStackingResult(
      width: 1,
      height: 1,
      data: [revision * 10],
      filterKey: key,
      revision: revision,
      stats: LiveStackingStats(stackedFrameCount: revision),
    );
  }

  @override
  Future<void> stop({String? filterKey}) async {
    await Future<void>.delayed(stopTakes);
  }
}

void main() {
  late _HostStacker host;
  late List<HostRuntimeUpdate> holds;
  late MirrorClient client;
  var revision = 0;

  LiveStackingNotifier notifier() =>
      client.container.read(liveStackingProvider.notifier);

  String shown() {
    final s = client.container.read(liveStackingProvider);
    return [
      s.status.name,
      s.isArmed ? 'armed' : '-',
      s.availableFilters.join(','),
      s.filterStacks.isEmpty ? '-' : s.viewedFilterKey,
      s.previewData?.join(',') ?? '-',
      s.stats.stackedFrameCount,
      s.errorMessage ?? '-',
    ].join(' | ');
  }

  /// The host's channel describes [slots] (or no stack), and the client
  /// re-reads it.
  void describe(FakeAsync async, Map<String, int>? slots, {bool armed = true}) {
    if (slots != null) {
      host.revisions
        ..clear()
        ..addAll(slots);
    }
    holds = [
      HostRuntimeUpdate(
        channel: 'liveStack',
        revision: ++revision,
        value: slots == null
            ? null
            : LiveStackSummary(
                armed: armed,
                slots: [
                  for (final MapEntry(:key, :value) in slots.entries)
                    LiveStackSlotSummary(
                      filterKey: key,
                      stats: LiveStackingStats(stackedFrameCount: value),
                      width: 1,
                      height: 1,
                      channels: 1,
                      revision: value,
                    ),
                ],
              ).toJson(),
      ),
    ];
    unawaited(hydrateHostRuntimeState(client.container, client.backend));
    async.flushMicrotasks();
  }

  List<String> run(List<(String, void Function(FakeAsync async))> steps) {
    final rows = <String>[];
    fakeAsync((async) {
      holds = const [];
      client = mirrorClient(
        null,
        snapshot: () => holds,
        overrides: [
          liveStackingServiceProvider.overrideWith(
            (ref) => host = _HostStacker(ref.read(loggingServiceProvider)),
          ),
        ],
      );
      client.container.read(liveStackingServiceProvider);
      for (final (name, step) in steps) {
        host.fetched.clear();
        step(async);
        async.elapse(const Duration(seconds: 6));
        rows.add('$name: ${shown()} | fetched ${host.fetched}');
      }
      client.container.dispose();
    });
    return rows;
  }

  test('a stack the client arms, through frames, a slow download, a second '
      'filter, a lost link and the end', () {
    expect(
      run([
        ('arm', (_) => unawaited(notifier().startRemote())),
        ('host armed', (a) => describe(a, {})),
        ('first L frame', (a) => describe(a, {'L': 1})),
        ('second L frame', (a) => describe(a, {'L': 2})),
        (
          'L frame during a slow download',
          (a) {
            host.download = const Duration(seconds: 3);
            describe(a, {'L': 3});
            a.elapse(const Duration(seconds: 1));
            describe(a, {'L': 4});
          },
        ),
        (
          'first R frame',
          (a) {
            host.download = Duration.zero;
            describe(a, {'L': 4, 'R': 1});
          },
        ),
        ('view R', (_) => notifier().selectFilter('R')),
        (
          'link lost',
          (a) {
            host.failNext = 3;
            describe(a, {'L': 4, 'R': 2});
          },
        ),
        ('retry', (_) => notifier().retryHostFetch()),
        ('host stack ends', (a) => describe(a, null)),
      ]),
      [
        'arm: running | armed |  | - | - | 0 | - | fetched []',
        'host armed: running | armed |  | - | - | 0 | - | fetched []',
        'first L frame: running | armed | L | L | 10 | 1 | - | fetched [L]',
        'second L frame: running | armed | L | L | 20 | 2 | - | fetched [L]',
        'L frame during a slow download: running | armed | L | L | 40 | 4 | - | fetched [L, L]',
        'first R frame: running | armed | L,R | L | 40 | 4 | - | fetched []',
        'view R: running | armed | L,R | R | 10 | 1 | - | fetched [R]',
        'link lost: running | armed | L,R | R | 10 | 2 | Lost contact with host stacker | fetched [R, R, R]',
        'retry: running | armed | L,R | R | 20 | 2 | - | fetched [R]',
        'host stack ends: idle | - |  | - | - | 0 | - | fetched []',
      ],
    );
  });

  test('a stack the host started, and one described while the client\'s own '
      'start is in flight', () {
    expect(
      run([
        ('host stack running', (a) => describe(a, {'L': 1}, armed: false)),
        ('host stack ends', (a) => describe(a, null)),
        (
          'arm, described before the start returns',
          (a) {
            host.startTakes = const Duration(seconds: 2);
            unawaited(notifier().startRemote());
            a.flushMicrotasks();
            describe(a, {'L': 1});
          },
        ),
        ('next L frame', (a) => describe(a, {'L': 2})),
      ]),
      [
        'host stack running: running | - | L | L | 10 | 1 | - | fetched [L]',
        'host stack ends: idle | - |  | - | - | 0 | - | fetched []',
        'arm, described before the start returns: running | armed | L | L | 10 | 1 | - | fetched [L]',
        'next L frame: running | armed | L | L | 20 | 2 | - | fetched [L]',
      ],
    );
  });

  test('what the host describes while the client\'s own arm or stop is in '
      'flight', () {
    void armSlowly(FakeAsync a, {bool fails = false}) {
      host
        ..startTakes = const Duration(seconds: 2)
        ..failStart = fails;
      unawaited(notifier().startRemote().catchError((Object _) {}));
      a.flushMicrotasks();
    }

    expect(
      run([
        (
          'no stack described before the start returns',
          (a) {
            armSlowly(a);
            describe(a, null);
          },
        ),
        ('host armed', (a) => describe(a, {})),
        ('first L frame', (a) => describe(a, {'L': 1})),
        (
          'stop, an L frame described before it returns',
          (a) {
            host.stopTakes = const Duration(seconds: 2);
            unawaited(notifier().stop());
            a.flushMicrotasks();
            describe(a, {'L': 2});
          },
        ),
        (
          'a refused arm, a stack described before the refusal',
          (a) {
            armSlowly(a, fails: true);
            describe(a, {'L': 3});
          },
        ),
      ]),
      [
        'no stack described before the start returns: running | armed |  | - | - | 0 | - | fetched []',
        'host armed: running | armed |  | - | - | 0 | - | fetched []',
        'first L frame: running | armed | L | L | 10 | 1 | - | fetched [L]',
        'stop, an L frame described before it returns: idle | - |  | - | - | 0 | - | fetched []',
        'a refused arm, a stack described before the refusal: error | armed |  | - | - | 0 | host refused | fetched []',
      ],
    );
  });
}
