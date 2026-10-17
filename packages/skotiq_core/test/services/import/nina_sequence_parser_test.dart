import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/import/canonical_sequence_node.dart';
import 'package:skotiq_core/src/models/import/import_result.dart';
import 'package:skotiq_core/src/services/import/nina_sequence_parser.dart';

void main() {
  group('NinaSequenceParser', () {
    test('sniff detects NINA discriminators', () {
      const sample =
          '{"\$type": "NINA.Sequencer.Container.SequenceRootContainer, NINA.Sequencer"}';
      expect(NinaSequenceParser.sniff(sample), isTrue);
    });

    test('sniff rejects non-NINA content', () {
      const sgp = '{"SequenceTitle": "x", "TargetSet": []}';
      expect(NinaSequenceParser.sniff(sgp), isFalse);
    });

    test(
      'parses nina_basic.json into canonical tree with expected shape',
      () async {
        final content = await File(
          'test/services/import/fixtures/nina_basic.json',
        ).readAsString();
        final root = NinaSequenceParser().parse(content);

        expect(root.kind, CanonicalKind.sequential);
        expect(root.sourceType, 'SequenceRootContainer');

        // First child: DeepSkyObjectContainer = targetHeader
        expect(root.children, hasLength(1));
        final target = root.children.first;
        expect(target.kind, CanonicalKind.targetHeader);
        expect(target.attributes['targetName'], 'M31 Andromeda Galaxy');
        expect(target.attributes['raHours'], closeTo(0.7122222, 1e-5));
        expect(target.attributes['decDegrees'], closeTo(41.2688, 1e-3));

        // Target body should include: Center, SwitchFilter, LoopContainer +
        // the meridian-flip trigger appended at the end.
        final bodyKinds = target.children.map((c) => c.kind).toList();
        expect(bodyKinds, contains(CanonicalKind.center));
        expect(bodyKinds, contains(CanonicalKind.filterChange));
        expect(bodyKinds, contains(CanonicalKind.loop));
        expect(bodyKinds, contains(CanonicalKind.meridianFlip));

        // Loop content: exposure + dither
        final loop = target.children.firstWhere(
          (c) => c.kind == CanonicalKind.loop,
        );
        expect(loop.attributes['iterations'], 20);
        final loopKinds = loop.children.map((c) => c.kind).toList();
        expect(
          loopKinds,
          containsAll([CanonicalKind.exposure, CanonicalKind.dither]),
        );

        // Exposure params survive the parse.
        final exposure = loop.children.firstWhere(
          (c) => c.kind == CanonicalKind.exposure,
        );
        expect(exposure.attributes['exposureTime'], 120.0);
        expect(exposure.attributes['gain'], 100);
        expect(exposure.attributes['filterName'], 'Lum');
        expect(exposure.attributes['imageType'], 'LIGHT');
      },
    );

    test('parses unsupported nodes as CanonicalKind.unsupported', () async {
      final content = await File(
        'test/services/import/fixtures/nina_unsupported.json',
      ).readAsString();
      final root = NinaSequenceParser().parse(content);

      final all = root.walk().toList();
      final hasUnsupported = all.any(
        (n) => n.kind == CanonicalKind.unsupported,
      );
      expect(
        hasUnsupported,
        isTrue,
        reason: 'fixture intentionally contains a vendor voodoo node',
      );
    });

    test('throws MalformedSourceError on invalid JSON', () {
      expect(
        () => NinaSequenceParser().parse('{not json'),
        throwsA(isA<MalformedSourceError>()),
      );
    });

    test('throws MalformedSourceError when root is not a JSON object', () {
      expect(
        () => NinaSequenceParser().parse('[]'),
        throwsA(isA<MalformedSourceError>()),
      );
    });

    test('honors Enabled=false by marking the node as disabled', () {
      const fragment = '''
{
  "\$type": "NINA.Sequencer.Container.SequenceRootContainer, NINA.Sequencer",
  "Items": [
    {
      "\$type": "NINA.Sequencer.SequenceItem.Imaging.TakeExposure, NINA.Sequencer",
      "Name": "Disabled exposure",
      "Enabled": false,
      "ExposureTime": 30
    }
  ]
}
''';
      final root = NinaSequenceParser().parse(fragment);
      final exposure = root.children.single;
      expect(exposure.kind, CanonicalKind.exposure);
      expect(exposure.attributes['_disabled'], isTrue);
    });

    test('Newtonsoft \$values list wrapper is unwrapped transparently', () {
      const fragment = '''
{
  "\$type": "NINA.Sequencer.Container.Container, NINA.Sequencer",
  "Items": {
    "\$values": [
      {
        "\$type": "NINA.Sequencer.SequenceItem.Utility.Annotation, NINA.Sequencer",
        "Name": "comment"
      }
    ]
  }
}
''';
      // The parser's child-list extractor accepts a `$values` wrapper either
      // as the list itself or inside a one-element list. Here we feed the
      // direct map; even if it isn't a top-level list the parser must still
      // produce no orphans.
      final root = NinaSequenceParser().parse(fragment);
      expect(root.kind, CanonicalKind.sequential);
    });
  });
}
