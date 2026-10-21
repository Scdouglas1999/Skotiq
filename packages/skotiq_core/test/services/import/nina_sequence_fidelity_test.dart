import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/import/canonical_sequence_node.dart'
    show SourceFormat;
import 'package:skotiq_core/src/models/import/import_result.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/services/import/sequence_importer.dart';

/// Living-documentation fidelity suite for NINA (and one SGP) imports.
///
/// Each test PINS a specific aspect of import fidelity. The test name
/// describes what the test guarantees ("lossless", "lossy", "dropped") so
/// reviewers can audit the fidelity status without running the suite. When
/// a node type is improved (e.g. a previously unsupported NINA construct
/// gains a Skotiq equivalent), the corresponding test here MUST be
/// updated, which is the regression-detection mechanism.
///
/// Provenance note: fixtures under `fixtures/nina_*.json` and `fixtures/sgp_*.sgf`
/// are authored from the parser's documented contract (`docs/sequence-import-formats.md`,
/// `NinaSequenceParser._classify`, `_extractAttributes`) rather than dumped
/// verbatim from a NINA / SGP installation. They reproduce the Newtonsoft
/// `$type` discriminator wire shape and the documented field names; they
/// are NOT lifted from a private user export. If a future version of
/// NINA / SGP changes its wire format, this suite is where the regression
/// will first surface.
void main() {
  group('NINA fidelity (lossless cases)', () {
    test(
      'happy-path advanced fixture: target / slew / center / autofocus / '
      'filter / loop / exposure / dither / meridian-flip / park survive',
      () async {
        final result = await _importFixture(
          'nina_advanced.json',
          sequenceName: 'NGC 7635 run',
        );

        // Importer must produce no unsupported records for the advanced
        // happy-path fixture — if this fails, a previously-mapped NINA
        // construct has regressed to unsupported.
        expect(
          result.unsupportedNodes,
          isEmpty,
          reason: 'advanced fixture must round-trip without any unsupported',
        );

        // Validate the mapping table covers every NINA node we shipped in
        // the fixture. The mapping table is what the import-summary dialog
        // shows the user, so it's the user-visible fidelity contract.
        final mapping = {
          for (final r in result.mappingTable) r.sourceType: r.skotiqType,
        };
        expect(mapping['SequenceRootContainer'], 'InstructionSet');
        expect(mapping['DeepSkyObjectContainer'], 'TargetHeader');
        expect(mapping['SlewScopeToCoordinates'], 'SlewToTarget');
        expect(mapping['Center'], 'CenterTarget');
        expect(mapping['RunAutofocus'], 'Autofocus');
        expect(mapping['StartGuiding'], 'StartGuiding');
        expect(mapping['StopGuiding'], 'StopGuiding');
        expect(mapping['SwitchFilter'], 'ChangeFilter');
        expect(mapping['LoopContainer'], 'Loop');
        expect(mapping['TakeExposure'], 'TakeExposure');
        expect(mapping['Dither'], 'Dither');
        // A time SPAN is a duration, so it maps to Delay, not to the
        // wait-until-an-instant node. Mapping it to WaitForTime produced a Wait
        // with no time set — an error the validator rightly blocks, which made
        // any NINA sequence containing one fail to import at all.
        expect(mapping['WaitForTimeSpan'], 'Delay');
        expect(mapping['MeridianFlipTrigger'], 'MeridianFlip');
        expect(mapping['ParkScope'], 'Park');
      },
    );

    test(
      'target header: TargetName and InputCoordinates round-trip exactly',
      () async {
        final result = await _importFixture(
          'nina_advanced.json',
          sequenceName: 'fidelity',
        );
        final target = _onlyOf<TargetHeaderNode>(result);
        expect(target.targetName, 'NGC 7635 Bubble Nebula');
        // RAHours / Dec preserved bitwise from the fixture.
        expect(target.raHours, closeTo(23.34111, 1e-6));
        expect(target.decDegrees, closeTo(61.20194, 1e-6));
        expect(target.rotation, closeTo(27.5, 1e-6));
      },
    );

    test('exposure: ExposureTime / Gain / Offset / Binning / ImageType / '
        'Filter all round-trip', () async {
      final result = await _importFixture(
        'nina_advanced.json',
        sequenceName: 'fidelity',
      );
      final exposures = result.sequence.nodes.values
          .whereType<ExposureNode>()
          .toList();
      expect(exposures, hasLength(1));
      final exposure = exposures.first;
      expect(exposure.durationSecs, 300.0);
      expect(exposure.gain, 100);
      expect(exposure.offset, 30);
      expect(exposure.binning, BinningMode.one);
      expect(exposure.frameType.name, contains('light'));
      expect(exposure.filter, 'Ha');
    });

    test('loop iterations from Conditions[].LoopCondition.Iterations '
        'are surfaced as repeatCount', () async {
      final result = await _importFixture(
        'nina_advanced.json',
        sequenceName: 'fidelity',
      );
      final loops = result.sequence.nodes.values.whereType<LoopNode>().toList();
      expect(
        loops,
        hasLength(1),
        reason: 'one inner LoopContainer in the fixture',
      );
      expect(loops.first.conditionType, LoopConditionType.count);
      expect(
        loops.first.repeatCount,
        30,
        reason: 'LoopContainer.Conditions[0].Iterations == 30',
      );
    });

    test('meridian-flip Trigger lifts into the child list with '
        'MinutesAfterMeridian preserved', () async {
      final result = await _importFixture(
        'nina_advanced.json',
        sequenceName: 'fidelity',
      );
      final flips = result.sequence.nodes.values
          .whereType<MeridianFlipNode>()
          .toList();
      expect(flips, hasLength(1));
      expect(flips.first.minutesPastMeridian, 7.0);
      expect(
        flips.first.useGlobalDefaults,
        isFalse,
        reason: 'imports honor per-node values; mapper sets this to false',
      );
    });

    test(
      'PauseTimeBeforeMeridian is never read as the flip threshold',
      () async {
        // N.I.N.A. stops tracking PauseTimeBeforeMeridian minutes BEFORE the
        // meridian; reading it as "minutes past" moved the flip to the wrong
        // side of the meridian for any trigger that set it.
        final content =
            (await File(
              'test/services/import/fixtures/nina_advanced.json',
            ).readAsString()).replaceFirst(
              '"MinutesAfterMeridian": 7.0',
              '"PauseTimeBeforeMeridian": 20.0',
            );
        final result = SequenceImporter().importFromString(
          content,
          forceUnsupported: false,
          sequenceName: 'fidelity',
        );
        final flip = _onlyOf<MeridianFlipNode>(result);
        expect(flip.minutesPastMeridian, 5.0);
      },
    );

    test('parent-target loop count from Conditions[].Iterations folds onto '
        'targetHeader siblings (basic fixture, 10 iterations)', () async {
      // The legacy nina_basic.json fixture places a LoopCondition with
      // Iterations: 10 on the DeepSkyObjectContainer itself. The parser
      // folds it into the targetHeader's attributes but the mapper does
      // NOT currently surface that as a Skotiq loop wrapping the
      // target — this is lossy. The test pins the gap.
      final result = await _importFixture(
        'nina_basic.json',
        sequenceName: 'M31',
      );
      final loops = result.sequence.nodes.values
          .whereType<LoopNode>()
          .map((l) => l.repeatCount)
          .toList();
      // Only the inner LoopContainer (20 iters) survives. The outer "run
      // this target 10x" intent is dropped.
      expect(loops, contains(20));
      expect(
        loops,
        isNot(contains(10)),
        reason:
            'KNOWN LOSSY: DeepSkyObjectContainer-level LoopCondition is '
            'parsed but the mapper does not wrap the targetHeader in a '
            'LoopNode (audit follow-up).',
      );
    });
  });

  group('NINA fidelity (lossy / dropped cases)', () {
    test(
      'plugin script node, SafetyMonitor trigger, and SmartExposure '
      'composite all surface as unsupportedNodes (strict mode aborts)',
      () async {
        final content = await File(
          'test/services/import/fixtures/nina_unsupported_edge.json',
        ).readAsString();
        expect(
          () => SequenceImporter().importFromString(
            content,
            forceUnsupported: false,
            sequenceName: 'edge strict',
          ),
          throwsA(
            isA<UnsupportedNodeError>().having(
              (e) => e.unsupported.map((u) => u.sourceType).toSet(),
              'unsupported sourceTypes',
              containsAll([
                'CustomScriptNode',
                'SafetyMonitorTrigger',
                'SmartExposure',
                // SwitchFilter with no filter name becomes a late-discovered
                // unsupported from the mapper.
                'SwitchFilter',
              ]),
            ),
          ),
        );
      },
    );

    test('force-import: ALL unsupported entries are surfaced individually '
        '(not just the first one)', () async {
      final result = await _importFixture(
        'nina_unsupported_edge.json',
        forceUnsupported: true,
        sequenceName: 'edge forced',
      );

      // The user must see every unsupported node they have to recreate by
      // hand, not "and 3 more".
      final unsupportedTypes = result.unsupportedNodes
          .map((u) => u.sourceType)
          .toSet();
      expect(
        unsupportedTypes,
        containsAll([
          'CustomScriptNode',
          'SafetyMonitorTrigger',
          'SmartExposure',
          'SwitchFilter',
        ]),
      );
      // And each unsupported node also lands in droppedNodes with
      // DropReason.unsupported so the summary dialog can group them.
      final unsupportedDrops = result.droppedNodes
          .where((d) => d.reason == DropReason.unsupported)
          .map((d) => d.sourceType)
          .toSet();
      expect(
        unsupportedDrops,
        containsAll([
          'CustomScriptNode',
          'SafetyMonitorTrigger',
          'SmartExposure',
          'SwitchFilter',
        ]),
      );
    });

    test('Annotation node is dropped silently with DropReason.decorative '
        '(never abort the import)', () async {
      final result = await _importFixture(
        'nina_unsupported_edge.json',
        forceUnsupported: true,
        sequenceName: 'edge',
      );
      final decorative = result.droppedNodes
          .where((d) => d.reason == DropReason.decorative)
          .toList();
      expect(decorative, hasLength(1));
      expect(decorative.single.sourceType, 'Annotation');
      // Annotations don't appear in unsupportedNodes — they're always-safe
      // to drop and the strict-mode gate should let them through.
      expect(
        result.unsupportedNodes.where((u) => u.sourceType == 'Annotation'),
        isEmpty,
      );
    });

    test('Enabled: false leaf is dropped with DropReason.disabled', () async {
      final result = await _importFixture(
        'nina_unsupported_edge.json',
        forceUnsupported: true,
        sequenceName: 'edge',
      );
      final disabled = result.droppedNodes
          .where((d) => d.reason == DropReason.disabled)
          .toList();
      expect(disabled, hasLength(1));
      // The disabled exposure shouldn't end up in the assembled sequence's
      // ExposureNode list.
      final ondisk = result.sequence.nodes.values
          .whereType<ExposureNode>()
          .toList();
      // Two TakeExposure entries in fixture (one enabled, one disabled);
      // only one survives.
      expect(ondisk, hasLength(1));
      expect(ondisk.first.durationSecs, 180.0);
    });

    test('NINA script triggers, plugin nodes, and dome plugins are NOT '
        'imported (no Skotiq equivalent — audit follow-up)', () async {
      // Pin the documented unsupported set. If a future Skotiq version
      // adds support for any of these, this test must be updated AND the
      // release notes' fidelity claim updated alongside.
      const unsupportedSet = {
        'CustomScriptNode', // arbitrary plugin script
        'SafetyMonitorTrigger', // safety-monitor watchdog
        'SmartExposure', // composite exposure node
      };
      final result = await _importFixture(
        'nina_unsupported_edge.json',
        forceUnsupported: true,
        sequenceName: 'edge',
      );
      final actuallyUnsupported = result.unsupportedNodes
          .map((u) => u.sourceType)
          .toSet();
      expect(
        actuallyUnsupported.containsAll(unsupportedSet),
        isTrue,
        reason:
            'fixture intentionally contains every documented-unsupported '
            'NINA construct; the importer must surface them all.',
      );
    });

    test('SwitchFilter with no resolvable filter name is reported '
        'unsupported (Skotiq requires a non-empty filterName)', () async {
      final result = await _importFixture(
        'nina_unsupported_edge.json',
        forceUnsupported: true,
        sequenceName: 'edge',
      );
      // The fixture's broken SwitchFilter (empty Filter payload) must
      // appear in unsupportedNodes with a useful reason string.
      final brokenFilter = result.unsupportedNodes.firstWhere(
        (u) => u.sourceType == 'SwitchFilter',
        orElse: () => throw StateError(
          'expected SwitchFilter in unsupportedNodes; got '
          '${result.unsupportedNodes.map((u) => u.sourceType).toList()}',
        ),
      );
      expect(
        brokenFilter.reason,
        contains('Skotiq'),
        reason:
            'unsupported reason should explain WHY a recognized type was '
            'rejected so users know how to fix the source file',
      );
    });
  });

  group('NINA fidelity (complex flow control)', () {
    test('multiple DSO containers in a single SequenceRoot all survive '
        '(multi-target nights)', () async {
      final result = await _importFixture(
        'nina_complex_flow.json',
        sequenceName: 'two-target',
      );
      final targets = result.sequence.nodes.values
          .whereType<TargetHeaderNode>()
          .toList();
      expect(targets, hasLength(2));
      final names = targets.map((t) => t.targetName).toSet();
      expect(names, contains('M81 Bode Galaxy'));
      expect(names, contains('M82 Cigar Galaxy'));
    });

    test('ParallelContainer round-trips as ParallelNode', () async {
      final result = await _importFixture(
        'nina_complex_flow.json',
        forceUnsupported: true,
        sequenceName: 'two-target',
      );
      final parallels = result.sequence.nodes.values
          .whereType<ParallelNode>()
          .toList();
      expect(
        parallels,
        hasLength(1),
        reason: 'fixture has exactly one ParallelContainer under M82',
      );
    });

    test('TimeCondition on a container is parsed but NOT surfaced on the '
        'TargetHeader (KNOWN LOSSY)', () async {
      // The parser folds TimeCondition.DateTime into _loopUntilTime on the
      // DeepSkyObjectContainer's attributes. The mapper for targetHeader
      // does not currently propagate that to the Skotiq target's
      // startAfter/endBefore. Pin the lossy state.
      final result = await _importFixture(
        'nina_complex_flow.json',
        forceUnsupported: true,
        sequenceName: 'two-target',
      );
      final m81 = result.sequence.nodes.values
          .whereType<TargetHeaderNode>()
          .firstWhere((t) => t.targetName == 'M81 Bode Galaxy');
      // TargetHeader has endBefore for time constraints but mapper doesn't
      // currently populate it from a TimeCondition.
      expect(
        m81.endBefore,
        isNull,
        reason:
            'KNOWN LOSSY: NINA TimeCondition on a DSO container does not '
            'currently land on TargetHeaderNode.endBefore. Tracked as a '
            'fidelity gap; will require mapper enhancement.',
      );
    });

    test('LoopForeverCondition on a DeepSkyObjectContainer is parsed but '
        'NOT promoted to a wrapping LoopNode (KNOWN LOSSY)', () async {
      // The parser sees the LoopForeverCondition and folds _loopForever=true
      // onto the parent. But because the parent's kind is targetHeader
      // (not loop), the mapper ignores the flag.
      final result = await _importFixture(
        'nina_complex_flow.json',
        forceUnsupported: true,
        sequenceName: 'two-target',
      );
      final foreverLoops = result.sequence.nodes.values
          .whereType<LoopNode>()
          .where((l) => l.conditionType == LoopConditionType.forever)
          .toList();
      expect(
        foreverLoops,
        isEmpty,
        reason:
            'KNOWN LOSSY: LoopForeverCondition on a target container is '
            'silently lost. The user must add a forever loop manually '
            'post-import. Mapper enhancement needed.',
      );
    });

    test('inner LoopContainer with LoopCondition.Iterations DOES survive '
        '(structural correctness inside parallel branches)', () async {
      final result = await _importFixture(
        'nina_complex_flow.json',
        forceUnsupported: true,
        sequenceName: 'two-target',
      );
      final loops = result.sequence.nodes.values
          .whereType<LoopNode>()
          .where((l) => l.repeatCount == 25)
          .toList();
      expect(
        loops,
        hasLength(1),
        reason:
            'fixture has one LoopContainer with Iterations: 25 inside a '
            'ParallelContainer; structure must survive nesting',
      );
    });
  });

  group('NINA fidelity (parser sanity)', () {
    test('TakeExposure rows in the mapping table count correctly and map to '
        'TakeExposure (no silent reclassification)', () async {
      final result = await _importFixture(
        'nina_advanced.json',
        sequenceName: 'sanity',
      );
      final exposureRow = result.mappingTable.firstWhere(
        (r) => r.sourceType == 'TakeExposure',
        orElse: () => throw StateError(
          'expected a TakeExposure row in the mapping table',
        ),
      );
      expect(exposureRow.skotiqType, 'TakeExposure');
      expect(
        exposureRow.count,
        1,
        reason: 'advanced fixture has exactly one TakeExposure node',
      );
    });
  });

  group('SGP fidelity (lossless cases)', () {
    test('SGP basic two-target fixture: every event becomes a '
        'FilterChange + Exposure pair (no unsupported)', () async {
      final result = await _importFixture(
        'sgp_basic.sgf',
        sequenceName: 'sgp lossless',
      );
      expect(result.sourceFormat, SourceFormat.sgp);
      expect(
        result.unsupportedNodes,
        isEmpty,
        reason:
            'SGP has no extensibility surface — every Event must map. If '
            'this fails, a previously-supported SGP construct regressed.',
      );
      // M42 has 2 events (Lum, Red) -> 2 FilterChange + 2 Exposure.
      // NGC 2024 has 1 event (Ha) -> 1 FilterChange + 1 Exposure.
      final exposures = result.sequence.nodes.values
          .whereType<ExposureNode>()
          .toList();
      expect(exposures, hasLength(3));
      final filters = result.sequence.nodes.values
          .whereType<FilterChangeNode>()
          .toList();
      expect(filters, hasLength(3));
    });

    test('SGP Reference block (RAHours / Dec / Rotation) round-trips '
        'into TargetHeader', () async {
      final result = await _importFixture(
        'sgp_basic.sgf',
        sequenceName: 'sgp coords',
      );
      final m42 = result.sequence.nodes.values
          .whereType<TargetHeaderNode>()
          .firstWhere((t) => t.targetName == 'M42 Orion Nebula');
      expect(m42.raHours, closeTo(5.5882, 1e-4));
      expect(m42.decDegrees, closeTo(-5.391, 1e-4));
      expect(m42.rotation, closeTo(90.0, 1e-4));
    });
  });
}

/// Load a fixture and run it through the full importer. Defaults match the
/// production strict-mode behavior; tests opt into forceUnsupported when
/// the fixture intentionally contains unsupported nodes.
Future<ImportResult> _importFixture(
  String fixtureFile, {
  required String sequenceName,
  bool forceUnsupported = false,
}) async {
  final content = await File(
    'test/services/import/fixtures/$fixtureFile',
  ).readAsString();
  return SequenceImporter().importFromString(
    content,
    forceUnsupported: forceUnsupported,
    sequenceName: sequenceName,
  );
}

/// Returns the single node of type [T] in the result; fails the test if
/// there are zero or more than one.
T _onlyOf<T extends SequenceNode>(ImportResult result) {
  final all = result.sequence.nodes.values.whereType<T>().toList();
  if (all.length != 1) {
    throw StateError(
      'expected exactly one $T in import; got ${all.length}: '
      '${all.map((n) => n.name).toList()}',
    );
  }
  return all.single;
}
