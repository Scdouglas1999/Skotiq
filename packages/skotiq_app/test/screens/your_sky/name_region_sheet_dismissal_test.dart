// Creating a region must not lock the whole app behind a modal that never
// lifts.
//
// A sheet that guards itself with `PopScope(canPop: !_saving)` and then closes
// itself with `maybePop` asks that guard for permission: as soon as the write
// outlives the frame that set `_saving`, it is asking a barrier it raised itself
// to let it out, and is told no. The write commits, but the button stays a
// spinner forever while Cancel, Escape, an outside click and every nav-rail item
// are inert — force-quitting is the only exit, taking any running sequence with
// it.
//
// The timing is why this needs a gated write: a write that completes inside
// the same frame as the tap pops before `canPop: false` is ever built, which
// is exactly what a naive test does and exactly what the live app never does.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/your_sky/widgets/name_region_sheet.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

/// A backend whose region write the test completes by hand, so the in-flight
/// window — the one the user was trapped in — is inspectable frame by frame.
class _GatedBackend extends Mock implements NetworkBackend {
  final createCalled = Completer<void>();
  final completion = Completer<int>();

  @override
  Future<int> createAtlasRegion({
    required String name,
    required double centerRaDeg,
    required double centerDecDeg,
    required double radiusDeg,
    String kind = 'custom',
    int? targetId,
  }) {
    if (!createCalled.isCompleted) createCalled.complete();
    return completion.future;
  }
}

Widget _surface(NetworkBackend backend, {ValueChanged<bool?>? onResult}) {
  return ProviderScope(
    overrides: [
      backendProvider.overrideWith(
        (ref) => _FixedBackendNotifier(ref, backend),
      ),
      skyAtlasRegionWriterProvider.overrideWithValue(
        SkyAtlasRegionWriter.remote(backend),
      ),
      allDbTargetsProvider.overrideWith((ref) => Stream.value(const [])),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                final result = await NameRegionSheet.show(context);
                onResult?.call(result);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Open the sheet and fill in a valid custom cone, leaving it one tap from a
/// create. Stops before the tap so each test owns the in-flight window.
Future<void> _openAndFillCustom(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Custom RA/Dec'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).at(0), '83.82');
  await tester.enterText(find.byType(TextField).at(1), '-5.39');
  await tester.pumpAndSettle();
}

/// Pump past the sheet's exit transition. `pumpAndSettle` is unusable while the
/// create spinner is on screen — it never settles, which is what a stuck sheet
/// looks like from a test.
Future<void> _pumpDismissal(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('a write that outlives its frame still closes the sheet',
      (tester) async {
    final backend = _GatedBackend();
    bool? result;
    await tester.pumpWidget(_surface(backend, onResult: (r) => result = r));
    await tester.pumpAndSettle();

    await _openAndFillCustom(tester);
    await tester.tap(find.text('Create region'));
    await tester.pump();
    expect(backend.createCalled.isCompleted, isTrue);
    expect(find.text('Name a region'), findsOneWidget);

    backend.completion.complete(7);
    await _pumpDismissal(tester);

    expect(find.text('Name a region'), findsNothing);
    expect(result, isTrue);
  });

  testWidgets('Escape stays live while the write is in flight', (tester) async {
    final backend = _GatedBackend();
    bool? result;
    await tester.pumpWidget(_surface(backend, onResult: (r) => result = r));
    await tester.pumpAndSettle();

    await _openAndFillCustom(tester);
    await tester.tap(find.text('Create region'));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _pumpDismissal(tester);

    expect(find.text('Name a region'), findsNothing);
    expect(
      result,
      isNull,
      reason: 'dismissing is not creating — the caller must not be told a '
          'region came back',
    );

    backend.completion.complete(7);
    await tester.pump();
  });

  testWidgets('Cancel stays live while the write is in flight', (tester) async {
    final backend = _GatedBackend();
    await tester.pumpWidget(_surface(backend));
    await tester.pumpAndSettle();

    await _openAndFillCustom(tester);
    await tester.tap(find.text('Create region'));
    await tester.pump();

    await tester.tap(find.text('Cancel'));
    await _pumpDismissal(tester);

    expect(find.text('Name a region'), findsNothing);

    backend.completion.complete(7);
    await tester.pump();
  });
}
