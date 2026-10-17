import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart' show SkotiqBackend;
import 'package:skotiq_core/src/database/daos/dark_library_dao.dart';
import 'package:skotiq_core/src/database/daos/equipment_profiles_dao.dart';
import 'package:skotiq_core/src/database/daos/images_dao.dart';
import 'package:skotiq_core/src/database/daos/sequence_checkpoints_dao.dart';
import 'package:skotiq_core/src/database/daos/sequences_dao.dart';
import 'package:skotiq_core/src/database/daos/sessions_dao.dart';
import 'package:skotiq_core/src/database/daos/settings_dao.dart';
import 'package:skotiq_core/src/database/daos/targets_dao.dart';
import 'package:skotiq_core/src/database/daos/weather_settings_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/backend/event_types.dart';
import 'package:skotiq_core/src/models/backend/image_result.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart'
    as seq_models;
import 'package:skotiq_core/src/models/science/science_models.dart' as science;
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/providers/profiles_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import 'package:skotiq_core/src/services/backup_service.dart';
import 'package:skotiq_core/src/services/catalog_service.dart';
import 'package:skotiq_core/src/services/dark_library_service.dart';
import 'package:skotiq_core/src/services/flat_wizard_service.dart';
import 'package:skotiq_core/src/services/logging_service.dart';
import 'package:skotiq_core/src/services/notification_service.dart';
import 'package:skotiq_core/src/services/paginated_image_loader.dart';
import 'package:skotiq_core/src/services/plate_solve_service.dart'
    as plate_solve;
import 'package:skotiq_core/src/services/profile_service.dart';
import 'package:skotiq_core/src/services/quick_start_service.dart';
import 'package:skotiq_core/src/services/sequence_repository.dart';
import 'package:skotiq_core/src/services/sky_brightness_tracker.dart';

import '../mocks/mock_backend.dart';
import '../mocks/mock_database.dart';

class _MockSessionsDao extends Mock implements SessionsDao {}

class _MockEquipmentProfilesDao extends Mock implements EquipmentProfilesDao {}

class _MockTargetsDao extends Mock implements TargetsDao {}

class _MockSequencesDao extends Mock implements SequencesDao {}

class _MockSequenceCheckpointsDao extends Mock
    implements SequenceCheckpointsDao {}

class _MockSequenceRepository extends Mock implements SequenceRepository {}

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

class _TestFlatWizardService extends FlatWizardService {
  final List<double?> _samples;
  int _index = 0;

  _TestFlatWizardService(this._samples) : super(MockBackend());

  @override
  Future<({double? adu, FlatFrameCapture? outcome})> captureTestFrame({
    required String deviceId,
    required double exposureTime,
    int? gain,
    int? offset,
    String? filterName,
    int? filterPosition,
    String? filterWheelDeviceId,
    int binX = 1,
    int binY = 1,
    FlatCancelToken? cancelToken,
    Duration abortSettleTimeout = const Duration(seconds: 10),
    Duration? overallTimeout,
  }) async {
    final sample = _samples[_index];
    _index = (_index + 1).clamp(0, _samples.length - 1);
    return (adu: sample, outcome: null);
  }
}

class _FlatWizardCaptureBackend extends MockBackend {
  final _events = StreamController<SkotiqEvent>.broadcast();
  int? gain;
  int? offset;
  int? binX;
  int? binY;

