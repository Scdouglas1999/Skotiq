import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/centering_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _Settings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState();
}

class _Solver extends PlateSolveService {
  _Solver(super.ref);
  @override
  Future<void> ensureSolverAvailable() async {}
}

class _Centering extends CenteringService {
  _Centering(super.ref);
  final result = Completer<CenteringResult>();
  final stopped = Completer<void>();
  int starts = 0;
  int stops = 0;
  void Function(CenteringStatus)? update;

  @override
  Future<CenteringResult> centerOnTarget({
    required double targetRa,
    required double targetDec,
    required PlateSolverConfig solverConfig,
    CenteringConfig config = const CenteringConfig(),
    void Function(CenteringStatus)? onStatusUpdate,
  }) {
    starts++;
    update = onStatusUpdate;
    report();
    return result.future;
  }

  void report({int iteration = 1, String message = 'Plate solving…'}) =>
      update!(CenteringStatus(
        state: CenteringState.solving,
        currentIteration: iteration,
        maxIterations: 5,
        currentOffsetArcsec: 42,
        currentOffsetArcmin: 0.7,
        message: message,
        iterationHistory: const [],
      ));

  @override
  Future<void> stop() {
    stops++;
    return stopped.future;
  }
}

class _Backend extends TestBackendNotifier {
  _Backend(super.ref, super.backend);
  void replace(SkotiqBackend backend) => state = backend;
}

class _Page extends StatelessWidget {
  final bool other;
  const _Page({this.other = false});
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Column(children: [
          Text(other ? 'Other page' : 'Original page'),
          TextButton(
            onPressed: () => showCenteringDialog(
                context: context,
                targetRa: 22.78,
                targetDec: 58.1,
                targetName: 'NGC7380'),
            child: const Text('Open centering'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pushReplacement(
                MaterialPageRoute<void>(
                    builder: (_) => const _Page(other: true))),
            child: const Text('Navigate'),
          ),
        ]),
      );
}

void main() {
  Future<(_Centering, _Backend)> launch(WidgetTester tester,
      {Size size = const Size(1280, 900)}) async {
    late _Centering service;
    late _Backend backend;
    await pumpAppScreen(tester, const _Page(), size: size, extraOverrides: [
      activeEquipmentProfileProvider.overrideWithValue(null),
      appSettingsProvider.overrideWith(_Settings.new),
      backendProvider
          .overrideWith((ref) => backend = _Backend(ref, mockBackend())),
      plateSolveServiceProvider.overrideWith(_Solver.new),
      centeringServiceProvider.overrideWith((ref) => service = _Centering(ref)),
    ]);
    await tester.tap(find.text('Open centering'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start centering'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(service.starts, 1);
    await tester.tap(find.byTooltip('Minimize centering'));
    await tester.pump();
    return (service, backend);
  }

  for (final size in [const Size(1280, 900), const Size(390, 844)]) {
    testWidgets('minimized centering survives navigation and restores at $size',
        (tester) async {
      final (service, _) = await launch(tester, size: size);
      expect(find.text('Plate solving…'), findsOneWidget);
      await tester.tap(find.text('Navigate'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.text('Other page'), findsOneWidget);
      expect(find.text('Original page'), findsNothing);
      service.report(iteration: 2, message: 'Verifying target…');
      await tester.pump();
      expect(find.textContaining('Iteration 2/5'), findsOneWidget);
      expect(find.text('Verifying target…'), findsOneWidget);
      // A second launch restores the existing operation instead of starting another.
      await tester.tap(find.text('Open centering'));
      await tester.pump();
      expect(find.text('Target Centering'), findsOneWidget);
      expect(service.starts, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      service.result.complete(CenteringResult.success(
          finalOffsetArcsec: 3, iterations: 2, iterationHistory: const []));
      await tester.pump();
      expect(find.text('Target centered'), findsOneWidget);
      expect(find.text('Abort'), findsNothing);
      await tester.tap(find.byTooltip('Restore centering'));
      await tester.pumpAndSettle();
      expect(find.text('Target Centering'), findsOneWidget);
      expect(service.starts, 1);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Other page'), findsOneWidget);
      expect(find.byType(CenteringDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'closing a finished card releases the presentation for the next target',
      (tester) async {
    final (service, _) = await launch(tester);
    service.result.complete(CenteringResult.failure(
        errorMessage: 'No plate solution',
        iterations: 1,
        iterationHistory: const []));
    await tester.pump();
    expect(find.text('No plate solution'), findsOneWidget);
    await tester.tap(find.byTooltip('Close centering'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open centering'));
    await tester.pumpAndSettle();
    expect(find.text('Target Centering'), findsOneWidget);
    expect(find.text('No plate solution'), findsNothing);
    expect(service.starts, 1);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
  });

  testWidgets('minimized Abort remains available and prevents duplicate stops',
      (tester) async {
    final (service, _) = await launch(tester);
    await tester.tap(find.text('Abort'));
    await tester.pump();
    await tester.tap(find.text('Abort'));
    expect(service.stops, 1);
    expect(find.text('Stopping…'), findsOneWidget);
    service.stopped.complete();
    service.result.complete(CenteringResult.failure(
        errorMessage: 'Aborted by user',
        iterations: 1,
        iterationHistory: const []));
    await tester.pump();
    expect(find.text('Aborted by user'), findsOneWidget);
    await tester.tap(find.byTooltip('Close centering'));
    await tester.pumpAndSettle();
    expect(find.byType(CenteringDialog), findsNothing);
  });

  testWidgets(
      'changing host dismisses minimized centering without popping the page',
      (tester) async {
    final (service, backend) = await launch(tester);
    await tester.tap(find.text('Navigate'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    backend.replace(mockBackend());
    await tester.pump();
    expect(find.byType(CenteringDialog), findsNothing);
    expect(find.text('Other page'), findsOneWidget);
    service.report(message: 'Late update from old host');
    service.result.complete(CenteringResult.failure(
        errorMessage: 'Host changed',
        iterations: 1,
        iterationHistory: const []));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
