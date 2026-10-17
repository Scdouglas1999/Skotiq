import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/imaging/widgets/calibration_section.dart';
import 'package:skotiq_app/screens/imaging/widgets/panel_widgets.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _SwitchingBackendNotifier extends BackendNotifier {
  _SwitchingBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void replaceWith(SkotiqBackend backend) => state = backend;
}

class _RecordingDefectMapService extends DefectMapService {
  _RecordingDefectMapService(super.ref);

  final directories = <String?>[];

  @override
  Future<DefectMapStatus> build({
    required String cameraId,
    required List<String> darkFramePaths,
    required double sensorTemperatureCelsius,
    String? darkFramesDirectory,
  }) async {
    directories.add(darkFramesDirectory);
    return DefectMapStatus(
      cameraId: cameraId,
      width: 100,
      height: 100,
      temperatureBucket: DefectMapTemperatureBucket.fromCelsius(
        sensorTemperatureCelsius,
      ),
      defectivePixelCount: 7,
      lastRebuiltUnixSeconds: 0,
      applyDuringCapture: false,
      storedOnDisk: true,
    );
  }
}

Widget _surface(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => DefectMapBuildButton(
            colors: SkotiqColors.of(context),
            enabled: true,
            disabledReason: null,
            cameraId: 'camera',
            temperatureC: -10,
            isRemoteMode: true,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets(
      'host change unlocks dark selection and rejects the old host directory',
      (tester) async {
    final firstPicker = Completer<String?>();
    final secondPicker = Completer<String?>();
    var pickerCalls = 0;
    late _SwitchingBackendNotifier backendNotifier;
    late _RecordingDefectMapService service;
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith((ref) {
          return backendNotifier =
              _SwitchingBackendNotifier(ref, _MockNetworkBackend());
        }),
        defectMapServiceProvider.overrideWith((ref) {
          return service = _RecordingDefectMapService(ref);
        }),
        defectMapHostDarkPickerProvider.overrideWithValue((context) {
          pickerCalls++;
          return pickerCalls == 1 ? firstPicker.future : secondPicker.future;
        }),
      ],
    );
    addTearDown(container.dispose);
    container.read(backendProvider);
    container.read(defectMapServiceProvider);

    await tester.pumpWidget(_surface(container));
    var buildButton = tester.widget<SmallButton>(find.byType(SmallButton));
    expect(buildButton.isEnabled, isTrue);

    await tester.tap(find.byType(SmallButton));
    await tester.pump();
    buildButton = tester.widget<SmallButton>(find.byType(SmallButton));
    expect(buildButton.label, 'Selecting dark frames...');
    expect(buildButton.isEnabled, isFalse);

    await tester.tap(find.byType(SmallButton), warnIfMissed: false);
    expect(pickerCalls, 1);

    backendNotifier.replaceWith(_MockNetworkBackend());
    await tester.pump();
    buildButton = tester.widget<SmallButton>(find.byType(SmallButton));
    expect(buildButton.isEnabled, isTrue);

    firstPicker.complete('/host-a/darks');
    await tester.pump();
    expect(service.directories, isEmpty);

    await tester.tap(find.byType(SmallButton));
    await tester.pump();
    secondPicker.complete('/host-b/darks');
    await tester.pump();
    await tester.pump();

    expect(service.directories, ['/host-b/darks']);
    expect(
      find.textContaining('Defect map built: 7 defective pixels'),
      findsOneWidget,
    );
  });
}
