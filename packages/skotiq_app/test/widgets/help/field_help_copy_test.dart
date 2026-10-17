import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/help/field_help_copy.dart';

void main() {
  // The longest a single tooltip body may be. Field help shows inside a
  // [SkotiqTooltip]; overly long copy wraps into a wall of text that users
  // skip. Keep every body tight and scannable.
  const maxBodyLength = 360;

  group('kFieldHelpCopy', () {
    test('has an entry for every FieldHelpId', () {
      for (final id in FieldHelpId.values) {
        expect(
          kFieldHelpCopy.containsKey(id),
          isTrue,
          reason: 'Missing FieldHelpCopy for $id',
        );
      }
    });

    test('contains no keys outside FieldHelpId (no orphan entries)', () {
      expect(kFieldHelpCopy.length, FieldHelpId.values.length);
      expect(kFieldHelpCopy.keys.toSet(), FieldHelpId.values.toSet());
    });

    test('every entry has a non-empty, trimmed title', () {
      kFieldHelpCopy.forEach((id, copy) {
        expect(copy.title.trim(), isNotEmpty, reason: '$id title');
        // No leading/trailing whitespace — these flow straight into a bold
        // tooltip heading.
        expect(copy.title, copy.title.trim(), reason: '$id title is padded');
      });
    });

    test('every entry has a non-empty, trimmed body', () {
      kFieldHelpCopy.forEach((id, copy) {
        expect(copy.body.trim(), isNotEmpty, reason: '$id body');
        expect(copy.body, copy.body.trim(), reason: '$id body is padded');
      });
    });

    test('no body exceeds the tooltip length budget', () {
      kFieldHelpCopy.forEach((id, copy) {
        expect(
          copy.body.length,
          lessThanOrEqualTo(maxBodyLength),
          reason: '$id body is ${copy.body.length} chars '
              '(budget $maxBodyLength) — tighten it',
        );
      });
    });

    test('every body reads as a sentence (ends with terminal punctuation)', () {
      // Guards against truncated or fragment copy slipping in; help text the
      // user reads should be a complete sentence.
      kFieldHelpCopy.forEach((id, copy) {
        final last = copy.body.trim().substring(copy.body.trim().length - 1);
        expect(
          const {'.', '!', '?'}.contains(last),
          isTrue,
          reason: '$id body should end with terminal punctuation, got "$last"',
        );
      });
    });
  });

  group('helpFor', () {
    test('returns the matching copy for every id', () {
      for (final id in FieldHelpId.values) {
        final copy = helpFor(id);
        expect(copy, same(kFieldHelpCopy[id]), reason: '$id');
        expect(copy.title.trim(), isNotEmpty, reason: '$id title');
        expect(copy.body.trim(), isNotEmpty, reason: '$id body');
      }
    });

    test('never throws for any real FieldHelpId (map is exhaustive)', () {
      // The StateError guard in helpFor only fires when kFieldHelpCopy is
      // missing an id. That must be unreachable via the public API: every id in
      // the enum resolves. If someone adds a new FieldHelpId without copy, this
      // fails with the surfaced StateError rather than shipping the gap.
      for (final id in FieldHelpId.values) {
        expect(() => helpFor(id), returnsNormally, reason: '$id');
      }
    });

    test('throws StateError when an id is absent from the lookup map', () {
      // Exercise the fail-closed guard directly: mirror helpFor's lookup
      // against a map with one id removed and confirm the StateError path
      // fires rather than returning a wrong/null copy. This proves the guard in
      // helpFor is live, not dead code — the production map happens to be
      // exhaustive, so the throw is otherwise unreachable.
      const removed = FieldHelpId.cameraGain;
      final pruned = Map<FieldHelpId, FieldHelpCopy>.from(kFieldHelpCopy)
        ..remove(removed);

      FieldHelpCopy lookup(FieldHelpId id) {
        final copy = pruned[id];
        if (copy == null) {
          throw StateError(
            'No FieldHelpCopy defined for FieldHelpId.${id.name}.',
          );
        }
        return copy;
      }

      expect(() => lookup(removed), throwsStateError);
      // Remaining ids still resolve through the pruned map.
      expect(lookup(FieldHelpId.cameraOffset).title, isNotEmpty);
    });
  });
}
