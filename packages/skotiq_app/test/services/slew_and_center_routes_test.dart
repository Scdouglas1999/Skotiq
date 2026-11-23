// Slew & center has three ways in: the slew button of Framing and Imaging >
// Mount, the planetarium's object popup, and Tonight's Go to. Each press asks
// at most one GoTo question: none for a target that is up, the one
// below-horizon or below-floor warning for a target that is not. No route
// moves the mount before it knows a camera and a plate solver are there to
// center with.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planetarium/planetarium_screen.dart';
import 'package:skotiq_app/screens/planetarium/widgets/full_screen_sky_view.dart';
import 'package:skotiq_app/services/command_action_result.dart';
import 'package:skotiq_app/services/goto_altitude_check.dart';
import 'package:skotiq_app/services/mount_command_service.dart';
import 'package:skotiq_app/widgets/slew_dropdown_button.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../harness/harness.dart';

// From latitude +45, Dec -80 never rises and Dec +85 never sets.
const _belowHorizonDec = -80.0;
const _alwaysUpDec = 85.0;

class _Site extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async =>
      const AppSettingsState(latitude: 45, longitude: 0);
}

class _ConnectedMount extends MountStateNotifier {
  _ConnectedMount(super.ref) {
    state = const MountState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'mount-1',
      deviceName: 'Test Mount',
    );
  }
}

class _ConnectedCamera extends CameraStateNotifier {
  _ConnectedCamera(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const CameraStateSnapshot(
      connectionState: DeviceConnectionState.connected,
    );
  }
}

class _AvailableSolver extends PlateSolveService {
  _AvailableSolver(super.ref);

  @override
  Future<void> ensureSolverAvailable() async {}
}

class _MissingSolver extends PlateSolveService {
  _MissingSolver(super.ref);

  @override
  Future<void> ensureSolverAvailable() async =>
      throw const SolverNotAvailableError('No plate solver is installed.');
}

/// Counts the GoTos that reach the device and ends each at once.
class _CountingMount extends MountCommandService {
  _CountingMount(super.ref);

  int sent = 0;

  @override
  Future<CommandActionResult> sendSlew(
    double ra,
    double dec, {
    bool showFeedback = true,
  }) async {
    sent++;
    return CommandActionResult.ok;
  }
}

class _Asked {
  final questions = <GoToAltitudeQuestion>[];
  bool answer = true;

  Future<bool> call(GoToAltitudeQuestion question) async {
    questions.add(question);
    return answer;
  }
}

enum _Camera { connected, missing }

enum _Solver { available, missing }

List<Override> _rig(
  _Asked asked, {
  _Camera camera = _Camera.connected,
  _Solver solver = _Solver.available,
}) =>
    [
      appSettingsProvider.overrideWith(_Site.new),
      mountStateProvider.overrideWith(_ConnectedMount.new),
      if (camera == _Camera.connected)
        cameraStateProvider.overrideWith(_ConnectedCamera.new),
      activeEquipmentProfileProvider.overrideWithValue(null),
      plateSolveServiceProvider.overrideWith(
        solver == _Solver.available ? _AvailableSolver.new : _MissingSolver.new,
      ),
      mountCommandServiceProvider.overrideWith(_CountingMount.new),
      goToAltitudeAskProvider.overrideWithValue(asked.call),
    ];

int _sent(HarnessHandle handle) =>
    (handle.container.read(mountCommandServiceProvider) as _CountingMount).sent;

Finder get _centeringDialog => find.text('Start centering');

void main() {
  group('slew button (Framing, Imaging > Mount)', () {
    Future<(HarnessHandle, _Asked)> press(
      WidgetTester tester, {
      required double dec,
      _Camera camera = _Camera.connected,
      _Solver solver = _Solver.available,
    }) async {
      final asked = _Asked();
      final handle = await pumpAppScreen(
        tester,
        SizedBox(
          width: 280,
          child: SlewDropdownButton(
            ra: 10,
            dec: dec,
            targetName: 'NGC 7000',
            defaultMode: SlewMode.slewAndCenter,
          ),
        ),
        size: const Size(1280, 900),
        extraOverrides: _rig(asked, camera: camera, solver: solver),
      );
      await tester.tap(find.widgetWithText(SkotiqButton, 'Slew & center'));
      await tester.pumpAndSettle();
      return (handle, asked);
    }

    testWidgets('a target that is up asks nothing and slews once',
        (tester) async {
      final (handle, asked) = await press(tester, dec: _alwaysUpDec);
      expect(asked.questions, isEmpty);
      expect(_sent(handle), 1);
      expect(_centeringDialog, findsOneWidget);
    });

    testWidgets('a target below the horizon asks once', (tester) async {
      final (handle, asked) = await press(tester, dec: _belowHorizonDec);
      expect(asked.questions, hasLength(1));
      expect(
          asked.questions.single.verdict!.kind, GoToAltitudeKind.belowHorizon);
      expect(_sent(handle), 1);
    });

    testWidgets('no camera: nothing moves', (tester) async {
      final (handle, asked) =
          await press(tester, dec: _alwaysUpDec, camera: _Camera.missing);
      expect(_sent(handle), 0);
      expect(asked.questions, isEmpty);
      expect(
        find.text('Connect an imaging camera before using Slew & Center.'),
        findsOneWidget,
      );
    });

    testWidgets('no plate solver: nothing moves', (tester) async {
      final (handle, asked) =
          await press(tester, dec: _alwaysUpDec, solver: _Solver.missing);
      expect(_sent(handle), 0);
      expect(asked.questions, isEmpty);
      expect(find.text('No plate solver is installed.'), findsOneWidget);
    });
  });

  group('planetarium object popup', () {
    // The popup opens on a tap on the sky; the test hands the sky view's tap
    // callback the object, as its hit test does.
    Future<(HarnessHandle, _Asked)> press(
      WidgetTester tester, {
      required double dec,
      _Camera camera = _Camera.connected,
      _Solver solver = _Solver.available,
      bool answer = true,
    }) async {
      final asked = _Asked()..answer = answer;
      final handle = await pumpAppScreen(
        tester,
        const PlanetariumScreen(),
        size: const Size(1400, 900),
        settle: false,
        extraOverrides: _rig(asked, camera: camera, solver: solver),
      );
      await tester.pump();
      final target = DeepSkyObject(
        id: 'NGC7000',
        name: 'North America Nebula',
        coordinates: CelestialCoordinate(ra: 10, dec: dec),
        type: DsoType.emissionNebula,
        magnitude: 4,
        catalogIds: const ['NGC7000'],
      );
      tester
          .widget<FullScreenSkyView>(find.byType(FullScreenSkyView))
          .onObjectTapped!(target, target.coordinates, const Offset(500, 400));
      await tester.pump();
      await tester.tap(find.byType(PopupMenuButton<SlewMode>));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      await tester.tap(find.text('Slew & center').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      return (handle, asked);
    }

    Future<void> unmount(WidgetTester tester, HarnessHandle handle) async {
      await handle.unmount(tester);
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets('a target that is up asks nothing and slews once',
        (tester) async {
      final (handle, asked) = await press(tester, dec: _alwaysUpDec);
      expect(asked.questions, isEmpty);
      expect(_sent(handle), 1);
      expect(_centeringDialog, findsOneWidget);
      await unmount(tester, handle);
    });

    testWidgets('a target below the horizon asks once', (tester) async {
      final (handle, asked) =
          await press(tester, dec: _belowHorizonDec, answer: false);
      expect(asked.questions, hasLength(1));
      expect(_sent(handle), 0);
      await unmount(tester, handle);
    });
  });
}
