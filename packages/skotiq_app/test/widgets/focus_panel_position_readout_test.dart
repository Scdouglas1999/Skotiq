// Truthful position readout for the FocusPanel manual-focus section
// (packages/skotiq_app/lib/screens/imaging/widgets/focus_panel.dart).
//
// The panel must not invent a travel ceiling. When the driver reports a real
// maximum it shows "current / max"; when the max is absent (null) or bogus
// (negative) it shows an honest unknown marker, never a fabricated ceiling nor
// an impossible 0..-1 range.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/imaging/widgets/focus_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockDeviceService extends Mock implements DeviceService {}

/// A focuser notifier pinned to a fixed [FocuserState] so the readout can be
/// driven directly without a live device.
class _FixedFocuserNotifier extends FocuserStateNotifier {
  _FixedFocuserNotifier(super.ref, FocuserState value) {
    state = value;
  }
}

Future<void> _pumpPanel(WidgetTester tester, FocuserState state) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        focuserStateProvider
            .overrideWith((ref) => _FixedFocuserNotifier(ref, state)),
        deviceServiceProvider.overrideWithValue(_MockDeviceService()),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: FocusPanel(colors: SkotiqColors.dark),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('shows current / max when the driver reports a real maximum',
      (tester) async {
    await _pumpPanel(
      tester,
      const FocuserState(
        connectionState: DeviceConnectionState.connected,
        position: 1234,
        maxPosition: 20000,
      ),
    );

    expect(find.text('1234'), findsOneWidget);
    expect(find.text(' / 20000'), findsOneWidget);
    // A fabricated ceiling must never appear.
    expect(find.textContaining('50000'), findsNothing);
  });

  testWidgets('reports an unknown ceiling instead of a fabricated 50000',
      (tester) async {
    await _pumpPanel(
      tester,
      const FocuserState(
        connectionState: DeviceConnectionState.connected,
        position: 1234,
        // Driver never reported a travel limit.
        maxPosition: null,
      ),
    );

    // The current position is still truthful...
    expect(find.text('1234'), findsOneWidget);
    // ...but there is no invented ceiling of any kind, only an honest marker.
    expect(find.textContaining('50000'), findsNothing);
    expect(find.text(' / —'), findsOneWidget);
  });

  testWidgets('treats a negative max as unknown, never an impossible range',
      (tester) async {
    await _pumpPanel(
      tester,
      const FocuserState(
        connectionState: DeviceConnectionState.connected,
        position: 1234,
        // A broken driver can report a nonsensical negative ceiling.
        maxPosition: -1,
      ),
    );

    expect(find.text('1234'), findsOneWidget);
    // No 0..-1 range leaks to the UI.
    expect(find.text(' / -1'), findsNothing);
    expect(find.text(' / —'), findsOneWidget);
  });

  testWidgets('treats a zero max as unknown driver data', (tester) async {
    await _pumpPanel(
      tester,
      const FocuserState(
        connectionState: DeviceConnectionState.connected,
        position: 1234,
        maxPosition: 0,
      ),
    );

    expect(find.text(' / 0'), findsNothing);
    expect(find.text(' / —'), findsOneWidget);
  });

  testWidgets('shows no position or ceiling while disconnected',
      (tester) async {
    await _pumpPanel(tester, const FocuserState());

    // Absent values read as an em dash (05 §3), never the old '---'.
    expect(find.text('\u2014'), findsWidgets);
    expect(find.text('---'), findsNothing);
    expect(find.textContaining('50000'), findsNothing);
  });

  const referenceSizes = <(String, Size)>[
    ('small phone portrait', Size(360, 640)),
    ('small phone landscape', Size(640, 360)),
    ('modern phone portrait', Size(390, 844)),
    ('modern phone landscape', Size(844, 390)),
    ('large phone portrait', Size(430, 932)),
    ('large phone landscape', Size(932, 430)),
  ];
  for (final (label, size) in referenceSizes) {
    testWidgets('focus panel has no overflow at $label', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await _pumpPanel(
        tester,
        const FocuserState(
          connectionState: DeviceConnectionState.connected,
          deviceId: 'focuser-1',
          position: 1234,
          maxPosition: 20000,
          isAbsolute: true,
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Manual focus'), findsOneWidget);
      expect(find.text('Autofocus'), findsOneWidget);
    });
  }
}
