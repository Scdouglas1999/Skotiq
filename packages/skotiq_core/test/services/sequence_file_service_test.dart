import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:path/path.dart' as path;

class TestFileSelectorPlatform extends FileSelectorPlatform {
  TestFileSelectorPlatform({required this.openPath, required this.savePath});

  final String openPath;
  final String? savePath;
  String? lastOpenInitialDirectory;
  String? lastSaveInitialDirectory;

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    lastOpenInitialDirectory = initialDirectory;
    return XFile(openPath);
  }

  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async {
    lastSaveInitialDirectory = options.initialDirectory;
    final path = savePath;
    return path == null ? null : FileSaveLocation(path);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'legacy node defaults stay enabled and preserve polar model defaults',
    () {
      final service = SequenceFileService();
      final exposure = service.nodeFromMap({
        'nodeType': 'Exposure',
        'durationSecs': 60,
        'count': 1,
      });
      final polar = service.nodeFromMap({'nodeType': 'PolarAlignment'});

      expect(exposure.isEnabled, isTrue);
      expect(polar, isA<PolarAlignmentNode>());
      expect((polar as PolarAlignmentNode).startFromCurrent, isTrue);
      expect(polar.isNorth, isTrue);
    },
  );

  test(
    'sequence picker reads the configured directory at dialog-open time',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('sequence_path_');
      addTearDown(() async => tempDir.delete(recursive: true));
      final filePath = path.join(tempDir.path, 'sequence.skeq.json');
      final originalPlatform = FileSelectorPlatform.instance;
      final platform = TestFileSelectorPlatform(
        openPath: filePath,
        savePath: filePath,
      );
      FileSelectorPlatform.instance = platform;
      addTearDown(() => FileSelectorPlatform.instance = originalPlatform);
      var configuredDirectory = '/observatory/one';
      final service = SequenceFileService(
        defaultDirectoryProvider: () => configuredDirectory,
      );
      final sequence = Sequence.create(
        id: 'path-test',
        name: 'Path test',
        rootNodeId: 'root',
        nodes: {'root': InstructionSetNode(id: 'root', name: 'Root')},
      );

      await service.exportSequence(sequence, forceExport: true);
      expect(platform.lastSaveInitialDirectory, '/observatory/one');

      configuredDirectory = '/observatory/two';
      await service.importSequence();
      expect(platform.lastOpenInitialDirectory, '/observatory/two');
    },
  );

  test(
    'cancelled export reports no save and does not invoke callback',
    () async {
      final originalPlatform = FileSelectorPlatform.instance;
      FileSelectorPlatform.instance = TestFileSelectorPlatform(
        openPath: '/unused/sequence.json',
        savePath: null,
      );
      addTearDown(() => FileSelectorPlatform.instance = originalPlatform);
      var callbackCalls = 0;
      final service = SequenceFileService(
        onExportSaved: (_) => callbackCalls++,
      );
      final sequence = Sequence.create(
        id: 'cancelled-export',
        name: 'Cancelled export',
        rootNodeId: 'root',
        nodes: {'root': InstructionSetNode(id: 'root', name: 'Root')},
      );

      final saved = await service.exportSequence(sequence, forceExport: true);

      // `exportSequence` returns the path written rather than a bool, because
      // on Android/iOS the caller has to hand that path to the share sheet or
      // the file stays stranded in the app sandbox. Cancelling still has to
      // read as "nothing was written".
      expect(saved, isNull);
      expect(callbackCalls, 0);
    },
  );

  test('sequence file export/import preserves nodes', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'sequence_file_service_',
    );
    addTearDown(() async => tempDir.delete(recursive: true));

    final filePath = path.join(tempDir.path, 'sequence.skeq.json');
    final originalPlatform = FileSelectorPlatform.instance;

    FileSelectorPlatform.instance = TestFileSelectorPlatform(
      openPath: filePath,
      savePath: filePath,
    );
    addTearDown(() => FileSelectorPlatform.instance = originalPlatform);

    final sequence = Sequence.create(
      id: 'seq-1',
      name: 'Test Sequence',
      rootNodeId: 'target-1',
      nodes: {
        'target-1': TargetHeaderNode(
          id: 'target-1',
          targetName: 'M31',
          raHours: 0.712,
          decDegrees: 41.269,
          mosaicPanel: const MosaicPanelInfo(
            mosaicName: 'M31 detail',
            panelIndex: 1,
            totalPanels: 4,
            row: 0,
            column: 0,
          ),
          integrationBudget: const IntegrationBudget(totalSecs: 3600),
          startWhen: const TargetTrigger.altitudeAbove(35),
          endWhen: const TargetTrigger.timeBefore(1784000000),
          triggerPollIntervalSecs: 19,
          childIds: const ['exposure-1'],
        ),
        'exposure-1': ExposureNode(
          id: 'exposure-1',
          parentId: 'target-1',
          comment: 'Use the low-read-noise preset for this block.',
          durationSecs: 60,
          count: 1,
          frameType: FrameType.bias,
          adaptiveExposure: const AdaptiveExposureConfig(
            targetSnr: 18,
            minExposureSecs: 2,
            maxExposureSecs: 45,
            enabled: false,
          ),
        ),
      },
    );

    final service = SequenceFileService();
    await service.exportSequence(sequence);
    final imported = await service.importSequence();

    expect(imported, isNotNull);
    expect(imported!.rootNodeId, 'target-1');
    expect(imported.nodes.length, 2);
    expect(imported.nodes['target-1'], isA<TargetHeaderNode>());
    expect(imported.nodes['exposure-1'], isA<ExposureNode>());
    final target = imported.nodes['target-1'] as TargetHeaderNode;
    expect(target.mosaicPanel?.mosaicName, 'M31 detail');
    expect(target.integrationBudget?.totalSecs, 3600);
    expect(target.startWhen, const TargetTrigger.altitudeAbove(35));
    expect(target.endWhen, const TargetTrigger.timeBefore(1784000000));
    expect(target.triggerPollIntervalSecs, 19);
    final exposure = imported.nodes['exposure-1'] as ExposureNode;
    expect(exposure.frameType, FrameType.bias);
    expect(exposure.adaptiveExposure?.targetSnr, 18);
    expect(exposure.adaptiveExposure?.minExposureSecs, 2);
    expect(exposure.adaptiveExposure?.maxExposureSecs, 45);
    expect(exposure.adaptiveExposure?.enabled, isFalse);
    expect(
      imported.nodes['exposure-1']?.comment,
      'Use the low-read-noise preset for this block.',
    );
  });

  test('dither pattern + grid size survive export/import round trip', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'sequence_file_service_dither_',
    );
    addTearDown(() async => tempDir.delete(recursive: true));

    final filePath = path.join(tempDir.path, 'dither.skeq.json');
    final originalPlatform = FileSelectorPlatform.instance;
    FileSelectorPlatform.instance = TestFileSelectorPlatform(
      openPath: filePath,
      savePath: filePath,
    );
    addTearDown(() => FileSelectorPlatform.instance = originalPlatform);

    final sequence = Sequence.create(
      id: 'seq-dither',
      name: 'Dither pattern roundtrip',
      rootNodeId: 'target-1',
      nodes: {
        'target-1': TargetHeaderNode(
          id: 'target-1',
          targetName: 'M81',
          raHours: 9.926,
          decDegrees: 69.065,
          childIds: const ['dither-1'],
        ),
        'dither-1': DitherNode(
          id: 'dither-1',
          parentId: 'target-1',
          pixels: 7.0,
          pattern: DitherPattern.grid,
          gridSize: 4,
        ),
      },
    );

    final service = SequenceFileService();
    await service.exportSequence(sequence);
    final imported = await service.importSequence();

    expect(imported, isNotNull);
    final ditherNode = imported!.nodes['dither-1'];
    expect(ditherNode, isA<DitherNode>());
    final dither = ditherNode as DitherNode;
    expect(dither.pattern, DitherPattern.grid);
    expect(dither.gridSize, 4);
    expect(dither.pixels, 7.0);
  });

  test(
    'sequence import fails fast when active profile is missing filters',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'sequence_file_service_validation_',
      );
      addTearDown(() async => tempDir.delete(recursive: true));

      final filePath = path.join(
        tempDir.path,
        'sequence_invalid_filter.skeq.json',
      );
      final originalPlatform = FileSelectorPlatform.instance;

      FileSelectorPlatform.instance = TestFileSelectorPlatform(
        openPath: filePath,
        savePath: filePath,
      );
      addTearDown(() => FileSelectorPlatform.instance = originalPlatform);

      const sequenceJson = '''
{
  "name": "Filter Test",
  "rootNodeId": "target-1",
  "nodes": {
    "target-1": {
      "id": "target-1",
      "nodeType": "targetHeader",
      "targetName": "M31",
      "raHours": 0.712,
      "decDegrees": 41.269,
      "childIds": ["filter-1"],
      "isEnabled": true
    },
    "filter-1": {
      "id": "filter-1",
      "nodeType": "filterChange",
      "filterName": "Ha",
      "parentId": "target-1",
      "childIds": [],
      "isEnabled": true
    }
  }
}
''';
      await File(filePath).writeAsString(sequenceJson);

      final container = ProviderContainer(
        overrides: [
          activeEquipmentProfileProvider.overrideWithValue(
            const EquipmentProfileModel(
              id: 1,
              name: 'Widefield',
              filterNames: ['L', 'R', 'G', 'B'],
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      final service = container.read(sequenceFileServiceProvider);

      await expectLater(
        service.importSequence(),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('filters not present'),
          ),
        ),
      );
    },
  );

  test(
    'exportSequence refuses to write a sequence with validation errors',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'sequence_file_service_export_validation_',
      );
      addTearDown(() async => tempDir.delete(recursive: true));

      final filePath = path.join(tempDir.path, 'invalid.skeq.json');
      final originalPlatform = FileSelectorPlatform.instance;
      FileSelectorPlatform.instance = TestFileSelectorPlatform(
        openPath: filePath,
        savePath: filePath,
      );
      addTearDown(() => FileSelectorPlatform.instance = originalPlatform);

      // An empty sequence is the simplest pre-built validation failure
      // (EmptySequenceRule fires).
      final bad = Sequence.create(id: 'bad', name: 'Empty');

      final service = SequenceFileService();

      await expectLater(
        service.exportSequence(bad),
        throwsA(isA<SequenceValidationFailedException>()),
      );

      // No file should have been written.
      expect(
        await File(filePath).exists(),
        isFalse,
        reason: 'export must not write when validation errors block it',
      );
    },
  );

  test(
    'sequence round-trip preserves every RecoveryNode control field',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'sequence_file_service_recovery_',
      );
      addTearDown(() async => tempDir.delete(recursive: true));

      final filePath = path.join(tempDir.path, 'recovery.skeq.json');
      final originalPlatform = FileSelectorPlatform.instance;
      FileSelectorPlatform.instance = TestFileSelectorPlatform(
        openPath: filePath,
        savePath: filePath,
      );
      addTearDown(() => FileSelectorPlatform.instance = originalPlatform);

      // Build a sequence using every new RecoveryNode / trigger field
      // introduced in (focus-drift window + humidity / focus-drift
      // trigger types). The exported JSON must round-trip back through
      // _jsonToNode without silently resetting to default values.
      final exposure = ExposureNode(id: 'exp-1', durationSecs: 60, count: 5);
      final recovery = RecoveryNode(
        id: 'recov-1',
        name: 'AF on drift',
        triggerType: TriggerType.focusDrift,
        recoveryAction: RecoveryActionType.autofocus,
        maxRetries: 4,
        triggerThreshold: 1.25,
        hfrThresholdPercent: 18.5,
        hfrConsecutiveFrames: 4,
        triggerEveryNFrames: 7,
        focusDriftWindowSize: 12,
        focusDriftMinIncreasingCount: 6,
        focusDriftMinTotalIncrease: 0.75,
        guidingFailedDurationSecs: 44,
        cloudMinutesBefore: 14,
        cloudCoverageThresholdPercent: 61,
        cloudOpeningMinDurationSecs: 420,
        cloudCoverMaxPercent: 73,
        cloudCoverDurationSecs: 88,
        transparencyBelowThreshold: 0.62,
        transparencyDurationSecs: 95,
        childIds: const ['exp-1'],
      );
      final root = InstructionSetNode(id: 'root', childIds: const ['recov-1']);

      final sequence = Sequence.create(
        id: 'seq-recov',
        name: 'Round trip recovery',
        rootNodeId: 'root',
        nodes: {
          'root': root,
          'recov-1': recovery.copyWith(parentId: 'root'),
          'exp-1': exposure.copyWith(parentId: 'recov-1'),
        },
      );

      final service = SequenceFileService();
      await service.exportSequence(sequence);
      final imported = await service.importSequence();
      expect(imported, isNotNull);

      final reloaded = imported!.nodes['recov-1'] as RecoveryNode;
      expect(
        reloaded.triggerType,
        TriggerType.focusDrift,
        reason: 'focusDrift trigger type must round-trip',
      );
      expect(reloaded.recoveryAction, RecoveryActionType.autofocus);
      expect(reloaded.maxRetries, 4);
      expect(reloaded.triggerThreshold, 1.25);
      expect(reloaded.hfrThresholdPercent, 18.5);
      expect(reloaded.hfrConsecutiveFrames, 4);
      expect(reloaded.triggerEveryNFrames, 7);
      // The focus-drift window fields — these were the round-trip
      // gap the audit caught.
      expect(reloaded.focusDriftWindowSize, 12);
      expect(reloaded.focusDriftMinIncreasingCount, 6);
      expect(reloaded.focusDriftMinTotalIncrease, 0.75);
      expect(reloaded.guidingFailedDurationSecs, 44);
      expect(reloaded.cloudMinutesBefore, 14);
      expect(reloaded.cloudCoverageThresholdPercent, 61);
      expect(reloaded.cloudOpeningMinDurationSecs, 420);
      expect(reloaded.cloudCoverMaxPercent, 73);
      expect(reloaded.cloudCoverDurationSecs, 88);
      expect(reloaded.transparencyBelowThreshold, 0.62);
      expect(reloaded.transparencyDurationSecs, 95);
    },
  );

  test(
    'sequence round-trip preserves humidityThreshold trigger type',
    () async {
      // Confirms TriggerType.humidityThreshold (added in ) survives
      // export → import via the same _parseTriggerType path used for
      // pre-existing trigger types.
      final tempDir = await Directory.systemTemp.createTemp(
        'sequence_file_service_humidity_',
      );
      addTearDown(() async => tempDir.delete(recursive: true));

      final filePath = path.join(tempDir.path, 'humidity.skeq.json');
      final originalPlatform = FileSelectorPlatform.instance;
      FileSelectorPlatform.instance = TestFileSelectorPlatform(
        openPath: filePath,
        savePath: filePath,
      );
      addTearDown(() => FileSelectorPlatform.instance = originalPlatform);

      final exposure = ExposureNode(id: 'exp-1', durationSecs: 60, count: 3);
      final recovery = RecoveryNode(
        id: 'recov-h',
        triggerType: TriggerType.humidityThreshold,
        triggerThreshold: 85,
        recoveryAction: RecoveryActionType.pause,
        childIds: const ['exp-1'],
      );
      final root = InstructionSetNode(id: 'root', childIds: const ['recov-h']);
      final sequence = Sequence.create(
        id: 'seq-humid',
        name: 'Humidity trigger round trip',
        rootNodeId: 'root',
        nodes: {
          'root': root,
          'recov-h': recovery.copyWith(parentId: 'root'),
          'exp-1': exposure.copyWith(parentId: 'recov-h'),
        },
      );

      final service = SequenceFileService();
      await service.exportSequence(sequence);
      final imported = await service.importSequence();
      final reloaded = imported!.nodes['recov-h'] as RecoveryNode;
      expect(reloaded.triggerType, TriggerType.humidityThreshold);
      expect(reloaded.triggerThreshold, 85);
      expect(reloaded.recoveryAction, RecoveryActionType.pause);
    },
  );

  test(
    'sequence round-trip preserves TargetScheduler adaptive swap fields',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'sequence_file_service_sched_',
      );
      addTearDown(() async => tempDir.delete(recursive: true));

      final filePath = path.join(tempDir.path, 'scheduler.skeq.json');
      final originalPlatform = FileSelectorPlatform.instance;
      FileSelectorPlatform.instance = TestFileSelectorPlatform(
        openPath: filePath,
        savePath: filePath,
      );
      addTearDown(() => FileSelectorPlatform.instance = originalPlatform);

      final root = InstructionSetNode(
        id: 'root',
        childIds: const ['scheduler'],
      );
      final scheduler = TargetSchedulerNode(
        id: 'scheduler',
        parentId: 'root',
        childIds: const ['target'],
        swapOnConditionsBelow: 46,
        swapHysteresisSecs: 225,
        brightnessTierPreferences: const BrightnessTierPreferences(
          faintMinScore: 76,
          mediumMinScore: 54,
          brightMinScore: 31,
        ),
        maxConditionsScoreAgeSecs: 480,
      );
      final target = TargetHeaderNode(
        id: 'target',
        parentId: 'scheduler',
        targetName: 'M51',
        raHours: 13.5,
        decDegrees: 47.2,
        childIds: const ['smart'],
      );
      final smart = SmartExposureNode(
        id: 'smart',
        parentId: 'target',
        loopUntilStopped: true,
        integrationBudgetSecs: 3600,
        plans: const [FilterPlan(filterName: 'L', count: 2, durationSecs: 120)],
      );
      final sequence = Sequence.create(
        id: 'seq-scheduler',
        name: 'Scheduler',
        rootNodeId: root.id,
        nodes: {
          root.id: root,
          scheduler.id: scheduler,
          target.id: target,
          smart.id: smart,
        },
      );

      final service = SequenceFileService();
      await service.exportSequence(sequence, forceExport: true);
      final imported = await service.importSequence();

      final restored = imported!.nodes['scheduler'] as TargetSchedulerNode;
      expect(restored.swapOnConditionsBelow, 46);
      expect(restored.swapHysteresisSecs, 225);
      expect(restored.maxConditionsScoreAgeSecs, 480);
      expect(restored.brightnessTierPreferences.faintMinScore, 76);
      expect(restored.brightnessTierPreferences.mediumMinScore, 54);
      expect(restored.brightnessTierPreferences.brightMinScore, 31);

      // loop_until_stopped must round-trip through export/import.
      final restoredSmart = imported.nodes['smart'] as SmartExposureNode;
      expect(restoredSmart.loopUntilStopped, isTrue);
      expect(restoredSmart.integrationBudgetSecs, 3600);
    },
  );

  test('cover / calibrator / science-photometry nodes survive export/import '
      '(P0 data-loss regression)', () async {
    // Five node types the encoder serialises need matching decoder cases, and
    // the cover/calibrator config has to survive the encode: without both, a
    // saved sequence containing one is permanently unloadable and the whole
    // sequence throws on reload.
    final tempDir = await Directory.systemTemp.createTemp(
      'sequence_file_service_cover_science_',
    );
    addTearDown(() async => tempDir.delete(recursive: true));

    final filePath = path.join(tempDir.path, 'cover_science.skeq.json');
    final originalPlatform = FileSelectorPlatform.instance;
    FileSelectorPlatform.instance = TestFileSelectorPlatform(
      openPath: filePath,
      savePath: filePath,
    );
    addTearDown(() => FileSelectorPlatform.instance = originalPlatform);

    final root = InstructionSetNode(
      id: 'root',
      childIds: const [
        'open-cover',
        'calib-on',
        'science',
        'calib-off',
        'close-cover',
      ],
    );
    final openCover = OpenCoverNode(
      id: 'open-cover',
      parentId: 'root',
      timeoutSecs: 90,
    );
    final calibOn = CalibratorOnNode(
      id: 'calib-on',
      parentId: 'root',
      brightness: 200,
      timeoutSecs: 45,
    );
    final science = SciencePhotometryNode(
      id: 'science',
      parentId: 'root',
      targetDesignation: 'V0376 Per',
      referenceStars: const ['ref-a', 'ref-b'],
      maxCadenceGapSecs: 1.5,
      filter: 'V',
      exposureSecs: 30,
      count: 120,
      reduceLive: false,
      applyDifferential: false,
      quality: const PhotometryQualityGates(
        minSnr: 75,
        maxFwhmArcsec: 3.5,
        requireAllRefsVisible: false,
        maxAirmass: 2.0,
      ),
      gain: 100,
      offset: 20,
      binning: BinningMode.two,
    );
    final calibOff = CalibratorOffNode(
      id: 'calib-off',
      parentId: 'root',
      timeoutSecs: 25,
    );
    final closeCover = CloseCoverNode(
      id: 'close-cover',
      parentId: 'root',
      timeoutSecs: 75,
    );

    final sequence = Sequence.create(
      id: 'seq-cover-science',
      name: 'Cover + science round trip',
      rootNodeId: 'root',
      nodes: {
        'root': root,
        'open-cover': openCover,
        'calib-on': calibOn,
        'science': science,
        'calib-off': calibOff,
        'close-cover': closeCover,
      },
    );

    final service = SequenceFileService();
    await service.exportSequence(sequence, forceExport: true);
    final imported = await service.importSequence();

    expect(imported, isNotNull, reason: 'sequence must reload, not throw');
    expect(imported!.nodes.length, 6);

    final reOpen = imported.nodes['open-cover'];
    expect(reOpen, isA<OpenCoverNode>());
    expect((reOpen as OpenCoverNode).timeoutSecs, 90);

    final reCalibOn = imported.nodes['calib-on'];
    expect(reCalibOn, isA<CalibratorOnNode>());
    expect((reCalibOn as CalibratorOnNode).brightness, 200);
    expect(reCalibOn.timeoutSecs, 45);

    final reCalibOff = imported.nodes['calib-off'];
    expect(reCalibOff, isA<CalibratorOffNode>());
    expect((reCalibOff as CalibratorOffNode).timeoutSecs, 25);

    final reClose = imported.nodes['close-cover'];
    expect(reClose, isA<CloseCoverNode>());
    expect((reClose as CloseCoverNode).timeoutSecs, 75);

    final reSci = imported.nodes['science'];
    expect(reSci, isA<SciencePhotometryNode>());
    final sci = reSci as SciencePhotometryNode;
    expect(sci.targetDesignation, 'V0376 Per');
    expect(sci.referenceStars, ['ref-a', 'ref-b']);
    expect(sci.maxCadenceGapSecs, 1.5);
    expect(sci.filter, 'V');
    expect(sci.exposureSecs, 30);
    expect(sci.count, 120);
    expect(sci.reduceLive, isFalse);
    expect(sci.applyDifferential, isFalse);
    expect(sci.gain, 100);
    expect(sci.offset, 20);
    expect(sci.binning, BinningMode.two);
    expect(sci.quality.minSnr, 75);
    expect(sci.quality.maxFwhmArcsec, 3.5);
    expect(sci.quality.requireAllRefsVisible, isFalse);
    expect(sci.quality.maxAirmass, 2.0);
  });

  test(
    'exportSequence honours forceExport flag and writes even with errors',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'sequence_file_service_export_force_',
      );
      addTearDown(() async => tempDir.delete(recursive: true));

      final filePath = path.join(tempDir.path, 'forced.skeq.json');
      final originalPlatform = FileSelectorPlatform.instance;
      FileSelectorPlatform.instance = TestFileSelectorPlatform(
        openPath: filePath,
        savePath: filePath,
      );
      addTearDown(() => FileSelectorPlatform.instance = originalPlatform);

      final bad = Sequence.create(id: 'bad', name: 'Empty');
      final service = SequenceFileService();

      await service.exportSequence(bad, forceExport: true);
      expect(
        await File(filePath).exists(),
        isTrue,
        reason: 'forceExport=true should bypass the validation gate',
      );
    },
  );
}
