// Widget test for the device-card subtitle line.
//
// When the owning device is in `DeviceConnectionState.error` and a raw driver
// message is available, the subtitle must surface a plain-language headline
// drawn from the connection-troubleshooter knowledge base (NOT the raw string,
// NOT the PrettyError pretty-printer), while the FULL untouched raw message
// remains reachable via the tooltip. When the
// device is healthy it falls back to the descriptive "Main imaging camera"
// blurb. A `Diagnose` affordance is offered only in the error state and only
// when the parent wires an `onDiagnose` callback.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_app/screens/equipment/utils/device_error_subtitle.dart';
import 'package:skotiq_core/skotiq_core.dart';
// The connection-troubleshooter knowledge base is deliberately kept out of the
// skotiq_core barrel; import the source path directly (mirroring
// connection_troubleshooter_dialog.dart and the widget under test).
// ignore: implementation_imports
import 'package:skotiq_core/src/models/troubleshooter/connection_diagnostic.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

SkotiqColors _testColors() {
  // Use the canonical theme so the widget under test gets every color it reads.
  // Fabricating partial SkotiqColors instances is brittle — pull the real
  // one for the dark theme.
  return SkotiqColors.dark;
}

Widget _wrap(Widget child) {
  return MaterialApp(
    // The widget localizes its "Diagnose" label via context.l10n, so the
    // delegate must be installed for the button-bearing cases to resolve.
    localizationsDelegates: SkotiqLocalizations.localizationsDelegates,
    supportedLocales: SkotiqLocalizations.supportedLocales,
    home: Scaffold(
      body: SizedBox(
        // Bound the width so the Flexible inside the widget has a concrete
        // constraint; otherwise Flutter throws in tests.
        width: 320,
        child: child,
      ),
    ),
  );
}

