// One-tap Tonight sat on "Planning the night…" on a computer that had just
// linked to a rig: the planner awaited `ref.read(provider.future)` of a
// provider nothing was watching, the provider's inputs changed while it
// loaded, and the load was never finished.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/utils/held_future.dart';

/// A provider that loads [input]'s value, slowly: each load waits on its own
/// gate in [gates].
FutureProvider<int> _slow(
  StateProvider<int> input,
  List<Completer<void>> gates,
) =>
    FutureProvider<int>((ref) async {
      final value = ref.watch(input);
      final gate = Completer<void>();
      gates.add(gate);
      await gate.future;
      return value;
    });

Future<WidgetRef> _ref(WidgetTester tester) async {
  late WidgetRef captured;
  await tester.pumpWidget(
    ProviderScope(
      child: Consumer(
        builder: (context, ref, _) {
          captured = ref;
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return captured;
}

Future<void> _openEvery(WidgetTester tester, List<Completer<void>> gates) async {
  // A reload adds its own gate after the first opens, so go round twice.
  for (var round = 0; round < 3; round++) {
    for (final gate in gates.toList()) {
      if (!gate.isCompleted) gate.complete();
    }
    await tester.pump();
  }
}

void main() {
  testWidgets(
      'a bare read hangs when the input changes mid-load and nobody listens',
      (tester) async {
    final ref = await _ref(tester);
    final input = StateProvider<int>((ref) => 0);
    final gates = <Completer<void>>[];
    final slow = _slow(input, gates);

    int? got;
    // The future ends, with an error, only when the scope is torn down.
    unawaited(
      ref.read(slow.future).then<void>(
            (value) => got = value,
            onError: (Object _) {},
          ),
    );
    await tester.pump();
    ref.read(input.notifier).state = 1;
    await tester.pump();
    await _openEvery(tester, gates);

    expect(got, isNull, reason: 'the shape the planner had');
    expect(gates, hasLength(1), reason: 'the reload never started');
  });

  testWidgets('a held read gets the reloaded value', (tester) async {
    final ref = await _ref(tester);
    final input = StateProvider<int>((ref) => 0);
    final gates = <Completer<void>>[];
    final slow = _slow(input, gates);

    int? got;
    unawaited(readHeld(ref, slow).then((value) => got = value));
    await tester.pump();
    ref.read(input.notifier).state = 1;
    await tester.pump();
    await _openEvery(tester, gates);

    expect(got, 1);
  });

  testWidgets('a held read of a loaded provider answers at once',
      (tester) async {
    final ref = await _ref(tester);
    final ready = FutureProvider<int>((ref) async => 7);
    final keep = ref.listenManual(ready, (_, __) {});
    await tester.pump();

    expect(await readHeld(ref, ready), 7);
    keep.close();
  });

  testWidgets('a held read ends with the provider\'s error', (tester) async {
    final ref = await _ref(tester);
    final broken = FutureProvider<int>((ref) async => throw StateError('no'));

    Object? error;
    unawaited(
      readHeld(ref, broken).then<void>((_) {}, onError: (Object e) {
        error = e;
      }),
    );
    await tester.pump();
    await tester.pump();

    expect(error, isA<StateError>());
  });

  testWidgets('the wait leaves no listener behind', (tester) async {
    final ref = await _ref(tester);
    var disposed = false;
    final watched = FutureProvider.autoDispose<int>((ref) async {
      ref.onDispose(() => disposed = true);
      return 3;
    });

    expect(await readHeld(ref, watched), 3);
    await tester.pump();
    expect(disposed, isTrue);
  });
}
