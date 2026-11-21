// Exercise flat-run admission and the preview through the production route
// table, authentication middleware, SQLite store, and capture notifier.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_desktop/headless_api/auth/pairing_service.dart';
import 'package:skotiq_desktop/headless_api/auth_policy.dart';
import 'package:skotiq_desktop/headless_api/display_buffer_jpeg.dart';
import 'package:skotiq_desktop/headless_api_server.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart'
    show PairingDatabase;
import 'package:skotiq_remote_protocol/wire.dart' show ApiResource;

import 'handler_test_helpers.dart';

class _Backend extends DisconnectedBackend {
  final exposureStarted = Completer<void>();
  final exposureDone = Completer<void>();
  int starts = 0;

  @override
  Future<List<DeviceInfo>> getConnectedDevices() async => const [
    DeviceInfo(
      id: 'test-camera',
      name: 'Camera',
      deviceType: DeviceType.camera,
      driverType: DriverType.ascom,
      description: 'Test camera',
      driverVersion: '1',
    ),
  ];

  @override
  Future<CameraStatus> getCameraStatus(String deviceId) async =>
      const CameraStatus(
        connected: true,
        state: CameraState.idle,
        gain: 100,
        offset: 20,
        binX: 1,
        binY: 1,
        sensorWidth: 16,
        sensorHeight: 16,
        pixelSizeX: 4,
        pixelSizeY: 4,
        maxAdu: 65535,
        canCool: false,
        canSetGain: true,
        canSetOffset: true,
      );

  @override
  Future<CameraCapabilities?> getCameraCapabilities(String deviceId) async =>
      null;

  @override
  Future<void> cameraStartExposure({
    required String deviceId,
    required double exposureTime,
    required FrameType frameType,
    int? gain,
    int? offset,
    int binX = 1,
    int binY = 1,
    int? x,
    int? y,
    int? width,
    int? height,
  }) async {
    starts++;
    if (!exposureStarted.isCompleted) exposureStarted.complete();
    await exposureDone.future;
  }
}

