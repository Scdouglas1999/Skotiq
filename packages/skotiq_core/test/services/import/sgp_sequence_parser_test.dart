import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/import/canonical_sequence_node.dart';
import 'package:skotiq_core/src/models/import/import_result.dart';
import 'package:skotiq_core/src/services/import/sgp_sequence_parser.dart';

void main() {
  group('SgpSequenceParser', () {
    test('sniff detects modern SGP exports', () {
      const sgp =
          '{"SequenceTitle":"X","TargetSet":[{"Target":{}}],"Events":[]}';
      expect(SgpSequenceParser.sniff(sgp), isTrue);
    });

    test('sniff rejects NINA content', () {
      const nina =
          '{"\$type":"NINA.Sequencer.SequenceItem.Imaging.TakeExposure"}';
      expect(SgpSequenceParser.sniff(nina), isFalse);
    });

    test('sniff rejects free-form text', () {
      expect(SgpSequenceParser.sniff('not a sequence'), isFalse);
    });

    test(
      'parses sgp_basic.sgf into two targets with expected exposures',
      () async {
        final content = await File(
          'test/services/import/fixtures/sgp_basic.sgf',
        ).readAsString();
        final root = SgpSequenceParser().parse(content);

        expect(root.kind, CanonicalKind.sequential);
        expect(root.name, 'Two-target night');
        expect(root.children, hasLength(2));

        // Target #1: M42 with AutoCenter + 2 events => slew + center + loop[Lum,Red].
        final m42 = root.children.first;
        expect(m42.kind, CanonicalKind.targetHeader);
        expect(m42.name, 'M42 Orion Nebula');
        expect(m42.attributes['raHours'], closeTo(5.5882, 1e-4));
        expect(m42.attributes['decDegrees'], closeTo(-5.391, 1e-4));
        expect(m42.attributes['rotation'], closeTo(90.0, 1e-4));

        final m42Kinds = m42.children.map((c) => c.kind).toList();
        // First slew (always), then center (because AutoCenter), then loop.
        expect(m42Kinds.first, CanonicalKind.slew);
        expect(m42Kinds, contains(CanonicalKind.center));
        expect(m42Kinds.last, CanonicalKind.loop);

        final m42Loop = m42.children.firstWhere(
          (c) => c.kind == CanonicalKind.loop,
        );
        // 2 events => 2 filter-change + 2 exposure children.
        final exposureKinds = m42Loop.children
            .where((c) => c.kind == CanonicalKind.exposure)
            .toList();
        expect(exposureKinds, hasLength(2));
        // Total exposure count attribute sums NumExposures across events.
        expect(m42Loop.attributes['_exposureCount'], 45);

        final lumExposure = m42Loop.children
            .where(
              (c) =>
                  c.kind == CanonicalKind.exposure &&
                  c.attributes['filterName'] == 'Lum',
            )
            .single;
        expect(lumExposure.attributes['exposureTime'], 60.0);
        expect(lumExposure.attributes['count'], 30);
        expect(lumExposure.attributes['gain'], 100);
        expect(lumExposure.attributes['offset'], 10);

        // Target #2: NGC 2024 without AutoCenter => only slew (no center).
        final ngc = root.children[1];
        expect(ngc.name, 'NGC 2024 Flame Nebula');
        expect(ngc.children.first.kind, CanonicalKind.slew);
        expect(
          ngc.children.any((c) => c.kind == CanonicalKind.center),
          isFalse,
        );
        final ngcExposures = ngc.children
            .firstWhere((c) => c.kind == CanonicalKind.loop)
            .children
            .where((c) => c.kind == CanonicalKind.exposure)
            .toList();
        expect(ngcExposures, hasLength(1));
        expect(ngcExposures.single.attributes['filterName'], 'Ha');
        expect(ngcExposures.single.attributes['exposureTime'], 300.0);
      },
    );

    test('throws MalformedSourceError on invalid JSON', () {
      expect(
        () => SgpSequenceParser().parse('{not json'),
        throwsA(isA<MalformedSourceError>()),
      );
    });

    test('throws MalformedSourceError when no targets are present', () {
      expect(
        () => SgpSequenceParser().parse('{"SequenceTitle":"X","TargetSet":[]}'),
        throwsA(isA<MalformedSourceError>()),
      );
    });

    test('treats a disabled event as an annotation drop, not an exposure', () {
      const sgp = '''
{
  "SequenceTitle": "Disabled-event test",
  "TargetSet": [
    {
      "Target": {
        "TargetName": "X",
        "Reference": {"RAHours": 1.0, "Dec": 2.0},
        "Events": [
          {"Enabled": false, "Filter": "Lum", "ExposureTime": 60, "NumExposures": 5}
        ]
      }
    }
  ]
}
''';
      final root = SgpSequenceParser().parse(sgp);
      final target = root.children.single;
      final loop = target.children.firstWhere(
        (c) => c.kind == CanonicalKind.loop,
      );
      // The disabled event becomes an annotation; no exposure node is emitted.
      expect(
        loop.children.any((c) => c.kind == CanonicalKind.exposure),
        isFalse,
      );
      expect(
        loop.children.any((c) => c.kind == CanonicalKind.annotation),
        isTrue,
      );
    });
  });
}
