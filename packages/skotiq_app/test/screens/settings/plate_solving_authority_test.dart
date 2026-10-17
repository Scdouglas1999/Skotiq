import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/settings/plate_solving_settings_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

class _MockPlateSolveService extends Mock implements PlateSolveService {}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }

  void swap(SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  registerFallbackValue(const PlateSolverPreference());

  testWidgets('path picker is single-flight and rejects an old-host result',
      (tester) async {
    final service = _MockPlateSolveService();
    final saved = <PlateSolverPreference>[];
    when(() => service.setConfig(any())).thenAnswer((invocation) async {
      saved.add(
        invocation.positionalArguments.single as PlateSolverPreference,
      );
    });
    final picks = [Completer<String?>(), Completer<String?>()];
    var pickerCalls = 0;

    final handle = await pumpAppScreen(
      tester,
      const PlateSolvingSettings(),
      size: const Size(1280, 1400),
      extraOverrides: [
        backendProvider.overrideWith(
          (ref) => _SwappableBackendNotifier(ref, DisconnectedBackend()),
        ),
        plateSolveServiceProvider.overrideWithValue(service),
        plateSolverDetectionProvider.overrideWith(
          (ref) async => const PlateSolverDetection(
            astapPath: '/detected/astap',
            catalogPath: '/detected/catalog',
          ),
        ),
        plateSolverPreferenceProvider.overrideWith(
          (ref) async => const PlateSolverPreference(),
        ),
        plateSolverPathPickerProvider.overrideWithValue(
          ({
            required context,
            required kind,
            required isRemote,
            required currentPath,
          }) {
            expect(kind, PlateSolverPathKind.astapExecutable);
            return picks[pickerCalls++].future;
          },
        ),
      ],
    );

    final astapInput = find.byKey(
      const ValueKey('plate_solver_astap_path'),
    );
    final browse = find.descendant(
      of: astapInput,
      matching: find.byType(GestureDetector),
    );
    await tester.tap(browse);
    await tester.tap(browse);
    await tester.pump();
    expect(pickerCalls, 1);
    expect(
      find.descendant(
        of: astapInput,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );

    final backend = handle.container.read(backendProvider.notifier)
        as _SwappableBackendNotifier;
    backend.swap(DisconnectedBackend());
    await tester.pump();

    picks.first.complete('/old-host/astap');
    await tester.pump();
    await tester.pump();
    expect(saved, isEmpty);

    await tester.tap(browse);
    await tester.pump();
    expect(pickerCalls, 2);
    picks.last.complete('/current-host/astap');
    await tester.pump();
    await tester.pump();

    expect(saved, hasLength(1));
    expect(saved.single.astapPath, '/current-host/astap');
    expect(tester.takeException(), isNull);
  });

  testWidgets('re-scan shows its own busy state and ignores repeat taps',
      (tester) async {
    final service = _MockPlateSolveService();
    final rescan = Completer<PlateSolverDetection>();
    var detectionCalls = 0;
    when(service.detect).thenAnswer((_) {
      detectionCalls++;
      if (detectionCalls == 1) {
        return Future.value(
          const PlateSolverDetection(
            astapPath: '/detected/astap',
            catalogPath: '/detected/catalog',
          ),
        );
      }
      return rescan.future;
    });
    when(service.getConfig).thenAnswer(
      (_) async => const PlateSolverPreference(),
    );

    await pumpAppScreen(
      tester,
      const PlateSolvingSettings(),
      size: const Size(1280, 1400),
      extraOverrides: [
        plateSolveServiceProvider.overrideWithValue(service),
      ],
    );

    final rescanButton = find.widgetWithText(SkotiqButton, 'Re-scan');
    expect(rescanButton, findsOneWidget);
    await tester.tap(rescanButton);
    await tester.tap(rescanButton);
    await tester.pump();

    expect(detectionCalls, 2);
    expect(
      find.widgetWithText(SkotiqButton, 'Re-scanning…'),
      findsOneWidget,
    );

    rescan.complete(
      const PlateSolverDetection(
        astapPath: '/rescanned/astap',
        catalogPath: '/rescanned/catalog',
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.widgetWithText(SkotiqButton, 'Re-scan'), findsOneWidget);
    expect(find.text('Re-scanned plate-solver paths.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
