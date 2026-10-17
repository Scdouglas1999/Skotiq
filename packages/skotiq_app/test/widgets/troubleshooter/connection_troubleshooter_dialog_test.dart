// Widget tests for the connection troubleshooter dialog.
//
// The dialog turns a raw driver error into a friendly diagnosis and an
// ordered remediation playbook. These tests prove it:
//   * renders the diagnosis headline + plain-language explanation,
//   * lists every remediation step with a 1-based number badge,
//   * keeps the raw error hidden until "Technical details" is expanded —
//     available, not shouting,
//   * resolves `show(...)` to `true` on Retry and `false` on Close.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/widgets/troubleshooter/connection_troubleshooter_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
// The C3 knowledge base is intentionally outside the core barrel; import it
// directly to assert against the exact diagnosis the dialog renders.
// ignore: implementation_imports
import 'package:skotiq_core/src/models/troubleshooter/connection_diagnostic.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Future<bool?> _showDialog(
  WidgetTester tester, {
  required DeviceType deviceType,
  required DriverType driverType,
  String? rawError,
}) async {
  bool? result;
  late BuildContext capturedContext;

  await tester.pumpWidget(
    MaterialApp(
      theme: SkotiqTheme.dark,
      home: Builder(
        builder: (context) {
          capturedContext = context;
          return const Scaffold(body: SizedBox.shrink());
        },
      ),
    ),
  );

  // Fire-and-forget; the future completes when the dialog pops.
  unawaited(
    ConnectionTroubleshooterDialog.show(
      capturedContext,
      deviceType: deviceType,
      driverType: driverType,
      rawError: rawError,
    ).then((value) => result = value),
  );

  await tester.pumpAndSettle();
  return result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders the diagnosis headline and plain-language body',
      (tester) async {
    const raw = 'CCD: 0x800706BA The RPC server is unavailable';
    final expected = diagnoseConnectionFailure(
      deviceType: DeviceType.camera,
      driverType: DriverType.ascom,
      rawError: raw,
    );

    await _showDialog(
      tester,
      deviceType: DeviceType.camera,
      driverType: DriverType.ascom,
      rawError: raw,
    );

    expect(find.text('Connection help'), findsOneWidget);
    expect(find.text(expected.headline), findsOneWidget);
    expect(find.text(expected.plainLanguage), findsOneWidget);
  });

  testWidgets('lists every remediation step with a numbered badge',
      (tester) async {
    const raw = 'access is denied';
    final expected = diagnoseConnectionFailure(
      deviceType: DeviceType.camera,
      driverType: DriverType.native,
      rawError: raw,
    );
    expect(expected.steps, isNotEmpty);

    await _showDialog(
      tester,
      deviceType: DeviceType.camera,
      driverType: DriverType.native,
      rawError: raw,
    );

    for (var i = 0; i < expected.steps.length; i++) {
      expect(find.text('${i + 1}'), findsOneWidget);
      expect(find.text(expected.steps[i].instruction), findsOneWidget);
    }
  });

  testWidgets('raw error is hidden until Technical details is expanded',
      (tester) async {
    const raw = 'totally-unique-driver-string-0xDEADBEEF';

    await _showDialog(
      tester,
      deviceType: DeviceType.mount,
      driverType: DriverType.ascom,
      rawError: raw,
    );

    // Collapsed by default: the raw string is not yet in the tree.
    expect(find.text('Technical details'), findsOneWidget);
    expect(find.text(raw), findsNothing);

    // The playbook can push the section below the fold in the test viewport;
    // scroll it into view before tapping.
    await tester.ensureVisible(find.text('Technical details'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Technical details'));
    await tester.pumpAndSettle();

    // The raw error renders verbatim in a selectable monospace block.
    final block = tester.widget<SelectableText>(find.byType(SelectableText));
    expect(block.data, raw);
  });

  testWidgets('Retry resolves the future to true', (tester) async {
    bool? result;
    late BuildContext capturedContext;

    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        home: Builder(
          builder: (context) {
            capturedContext = context;
            return const Scaffold(body: SizedBox.shrink());
          },
        ),
      ),
    );

    unawaited(
      ConnectionTroubleshooterDialog.show(
        capturedContext,
        deviceType: DeviceType.camera,
        driverType: DriverType.ascom,
        rawError: 'class not registered',
      ).then((value) => result = value),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Retry connection'));
    await tester.pumpAndSettle();

    expect(result, isTrue);
  });

  testWidgets('Close resolves the future to false', (tester) async {
    bool? result;
    late BuildContext capturedContext;

    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        home: Builder(
          builder: (context) {
            capturedContext = context;
            return const Scaffold(body: SizedBox.shrink());
          },
        ),
      ),
    );

    unawaited(
      ConnectionTroubleshooterDialog.show(
        capturedContext,
        deviceType: DeviceType.camera,
        driverType: DriverType.ascom,
        rawError: 'class not registered',
      ).then((value) => result = value),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    expect(result, isFalse);
  });

  // The rendered end of the built-in-guider defect: the dialog held a
  // fully-specified first-party error and told the operator "we couldn't pin
  // down the exact cause", then offered four steps for hardware the built-in
  // guider does not have.
  testWidgets('the built-in guider preflight renders the setting, not a cable',
      (tester) async {
    await _showDialog(
      tester,
      deviceType: DeviceType.guider,
      driverType: DriverType.native,
      rawError: 'Failed to connect built-in guider: Operation failed: Built-in '
          'guider requires positive guide focal length and camera pixel size '
          '(focal_length_mm=0, pixel_size_x_um=3.76, pixel_size_y_um=3.76)',
    );

    expect(find.textContaining("couldn't pin down"), findsNothing);
    expect(find.textContaining('Reseat the cable'), findsNothing);
    expect(find.textContaining('Restart Skotiq'), findsNothing);
    expect(
      find.textContaining('Focal Length', findRichText: true),
      findsWidgets,
    );
  });

  testWidgets('a null raw error renders no Technical details section',
      (tester) async {
    // An empty discovery result classifies as USB with concrete steps and no
    // raw string — the technical-details affordance must not appear.
    await _showDialog(
      tester,
      deviceType: DeviceType.focuser,
      driverType: DriverType.native,
      rawError: null,
    );

    expect(find.text('Technical details'), findsNothing);
    expect(find.text('Retry connection'), findsOneWidget);
  });
}