  @override
  Stream<SkotiqEvent> get eventStream => _events.stream;

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
    this.gain = gain;
    this.offset = offset;
    this.binX = binX;
    this.binY = binY;
    Timer.run(() {
      _events.add(
        SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.info,
          category: EventCategory.imaging,
          eventType: 'ExposureComplete',
          data: const {},
        ),
      );
    });
  }

  @override
  Future<CapturedImageResult?> cameraGetLastImage(String deviceId) async {
    return CapturedImageResult(
      width: 1,
      height: 1,
      displayData: const [0, 0, 0, 255],
      histogram: const [1],
      stats: const ImageStatsResult(
        min: 1234,
        max: 1234,
        mean: 1234,
        median: 1234,
        stdDev: 0,
        starCount: 0,
      ),
      exposureTime: 1.5,
      timestamp: DateTime.now().toIso8601String(),
    );
  }

  Future<void> close() => _events.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Residual service fixes', () {
    test(
      'searchCatalog applies offset exactly once across streamed pages',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'catalog_service_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final catalogFile = File(
          '${tempDir.path}${Platform.pathSeparator}catalog.csv',
        );
        final rows = <String>[
          'id,name,ra,dec',
          for (int i = 1; i <= 10; i++)
            'M$i,Object $i,${i.toDouble()},${i.toDouble()}',
        ];
        await catalogFile.writeAsString(rows.join('\n'));

        final service = CatalogService(catalogFile.path);
        final results = await service.searchCatalog(
          query: '',
          offset: 5,
          limit: 3,
        );

        expect(results.map((entry) => entry.id).toList(), ['M6', 'M7', 'M8']);
      },
    );

    test('loadDarkPixels rejects truncated FITS pixel payloads', () async {
      final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);

      final service = DarkLibraryService(DarkLibraryDao(database));
      final tempDir = await Directory.systemTemp.createTemp('dark_library_');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final truncatedFits = File(
        '${tempDir.path}${Platform.pathSeparator}truncated.fit',
      );
      await truncatedFits.writeAsBytes(
        _buildFitsFileBytes(width: 2, height: 1, dataBytes: [0, 1, 2]),
      );

      expect(
        service.loadDarkPixels(truncatedFits.path),
        throwsA(isA<FormatException>()),
      );
    });

    test(
      'notification requests time out instead of hanging indefinitely',
      () async {
        final client = MockClient((request) async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return http.Response('{}', 200);
        });

        final service = NotificationService.testing(
          settingsReader: () => const AppSettingsState(
            notificationsEnabled: true,
            discordWebhook: 'https://example.com/webhook',
          ),
          httpClient: client,
          requestTimeout: const Duration(milliseconds: 10),
        );

        final sent = await service.notify(
          event: NotificationEvent.custom,
          title: 'Test',
          message: 'Timeout test',
        );

        expect(sent, isFalse);
      },
    );

    test(
      'calibrateFilterWithRateTracking reports maxIterations on non-convergence',
      () async {
        final service = _TestFlatWizardService([5000, 5000]);
        final tracker = SkyBrightnessTracker();

        final result = await service.calibrateFilterWithRateTracking(
          deviceId: 'camera-1',
          filter: 'L',
          gain: 100,
          offset: 50,
          targetAdu: 20000,
          tolerance: 5,
          minExposure: 1,
          maxExposure: 100,
          brightnessTracker: tracker,
          maxIterations: 2,
        );

        expect(result.success, isFalse);
        expect(result.iterations, 2);
      },
    );

    test('calibrateFilter reports maxIterations on non-convergence', () async {
      // Same restored capture seam as the rate-tracking solver: each measured
      // ADU is valid but far off target, so the solver must run the full
      // budget and report it — not short-circuit at iteration 1.
      final service = _TestFlatWizardService([5000, 5000, 5000]);

      final result = await service.calibrateFilter(
        deviceId: 'camera-1',
        filter: 'L',
        gain: 100,
        offset: 50,
        targetAdu: 20000,
        tolerance: 5,
        minExposure: 1,
        maxExposure: 100,
        maxIterations: 3,
      );

      expect(result.success, isFalse);
      expect(result.iterations, 3);
    });

    test(
      'captureTestFrame forwards supplied gain and offset to the camera',
      () async {
        final backend = _FlatWizardCaptureBackend();
        addTearDown(backend.close);

        final service = FlatWizardService(backend);
        final frame = await service.captureTestFrame(
          deviceId: 'camera-1',
          exposureTime: 1.5,
          gain: 137,
          offset: 42,
          binX: 2,
          binY: 2,
        );

        expect(frame.adu, 1234);
        expect(backend.gain, 137);
        expect(backend.offset, 42);
        expect(backend.binX, 2);
        expect(backend.binY, 2);
      },
    );

    test(
      'quick start propagates storage failures instead of returning empty state',
      () async {
        final sessionsDao = _MockSessionsDao();
        // The first read the context makes: the nights a process left
        // unfinished. (It used to read the active ones — the same set, before
        // the boot sweep started closing an abandoned row at open.)
        when(
          () => sessionsDao.getInterruptedSessions(),
        ).thenThrow(StateError('db corrupt'));

        final service = QuickStartService(
          sessionsDao: sessionsDao,
          profilesDao: _MockEquipmentProfilesDao(),
          targetsDao: _MockTargetsDao(),
          sequencesDao: _MockSequencesDao(),
          checkpointsDao: _MockSequenceCheckpointsDao(),
        );

        expect(service.getQuickStartContext(), throwsA(isA<StateError>()));
      },
    );

    test(
      'paginated image loader updates paging state for explicit page loads',
      () async {
        final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);

        final imagesDao = ImagesDao(database);
        for (int i = 0; i < 3; i++) {
          await imagesDao.createImage(
            DatabaseTestFixtures.sampleImageCompanion(
              filePath: '/tmp/image_$i.fit',
              fileName: 'image_$i.fit',
              capturedAt: DateTime.utc(2026, 1, 1, 0, i),
            ),
          );
        }

        final loader = PaginatedImageLoader(imagesDao: imagesDao, pageSize: 2);
        final page = await loader.loadPage(2);

        expect(page, hasLength(1));
        expect(loader.currentPage, 2);
        expect(loader.hasMore, isFalse);
        expect(loader.loadedCount, 1);
      },
    );

    test(
      'backup restore coerces legacy non-string setting values instead of crashing',
      () async {
        final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);

        final tempDir = await Directory.systemTemp.createTemp(
          'backup_restore_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final backupFile = File(
          '${tempDir.path}${Platform.pathSeparator}legacy.nsbackup',
        );
        await backupFile.writeAsString(
          jsonEncode({
            'version': '2.0',
            'createdAt': DateTime.now().toIso8601String(),
            'appVersion': '2.5.0',
            'platform': 'windows',
            'settings': {
              'notifications_enabled': true,
              'plate_solve_timeout': 45,
            },
            'equipmentProfiles': const [],
            'targets': const [],
          }),
        );

        final service = BackupService(
          database: database,
          sequenceRepository: _MockSequenceRepository(),
          logger: LoggingService(),
        );

        final result = await service.restoreBackup(filePath: backupFile.path);
        final settings = await SettingsDao(database).getAllSettings();

        expect(result.success, isTrue);
        expect(settings['notifications_enabled'], 'true');
        expect(settings['plate_solve_timeout'], '45');
      },
    );

    test(
      'backup metadata reads nested category counts from v2 backups',
      () async {
        final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);

        final tempDir = await Directory.systemTemp.createTemp(
          'backup_metadata_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final backupFile = File(
          '${tempDir.path}${Platform.pathSeparator}metadata.nsbackup',
        );
        await backupFile.writeAsString(
          jsonEncode({
            'version': '2.0',
            'createdAt': DateTime.utc(2026, 5, 5).toIso8601String(),
            'appVersion': '2.5.0',
            'platform': 'windows',
            'metadata': {
              'settingsCount': 2,
              'profilesCount': 3,
              'sequencesCount': 4,
              'targetsCount': 5,
            },
            'settings': const {},
            'equipmentProfiles': const [],
            'sequences': const [],
            'targets': const [],
          }),
        );

        final service = BackupService(
          database: database,
          sequenceRepository: _MockSequenceRepository(),
          logger: LoggingService(),
        );

        final metadata = await service.readBackupMetadata(backupFile.path);

        expect(metadata?.settingsCount, 2);
        expect(metadata?.profilesCount, 3);
        expect(metadata?.sequencesCount, 4);
        expect(metadata?.targetsCount, 5);
      },
    );

    test(
      'backup restore accepts current TargetHeader sequence nodes',
      () async {
        final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);

        final tempDir = await Directory.systemTemp.createTemp(
          'backup_sequence_restore_',
        );
        addTearDown(() async {
          if (await tempDir.exists()) {
            await tempDir.delete(recursive: true);
          }
        });

        final backupFile = File(
          '${tempDir.path}${Platform.pathSeparator}sequence.nsbackup',
        );
        await backupFile.writeAsString(
          jsonEncode({
            'version': '2.0',
            'createdAt': DateTime.utc(2026, 5, 5).toIso8601String(),
            'appVersion': '2.5.0',
            'platform': 'windows',
            'settings': const {},
            'equipmentProfiles': const [],
            'sequences': [
              {
                'name': 'Restored Sequence',
                'description': 'TargetHeader restore coverage',
                'rootNodeId': 'target-1',
                'isTemplate': false,
                'createdAt': DateTime.utc(2026, 5, 5).toIso8601String(),
                'modifiedAt': DateTime.utc(2026, 5, 5).toIso8601String(),
                'nodes': {
                  'target-1': {
                    'id': 'target-1',
                    'nodeType': 'TargetHeader',
                    'name': 'M31',
                    'parentId': null,
                    'childIds': const [],
                    'orderIndex': 0,
                    'isEnabled': true,
                    'targetName': 'M31',
                    'raHours': 0.712,
                    'decDegrees': 41.269,
                    'rotation': 15.0,
                    'minAltitude': 30.0,
                    'maxAltitude': 80.0,
                    'priority': 2,
                  },
                },
              },
            ],
            'targets': const [],
          }),
        );

        final repository = SequenceRepository(SequencesDao(database));
        final service = BackupService(
          database: database,
          sequenceRepository: repository,
          logger: LoggingService(),
        );

        final result = await service.restoreBackup(filePath: backupFile.path);
        final restoredSequences = await repository.loadAllSequences();
        final targetNode = restoredSequences.single.nodes['target-1'];

        expect(result.success, isTrue);
        expect(result.categoryCounts['sequences'], 1);
        expect(targetNode, isA<seq_models.TargetHeaderNode>());
        expect((targetNode! as seq_models.TargetHeaderNode).targetName, 'M31');
      },
    );

    test(
      'backup restore rolls back replace when a late table is malformed',
      () async {
        final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);
        final settingsDao = SettingsDao(database);
        await settingsDao.setSetting('sentinel', 'keep-me');

        final dir = await Directory.systemTemp.createTemp('sk_atomic_restore_');
        addTearDown(() => dir.delete(recursive: true));
        final backupFile = File('${dir.path}/malformed.nsbackup');
        await backupFile.writeAsString(
          jsonEncode({
            'version': BackupService.backupVersion,
            'createdAt': DateTime.utc(2026, 7, 13).toIso8601String(),
            'settings': {'replacement': 'new-value'},
            'equipmentProfiles': <Object?>[],
            'sequences': <Object?>[],
            'targets': <Object?>[],
            // Reached after core tables have already been applied: skipping
            // it while still returning success is the failure under test.
            'darkLibrary': [42],
          }),
        );

        final service = BackupService(
          database: database,
          sequenceRepository: SequenceRepository(SequencesDao(database)),
          logger: LoggingService(),
        );

        final result = await service.restoreBackup(
          filePath: backupFile.path,
          replaceExisting: true,
        );

        expect(result.success, isFalse);
        expect(await settingsDao.getSetting('sentinel'), 'keep-me');
        expect(await settingsDao.getSetting('replacement'), equals(null));
      },
    );

    test(
      'profile import tolerates numeric legacy values and float offsets',
      () {
        final data = ProfileExportData.fromJson({
          'name': 'Test Profile',
          'defaultGain': 100.9,
          'defaultOffset': 50.1,
          'defaultBinX': 2.0,
          'defaultBinY': 3.0,
          'filterFocusOffsets': {'L': 1.9, 'R': -2.2},
        });

        expect(data.defaultGain, 100);
        expect(data.defaultOffset, 50);
        expect(data.defaultBinX, 2);
        expect(data.defaultBinY, 3);
        expect(data.filterFocusOffsets, {'L': 1, 'R': -2});
      },
    );

    // Import is a real entry point for an impossible optical train, not just a
    // round-trip of our own data: the file is hand-editable and may come from a
    // build that had no plausibility bounds. Focal length reaches the FITS
    // FOCALLEN card and the plate-solve field-of-view estimate, so it must be
    // bounded here too, by the same shared contract the editors use.
    test('profile import rejects an implausible optical train', () {
      expect(
        () => ProfileExportData.fromJson({
          'name': 'Absurd optics',
          'focalLength': 999999999.0,
          'aperture': 0.0001,
        }),
        throwsFormatException,
      );
      expect(
        () => ProfileExportData.fromJson({
          'name': 'Absurd focal length',
          'focalLength': 999999999.0,
        }),
        throwsFormatException,
      );
      expect(
        () => ProfileExportData.fromJson({
          'name': 'Impossible ratio from in-range fields',
          'focalLength': 40000.0,
          'aperture': 2.0,
        }),
        throwsFormatException,
      );
      expect(
        () => ProfileExportData.fromJson({
          'name': 'Absurd stored ratio',
          'focalLength': 550.0,
          'aperture': 100.0,
          'focalRatio': 9999999990000.0,
        }),
        throwsFormatException,
      );
      expect(
        () => ProfileExportData.fromJson({
          'name': 'Absurd legacy telescope optics',
          'telescopeFocalLength': 999999999.0,
        }),
        throwsFormatException,
      );
    });

    test('profile import accepts real rigs and unspecified optics', () {
      // Samyang 135 f/2, RASA 11 f/2.2, 1 m professional f/8, and a profile
      // that simply never filled optics in.
      const rigs = <List<double>>[
        [135, 67.5],
        [620, 279],
        [8000, 1000],
        [0, 0],
      ];
      for (final rig in rigs) {
        final data = ProfileExportData.fromJson({
          'name': 'Rig ${rig[0]}',
          'focalLength': rig[0],
          'aperture': rig[1],
        });
        expect(data.focalLength, rig[0]);
        expect(data.aperture, rig[1]);
      }
    });

    test('profile import rejects invalid binning and filter schemas', () {
      expect(
        () => ProfileExportData.fromJson({
          'name': 'Broken binning',
          'defaultBinX': 0,
        }),
        throwsFormatException,
      );
      expect(
        () => ProfileExportData.fromJson({
          'name': 'Broken filters',
          'filterNames': ['L', 42],
        }),
        throwsFormatException,
      );
    });

    test('profile export round-trips the complete portable configuration', () {
      const model = EquipmentProfileModel(
        name: 'Remote Rig',
        cameraId: 'camera-id',
        cameraName: 'ASI2600MM Pro',
        mountName: 'EQ6-R Pro',
        focuserName: 'EAF',
        filterWheelName: 'EFW',
        guiderName: 'PHD2',
        rotatorName: 'Falcon',
        safetyMonitorName: 'Cloud Watcher',
        switchName: 'Power Box',
        telescopeName: 'Esprit 100',
        telescopeFocalLength: 550,
        telescopeAperture: 100,
        focalLength: 413,
        aperture: 100,
        defaultCoolingTemp: -10,
        coolOnConnect: true,
        defaultCenteringExposure: 4.5,
        filterNames: ['L', 'R'],
        filterFocusOffsets: {'L': 0, 'R': 12},
        meridianFlipOverrides: '{"enabled":true}',
        profileIcon: 'telescope',
        profileColor: 0xff336699,
      );

      final restored = ProfileExportData.fromJson(
        ProfileExportData.fromModel(model).toJson(),
      );

      expect(restored.cameraName, model.cameraName);
      expect(restored.mountName, model.mountName);
      expect(restored.telescopeName, model.telescopeName);
      expect(restored.telescopeFocalLength, 550);
      expect(restored.telescopeAperture, 100);
      expect(restored.coolOnConnect, isTrue);
      expect(restored.defaultCenteringExposure, 4.5);
      expect(restored.meridianFlipOverrides, '{"enabled":true}');
      expect(restored.profileIcon, 'telescope');
      expect(restored.profileColor, 0xff336699);
      expect(restored.filterFocusOffsets, {'L': 0, 'R': 12});
    });

    test('equipment snapshot rejects malformed JSON schema', () {
      expect(
        () => EquipmentSnapshot.fromJsonString('["not-an-object"]'),
        throwsA(isA<FormatException>()),
      );
    });

    test('loadSequence fails loudly on unsupported node types', () async {
      final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);

      final dao = SequencesDao(database);
      final repository = SequenceRepository(dao);
      final sequenceId = await dao.createSequence(
        SequencesCompanion.insert(name: 'Broken Sequence'),
      );

      await dao.createNode(
        SequenceNodesCompanion.insert(
          sequenceId: sequenceId,
          nodeId: 'node-1',
          nodeType: 'instruction',
          specificType: 'unknown-node-type',
          name: 'Broken Node',
        ),
      );

      expect(repository.loadSequence(sequenceId), throwsA(isA<StateError>()));
    });

    test(
      'sequence repository preserves Smart Exposure loop-until-stopped',
      () async {
        final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);

        final repository = SequenceRepository(SequencesDao(database));
        final sequenceId = await repository.saveSequence(
          seq_models.Sequence.create(
            name: 'Smart Exposure Persistence',
            rootNodeId: 'root',
            nodes: {
              'root': seq_models.InstructionSetNode(
                id: 'root',
                childIds: const ['smart'],
              ),
              'smart': seq_models.SmartExposureNode(
                id: 'smart',
                parentId: 'root',
                loopUntilStopped: true,
                integrationBudgetSecs: 5400,
                plans: const [
                  seq_models.FilterPlan(
                    filterName: 'L',
                    count: 3,
                    durationSecs: 180,
                  ),
                ],
              ),
            },
          ),
        );

        final restored = await repository.loadSequence(sequenceId);
        final smart = restored!.nodes['smart'] as seq_models.SmartExposureNode;

        expect(smart.loopUntilStopped, isTrue);
        expect(smart.integrationBudgetSecs, 5400);
        expect(smart.plans.single.filterName, 'L');
      },
    );

    test('saving sequence clears legacy recovery config references', () async {
      final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);

      final dao = SequencesDao(database);
      final repository = SequenceRepository(dao);
      final sequenceId = await dao.createSequence(
        SequencesCompanion.insert(
          name: 'Legacy Recovery Sequence',
          rootNodeId: const Value('root'),
        ),
      );

      await dao.createNode(
        SequenceNodesCompanion.insert(
          sequenceId: sequenceId,
          nodeId: 'root',
          nodeType: 'logic',
          specificType: 'recovery',
          name: 'Recovery',
          properties: const Value('{"recoveryAction":"retry"}'),
          recoveryConfig: const Value('{"targetNodeId":"child"}'),
        ),
      );
      await dao.createNode(
        SequenceNodesCompanion.insert(
          sequenceId: sequenceId,
          nodeId: 'child',
          nodeType: 'instruction',
          specificType: 'exposure',
          name: 'Exposure',
          properties: const Value('{"count":1,"durationSecs":60.0}'),
          parentNodeId: const Value('root'),
          orderIndex: const Value(0),
        ),
      );

      await repository.saveSequence(
        seq_models.Sequence.create(
          databaseId: sequenceId,
          name: 'Legacy Recovery Sequence',
          rootNodeId: 'root',
          nodes: {
            'root': seq_models.RecoveryNode(id: 'root', childIds: const []),
          },
        ),
      );

      final nodes = await dao.getNodesForSequence(sequenceId);
      expect(nodes, hasLength(1));
      expect(nodes.single.nodeId, 'root');
      expect(nodes.single.recoveryConfig, equals(null));
    });

    test('plate solve fallback preserves backend error details', () async {
      final backend = MockBackend();
      when(() => backend.eventStream).thenAnswer((_) => const Stream.empty());
      when(
        () => backend.polarAlignmentEvents,
      ).thenAnswer((_) => const Stream.empty());
      when(
        () => backend.plateSolve(
          imagePath: any(named: 'imagePath'),
          ra: any(named: 'ra'),
          dec: any(named: 'dec'),
          fovDegrees: any(named: 'fovDegrees'),
          timeoutSeconds: any(named: 'timeoutSeconds'),
        ),
      ).thenThrow(StateError('backend failed'));

      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);

      final service = container.read(plate_solve.plateSolveServiceProvider);
      final result = await service.solve(
        'missing.fit',
        const plate_solve.PlateSolverConfig(
          type: plate_solve.PlateSolverType.astap,
          executablePath: 'C:/missing/astap.exe',
        ),
      );

      expect(result.success, isFalse);
      expect(result.error, contains('backend failed'));
      expect(result.error, contains('Local fallback failed'));
    });

    test('dark library deduplicates entries by file path', () async {
      final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);

      final dao = DarkLibraryDao(database);
      final firstId = await dao.addEntry(
        DarkLibraryCompanion.insert(
          filePath: '/tmp/dark.fit',
          exposureTime: 60,
          gain: const Value(100),
          offset: const Value(10),
        ),
      );
      final secondId = await dao.addEntry(
        DarkLibraryCompanion.insert(
          filePath: '/tmp/dark.fit',
          exposureTime: 120,
          gain: const Value(100),
          offset: const Value(10),
        ),
      );

      final entries = await dao.getAllEntries();
      expect(secondId, firstId);
      expect(entries, hasLength(1));
      expect(entries.single.exposureTime, 120);
    });

    test('dark matching includes camera offset', () async {
      final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);

      final dao = DarkLibraryDao(database);
      await dao.addEntry(
        DarkLibraryCompanion.insert(
          filePath: '/tmp/dark_offset_10.fit',
          exposureTime: 60,
          gain: const Value(100),
          offset: const Value(10),
        ),
      );
      await dao.addEntry(
        DarkLibraryCompanion.insert(
          filePath: '/tmp/dark_offset_20.fit',
          exposureTime: 60,
          gain: const Value(100),
          offset: const Value(20),
        ),
      );

      final match = await dao.findBestMatch(
        exposureTime: 60,
        gain: 100,
        offset: 20,
        binX: 1,
        binY: 1,
      );

      expect(match?.filePath, '/tmp/dark_offset_20.fit');
    });

    test('science session config upsert updates in place', () async {
      final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);

      final sessionId = await database.sessionsDao.createSession(
        ImagingSessionsCompanion.insert(startTime: DateTime.utc(2026, 1, 1)),
      );

      await database.scienceDao.upsertSessionConfig(
        science.ScienceSessionConfig(
          sessionId: sessionId,
          photometryEnabled: true,
        ),
      );
      await database.scienceDao.upsertSessionConfig(
        science.ScienceSessionConfig(
          sessionId: sessionId,
          photometryEnabled: false,
        ),
      );

      final rows = await (database.select(
        database.scienceSessionConfig,
      )..where((tbl) => tbl.sessionId.equals(sessionId))).get();

      expect(rows, hasLength(1));
      expect(rows.single.photometryEnabled, isFalse);
    });

    test(
      'weather settings DAO collapses duplicate rows into a singleton',
      () async {
        final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
        addTearDown(database.close);

        final dao = WeatherSettingsDao(database);
        await database
            .into(database.weatherSettings)
            .insert(WeatherSettingsCompanion.insert(id: const Value(1)));
        await database
            .into(database.weatherSettings)
            .insert(WeatherSettingsCompanion.insert(id: const Value(2)));

        final settings = await dao.getOrCreateSettings();
        final rows = await database.select(database.weatherSettings).get();

        expect(settings.id, 1);
        expect(rows, hasLength(1));
      },
    );
  });
}

Uint8List _buildFitsFileBytes({
  required int width,
  required int height,
  required List<int> dataBytes,
}) {
  final headerCards = <String>[
    _fitsCard('SIMPLE', 'T'),
    _fitsCard('BITPIX', '16'),
    _fitsCard('NAXIS', '2'),
    _fitsCard('NAXIS1', width.toString()),
    _fitsCard('NAXIS2', height.toString()),
    'END'.padRight(80, ' '),
  ];

  final header = headerCards.join().padRight(2880, ' ');
  final bytes = <int>[...ascii.encode(header), ...dataBytes];
  return Uint8List.fromList(bytes);
}

String _fitsCard(String keyword, String value) {
  return '${keyword.padRight(8)}= ${value.toString().padLeft(20)}'.padRight(
    80,
    ' ',
  );
}
