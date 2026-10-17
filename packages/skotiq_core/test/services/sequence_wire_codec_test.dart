// A sequence is serialized by two independent codecs — the DB
// `sequence_nodes.properties` blob and the sequence FILE format — and each had
// its own hand-rolled converter per enum. They had already drifted:
//
//   * `RecoveryActionType.continueExecution` was written as 'continue' by the
//     DB codec and 'continueExecution' by the file codec, and neither reader
//     accepted the other's token.
//   * An unrecognised recovery token decoded to `continueExecution` on one
//     side and `retry` on the other.
//   * The DB reader hand-listed the meridian trigger methods and silently
//     mapped anything it had missed — including `onTrackingLimitHit`, which
//     the DB WRITER emits — back to `minutesPastMeridian`.
//
// The tokens now come from one codec. Encoding still emits each format's
// historical bytes; decoding accepts both.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/services/sequence_wire_codec.dart';

void main() {
  group('recovery action', () {
    test('each format still writes the bytes it always wrote', () {
      expect(
        recoveryActionToDbWire(RecoveryActionType.continueExecution),
        'continue',
      );
      expect(
        recoveryActionToFileWire(RecoveryActionType.continueExecution),
        'continueExecution',
      );
      for (final action in RecoveryActionType.values) {
        if (action == RecoveryActionType.continueExecution) continue;
        expect(recoveryActionToDbWire(action), action.name);
        expect(recoveryActionToFileWire(action), action.name);
      }
    });

    test('one reader accepts both historical spellings', () {
      for (final token in ['continue', 'continueExecution']) {
        for (final fallback in [
          RecoveryActionType.retry,
          RecoveryActionType.continueExecution,
        ]) {
          expect(
            recoveryActionFromWire(token, fallback: fallback),
            RecoveryActionType.continueExecution,
            reason: '"$token" must decode the same on both sides',
          );
        }
      }
    });

    test('every action round-trips through either format', () {
      for (final action in RecoveryActionType.values) {
        expect(
          recoveryActionFromWire(
            recoveryActionToDbWire(action),
            fallback: RecoveryActionType.retry,
          ),
          action,
        );
        expect(
          recoveryActionFromWire(
            recoveryActionToFileWire(action),
            fallback: RecoveryActionType.retry,
          ),
          action,
        );
      }
    });

    test('the unknown-token fallback stays per-format', () {
      // Deliberately divergent and documented: changing what a corrupt node
      // does unattended is a behaviour change, not a cleanup.
      expect(
        recoveryActionFromWire(
          'not-an-action',
          fallback: RecoveryActionType.continueExecution,
        ),
        RecoveryActionType.continueExecution,
      );
      expect(
        recoveryActionFromWire(
          'not-an-action',
          fallback: RecoveryActionType.retry,
        ),
        RecoveryActionType.retry,
      );
      expect(
        recoveryActionFromWire(null, fallback: RecoveryActionType.retry),
        RecoveryActionType.retry,
      );
    });
  });

  group('enumFromWire', () {
    test('resolves every value of an enum the writers emit by name', () {
      for (final method in MeridianTriggerMethod.values) {
        expect(
          enumFromWireOr(
            MeridianTriggerMethod.values,
            method.name,
            MeridianTriggerMethod.minutesPastMeridian,
          ),
          method,
          reason:
              'the writer emits ${method.name}; a reader that misses it '
              'silently rewrites the operator\'s flip trigger',
        );
      }
      for (final action in FlipFailureAction.values) {
        expect(
          enumFromWireOr(
            FlipFailureAction.values,
            action.name,
            FlipFailureAction.pauseAndAlert,
          ),
          action,
        );
      }
      for (final mode in BinningMode.values) {
        expect(
          enumFromWireOr(BinningMode.values, mode.name, BinningMode.one),
          mode,
        );
      }
    });

    test('is case-insensitive and falls back on anything else', () {
      expect(
        enumFromWireOr(BinningMode.values, 'TWO', BinningMode.one),
        BinningMode.two,
      );
      expect(
        enumFromWire(TwilightType.values, 'ASTRONOMICAL'),
        TwilightType.astronomical,
      );
      expect(enumFromWire(TwilightType.values, 'dusk'), isNull);
      expect(enumFromWire(TwilightType.values, 42), isNull);
      expect(
        enumFromWireOr(BinningMode.values, null, BinningMode.one),
        BinningMode.one,
      );
    });
  });

  group('autofocus method', () {
    test('still reads the legacy "parabolic" token as quadratic', () {
      expect(autofocusMethodFromWire('parabolic'), AutofocusMethod.quadratic);
      expect(autofocusMethodFromWire('Parabolic'), AutofocusMethod.quadratic);
      for (final method in AutofocusMethod.values) {
        expect(autofocusMethodFromWire(method.name), method);
      }
      expect(autofocusMethodFromWire('nonsense'), AutofocusMethod.vCurve);
    });
  });

  group('explicit notification transports', () {
    test('drops unknown keys and reads absent/empty as null', () {
      expect(explicitTransportsFromWire(null), isNull);
      expect(explicitTransportsFromWire(const []), isNull);
      expect(explicitTransportsFromWire(const ['not-a-transport']), isNull);
      final known = NotificationTransportKind.values.first.storageKey;
      expect(explicitTransportsFromWire([known, 'not-a-transport']), [
        NotificationTransportKind.values.first,
      ]);
    });
  });
}
