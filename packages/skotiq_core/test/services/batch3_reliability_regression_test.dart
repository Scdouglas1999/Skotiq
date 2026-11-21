import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/src/backend/network_backend/host_data/host_poll.dart';
import 'package:skotiq_core/src/database/daos/focus_history_dao.dart';
import 'package:skotiq_core/src/services/centering_service.dart';
import 'package:skotiq_core/src/services/darkroom_target_edits.dart';
import 'package:skotiq_core/src/services/file_trash.dart';
import 'package:skotiq_core/src/services/notification/secrets_store.dart';
import 'package:skotiq_remote_protocol/wire.dart' show skotiqRelease;

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend initial) {
    state = initial;
  }
}

class _RecordingCalBackend extends DisconnectedBackend {
  String? lastOutputPath;

  @override
  Future<void> calibrateImageFile({
    required String lightPath,
    String? darkPath,
    String? flatPath,
    String? biasPath,
    required String outputPath,
  }) async {
    lastOutputPath = outputPath;
    await File(outputPath).writeAsString('calibrated');
  }
}

class _FakeHostPointing implements HostPointing {
  _FakeHostPointing(this._startGate);

  final Completer<String> _startGate;
  final List<String> cancelledJobs = [];

  @override
  Future<String> startCentering({
    required double raHours,
    required double decDegrees,
    int maxAttempts = 5,
    double accuracyArcsec = 30,
    double exposureSecs = 3,
    bool syncMount = true,
  }) => _startGate.future;

  @override
  Future<void> cancelJob(String jobId) async {
    cancelledJobs.add(jobId);
  }

