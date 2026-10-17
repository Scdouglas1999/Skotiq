import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/imaging/tabs/mount_tab.dart';
import 'package:skotiq_app/widgets/slew_dropdown_button.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/harness.dart';

const _mountId = 'simulator:mount:0';

class _ConnectedMountNotifier extends MountStateNotifier {
  _ConnectedMountNotifier(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const MountState(
      connectionState: DeviceConnectionState.connected,
      deviceId: _mountId,
      deviceName: 'Simulated Mount',
      isParked: false,
      isTracking: true,
    );
  }
}

List<Override> _connectedOverrides(MountCapabilities caps) => [
      mountStateProvider.overrideWith(_ConnectedMountNotifier.new),
      equipmentMountCapabilitiesProvider(_mountId)
          .overrideWith((ref) async => caps),
    ];

Finder _pulseButton(IconData icon) => find.ancestor(
      of: find.byIcon(icon),
      matching: find.byType(InkWell),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('coordinate edits immediately rebuild the slew payload',
      (tester) async {
    await pumpAppScreen(tester, const MountTab());

    expect(find.byType(SlewDropdownButton), findsNothing);

    await tester.enterText(
      find.widgetWithText(SkotiqTextField, 'RA'),
      '05:30:00',
    );
    await tester.enterText(
      find.widgetWithText(SkotiqTextField, 'Dec'),
      '-20:15:00',
    );
    await tester.pump();

    final slew = tester.widget<SlewDropdownButton>(
      find.byType(SlewDropdownButton),
    );
    expect(slew.ra, closeTo(5.5, 1e-9));
    expect(slew.dec, closeTo(-20.25, 1e-9));

    await tester.enterText(
      find.widgetWithText(SkotiqTextField, 'RA'),
      'not coordinates',
    );
    await tester.pump();

    expect(find.byType(SlewDropdownButton), findsNothing);
  });

  testWidgets('Sync is disabled while the mount is disconnected',
      (tester) async {
    await pumpAppScreen(tester, const MountTab());

    await tester.enterText(
      find.widgetWithText(SkotiqTextField, 'RA'),
      '5.5',
    );
    await tester.enterText(
      find.widgetWithText(SkotiqTextField, 'Dec'),
      '-20.25',
    );
    await tester.pump();

    final sync = tester.widget<SkotiqButton>(
      find.widgetWithText(SkotiqButton, 'Sync'),
    );
    expect(sync.onPressed, isNull);
  });

  testWidgets('pulse-guide controls are disabled while disconnected',
      (tester) async {
    await pumpAppScreen(tester, const MountTab());

    expect(find.text('Connect a mount to send guide corrections.'),
        findsOneWidget);
    final north = tester.widget<InkWell>(
      _pulseButton(SkotiqIcons.chevronUp),
    );
    expect(north.onTap, isNull);
  });

  testWidgets('GoTo is disabled when the connected mount cannot slew',
      (tester) async {
    await pumpAppScreen(
      tester,
      const MountTab(),
      extraOverrides: _connectedOverrides(
        const MountCapabilities(canSync: true, canPulseGuide: true),
      ),
    );

    await tester.enterText(
      find.widgetWithText(SkotiqTextField, 'RA'),
      '05:30:00',
    );
    await tester.enterText(
      find.widgetWithText(SkotiqTextField, 'Dec'),
      '-20:15:00',
    );
    await tester.pump();

    final slew = tester.widget<SlewDropdownButton>(
      find.byType(SlewDropdownButton),
    );
    expect(slew.isEnabled, isFalse);
  });

  testWidgets('pulse-guide duration respects the mount capability window',
      (tester) async {
    await pumpAppScreen(
      tester,
      const MountTab(),
      extraOverrides: _connectedOverrides(
        const MountCapabilities(
          canSlew: true,
          canSync: true,
          canPulseGuide: true,
          minPulseGuideMs: 750,
          maxPulseGuideMs: 900,
        ),
      ),
    );

    expect(find.text('750 ms correction pulses'), findsOneWidget);
    final north = tester.widget<InkWell>(
      _pulseButton(SkotiqIcons.chevronUp),
    );
    expect(north.onTap, isNotNull);
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
    testWidgets('Mount tab has no overflow at $label', (tester) async {
      await pumpAppScreen(
        tester,
        const MountTab(),
        size: size,
      );

      expect(tester.takeException(), isNull);
      expect(find.text('Mount status'), findsOneWidget);
      expect(find.text('Go to & sync'), findsOneWidget);
    });
  }
}
