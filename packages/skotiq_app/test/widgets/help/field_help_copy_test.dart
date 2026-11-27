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
              '(budget $maxBodyLength): tighten it',
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
  });
}