void main() {
  group('DeviceErrorSubtitle', () {
    testWidgets('renders descriptive subtitle when not in error',
        (tester) async {
      await tester.pumpWidget(_wrap(
        DeviceErrorSubtitle(
          descriptiveSubtitle: 'Main imaging camera',
          isError: false,
          errorMessage: null,
          deviceType: DeviceType.camera,
          driverType: DriverType.ascom,
          colors: _testColors(),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Main imaging camera'), findsOneWidget);
      // No tooltip surface when we're not in error mode.
      expect(find.byType(Tooltip), findsNothing);
    });

    testWidgets(
        'ASCOM "class not registered" surfaces the friendly headline, not '
        'the raw string, with the full raw text in the tooltip',
        (tester) async {
      const raw =
          'CoCreateInstance failed: Class not registered (0x80040154) for '
          'ASCOM.MyCamera.Camera';
      await tester.pumpWidget(_wrap(
        DeviceErrorSubtitle(
          descriptiveSubtitle: 'Main imaging camera',
          isError: true,
          errorMessage: raw,
          deviceType: DeviceType.camera,
          driverType: DriverType.ascom,
          colors: _testColors(),
        ),
      ));
      await tester.pumpAndSettle();

      // Descriptive subtitle must be replaced.
      expect(find.text('Main imaging camera'), findsNothing);

      // The raw, hostile string must NOT be the inline label.
      expect(find.text(raw), findsNothing);

      // The friendly classifier headline is rendered. "class not registered"
      // classifies as a driver problem ("The driver isn't responding"). We
      // pin to the exact headline the troubleshooter KB produces so this test
      // fails loudly if the classification regresses.
      final diagnosis = diagnoseConnectionFailure(
        deviceType: DeviceType.camera,
        driverType: DriverType.ascom,
        rawError: raw,
      );
      expect(diagnosis.category, DiagnosticCategory.driver);
      expect(find.text(diagnosis.headline), findsOneWidget);

      // The full untouched raw message must be reachable verbatim via tooltip.
      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(
        tooltip.message,
        raw,
        reason: 'The full untouched raw driver message must survive verbatim '
            'in the tooltip.',
      );
    });

    testWidgets('falls back to descriptive subtitle when errorMessage is empty',
        (tester) async {
      // Defensive: if the state notifier reports error state but the message
      // slot is empty (e.g. a fail-open path we missed), the widget must NOT
      // render a misleading "isError UI" with no content; it falls back to the
      // descriptive subtitle.
      await tester.pumpWidget(_wrap(
        DeviceErrorSubtitle(
          descriptiveSubtitle: 'Main imaging camera',
          isError: true,
          errorMessage: '   ',
          deviceType: DeviceType.camera,
          driverType: DriverType.ascom,
          colors: _testColors(),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Main imaging camera'), findsOneWidget);
      expect(find.byType(Tooltip), findsNothing);
    });

    testWidgets('Diagnose button renders only in the error state',
        (tester) async {
      // Healthy device + onDiagnose wired: no button (and no error UI).
      var diagnoseInvocations = 0;
      await tester.pumpWidget(_wrap(
        DeviceErrorSubtitle(
          descriptiveSubtitle: 'Main imaging camera',
          isError: false,
          errorMessage: null,
          deviceType: DeviceType.camera,
          driverType: DriverType.ascom,
          colors: _testColors(),
          onDiagnose: () => diagnoseInvocations++,
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(SkotiqButton), findsNothing);
      expect(find.text('Diagnose'), findsNothing);

      // Error device + onDiagnose wired: the ghost Diagnose button appears and
      // routes taps to the callback.
      await tester.pumpWidget(_wrap(
        DeviceErrorSubtitle(
          descriptiveSubtitle: 'Main imaging camera',
          isError: true,
          errorMessage:
              'RPC server unavailable (0x800706ba): driver process not running',
          deviceType: DeviceType.camera,
          driverType: DriverType.ascom,
          colors: _testColors(),
          onDiagnose: () => diagnoseInvocations++,
        ),
      ));
      await tester.pumpAndSettle();
      final button = find.byType(SkotiqButton);
      expect(button, findsOneWidget);
      expect(find.text('Diagnose'), findsOneWidget);

      await tester.tap(button);
      await tester.pump();
      expect(diagnoseInvocations, 1);
    });

    testWidgets('no Diagnose button when onDiagnose is null even in error',
        (tester) async {
      await tester.pumpWidget(_wrap(
        DeviceErrorSubtitle(
          descriptiveSubtitle: 'Main imaging camera',
          isError: true,
          errorMessage:
              'RPC server unavailable (0x800706ba): driver process not running',
          deviceType: DeviceType.camera,
          driverType: DriverType.ascom,
          colors: _testColors(),
        ),
      ));
      await tester.pumpAndSettle();
      // Error UI is present (tooltip wraps the headline) but no affordance.
      expect(find.byType(Tooltip), findsOneWidget);
      expect(find.byType(SkotiqButton), findsNothing);
    });

    testWidgets(
        'unknown driver error still surfaces a friendly headline with the raw '
        'text in the tooltip', (tester) async {
      // An error the classifier cannot confidently bucket must still produce a
      // concrete headline rather than a dead end, with the raw text surviving
      // in the tooltip.
      const raw = 'Touptek SDK: device not responding to ping';
      await tester.pumpWidget(_wrap(
        DeviceErrorSubtitle(
          descriptiveSubtitle: 'Main imaging camera',
          isError: true,
          errorMessage: raw,
          deviceType: DeviceType.camera,
          driverType: DriverType.native,
          colors: _testColors(),
        ),
      ));
      await tester.pumpAndSettle();

      final diagnosis = diagnoseConnectionFailure(
        deviceType: DeviceType.camera,
        driverType: DriverType.native,
        rawError: raw,
      );
      // Headline (not the raw string) is shown inline.
      expect(find.text(diagnosis.headline), findsOneWidget);
      expect(find.text(raw), findsNothing);

      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, raw);
    });
  });
}
