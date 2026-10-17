import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/calibration_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

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

  testWidgets('calibration picker is single-flight and host-authoritative',
      (tester) async {
    final picks = <Completer<String?>>[
      Completer<String?>(),
      Completer<String?>(),
    ];
    var pickerCalls = 0;
    final writes = <(CalibrationFileType, String)>[];

    final handle = await pumpAppScreen(
      tester,
      const CalibrationFileBrowseButton(
        fileType: CalibrationFileType.flat,
        currentPath: '/master-flat.fits',
      ),
      extraOverrides: [
        backendProvider.overrideWith(
          (ref) => _SwappableBackendNotifier(ref, DisconnectedBackend()),
        ),
        calibrationFilePickerProvider.overrideWithValue(
          (context,
              {required fileType, required isRemote, required currentPath}) {
            return picks[pickerCalls++].future;
          },
        ),
        calibrationFileWriterProvider.overrideWithValue(
          (fileType, path) async => writes.add((fileType, path)),
        ),
      ],
    );

    await tester.tap(find.widgetWithText(SkotiqButton, 'Browse'));
    await tester.tap(find.widgetWithText(SkotiqButton, 'Browse'));
    await tester.pump();
    expect(pickerCalls, 1);
    expect(find.text('Selecting...'), findsOneWidget);

    final backendNotifier = handle.container.read(backendProvider.notifier)
        as _SwappableBackendNotifier;
    backendNotifier.swap(DisconnectedBackend());
    await tester.pump();
    expect(find.text('Browse'), findsOneWidget);

    picks.first.complete('/old-host-flat.fits');
    await tester.pump();
    await tester.pump();
    expect(writes, isEmpty);

    await tester.tap(find.widgetWithText(SkotiqButton, 'Browse'));
    await tester.pump();
    picks[1].complete('/current-host-flat.fits');
    await tester.pump();
    await tester.pump();

    expect(
      writes,
      [(CalibrationFileType.flat, '/current-host-flat.fits')],
    );
    expect(find.text('Browse'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('calibration picker completion after disposal is ignored',
      (tester) async {
    final pick = Completer<String?>();
    final writes = <String>[];
    await pumpAppScreen(
      tester,
      const CalibrationFileBrowseButton(
        fileType: CalibrationFileType.dark,
        currentPath: null,
      ),
      extraOverrides: [
        calibrationFilePickerProvider.overrideWithValue(
          (context,
                  {required fileType,
                  required isRemote,
                  required currentPath}) =>
              pick.future,
        ),
        calibrationFileWriterProvider.overrideWithValue(
          (fileType, path) async => writes.add(path),
        ),
      ],
    );

    await tester.tap(find.widgetWithText(SkotiqButton, 'Browse'));
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

    pick.complete('/late-dark.fits');
    await tester.pump();
    await tester.pump();

    expect(writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('calibration picker errors are visible and retryable',
      (tester) async {
    await pumpAppScreen(
      tester,
      const CalibrationFileBrowseButton(
        fileType: CalibrationFileType.bias,
        currentPath: null,
      ),
      extraOverrides: [
        calibrationFilePickerProvider.overrideWithValue(
          (context,
                  {required fileType,
                  required isRemote,
                  required currentPath}) async =>
              throw StateError('picker unavailable'),
        ),
      ],
    );

    await tester.tap(find.widgetWithText(SkotiqButton, 'Browse'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('picker unavailable'), findsOneWidget);
    expect(find.text('Browse'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
