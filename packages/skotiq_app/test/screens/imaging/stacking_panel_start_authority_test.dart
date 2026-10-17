import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/widgets/stacking_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

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

class _RecordingLiveStackingNotifier extends LiveStackingNotifier {
  _RecordingLiveStackingNotifier(super.ref);

  final starts = <String>[];

  @override
  Future<void> startFromFile(
    String referenceImagePath, {
    LiveStackingConfig? config,
  }) async {
    starts.add(referenceImagePath);
  }
}

Future<({ProviderContainer container, _RecordingLiveStackingNotifier stacker})>
    _pumpPanel(
  WidgetTester tester,
  StackingReferencePicker picker,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(420, 1600);
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });

  late _RecordingLiveStackingNotifier stacker;
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      backendProvider.overrideWith(
        (ref) => _SwappableBackendNotifier(ref, DisconnectedBackend()),
      ),
      isRemoteModeProvider.overrideWithValue(false),
      connectedCameraIdProvider.overrideWithValue(null),
      stackingReferencePickerProvider.overrideWithValue(picker),
      liveStackingProvider.overrideWith((ref) {
        stacker = _RecordingLiveStackingNotifier(ref);
        return stacker;
      }),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: StackingPanel(colors: SkotiqColors.dark),
        ),
      ),
    ),
  );
  await tester.pump();
  return (container: container, stacker: stacker);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'reference picker is single-flight and old-host selection is discarded',
      (tester) async {
    final picks = <Completer<XFile?>>[
      Completer<XFile?>(),
      Completer<XFile?>(),
    ];
    var pickerCalls = 0;
    final harness = await _pumpPanel(tester, () {
      return picks[pickerCalls++].future;
    });

    await tester.tap(find.text('Start stacking'));
    await tester.tap(find.text('Start stacking'));
    await tester.pump();
    expect(pickerCalls, 1);
    expect(find.text('Starting...'), findsOneWidget);

    final backendNotifier = harness.container.read(backendProvider.notifier)
        as _SwappableBackendNotifier;
    backendNotifier.swap(DisconnectedBackend());
    await tester.pump();
    expect(find.text('Start stacking'), findsOneWidget);

    picks.first.complete(XFile('/old-host-reference.fits'));
    await tester.pump();
    await tester.pump();
    expect(harness.stacker.starts, isEmpty);

    await tester.tap(find.text('Start stacking'));
    await tester.pump();
    expect(pickerCalls, 2);
    picks[1].complete(XFile('/current-host-reference.fits'));
    await tester.pump();
    await tester.pump();

    expect(harness.stacker.starts, ['/current-host-reference.fits']);
    expect(find.text('Start stacking'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing the panel while the reference picker is open is safe',
      (tester) async {
    final pick = Completer<XFile?>();
    final harness = await _pumpPanel(tester, () => pick.future);

    await tester.tap(find.text('Start stacking'));
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

    pick.complete(XFile('/late-reference.fits'));
    await tester.pump();
    await tester.pump();

    expect(harness.stacker.starts, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reference picker failures are actionable and retryable',
      (tester) async {
    var calls = 0;
    await _pumpPanel(tester, () async {
      calls++;
      throw StateError('picker unavailable');
    });

    await tester.tap(find.text('Start stacking'));
    await tester.pump();
    await tester.pump();

    expect(calls, 1);
    expect(find.textContaining('picker unavailable'), findsOneWidget);
    expect(find.text('Start stacking'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
