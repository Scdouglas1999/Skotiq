// Go to: a typed object name is looked up by the button pressed, so typing
// "NGC 7331" and pressing Slew goes there without a separate Enter, and RA
// and Dec typed by hand are used as typed.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_app/screens/night_control/panel/mount/mount_go_to.dart';
import 'package:skotiq_app/screens/night_control/panel/mount/night_mount_tab.dart';
import 'package:skotiq_app/services/command_action_result.dart';
import 'package:skotiq_app/services/goto_altitude_check.dart';
import 'package:skotiq_app/services/mount_command_service.dart';

import '../../../../harness/harness.dart';
import '../scope_panel_test_support.dart';

const _name = ValueKey<String>('nightMount.goToName');
const _ra = ValueKey<String>('nightMount.goToRa');
const _dec = ValueKey<String>('nightMount.goToDec');
const _slew = ValueKey<String>('nightMount.slew');
const _slewCenter = ValueKey<String>('nightMount.slewCenter');

class _SlewRecorder extends RecordingMountCommands {
  _SlewRecorder(super.ref);

  final List<(double, double)> slews = [];

  @override
  Future<CommandActionResult> sendSlew(double ra, double dec,
      {bool showFeedback = true}) {
    slews.add((ra, dec));
    return super.sendSlew(ra, dec, showFeedback: showFeedback);
  }
}

/// A site at +45 with a flat horizon: Dec -80 never rises there.
class _Site extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async =>
      const AppSettingsState(latitude: 45, longitude: 0);
}

class _CenterRecorder extends CenteringRun {
  _CenterRecorder(super.ref);

  int runs = 0;

  @override
  Future<CenteringResult?> center({
    required double raHours,
    required double decDegrees,
    double? exposureSeconds,
    CenteringConfig? config,
    bool publishes = true,
    bool Function()? isCurrent,
  }) async {
    runs++;
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(HarnessHandle, List<String>)> pump(WidgetTester tester) async {
    final lookups = <String>[];
    final handle = await pumpPanelTab(
      tester,
      const NightMountTab(),
      overrides: [
        ...panelOverrides(),
        mountCommandServiceProvider.overrideWith(_SlewRecorder.new),
        nightGoToResolverProvider.overrideWithValue((query) async {
          lookups.add(query);
          return query == 'NGC 7331'
              ? const NightGoToTarget(
                  name: 'NGC7331', raHours: 22.618, decDegrees: 34.416)
              : null;
        }),
      ],
    );
    await tester.ensureVisible(find.byKey(_slew));
    await tester.pump();
    return (handle, lookups);
  }

  _SlewRecorder commands(HarnessHandle handle) =>
      handle.container.read(mountCommandServiceProvider) as _SlewRecorder;

  testWidgets('a typed name is looked up when Slew is pressed', (tester) async {
    final (handle, lookups) = await pump(tester);
    expect(isEnabled(tester, _slew), isFalse,
        reason: 'nothing typed, nothing to go to');

    await tester.enterText(find.byKey(_name), 'NGC 7331');
    await tester.pump();
    expect(isEnabled(tester, _slew), isTrue);
    expect(isEnabled(tester, _slewCenter), isTrue);

    await tester.tap(find.byKey(_slew));
    await tester.pumpAndSettle();

    expect(lookups, ['NGC 7331']);
    expect(commands(handle).slews, [(22.618, 34.416)]);
    expect(find.text('NGC7331'), findsOneWidget,
        reason: 'the field shows the object the lookup found');
  });

  testWidgets('a name that finds nothing says so and moves nothing',
      (tester) async {
    final (handle, lookups) = await pump(tester);
    await tester.enterText(find.byKey(_name), 'Nowhere');
    await tester.pump();
    await tester.tap(find.byKey(_slew));
    await tester.pumpAndSettle();

    expect(lookups, ['Nowhere']);
    expect(commands(handle).slews, isEmpty);
    expect(find.textContaining('Nowhere'), findsWidgets);
  });

  testWidgets('RA and Dec typed after a name are used as typed',
      (tester) async {
    final (handle, lookups) = await pump(tester);
    await tester.enterText(find.byKey(_name), 'my field');
    await tester.enterText(find.byKey(_ra), '10h00m00s');
    await tester.enterText(find.byKey(_dec), '+20 00 00');
    await tester.pump();
    await tester.tap(find.byKey(_slew));
    await tester.pumpAndSettle();

    expect(lookups, isEmpty);
    expect(commands(handle).slews, [(10.0, 20.0)]);
  });

  group('below the horizon', () {
    Future<(HarnessHandle, List<GoToAltitudeQuestion>)> pumpSite(
      WidgetTester tester,
    ) async {
      final asked = <GoToAltitudeQuestion>[];
      final handle = await pumpPanelTab(
        tester,
        const NightMountTab(),
        overrides: [
          ...panelOverrides(),
          mountCommandServiceProvider.overrideWith(_SlewRecorder.new),
          appSettingsProvider.overrideWith(_Site.new),
          centeringRunProvider.overrideWith(_CenterRecorder.new),
          goToAltitudeAskProvider.overrideWithValue((question) async {
            asked.add(question);
            return false;
          }),
        ],
      );
      await tester.ensureVisible(find.byKey(_slew));
      await tester.enterText(find.byKey(_ra), '10h00m00s');
      await tester.enterText(find.byKey(_dec), '-80 00 00');
      await tester.pump();
      return (handle, asked);
    }

    testWidgets('Slew asks once and moves nothing on a no', (tester) async {
      final (handle, asked) = await pumpSite(tester);

      await tester.tap(find.byKey(_slew));
      await tester.pumpAndSettle();

      expect(asked, hasLength(1));
      expect(commands(handle).slews, isEmpty);
    });

    testWidgets('Slew & center asks once and runs no centering on a no',
        (tester) async {
      final (handle, asked) = await pumpSite(tester);

      await tester.tap(find.byKey(_slewCenter));
      await tester.pumpAndSettle();

      expect(asked, hasLength(1));
      expect(
        (handle.container.read(centeringRunProvider) as _CenterRecorder).runs,
        0,
      );
    });

    testWidgets('a target that is up asks nothing', (tester) async {
      final (handle, asked) = await pumpSite(tester);
      await tester.enterText(find.byKey(_dec), '+85 00 00');
      await tester.pump();

      await tester.tap(find.byKey(_slew));
      await tester.pumpAndSettle();

      expect(asked, isEmpty);
      expect(commands(handle).slews, hasLength(1));
    });
  });
}
