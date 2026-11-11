// A stack started from tonight's frames: the reference first, then every
// other frame already on disk, in order. A Stop during that catch-up ends it
// after the frame in flight instead of feeding the rest into a released
// stacker.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../harness/in_memory_database.dart';

class _MockLocalBackend extends Mock implements SkotiqBackend {}

class _LocalBackendNotifier extends BackendNotifier {
  _LocalBackendNotifier(super.ref) {
    state = _MockLocalBackend();
  }
}

class _RecordingStackingService extends LiveStackingService {
  _RecordingStackingService(super.ref);

  final calls = <String>[];

  /// When set, each add waits for this before answering.
  Completer<void>? gate;

  @override
  Future<LiveStackingStats> startFromFile({
    required String referenceImagePath,
    LiveStackingConfig config = const LiveStackingConfig(),
  }) async {
    calls.add('start $referenceImagePath');
    return const LiveStackingStats(stackedFrameCount: 1);
  }

  @override
  Future<LiveStackingResult> addFrameFromFile(String imagePath) async {
    calls.add('add $imagePath');
    await gate?.future;
    final count = calls.where((c) => c.startsWith('add')).length + 1;
    return LiveStackingResult(
      width: 2,
      height: 1,
      data: const [1, 2],
      stats: LiveStackingStats(stackedFrameCount: count),
    );
  }

  @override
  Future<LiveStackingResult> getCurrentResult() async =>
      const LiveStackingResult(
        width: 2,
        height: 1,
        data: [1, 2],
        stats: LiveStackingStats(stackedFrameCount: 1),
      );

  @override
  Future<void> stop() async {
    calls.add('stop');
  }
}

void main() {
  late _RecordingStackingService service;
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(_LocalBackendNotifier.new),
        loggingServiceProvider.overrideWithValue(LoggingService()),
        liveStackingServiceProvider.overrideWith((ref) {
          service = _RecordingStackingService(ref);
          return service;
        }),
      ],
    );
    addTearDown(container.dispose);
  });

  test('the reference starts the stack and the rest join in order', () async {
    final notifier = container.read(liveStackingProvider.notifier);

    await notifier.startFromFrames('/n/f2.fits', ['/n/f1.fits', '/n/f3.fits']);

    expect(service.calls, [
      'start /n/f2.fits',
      'add /n/f1.fits',
      'add /n/f3.fits',
    ]);
    final state = container.read(liveStackingProvider);
    expect(state.status, LiveStackingStatus.running);
    expect(state.referenceImagePath, '/n/f2.fits');
    expect(state.stats.stackedFrameCount, 3);
  });

  test('Stop during the catch-up adds nothing after the frame in flight',
      () async {
    final notifier = container.read(liveStackingProvider.notifier);
    container.read(liveStackingServiceProvider);
    service.gate = Completer<void>();

    final start = notifier.startFromFrames(
      '/n/f1.fits',
      ['/n/f2.fits', '/n/f3.fits', '/n/f4.fits'],
    );
    await pumpEventQueue();
    expect(service.calls.last, 'add /n/f2.fits');

    final stop = notifier.stop();
    service.gate!.complete();
    await Future.wait([start, stop]);

    expect(service.calls, [
      'start /n/f1.fits',
      'add /n/f2.fits',
      'stop',
    ]);
    expect(container.read(liveStackingProvider).status, LiveStackingStatus.idle);
  });
}
