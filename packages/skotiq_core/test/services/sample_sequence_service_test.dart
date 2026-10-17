import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// Import the focused modules directly rather than the full skotiq_core
// barrel; the broader barrel pulls in providers that are unrelated to the
// sample-sequence library and can mask the real failures we're checking for.
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/models/imaging/imaging_models.dart'
    show FrameType;
import 'package:skotiq_core/src/services/sample_sequence_service.dart';
import 'package:path/path.dart' as p;

/// Override [rootBundle] for tests so the sample-sequence JSONs can be loaded
/// from the on-disk asset directory without booting a full Flutter app.
///
/// The bundled assets live at `packages/skotiq_core/assets/sample_sequences/`
/// in source form. At test time `ServicesBinding.instance.defaultBinaryMessenger`
/// is wired up by `TestWidgetsFlutterBinding`, but the real asset bundle is
/// not populated — we therefore intercept the asset-loading platform channel
/// and serve the files straight from disk.
void _installAssetHandlerFromDisk(String corePackageRoot) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMessageHandler('flutter/assets', (ByteData? message) async {
        if (message == null) return null;
        final key = utf8.decode(message.buffer.asUint8List());

        // Asset keys for package dependencies look like
        // `packages/skotiq_core/assets/sample_sequences/<file>.json`.
        const prefix = 'packages/skotiq_core/';
        if (!key.startsWith(prefix)) return null;
        final relative = key.substring(prefix.length);
        final filePath = p.join(corePackageRoot, relative);
        final file = File(filePath);
        if (!await file.exists()) return null;
        final bytes = await file.readAsBytes();
        return ByteData.view(Uint8List.fromList(bytes).buffer);
      });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The test working directory is the package root
  // (packages/skotiq_core). Resolve it once for the asset handler.
  final corePackageRoot = Directory.current.absolute.path;

  setUpAll(() {
    _installAssetHandlerFromDisk(corePackageRoot);
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
  });

  group('SampleSequenceService', () {
    test('loads all five bundled sample sequences', () async {
      final service = SampleSequenceService();
      final samples = await service.load();

      expect(samples, hasLength(5));
      final ids = samples.map((s) => s.id).toSet();
      expect(
        ids,
        equals({
          'dslr_m31_lrgb',
          'lunar_terminator',
          'mono_lrgb_m51',
          'planetary_jupiter',
          'narrowband_ngc7000_sho',
        }),
      );

      // Every sample must have a non-empty description that is at least one
      // full sentence — the audit explicitly requires 2-3 sentence beginner
      // guidance so we keep a minimum-length guard.
      for (final sample in samples) {
        expect(sample.displayName, isNotEmpty);
        expect(
          sample.description.length,
          greaterThan(60),
          reason: '${sample.id} description must explain the target',
        );
        expect(sample.template.nodes, isNotEmpty);
        expect(sample.template.rootNodeId, isNotNull);
        expect(
          sample.template.nodes.containsKey(sample.template.rootNodeId),
          isTrue,
          reason: '${sample.id} rootNodeId must reference a real node',
        );
      }
    });

    test('parses M31 DSLR sample with calibration frames', () async {
      final service = SampleSequenceService();
      final samples = await service.load();
      final m31 = samples.firstWhere((s) => s.id == 'dslr_m31_lrgb');

      // Verify the target header coordinates are real Andromeda values.
      final targets = m31.template.nodes.values
          .whereType<TargetHeaderNode>()
          .toList();
      expect(targets, hasLength(1));
      expect(targets.first.raHours, closeTo(0.71, 0.05));
      expect(targets.first.decDegrees, closeTo(41.27, 0.05));

      // Confirm light + flat + bias exposure groups are present.
      final exposures = m31.template.nodes.values
          .whereType<ExposureNode>()
          .toList();
      final lights = exposures
          .where((e) => e.frameType == FrameType.light)
          .toList();
      final flats = exposures
          .where((e) => e.frameType == FrameType.flat)
          .toList();
      final biases = exposures
          .where((e) => e.frameType == FrameType.bias)
          .toList();

      expect(lights, hasLength(1));
      expect(lights.first.count, 30);
      expect(lights.first.durationSecs, 120.0);
      expect(flats, hasLength(1));
      expect(flats.first.count, 20);
      expect(biases, hasLength(1));
      expect(biases.first.count, 30);
    });

    test('parses Mono LRGB M51 sample with RGB filters and dither', () async {
      final service = SampleSequenceService();
      final samples = await service.load();
      final m51 = samples.firstWhere((s) => s.id == 'mono_lrgb_m51');

      final exposures = m51.template.nodes.values
          .whereType<ExposureNode>()
          .toList();
      final filtersUsed = exposures
          .where((e) => e.filter != null)
          .map((e) => e.filter!)
          .toSet();
      expect(filtersUsed, containsAll({'Lum', 'R', 'G', 'B'}));

      // Luminance is 40 x 120s; RGB are 20 x 60s each.
      final lum = exposures.firstWhere((e) => e.filter == 'Lum');
      expect(lum.count, 40);
      expect(lum.durationSecs, 120.0);
      expect(lum.ditherEvery, 5);

      for (final filter in ['R', 'G', 'B']) {
        final exp = exposures.firstWhere((e) => e.filter == filter);
        expect(exp.count, 20);
        expect(exp.durationSecs, 60.0);
      }

      // Recovery node with HFR trigger should be wired into the lum loop.
      final recoveries = m51.template.nodes.values
          .whereType<RecoveryNode>()
          .toList();
      expect(recoveries, isNotEmpty);
      expect(recoveries.first.triggerType, TriggerType.hfrDegraded);
    });

    test('parses NGC 7000 SHO narrowband with meridian flip', () async {
      final service = SampleSequenceService();
      final samples = await service.load();
      final ngc = samples.firstWhere((s) => s.id == 'narrowband_ngc7000_sho');

      final exposures = ngc.template.nodes.values
          .whereType<ExposureNode>()
          .toList();
      final filtersUsed = exposures
          .where((e) => e.filter != null)
          .map((e) => e.filter!)
          .toSet();
      expect(filtersUsed, containsAll({'SII', 'Ha', 'OIII'}));

      for (final filter in ['SII', 'Ha', 'OIII']) {
        final exp = exposures.firstWhere((e) => e.filter == filter);
        expect(exp.count, 60, reason: '$filter must be 60 frames');
        expect(exp.durationSecs, 300.0, reason: '$filter must be 300s');
      }

      // Meridian flip watchdog must be present.
      final flips = ngc.template.nodes.values
          .whereType<MeridianFlipNode>()
          .toList();
      expect(flips, hasLength(1));
      expect(flips.first.autoCenter, isTrue);

      // Each filter block should have its own autofocus (AF on filter change).
      final focusNodes = ngc.template.nodes.values
          .whereType<AutofocusNode>()
          .toList();
      expect(focusNodes.length, greaterThanOrEqualTo(3));
    });

    test('parses lunar terminator sample with no guiding/dither', () async {
      final service = SampleSequenceService();
      final samples = await service.load();
      final lunar = samples.firstWhere((s) => s.id == 'lunar_terminator');

      final exposures = lunar.template.nodes.values
          .whereType<ExposureNode>()
          .toList();
      expect(exposures, hasLength(1));
      expect(exposures.first.count, 200);
      expect(exposures.first.durationSecs, 0.005);
      // No dithering for lunar work.
      expect(exposures.first.ditherEvery, isNull);

      // No StartGuiding nodes should be present.
      expect(
        lunar.template.nodes.values.whereType<StartGuidingNode>(),
        isEmpty,
      );
    });

    test('parses planetary Jupiter sample with high frame count', () async {
      final service = SampleSequenceService();
      final samples = await service.load();
      final jup = samples.firstWhere((s) => s.id == 'planetary_jupiter');

      final exposures = jup.template.nodes.values
          .whereType<ExposureNode>()
          .toList();
      expect(exposures, hasLength(1));
      expect(exposures.first.count, 1000);
      expect(exposures.first.durationSecs, 0.005);

      // No calibration frame types.
      expect(exposures.where((e) => e.frameType != FrameType.light), isEmpty);
    });

    test('cloneForUse regenerates ids and preserves tree structure', () async {
      final service = SampleSequenceService();
      final samples = await service.load();
      final original = samples.first;

      final cloneA = service.cloneForUse(original);
      final cloneB = service.cloneForUse(original);

      // Clone IDs differ from the source template and from each other.
      expect(cloneA.id, isNot(equals(original.template.id)));
      expect(cloneB.id, isNot(equals(original.template.id)));
      expect(cloneA.id, isNot(equals(cloneB.id)));

      // Node ID sets must be fully disjoint between clones.
      final aNodes = cloneA.nodes.keys.toSet();
      final bNodes = cloneB.nodes.keys.toSet();
      expect(aNodes.intersection(bNodes), isEmpty);

      // Node count is preserved across cloning.
      expect(cloneA.nodes.length, original.template.nodes.length);

      // Parent/child wiring stays internally consistent.
      for (final entry in cloneA.nodes.entries) {
        final node = entry.value;
        if (node.parentId != null) {
          expect(
            cloneA.nodes.containsKey(node.parentId),
            isTrue,
            reason: 'parent ${node.parentId} of ${node.id} missing',
          );
        }
        for (final childId in node.childIds) {
          expect(
            cloneA.nodes.containsKey(childId),
            isTrue,
            reason: 'child $childId of ${node.id} missing',
          );
        }
      }

      // Root references the cloned root, not the original.
      expect(cloneA.rootNodeId, isNotNull);
      expect(cloneA.nodes.containsKey(cloneA.rootNodeId), isTrue);
      expect(cloneA.rootNodeId, isNot(equals(original.template.rootNodeId)));

      // Cloned sequence is no longer flagged as a template.
      expect(cloneA.isTemplate, isFalse);
    });

    test('cloneForUse honours nameOverride', () async {
      final service = SampleSequenceService();
      final samples = await service.load();
      final clone = service.cloneForUse(samples.first, nameOverride: 'My Run');
      expect(clone.name, 'My Run');
    });
  });
}