  @override
  Future<RemoteJob> awaitJobCompletion(
    String jobId, {
    Duration timeout = const Duration(minutes: 10),
    Duration pollInterval = const Duration(seconds: 1),
  }) async => RemoteJob(
    jobId: jobId,
    operation: 'centering',
    state: 'cancelled',
    createdAt: DateTime.utc(2026, 11, 1),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FlakySecureStore implements SecureKeyValueStore {
  bool locked = true;
  final Map<String, String> values = {};

  @override
  Future<String?> read({required String key}) async {
    if (locked) {
      throw StateError('keyring locked');
    }
    return values[key];
  }

  @override
  Future<void> write({required String key, required String value}) async {
    if (locked) {
      throw StateError('keyring locked');
    }
    values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    if (locked) {
      throw StateError('keyring locked');
    }
    values.remove(key);
  }
}

class _NoopFileTrash implements FileTrash {
  @override
  bool get restorable => false;

  @override
  Future<List<String>> remove(List<String> paths) async => const [];
}

void main() {
  group('Batch 3 reliability regressions', () {
    test(
      'NetworkBackend dispose during in-flight connect and HostPoll.dispose do not throw',
      () async {
        final infoGate = Completer<http.Response>();
        final backend = NetworkBackend(
          serverHost: '127.0.0.1',
          serverPort: 18999,
          httpClient: MockClient((_) => infoGate.future),
        );

        final connectFuture = backend.connect();
        await Future<void>.delayed(Duration.zero);
        backend.dispose();

        infoGate.complete(
          http.Response(
            '{"version":"$skotiqRelease","serverInstanceId":"inst-1"}',
            200,
          ),
        );
        await connectFuture;

        final poll = HostPoll('test');
        poll.dispose();
        // Safe no-op after dispose.
        poll.refresh();
        poll.dispose();
      },
    );

    test(
      'CalibrationService creates .uncal backup only on true in-place overwrite',
      () async {
        final dir = await Directory.systemTemp.createTemp('cal_backup_');
        addTearDown(() => dir.delete(recursive: true));
        final light = File(p.join(dir.path, 'sub_001.fits'))
          ..writeAsStringSync('raw-light');
        final dark = File(p.join(dir.path, 'master_dark.fits'))
          ..writeAsStringSync('master-dark');
        final backend = _RecordingCalBackend();
        final container = ProviderContainer(
          overrides: [
            backendProvider.overrideWith(
              (ref) => _FixedBackendNotifier(ref, backend),
            ),
          ],
        );
        addTearDown(container.dispose);

        final service = container.read(calibrationServiceProvider);
        final settings = CalibrationSettings(
          autoDarkFromLibrary: false,
          manualDarkPath: dark.path,
        );

        // Default outputPath == null writes sibling `_cal.fits`; must NOT create `.uncal`.
        final sibling = await service.calibrateFile(
          lightPath: light.path,
          settings: settings,
        );
        expect(sibling.outputPath, p.join(dir.path, 'sub_001_cal.fits'));
        expect(File('${light.path}.uncal').existsSync(), isFalse);

        // Explicit in-place overwrite (outputPath == lightPath) MUST back up `.uncal`.
        await service.calibrateFile(
          lightPath: light.path,
          outputPath: light.path,
          settings: settings,
        );
        expect(File('${light.path}.uncal').existsSync(), isTrue);
        expect(File('${light.path}.uncal').readAsStringSync(), 'raw-light');
      },
    );

    test(
      'HostCenteringRunner.cancel during in-flight startCentering cancels the job once id resolves',
      () async {
        final startGate = Completer<String>();
        final host = _FakeHostPointing(startGate);
        final runner = HostCenteringRunner(host);

        final streamFuture = runner
            .center(
              const bridge.ApiCenteringRequest(
                mountId: 'm1',
                cameraId: 'c1',
                raHours: 10.0,
                decDegrees: 20.0,
                accuracyArcsec: 30.0,
                maxAttempts: 3,
                exposureSecs: 2.0,
                syncMount: true,
              ),
            )
            .toList();
        await Future<void>.delayed(Duration.zero);

        await runner.cancel();
        expect(host.cancelledJobs, isEmpty);

        startGate.complete('job-42');
        final steps = await streamFuture;

        expect(host.cancelledJobs, ['job-42']);
        expect(steps.last, isA<bridge.ApiCenteringStep_Finished>());
      },
    );

    test(
      'NativeDiscovery.forget invalidates in-flight sweep and canCache=false avoids caching pre-init empties',
      () async {
        final firstSweep =
            Completer<Map<bridge.DeviceType, List<bridge.DeviceInfo>>>();
        var calls = 0;
        var ready = false;
        final discovery = NativeDiscovery(
          () async {
            calls++;
            if (calls == 1) return firstSweep.future;
            return {
              bridge.DeviceType.camera: [
                const bridge.DeviceInfo(
                  id: 'cam-fresh',
                  name: 'Fresh Cam',
                  deviceType: bridge.DeviceType.camera,
                  driverType: bridge.DriverType.simulator,
                  description: 'Simulator camera',
                  driverVersion: '1.0',
                  displayName: 'Fresh Cam',
                ),
              ],
            };
          },
          canCache: () => ready,
        );

        final pending = discovery.devices(bridge.DeviceType.camera);
        await Future<void>.delayed(Duration.zero);
        // Invalidate while sweep 1 is still running.
        discovery.forget();
        firstSweep.complete({bridge.DeviceType.camera: const []});

        final cams = await pending;
        expect(calls, 2);
        expect(cams.map((c) => c.id), ['cam-fresh']);

        // Because ready == false, sweep 2 was NOT cached; a subsequent call sweeps again.
        await discovery.devices(bridge.DeviceType.camera);
        expect(calls, 3);

        // Once native is ready, results ARE cached within TTL.
        ready = true;
        await discovery.devices(bridge.DeviceType.camera);
        await discovery.devices(bridge.DeviceType.camera);
        expect(calls, 4);
      },
    );

    test(
      'DarkroomTargetEdits computes circular median RA across 0h/24h wrap and chunks >500 frames',
      () async {
        final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final edits = DarkroomTargetEdits(
          db,
          trash: () async => _NoopFileTrash(),
        );

        final frames = <DbCapturedImage>[];
        final ras = [23.95, 23.98, 0.04];
        for (var i = 0; i < 520; i++) {
          final id = await db.imagesDao.insertSequenceFrame(
            filePath: '/lights/wrap_$i.fits',
            fileName: 'wrap_$i.fits',
            fileFormat: 'fits',
            exposureDuration: 60,
            capturedAt: DateTime.utc(2026, 11, 1),
            isAccepted: true,
            producingNodeId: 'n1',
            mountRa: ras[i % ras.length],
            mountDec: 40.0,
          );
          frames.add((await db.imagesDao.getImageById(id))!);
        }

        final edit = await edits.rename(
          DarkroomTargetGroup(key: 'Unknown', frames: frames),
          'NGC 7822',
        );
        final target = await db.targetsDao.getTargetById(edit.createdRow!);
        expect(target, isNotNull);
        // Circular median of {23.95, 23.98, 0.04} is ~23.98h (within 0.1h of 0h/24h).
        final distFromZero = target!.ra > 12.0 ? 24.0 - target.ra : target.ra;
        expect(distFromZero, lessThan(0.1));
        expect(edit.frameTargets.length, 520);
      },
    );

    test(
      'FocusModelService retries failed initialize and persists setReferenceFilter on fresh profile',
      () async {
        final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        var failFolderOnce = true;
        final focus = FocusModelService(
          FocusHistoryDao(db),
          jsonFolder: () async {
            if (failFolderOnce) {
              failFolderOnce = false;
              throw StateError('transient storage failure');
            }
            return null;
          },
        );
        await expectLater(focus.initialize(), throwsStateError);
        // Second call succeeds because the failed future was cleared.
        await focus.setReferenceFilter('fresh-profile', 'L');
        expect(focus.getProfileData('fresh-profile')?.referenceFilter, 'L');

        final backing = _FlakySecureStore();
        final secrets = SecretsStore(backing);
        await expectLater(
          secrets.read(SecretField.emailPassword),
          throwsStateError,
        );
        backing.locked = false;
        expect(await secrets.read(SecretField.emailPassword), '');
      },
    );
  });
}