class _BackendNotifier extends BackendNotifier {
  _BackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

class _Camera extends CameraStateNotifier {
  _Camera(super.ref) {
    state = const CameraStateSnapshot(
      deviceId: 'test-camera',
      connectionState: DeviceConnectionState.connected,
      gain: 100,
      offset: 20,
    );
  }
}

class _Settings extends AppSettingsNotifier {
  _Settings(this.capture);
  final String capture;
  @override
  Future<AppSettingsState> build() async =>
      AppSettingsState(imageOutputPath: capture);
}

void main() {
  late Directory capture;
  late ProviderContainer container;
  late HeadlessApiServer server;
  late HttpClient client;
  late _Backend backend;
  late PairingService pairing;

  setUp(() async {
    capture = await Directory.systemTemp.createTemp('skotiq-flat-host-');
    backend = _Backend();
    container = createHeadlessTestContainer(
      overrides: [
        appVersionProvider.overrideWithValue(
          const AppVersionInfo(version: '9.1.0', buildNumber: 39),
        ),
        appSettingsProvider.overrideWith(() => _Settings(capture.path)),
        backendProvider.overrideWith((ref) => _BackendNotifier(ref, backend)),
        cameraStateProvider.overrideWith(_Camera.new),
        activeEquipmentProfileProvider.overrideWithValue(null),
      ],
    );
    await container.read(appSettingsProvider.future);
    pairing = PairingService(
      database: PairingDatabase.forTesting(NativeDatabase.memory()),
    );
    server = HeadlessApiServer(
      pairingService: pairing,
      port: 0,
      container: container,
      bindLocalOnly: true,
      authToken: 'admin-token',
      fineGrainedAuthTokens: {
        'mount-token': HeadlessAuthGrant.forResources({
          ApiResource.mount: HeadlessAccessLevel.control,
        }),
      },
      scopedAuthTokens: const {
        'control-token': HeadlessTokenScope.control,
        'view-token': HeadlessTokenScope.view,
      },
    );
    client = HttpClient();
    await server.start();
  });

  tearDown(() async {
    if (!backend.exposureDone.isCompleted) backend.exposureDone.complete();
    client.close(force: true);
    await server.stop();
    await pairing.close();
    container.dispose();
    await capture.delete(recursive: true);
  });

  Map<String, dynamic> draft({
    Map<String, dynamic>? global,
    Map<String, dynamic>? filter,
  }) => {
    'mode': 'quick',
    'twilightMode': 'dawn',
    'globalSettings': {
      'frameCount': 1,
      'createDateSubfolder': false,
      ...?global,
    },
    'filterSettings': [
      {'filterPosition': 0, 'filterName': '', ...?filter},
    ],
  };

  Future<HttpClientResponse> request(
    String method,
    String route, {
    String token = 'control-token',
    Map<String, dynamic>? body,
  }) async {
    final req = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${server.actualPort}/api/$route'),
    );
    req.headers.set('x-skotiq-version', '9.1.0');
    req.headers.set('Authorization', 'Bearer $token');
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
    }
    return req.close();
  }

  Future<(int, Map<String, dynamic>)> call(
    String method,
    String route, {
    String token = 'control-token',
    Map<String, dynamic>? body,
  }) async {
    final res = await request(method, route, token: token, body: body);
    return (
      res.statusCode,
      jsonDecode(await utf8.decodeStream(res)) as Map<String, dynamic>,
    );
  }

  test(
    'the host creates its default Flats folder, holds the camera and accepts cancellation',
    () async {
      final flats = Directory(p.join(capture.path, 'Flats'));
      expect(await flats.exists(), isFalse);
      final (status, start) = await call(
        'POST',
        'flat-wizard/run',
        body: draft(),
      );
      expect(status, 200, reason: '$start');
      expect(start['busy'], true);
      expect(start['state']['globalSettings']['savePath'], flats.path);
      await backend.exposureStarted.future.timeout(const Duration(seconds: 5));
      expect(await flats.exists(), isTrue);
      expect(
        (await call(
          'GET',
          'flat-wizard/state',
          token: 'view-token',
        )).$2['busy'],
        true,
      );
      final second = await call('POST', 'flat-wizard/run', body: draft());
      expect(second.$1, 409, reason: '${second.$2}');
      expect(second.$2['error'], 'rig_busy');
      final expose = await call(
        'POST',
        'camera/expose',
        body: {'deviceId': 'test-camera', 'exposureTime': 1},
      );
      expect(expose.$1, 409);
      expect(backend.starts, 1);
      expect((await call('POST', 'flat-wizard/cancel')).$1, 200);
      backend.exposureDone.complete();
      await _waitForFlatIdle(container);
    },
  );

  test(
    'raw camera, manual capture and sequence ownership each refuse a flat start',
    () async {
      final raw = call(
        'POST',
        'camera/expose',
        body: {'deviceId': 'test-camera', 'exposureTime': 1},
      );
      await backend.exposureStarted.future.timeout(const Duration(seconds: 5));
      expect((await call('POST', 'flat-wizard/run', body: draft())).$1, 409);
      backend.exposureDone.complete();
      expect((await raw).$1, 200);
      expect(container.read(rawCameraExposureInFlightProvider), false);
      container.read(sessionStateProvider.notifier).setCapturing(true);
      expect((await call('POST', 'flat-wizard/run', body: draft())).$1, 409);
      container.read(sessionStateProvider.notifier).setCapturing(false);
      container
          .read(runRecordProvider.notifier)
          .setLifecycle(SequenceExecutionState.running);
      expect((await call('POST', 'flat-wizard/run', body: draft())).$1, 409);
      expect(backend.starts, 1);
    },
  );

  test(
    'view credentials read state; only the owning control credential can start and cancel',
    () async {
      expect(
        (await call('GET', 'flat-wizard/state', token: 'view-token')).$1,
        200,
      );
      expect(
        (await call('GET', 'flat-wizard/state', token: 'mount-token')).$1,
        403,
      );
      expect(
        (await call(
          'POST',
          'flat-wizard/run',
          token: 'mount-token',
          body: draft(),
        )).$1,
        403,
      );
      expect(
        (await call('GET', 'flat-wizard/state', token: 'invalid')).$1,
        403,
      );
      expect(
        (await call(
          'POST',
          'flat-wizard/run',
          token: 'view-token',
          body: draft(),
        )).$1,
        403,
      );
      expect(
        (await call('POST', 'flat-wizard/cancel', token: 'view-token')).$1,
        403,
      );
      expect(
        (await call(
          'POST',
          'session/claim',
          token: 'admin-token',
          body: {'clientName': 'Observatory'},
        )).$1,
        200,
      );
      expect((await call('POST', 'flat-wizard/run', body: draft())).$1, 409);
      expect((await call('POST', 'flat-wizard/cancel')).$1, 409);
      expect(backend.starts, 0);
    },
  );

  test('a disconnected wheel cannot start a batch on two filters', () async {
    final result = await call(
      'POST',
      'flat-wizard/run',
      body: {
        ...draft(),
        'mode': 'batch',
        'filterSettings': [
          {'filterName': 'L', 'filterPosition': 0},
          {'filterName': 'R', 'filterPosition': 1},
        ],
      },
    );
    expect(result.$1, 409);
    expect(result.$2['error'], 'filter_wheel_not_connected');
    expect(backend.starts, 0);
  });

  test('invalid capture parameters are refused before admission', () async {
    for (final bad in [
      draft(global: {'frameCount': 1.5}),
      draft(global: {'gain': -1}),
      draft(global: {'binning': 0}),
      draft(global: {'histogramTarget': 101}),
      draft(global: {'tolerancePercent': 0}),
      draft(global: {'imageDownloadTimeoutSeconds': 0}),
      draft(global: {'minExposure': 3, 'maxExposure': 2}),
      draft(filter: {'offsetOverride': -1}),
      draft(filter: {'minExposureOverride': 0}),
      draft(filter: {'frameCountOverride': 1000}),
      draft(filter: {'histogramTargetOverride': -1}),
      draft(filter: {'toleranceOverride': 26}),
      draft(filter: {'suggestedExposure': -2}),
      {...draft(), 'currentFilterIndex': 5},
      {
        ...draft(),
        'mode': 'batch',
        'filterSettings': [
          {'filterName': 'L', 'filterPosition': 0, 'enabled': false},
        ],
      },
      {
        ...draft(),
        'filterSettings': [
          {'filterPosition': 0, 'filterName': 'L'},
          {'filterPosition': 0, 'filterName': 'R'},
        ],
      },
    ]) {
      final result = await call(
        'POST',
        'flat-wizard/run',
        token: 'admin-token',
        body: bad,
      );
      expect(result.$1, 400, reason: '$bad => $result');
    }
    // A JSON exponent can exceed a native double even though the JSON
    // parser accepts it. Reject that value before converting gain to an int.
    final req = await client.postUrl(
      Uri.parse('http://127.0.0.1:${server.actualPort}/api/flat-wizard/run'),
    );
    req.headers.set('x-skotiq-version', '9.1.0');
    req.headers.set('Authorization', 'Bearer admin-token');
    req.headers.contentType = ContentType.json;
    req.write(
      jsonEncode(draft(global: {'gain': 12345})).replaceFirst('12345', '1e400'),
    );
    final response = await req.close();
    expect(response.statusCode, 400);
    await response.drain<void>();
    expect(backend.starts, 0);
  });

  test(
    'explicit folders must exist and the default must remain inside the host roots',
    () async {
      final (status, _) = await call(
        'POST',
        'flat-wizard/run',
        body: draft(global: {'savePath': p.join(capture.path, 'missing')}),
      );
      expect(status, 400);
      final outside = await Directory.systemTemp.createTemp(
        'skotiq-unrelated-',
      );
      addTearDown(() => outside.delete(recursive: true));
      await Link(p.join(capture.path, 'Flats')).create(outside.path);
      expect((await call('POST', 'flat-wizard/run', body: draft())).$1, 403);
      expect(backend.starts, 0);
    },
    skip: Platform.isWindows ? 'symlink creation needs OS privileges' : null,
  );

  test(
    'portrait preview caps both axes, preserves sensor geometry, and rejects a stale key',
    () async {
      const key = '2026-11-21T00:00:00Z';
      container
          .read(flatWizardProvider.notifier)
          .setLastImage(
            null,
            CapturedImageResult(
              width: 8,
              height: 3200,
              displayData: Uint8List(8 * 3200 * 4),
              histogram: const [],
              stats: const ImageStatsResult(
                min: 0,
                max: 0,
                mean: 0,
                median: 0,
                stdDev: 0,
                starCount: 0,
              ),
              exposureTime: 1,
              timestamp: key,
            ),
          );
      expect(
        (await call(
          'GET',
          'flat-wizard/preview?key=old',
          token: 'view-token',
        )).$1,
        404,
      );
      final res = await request(
        'GET',
        'flat-wizard/preview?key=$key',
        token: 'view-token',
      );
      expect(res.statusCode, 200);
      final header = decodeImageMetaHeader(res.headers.value('x-image-meta')!);
      expect([header['width'], header['height']], [8, 3200]);
      final bytes = await res.fold<List<int>>(
        <int>[],
        (all, chunk) => all..addAll(chunk),
      );
      final decoded = img.decodeJpg(Uint8List.fromList(bytes))!;
      expect([decoded.width, decoded.height], [4, 1600]);
    },
  );
}

Future<void> _waitForFlatIdle(ProviderContainer container) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (container.read(flatWizardProvider.notifier).isBusy &&
      DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(container.read(flatWizardProvider.notifier).isBusy, false);
}
