// Every GoTo asks once before it points below the horizon or the site's
// altitude floor, and never above it (P7-1). The question is the mount
// service's, so every interactive caller of slewTo meets it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/services/command_action_result.dart';
import 'package:skotiq_app/services/goto_altitude_check.dart';
import 'package:skotiq_app/services/mount_command_service.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';

import '../harness/harness.dart';

const _mountId = 'simulator:mount:0';

// From latitude +45 Dec -80 never rises above -35, and Dec +85 stays between
// +40 and +50, whatever the clock says.
const _belowHorizonDec = -80.0;
const _alwaysUpDec = 85.0;

class _MountNotifier extends MountStateNotifier {
  _MountNotifier(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const MountState(
      connectionState: DeviceConnectionState.connected,
      deviceId: _mountId,
      deviceName: 'Simulated Mount',
    );
  }
}

class _SiteSettings extends AppSettingsNotifier {
  _SiteSettings(this.floorDeg);

  final double floorDeg;

  @override
  Future<AppSettingsState> build() async => AppSettingsState(
        latitude: 45,
        longitude: 0,
        horizonProfileJson: '{"N":$floorDeg,"NE":$floorDeg,"E":$floorDeg,'
            '"SE":$floorDeg,"S":$floorDeg,"SW":$floorDeg,"W":$floorDeg,'
            '"NW":$floorDeg}',
      );
}

class _SlewRecorder extends MountCommandService {
  _SlewRecorder(super.ref);

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(_SlewRecorder, List<GoToAltitudeQuestion>)> pump(
    WidgetTester tester, {
    double floorDeg = 0,
    bool answer = false,
  }) async {
    final asked = <GoToAltitudeQuestion>[];
    final handle = await pumpAppScreen(
      tester,
      const SizedBox.shrink(),
      extraOverrides: [
        appSettingsProvider.overrideWith(() => _SiteSettings(floorDeg)),
        mountStateProvider.overrideWith(_MountNotifier.new),
        mountCommandServiceProvider.overrideWith(_SlewRecorder.new),
        goToAltitudeAskProvider.overrideWithValue((question) async {
          asked.add(question);
          return answer;
        }),
      ],
    );
    return (
      handle.container.read(mountCommandServiceProvider) as _SlewRecorder,
      asked,
    );
  }

  testWidgets('a GoTo above the floor never asks', (tester) async {
    final (mount, asked) = await pump(tester);

    final result = await mount.slewTo(12, _alwaysUpDec, targetName: 'M81');

    expect(asked, isEmpty);
    expect(mount.sent, 1);
    expect(result.isSuccess, isTrue);
  });

  testWidgets('a GoTo below the horizon asks once and is not sent on a no', (
    tester,
  ) async {
    final (mount, asked) = await pump(tester);

    final result = await mount.slewTo(12, _belowHorizonDec, targetName: 'X');

    expect(asked, hasLength(1));
    expect(asked.single.verdict.kind, GoToAltitudeKind.belowHorizon);
    expect(asked.single.targetName, 'X');
    expect(mount.sent, 0);
    expect(result.isSuccess, isFalse);
    expect(result.hasMessage, isFalse, reason: 'a no is not a failure');
  });

  testWidgets('a GoTo under the site floor asks once', (tester) async {
    final (mount, asked) = await pump(tester, floorDeg: 60);

    await mount.slewTo(12, _alwaysUpDec);

    expect(asked, hasLength(1));
    expect(asked.single.verdict.kind, GoToAltitudeKind.belowFloor);
    expect(mount.sent, 0);
  });

  testWidgets('a yes sends the GoTo', (tester) async {
    final (mount, asked) = await pump(tester, answer: true);

    await mount.slewTo(12, _belowHorizonDec);

    expect(asked, hasLength(1));
    expect(mount.sent, 1);
  });

  testWidgets('a second GoTo while the question is open does not stack one', (
    tester,
  ) async {
    final (mount, asked) = await pump(tester, answer: true);

    final first = mount.slewTo(12, _belowHorizonDec);
    final second = await mount.slewTo(12, _belowHorizonDec);
    await first;

    expect(asked, hasLength(1));
    expect(second.isSuccess, isFalse);
    expect(mount.sent, 1);
  });
}
