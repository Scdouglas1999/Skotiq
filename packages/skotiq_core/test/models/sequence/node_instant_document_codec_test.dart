import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/models.dart';

// A plan built on a phone is sent to the imaging host as a document. The two
// clocks can be set to different time zones (a phone on local time, a Pi left
// on UTC), so a time in the document has to name its instant: a bare local
// wall-clock string was read in the host's zone and moved the start of a
// target by the difference between the two.
void main() {
  TargetHeaderNode header(DateTime startAfter) => TargetHeaderNode(
    id: 'th',
    targetName: 'NGC 1313',
    raHours: 3.3,
    decDegrees: -66.5,
    startAfter: startAfter,
  );

  test('a document stores a time as UTC with its zone marker', () {
    final local = DateTime(2026, 11, 25, 23, 15);
    final fields = header(
      local,
    ).kind.encodeFields(header(local), NodeStore.document);
    final text = fields['startAfter'] as String;
    expect(text, endsWith('Z'));
    expect(DateTime.parse(text).isAtSameMomentAs(local), isTrue);
  });

  test('a document time reads back as the same instant, on local time', () {
    final local = DateTime(2026, 11, 25, 23, 15);
    final node = header(local);
    final fields = node.kind.encodeFields(node, NodeStore.document);
    final back = node.kind.decodeFields(fields, NodeStore.document);
    expect(back.startAfter!.isAtSameMomentAs(local), isTrue);
    expect(back.startAfter!.isUtc, isFalse);
  });

  test('a document written before the zone marker still reads as local', () {
    final node = header(DateTime(2026));
    final fields = node.kind.encodeFields(node, NodeStore.document)
      ..['startAfter'] = '2026-11-25T23:15:00.000';
    final back = node.kind.decodeFields(fields, NodeStore.document);
    expect(back.startAfter, DateTime(2026, 11, 25, 23, 15));
  });
}
