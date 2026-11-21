import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_core/src/providers/sequence/sequence_editor.dart';
import 'package:skotiq_core/src/services/device_service.dart';
import 'package:skotiq_core/src/services/weather/current_sky_service.dart';
import 'package:skotiq_core/utils.dart';

import '../harness/in_memory_database.dart';

class _Ffi extends Mock implements FfiBackend {}

class _Net extends Mock implements NetworkBackend {}

class _BackendNotifier extends BackendNotifier {
  _BackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

class _Settings extends AppSettingsNotifier {
  _Settings(this.path);
  final String path;

  @override
  Future<AppSettingsState> build() async =>
      AppSettingsState(imageOutputPath: path, tempCompensation: true);
}

class _Sequence extends CurrentSequenceNotifier {
  _Sequence(Ref ref, Sequence sequence) : super(ref: ref) {
    state = sequence;
  }
}

class _Moves extends Mock implements DeviceService {
  final List<int> moves = <int>[];

  @override
  bool get isAutofocusRunning => false;

  @override
  Future<void> moveFocuserTo(int position) async {
    moves.add(position);
  }
}

class _Sky extends CurrentSkyService {
  int fetches = 0;

  @override
  Future<CurrentSky?> fetch({
    required double latitude,
    required double longitude,
  }) async {
    fetches++;
    return null;
  }
}

CapturedImageResult _frame() => CapturedImageResult(
  width: 4,
  height: 4,
  displayData: List<int>.filled(64, 1),
  histogram: List<int>.filled(256, 0),
  stats: const ImageStatsResult(
    min: 0,
    max: 1,
    mean: 0,
    median: 0,
    stdDev: 0,
    hfr: 0,
    starCount: 0,
  ),
  exposureTime: 1,
  timestamp: 'not-a-timestamp',
);

ProviderContainer _client(_Net backend) => ProviderContainer(
  overrides: [
    inMemoryDatabaseOverride(),
    backendProvider.overrideWith((ref) => _BackendNotifier(ref, backend)),
  ],
);

_Net _net() {
  final backend = _Net();
  when(() => backend.connectionState).thenReturn(BackendConnectionState.connected);
  when(() => backend.isAuthTokenRejected).thenReturn(false);
  when(() => backend.eventStream).thenAnswer((_) => const Stream.empty());
  return backend;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a later instant on the same scratch path is fetched, then a clear wins', () async {
    final first = DateTime.utc(2026, 10, 31, 19, 4, 15);
    final second = DateTime.utc(2026, 10, 31, 19, 5, 15);
    final downloads = <Completer<CapturedImageResult?>>[];
    final backend = _net();
    when(
      () => backend.cameraGetLastImage(any(), maxWidth: any(named: 'maxWidth')),
    ).thenAnswer((_) {
      final pending = Completer<CapturedImageResult?>();
      downloads.add(pending);
      return pending.future;
    });
    final client = _client(backend);
    addTearDown(client.dispose);
    client.read(cameraStateProvider.notifier)
      ..setConnecting('cam', 'Cam')
      ..setConnected();
    client.read(currentImageProvider.notifier).state = CapturedImageData(
      width: 4,
      height: 4,
      displayData: Uint8List(64),
      histogram: const [],
      stats: const ImageStats(min: 0, max: 0, mean: 0, median: 0, stdDev: 0),
      capturedAt: first,
      filePath: r'C:\temp\liveview_ASI1600.fits',
      settings: const ExposureSettings(
        exposureTime: 1,
        gain: 0,
        offset: 0,
        binningX: 1,
        binningY: 1,
        frameType: FrameType.light,
      ),
    );

    void announce(DateTime at) {
      applyHostRuntimeUpdate(
        client,
        HostRuntimeUpdate(
          channel: 'currentFrame',
          revision: at.millisecondsSinceEpoch,
          value: {
            'capturedAt': at.millisecondsSinceEpoch,
            'width': 4,
            'height': 4,
            'filePath': r'C:\temp\liveview_ASI1600.fits',
            'exposure': 1.0,
            'gain': 0,
            'offset': 0,
          },
        ),
        networkBackend: backend,
      );
    }

    announce(second);
    await pumpEventQueue();
    expect(downloads, hasLength(1));
    downloads.single.complete(_frame());
    await pumpEventQueue();
    expect(client.read(currentImageProvider)?.capturedAt.toUtc(), second);

    final third = second.add(const Duration(minutes: 1));
    announce(third);
    await pumpEventQueue();
    expect(downloads, hasLength(2));
    applyHostRuntimeUpdate(
      client,
      HostRuntimeUpdate(
        channel: 'currentFrame',
        revision: third.millisecondsSinceEpoch + 1,
        value: null,
      ),
      networkBackend: backend,
    );
    downloads.last.complete(_frame());
    await pumpEventQueue();
    await Future<void>.delayed(Duration.zero);
    expect(client.read(currentImageProvider), isNull);
    expect(client.read(lastImageStatsProvider), isNull);
  });

  test('a malformed client report is not applied', () {
    final backend = _Ffi();
    when(() => backend.eventStream).thenAnswer((_) => const Stream.empty());
    final host = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith((ref) => _BackendNotifier(ref, backend)),
      ],
    );
    addTearDown(host.dispose);
    final before = host.read(framingProvider);
    final dropped = applyClientRuntimeReport(
      host,
      channel: 'framingGeometry',
      value: const {'rotation': 'no'},
      origin: 'client-a',
    );
    expect(dropped, isFalse);
    expect(identical(host.read(framingProvider), before), isTrue);

    final applied = applyClientRuntimeReport(
      host,
      channel: 'framingGeometry',
      value: const {
        'rotation': 12.0,
        'mosaicEnabled': false,
        'columns': 1,
        'rows': 1,
        'overlapPercent': 10.0,
        'serpentine': false,
        'startCorner': 'topLeft',
      },
      origin: 'client-a',
    );
    expect(applied, isTrue);
    expect(host.read(framingProvider).rotation, 12.0);
  });

  test('the host focus baseline is shown and does not move the focuser', () async {
    final moves = _Moves();
    final backend = _net();
    final capturedAt = DateTime.utc(2026, 10, 31);
    final client = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith((ref) => _BackendNotifier(ref, backend)),
        appSettingsProvider.overrideWith(() => _Settings('/captures')),
        deviceServiceProvider.overrideWithValue(moves),
      ],
    );
    addTearDown(client.dispose);
    await client.read(appSettingsProvider.future);
    applyHostRuntimeUpdate(
      client,
      HostRuntimeUpdate(
        channel: 'focusBaseline',
        revision: 1,
        value: {
          'temperature': 18.0,
          'position': 45350,
          'capturedAt': capturedAt.millisecondsSinceEpoch,
        },
      ),
      networkBackend: backend,
    );
    final baseline = client.read(focuserTempCompensationBaselineProvider);
    expect(baseline?.temperature, 18);
    expect(baseline?.position, 45350);
    expect(baseline?.capturedAt, capturedAt);

    client.read(focuserTempCompensationProvider);
    final focuser = client.read(focuserStateProvider.notifier);
    focuser.setConnecting('focus');
    focuser.setConnected();
    focuser.updatePosition(45350);
    focuser.updateTemperature(18);
    focuser.updateTemperature(17);
    await Future<void>.delayed(Duration.zero);
    expect(moves.moves, isEmpty);

    applyHostRuntimeUpdate(
      client,
      const HostRuntimeUpdate(channel: 'focusBaseline', revision: 2),
      networkBackend: backend,
    );
    expect(client.read(focuserTempCompensationBaselineProvider), isNull);
  });

  test('a new host process clears the event log and a seed replaces it', () async {
    final backend = _net();
    when(() => backend.getHostRecentEvents()).thenAnswer(
      (_) async => const [
        SkotiqEvent(
          timestamp: 1000,
          severity: EventSeverity.info,
          category: EventCategory.sequencer,
          eventType: 'Started',
          data: {'sequence_name': 'New process'},
        ),
      ],
    );
    final client = _client(backend);
    addTearDown(client.dispose);
    client.read(runtimeHostSessionProvider.notifier).state = 'A';
    client.read(eventHistoryProvider.notifier).addEvent(
      bridge.SkotiqEvent(
        eventId: BigInt.one,
        timestamp: 1,
        severity: bridge.EventSeverity.info,
        category: bridge.EventCategory.system,
        payload: const bridge.EventPayload.system(
          bridge.SystemEvent.initialized(),
        ),
      ),
    );
    applyHostRuntimeUpdate(
      client,
      const HostRuntimeUpdate(
        channel: 'hostSession',
        revision: 1,
        value: {'id': 'A'},
      ),
      networkBackend: backend,
    );
    expect(client.read(eventHistoryProvider), hasLength(1));

    applyHostRuntimeUpdate(
      client,
      const HostRuntimeUpdate(
        channel: 'hostSession',
        revision: 2,
        value: {'id': 'B'},
      ),
      networkBackend: backend,
    );
    expect(client.read(eventHistoryProvider), isEmpty);

    await seedEventLogFromHost(client, backend);
    final history = client.read(eventHistoryProvider);
    expect(history, hasLength(1));
    expect(history.single.timestamp.toInt(), 1000);
  });

  test('a linked client shows the host forecast and does not fetch the sky', () async {
    final sky = _Sky();
    final backend = _net();
    final client = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith((ref) => _BackendNotifier(ref, backend)),
        currentSkyServiceProvider.overrideWithValue(sky),
      ],
    );
    addTearDown(client.dispose);
    expect(await client.read(cloudCoverPercentageProvider.future), isNull);
    expect(sky.fetches, 0);

    applyHostRuntimeUpdate(
      client,
      const HostRuntimeUpdate(
        channel: 'environment',
        revision: 1,
        value: {'forecastCloudCover': 2.0},
      ),
      networkBackend: backend,
    );
    expect(await client.read(cloudCoverPercentageProvider.future), 2.0);
    expect(sky.fetches, 0);

    applyHostRuntimeUpdate(
      client,
      const HostRuntimeUpdate(
        channel: 'environment',
        revision: 2,
        value: {'forecastCloudCover': null},
      ),
      networkBackend: backend,
    );
    expect(await client.read(cloudCoverPercentageProvider.future), isNull);
    expect(sky.fetches, 0);
  });

  test('a rebuilt equipment event keeps its device id', () {
    final event = typedEventFromWire(
      const SkotiqEvent(
        timestamp: 1000,
        severity: EventSeverity.info,
        category: EventCategory.equipment,
        eventType: 'Connected',
        data: {
          'device_type': 'Filter Wheel',
          'device_id': 'native:zwo_efw:0',
        },
      ),
    );
    expect(event, isNotNull);
    expect(event!.deviceId, 'native:zwo_efw:0');
    final friendly = friendlyNameFromDeviceId('native:zwo_efw:0');
    expect(friendly, 'ZWO EFW 0');
  });

  test('the host restored checkpoint reaches the client and can clear', () {
    final backend = _net();
    final client = _client(backend);
    addTearDown(client.dispose);
    const exposures = 61;
    applyHostRuntimeUpdate(
      client,
      HostRuntimeUpdate(
        channel: 'runRecord',
        revision: 1,
        value: {
          'terminal': null,
          'imagingRun': null,
          'lastEnded': null,
          'stop': null,
          'runStartedAt': null,
          'stats': null,
          'restoredCheckpoint': {
            'sequenceName': 'M74',
            'timestamp': '2026-10-31T00:00:00.000Z',
            'completedExposures': exposures,
            'completedIntegrationSecs': 0,
            'canResume': true,
            'ageSeconds': 10,
            'framesDoneByStep': <String, int>{},
          },
        },
      ),
      networkBackend: backend,
    );
    expect(
      client.read(restoredCheckpointProvider)?.completedExposures,
      exposures,
    );
    applyHostRuntimeUpdate(
      client,
      const HostRuntimeUpdate(
        channel: 'runRecord',
        revision: 2,
        value: {
          'terminal': null,
          'imagingRun': null,
          'lastEnded': null,
          'stop': null,
          'runStartedAt': null,
          'stats': null,
          'restoredCheckpoint': null,
        },
      ),
      networkBackend: backend,
    );
    expect(client.read(restoredCheckpointProvider), isNull);
  });

  test('a linked projection uses the host sample and does not query local disk', () async {
    final backend = _net();
    final nextSample = Completer<void>();
    const path = r'C:\captures';
    final sequence = Sequence.create(
      name: 'M74',
      nodes: {
        'exposure': ExposureNode(
          id: 'exposure',
          name: 'Light',
          durationSecs: 60,
          count: 1,
        ),
      },
    );
    final client = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith((ref) => _BackendNotifier(ref, backend)),
        appSettingsProvider.overrideWith(() => _Settings(path)),
        currentSequenceProvider.overrideWith(
          (ref) => _Sequence(ref, sequence),
        ),
        captureDirDiskSpaceProvider.overrideWith((ref) async* {
          yield DiskSpaceInfo(
            path: path,
            totalBytes: 100000,
            freeBytes: 50000,
            sampledAt: DateTime.utc(2026, 10, 31),
          );
          await nextSample.future;
          yield DiskSpaceInfo(
            path: path,
            totalBytes: 100000,
            freeBytes: 30000,
            sampledAt: DateTime.utc(2026, 10, 31, 1),
          );
        }),
        diskSpaceServiceProvider.overrideWith(
          (ref) => _ThrowingDisk(),
        ),
      ],
    );
    addTearDown(client.dispose);
    final sub = client.listen(sequenceDiskProjectionProvider, (_, _) {});
    addTearDown(sub.close);

    Future<int?> untilFree(int want) async {
      int? bytes;
      for (var i = 0; i < 20; i++) {
        bytes = (await client.read(sequenceDiskProjectionProvider.future))
            .projection
            ?.freeBytes;
        if (bytes == want) return bytes;
        await pumpEventQueue();
      }
      return bytes;
    }

    expect(await untilFree(50000), 50000);
    nextSample.complete();
    await pumpEventQueue();
    expect(await untilFree(30000), 30000);
  });
}

class _ThrowingDisk extends DiskSpaceService {
  @override
  Future<DiskSpaceInfo> query(String path) {
    throw StateError('local disk was asked for $path');
  }
}
