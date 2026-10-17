import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/import/import_result.dart';
import 'package:skotiq_core/src/models/sequence/sequence_models.dart';
import 'package:skotiq_core/src/services/import/canonical_node_mapper.dart';
import 'package:skotiq_core/src/services/import/ics_calendar_importer.dart';

void main() {
  group('IcsCalendarImporter sniff', () {
    test('detects BEGIN:VCALENDAR', () {
      expect(
        IcsCalendarImporter.sniff('BEGIN:VCALENDAR\nVERSION:2.0\n'),
        isTrue,
      );
    });

    test('case-insensitive sniff', () {
      expect(
        IcsCalendarImporter.sniff('begin:vcalendar\nversion:2.0\n'),
        isTrue,
      );
    });

    test('rejects non-ICS content', () {
      expect(IcsCalendarImporter.sniff('hello'), isFalse);
      expect(IcsCalendarImporter.sniff('{}'), isFalse);
    });
  });

  group('IcsCalendarImporter parse', () {
    test('extracts targets from VEVENTs with RA/Dec', () async {
      final content = await File(
        'test/services/import/fixtures/calendar_basic.ics',
      ).readAsString();
      final result = IcsCalendarImporter().parse(content);
      expect(result.totalEvents, 3);
      // 2 resolved + 1 maintenance event with no RA/Dec
      expect(result.unresolved, hasLength(1));
      expect(result.unresolved.first.summary, 'Maintenance');

      final mapped = CanonicalNodeMapper().map(
        result.root,
        sequenceName: 'Calendar',
        forceUnsupported: false,
      );
      final targets = mapped.sequence.nodes.values
          .whereType<TargetHeaderNode>()
          .toList();
      expect(targets, hasLength(2));
      final names = targets.map((t) => t.targetName).toSet();
      expect(names, containsAll(['M42 Imaging', 'M31 Wide-field']));

      final m42 = targets.firstWhere((t) => t.targetName == 'M42 Imaging');
      expect(m42.raHours, closeTo(5.588, 1e-2));
      expect(m42.decDegrees, closeTo(-5.391, 1e-2));
    });

    test('throws on calendar with no VEVENTs', () {
      const ics = 'BEGIN:VCALENDAR\nVERSION:2.0\nEND:VCALENDAR\n';
      expect(
        () => IcsCalendarImporter().parse(ics),
        throwsA(isA<MalformedSourceError>()),
      );
    });

    test('handles inline RA/Dec in SUMMARY field', () {
      const ics =
          'BEGIN:VCALENDAR\nVERSION:2.0\n'
          'BEGIN:VEVENT\n'
          'UID:1\n'
          'SUMMARY:Imaging M42 - RA: 05h35m17s, Dec: -05°23\'28"\n'
          'DTSTART:20260201T020000Z\n'
          'END:VEVENT\n'
          'END:VCALENDAR\n';
      final result = IcsCalendarImporter().parse(ics);
      expect(result.unresolved, isEmpty);
      expect(result.root.children, hasLength(1));
    });

    test('preserves LOCATION + DTSTART into notes / startAfter', () async {
      final content = await File(
        'test/services/import/fixtures/calendar_basic.ics',
      ).readAsString();
      final result = IcsCalendarImporter().parse(content);
      final m42 = result.root.children.firstWhere(
        (c) => c.attributes['targetName'] == 'M42 Imaging',
      );
      expect(m42.attributes['notes'], contains('Backyard Observatory'));
      expect(m42.attributes['startAfter'], startsWith('2026-02-01'));
    });
  });
}
