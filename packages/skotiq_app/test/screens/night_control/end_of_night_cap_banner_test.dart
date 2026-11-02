import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/night_control/end_of_night_cap_banner.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _NoRig implements EonRig {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Service extends EndOfNightCalibrationService {
  _Service(EonStatus status)
      : super(_NoRig(), () async => const EonSettings()) {
    state = status;
  }

  var confirmed = 0;
  var cancelled = 0;

  @override
  bool confirmCapped() {
    confirmed++;
    return true;
  }

  @override
  Future<void> cancel() async => cancelled++;
}

Future<_Service> _pump(WidgetTester tester, EonStatus status,
    {double width = 1200}) async {
  final service = _Service(status);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 400);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        endOfNightCalibrationProvider.overrideWith((ref) => service),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: EndOfNightCapBanner()),
      ),
    ),
  );
  return service;
}

void main() {
  testWidgets('asks Tonight to cap the telescope and confirms it',
      (tester) async {
    final service = await _pump(
      tester,
      EonStatus(
        phase: EonPhase.waitingForCap,
        capDeadline: DateTime(2026, 11, 1, 6, 12),
      ),
    );
    expect(find.text('Cap the telescope for the end-of-night darks'),
        findsOneWidget);
    expect(find.textContaining('skipped at 06:12'), findsOneWidget);

    await tester.tap(find.text('The telescope is capped'));
    expect(service.confirmed, 1);
    await tester.tap(find.text('Skip the darks'));
    expect(service.cancelled, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fits a narrow window', (tester) async {
    await _pump(
      tester,
      EonStatus(
        phase: EonPhase.waitingForCap,
        capDeadline: DateTime(2026, 11, 1, 6, 12),
      ),
      width: 360,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Skip the darks'), findsOneWidget);
  });

  testWidgets('says nothing when calibration is not waiting', (tester) async {
    await _pump(tester, const EonStatus(phase: EonPhase.capturing));
    expect(find.byType(SkotiqButton), findsNothing);
  });

  // reverify RV-08: the cap request showed only on the host; a companion
  // driving the night saw "Finished" and the darks were skipped.
  testWidgets('a linked client shows the host request and answers the host',
      (tester) async {
    final backend = _MockNetworkBackend();
    when(backend.confirmHostEndOfNightCapped).thenAnswer(
      (_) async => const EonStatus(phase: EonPhase.capturing),
    );
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 400);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final local = _Service(const EonStatus());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backendProvider.overrideWith((ref) => _BackendNotifier(ref, backend)),
          endOfNightCalibrationProvider.overrideWith((ref) => local),
          hostEndOfNightStatusProvider.overrideWith(
            (ref) => EonStatus(
              phase: EonPhase.waitingForCap,
              capDeadline: DateTime(2026, 11, 1, 15, 12),
            ),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: EndOfNightCapBanner()),
        ),
      ),
    );

    expect(find.text('Cap the telescope for the end-of-night darks'),
        findsOneWidget);
    expect(find.textContaining('skipped at 15:12'), findsOneWidget);
    await tester.tap(find.text('The telescope is capped'));
    await tester.pump();
    verify(backend.confirmHostEndOfNightCapped).called(1);
    expect(local.confirmed, 0);
    expect(find.text('Cap the telescope for the end-of-night darks'),
        findsNothing);
  });
}

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _BackendNotifier extends BackendNotifier {
  _BackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}
