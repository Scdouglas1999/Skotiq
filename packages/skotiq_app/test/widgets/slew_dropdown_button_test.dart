import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/models/command_action_result.dart';
import 'package:skotiq_app/services/mount_command_service.dart';
import 'package:skotiq_app/widgets/slew_dropdown_button.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../harness/harness.dart';

class _ConnectedMountNotifier extends MountStateNotifier {
  _ConnectedMountNotifier(super.ref) {
    state = const MountState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'mount-1',
      deviceName: 'Test Mount',
    );
  }
}

class _SwitchableBackendNotifier extends BackendNotifier {
  _SwitchableBackendNotifier(super.ref, SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }

  void replaceBackend(SkotiqBackend backend) => state = backend;
}

/// Settings with a real observing site so the horizon gate has something to
/// compute against. [horizonFloorDeg] is Settings → Location → effective
/// horizon.
class _SiteSettingsNotifier extends AppSettingsNotifier {
  _SiteSettingsNotifier({this.horizonFloorDeg = 0.0});

  final double horizonFloorDeg;

  @override
  Future<AppSettingsState> build() async => AppSettingsState(
        latitude: 45,
        longitude: 0,
        effectiveHorizonDeg: horizonFloorDeg,
      );
}

class _FailingSiteSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() =>
      Future.error(StateError('settings unavailable'));
}

class _ControlledMountService extends MountCommandService {
  _ControlledMountService(super.ref);

  final result = Completer<CommandActionResult>();
  int calls = 0;

  @override
  Future<CommandActionResult> slewTo(
    double ra,
    double dec, {
    bool showFeedback = true,
  }) {
    calls++;
    return result.future;
  }
}

Widget _harness({required bool mountConnected, double width = 220}) {
  return ProviderScope(
    overrides: [
      if (mountConnected)
        mountStateProvider.overrideWith((ref) {
          final notifier = MountStateNotifier(ref);
          notifier.setConnecting('test-mount');
          notifier.setConnected();
          return notifier;
        }),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: width,
          child: const SlewDropdownButton(ra: 12, dec: 30),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('the chevron half opens the menu', (tester) async {
    await tester.pumpWidget(_harness(mountConnected: true));

    final visualButton = tester.widget<SkotiqButton>(
      find.byType(SkotiqButton),
    );
    expect(visualButton.onPressed, isNotNull);

    await tester.tap(find.byType(PopupMenuButton<SlewMode>));
    await tester.pumpAndSettle();

    expect(find.text('Slew & Center'), findsOneWidget);
  });

  testWidgets('the primary half slews on ONE click, with no menu',
      (tester) async {
    late _ControlledMountService service;

    await pumpAppScreen(
      tester,
      const SizedBox(
        width: 220,
        child: SlewDropdownButton(ra: 12, dec: 30),
      ),
      extraOverrides: [
        mountStateProvider.overrideWith(_ConnectedMountNotifier.new),
        mountCommandServiceProvider.overrideWith(
          (ref) => service = _ControlledMountService(ref),
        ),
      ],
    );

    await tester.tap(find.widgetWithText(SkotiqButton, 'Slew'));
    await tester.pumpAndSettle();

    expect(service.calls, 1);
    expect(find.text('Slew & Center'), findsNothing,
        reason: 'the primary half must act, not open the alternatives');

    service.result.complete(CommandActionResult.ok);
    await tester.pump();
  });

  testWidgets('centering as the primary mode runs the camera preflight',
      (tester) async {
    _ControlledMountService? service;
    await pumpAppScreen(
      tester,
      const SizedBox(
          width: 280,
          child: SlewDropdownButton(
              ra: 12, dec: 30, defaultMode: SlewMode.slewAndCenter)),
      extraOverrides: [
        mountStateProvider.overrideWith(_ConnectedMountNotifier.new),
        mountCommandServiceProvider
            .overrideWith((ref) => service = _ControlledMountService(ref)),
      ],
    );
    await tester.tap(find.widgetWithText(SkotiqButton, 'Slew & Center'));
    await tester.pumpAndSettle();
    expect(find.text('Connect an imaging camera before using Slew & Center.'),
        findsOneWidget);
    expect(service, isNull);
  });

  testWidgets('the chevron half meets the design system touch minimum',
      (tester) async {
    await tester.pumpWidget(_harness(mountConnected: true));

    // Splitting the control made the chevron the ONLY route to Slew & Center
    // and Slew, Center & Rotate, so it is a first-class control and owes
    // SkotiqTokens.minTouchTarget (48dp — see the token's own comment) in
    // both axes. Padding it to 28x36 is not a touch target.
    final chevron = tester.getSize(find.byType(PopupMenuButton<SlewMode>));
    expect(
      chevron.width,
      greaterThanOrEqualTo(SkotiqTokens.minTouchTarget),
    );
    expect(
      chevron.height,
      greaterThanOrEqualTo(SkotiqTokens.minTouchTarget),
    );
  });

  testWidgets('both halves fit the narrow half-row mount_tab gives them',
      (tester) async {
    // mount_tab.dart:431 puts this in one Expanded half of a Row beside Sync;
    // on a 360dp phone that is ~158dp. The chevron grew when it was split out,
    // so the primary half has to survive the loss.
    await tester.pumpWidget(_harness(mountConnected: true, width: 158));

    expect(tester.takeException(), isNull);
    expect(find.widgetWithText(SkotiqButton, 'Slew'), findsOneWidget);
  });

  testWidgets('disconnected popup trigger paints as disabled', (tester) async {
    await tester.pumpWidget(_harness(mountConnected: false));

    final visualButton = tester.widget<SkotiqButton>(
      find.byType(SkotiqButton),
    );
    final popup = tester.widget<PopupMenuButton<SlewMode>>(
      find.byType(PopupMenuButton<SlewMode>),
    );
    expect(visualButton.onPressed, isNull);
    expect(popup.enabled, isFalse);
  });

  // SkotiqButton's rendered text can merge into its semantic label, so
  // match the primary action by prefix.
  testWidgets('both halves publish a named button node', (tester) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(_harness(mountConnected: true));

    final slew = tester.getSemantics(find.bySemanticsLabel(RegExp(r'^Slew')));
    expect(slew.label, contains('Slew'));
    expect(
      slew,
      isSemantics(
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );

    expect(
      tester.getSemantics(find.bySemanticsLabel('More slew options')),
      isSemantics(
        label: 'More slew options',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('publishes the disabled state when the mount is down',
      (tester) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(_harness(mountConnected: false));

    expect(
      tester.getSemantics(find.bySemanticsLabel(RegExp(r'^Slew'))),
      isSemantics(
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
      ),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('More slew options')),
      isSemantics(
        isButton: true,
        hasEnabledState: true,
        isEnabled: false,
      ),
    );
    handle.dispose();
  });

  testWidgets('slew is single-flight and old-host completion is discarded',
      (tester) async {
    final backendA = mockBackend();
    final backendB = mockBackend();
    late _SwitchableBackendNotifier backendNotifier;
    late _ControlledMountService serviceA;
    late _ControlledMountService serviceB;

    await pumpAppScreen(
      tester,
      const SizedBox(
        width: 220,
        child: SlewDropdownButton(ra: 12, dec: 30),
      ),
      backend: backendA,
      extraOverrides: [
        backendProvider.overrideWith(
          (ref) => backendNotifier = _SwitchableBackendNotifier(ref, backendA),
        ),
        mountStateProvider.overrideWith(_ConnectedMountNotifier.new),
        mountCommandServiceProvider.overrideWith((ref) {
          final backend = ref.watch(backendProvider);
          final service = _ControlledMountService(ref);
          if (identical(backend, backendA)) {
            serviceA = service;
          } else {
            serviceB = service;
          }
          return service;
        }),
      ],
    );

    await tester.tap(find.widgetWithText(SkotiqButton, 'Slew'));
    await tester.pump();
    expect(find.text('Working...'), findsOneWidget);
    expect(serviceA.calls, 1);

    backendNotifier.replaceBackend(backendB);
    await tester.pump();
    expect(
      find.widgetWithText(SkotiqButton, 'Slew'),
      findsOneWidget,
    );

    serviceA.result.complete(
      const CommandActionResult.success(message: 'Old host slew complete'),
    );
    await tester.pump();
    expect(find.text('Old host slew complete'), findsNothing);

    await tester.tap(find.widgetWithText(SkotiqButton, 'Slew'));
    await tester.pump();
    expect(serviceB.calls, 1);
    serviceB.result.complete(CommandActionResult.ok);
    await tester.pump();
  });

  group('horizon gate', () {
    // Declinations chosen so the answer does not depend on the wall clock.
    // From latitude +45°, Dec −80° can never rise above −35°, and Dec +85° is
    // circumpolar between +40° and +50°.
    const belowHorizonDec = -80.0;
    const alwaysUpDec = 85.0;

    Future<_ControlledMountService> pumpSlew(
      WidgetTester tester, {
      required double dec,
      double horizonFloorDeg = 0.0,
    }) async {
      final handle = await pumpAppScreen(
        tester,
        SizedBox(
          width: 220,
          child: SlewDropdownButton(ra: 12, dec: dec, targetName: 'NGC 7000'),
        ),
        extraOverrides: [
          appSettingsProvider.overrideWith(
            () => _SiteSettingsNotifier(horizonFloorDeg: horizonFloorDeg),
          ),
          mountStateProvider.overrideWith(_ConnectedMountNotifier.new),
          mountCommandServiceProvider.overrideWith(
            (ref) => _ControlledMountService(ref),
          ),
        ],
      );
      return handle.container.read(mountCommandServiceProvider)
          as _ControlledMountService;
    }

    Future<void> chooseSlew(WidgetTester tester) async {
      await tester.tap(find.widgetWithText(SkotiqButton, 'Slew'));
      await tester.pumpAndSettle();
    }

    testWidgets('a below-horizon target is not dispatched without a confirm',
        (tester) async {
      final service = await pumpSlew(tester, dec: belowHorizonDec);

      await chooseSlew(tester);

      expect(find.text('Target is below the horizon'), findsOneWidget);
      expect(service.calls, 0);

      await tester.tap(find.widgetWithText(SkotiqButton, 'Cancel'));
      await tester.pumpAndSettle();

      // Refused: nothing was sent, and the control is not stuck working.
      expect(service.calls, 0);
      expect(find.widgetWithText(SkotiqButton, 'Slew'), findsOneWidget);
    });

    testWidgets('confirming the horizon warning sends the slew',
        (tester) async {
      final service = await pumpSlew(tester, dec: belowHorizonDec);

      await chooseSlew(tester);
      await tester.tap(find.widgetWithText(SkotiqButton, 'Slew anyway'));
      await tester.pumpAndSettle();

      expect(service.calls, 1);
      service.result.complete(CommandActionResult.ok);
      await tester.pump();
    });

    testWidgets('a target that is up slews with no prompt at all',
        (tester) async {
      final service = await pumpSlew(tester, dec: alwaysUpDec);

      await chooseSlew(tester);

      expect(find.text('Target is below the horizon'), findsNothing);
      expect(find.text('Target is below your horizon limit'), findsNothing);
      expect(service.calls, 1);
      service.result.complete(CommandActionResult.ok);
      await tester.pump();
    });

    testWidgets('the configured horizon floor is enforced above 0 degrees',
        (tester) async {
      final service =
          await pumpSlew(tester, dec: alwaysUpDec, horizonFloorDeg: 60);

      await chooseSlew(tester);

      // Above the ground but under the site's effective horizon.
      expect(find.text('Target is below your horizon limit'), findsOneWidget);
      expect(service.calls, 0);
    });

    testWidgets('Slew & Center is gated too, not just the plain slew',
        (tester) async {
      final service = await pumpSlew(tester, dec: belowHorizonDec);

      await tester.tap(find.byType(PopupMenuButton<SlewMode>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Slew & Center'));
      await tester.pumpAndSettle();

      expect(find.text('Target is below the horizon'), findsOneWidget);
      expect(service.calls, 0);

      await tester.tap(find.widgetWithText(SkotiqButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(service.calls, 0);
    });

    testWidgets('a settings failure blocks the slew', (tester) async {
      final handle = await pumpAppScreen(
        tester,
        const SizedBox(
          width: 220,
          child: SlewDropdownButton(ra: 12, dec: alwaysUpDec),
        ),
        extraOverrides: [
          appSettingsProvider.overrideWith(_FailingSiteSettingsNotifier.new),
          mountStateProvider.overrideWith(_ConnectedMountNotifier.new),
          mountCommandServiceProvider.overrideWith(
            (ref) => _ControlledMountService(ref),
          ),
        ],
      );
      final service = handle.container.read(mountCommandServiceProvider)
          as _ControlledMountService;

      await chooseSlew(tester);

      expect(service.calls, 0);
      expect(find.textContaining('Slew was not sent'), findsOneWidget);
    });
  });
}
