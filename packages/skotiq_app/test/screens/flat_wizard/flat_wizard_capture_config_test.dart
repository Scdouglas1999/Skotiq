import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/flat_wizard/flat_wizard_screen.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../../harness/harness.dart';

/// The wizard commanded a gain/offset the operator could not see anywhere, so a
/// flat run at offset 10 against lights at offset 50 produced a whole library
/// the matcher then refused ("gain, offset, and binning must match exactly").
class _FixedFlatConfig extends FlatCameraConfigNotifier {
  _FixedFlatConfig(super.ref, FlatCaptureConfig fixed) {
    // ignore: invalid_use_of_protected_member
    super.state = fixed;
    _pinned = true;
  }

  /// The real notifier re-resolves against the connected camera on
  /// construction; pin it so the test drives exactly the config under test.
  bool _pinned = false;

  @override
  set state(FlatCaptureConfig value) {
    if (_pinned) return;
    super.state = value;
  }
}

Future<void> _pump(
  WidgetTester tester, {
  required FlatCaptureConfig config,
  required ExposureSettings lights,
}) async {
  await pumpAppScreen(
    tester,
    const FlatWizardScreen(),
    size: const Size(1280, 900),
    settle: false,
    extraOverrides: [
      flatCameraConfigProvider.overrideWith(
        (ref) => _FixedFlatConfig(ref, config),
      ),
      exposureSettingsProvider.overrideWith((ref) => lights),
    ],
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

const _lights = ExposureSettings(exposureTime: 120, gain: 100, offset: 50);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the wizard shows the gain/offset/binning it will command',
      (tester) async {
    await _pump(
      tester,
      config: const FlatCaptureConfig(
        gain: 100,
        offset: 50,
        canSetGain: true,
        canSetOffset: true,
      ),
      lights: _lights,
    );

    // The run-on mono line became a KeyValueList: each value is its own
    // Text, keyed by its own label.
    expect(find.text('Gain'), findsWidgets);
    expect(find.text('100'), findsWidgets);
    expect(find.text('Offset'), findsWidgets);
    expect(find.text('50'), findsWidgets);
    expect(find.text('Binning'), findsWidgets);
    expect(find.text('1×1'), findsWidgets);
  });

  testWidgets('a flat/light offset divergence is called out', (tester) async {
    await _pump(
      tester,
      config: const FlatCaptureConfig(
        gain: 100,
        offset: 10,
        canSetGain: true,
        canSetOffset: true,
      ),
      lights: _lights,
    );

    expect(find.text('Gain'), findsWidgets);
    expect(find.text('100'), findsWidgets);
    expect(find.text('10'), findsWidgets);
    expect(
      find.textContaining(
          'Camera settings differ from current light settings'),
      findsWidgets,
    );
    expect(find.textContaining('offset 10 vs 50'), findsWidgets);
  });

  testWidgets('matching settings raise no warning', (tester) async {
    await _pump(
      tester,
      config: const FlatCaptureConfig(
        gain: 100,
        offset: 50,
        canSetGain: true,
        canSetOffset: true,
      ),
      lights: _lights,
    );

    expect(
      find.textContaining(
          'Camera settings differ from current light settings'),
      findsNothing,
    );
  });

  testWidgets('a camera without gain or offset is not described as a DSLR',
      (tester) async {
    await _pump(
      tester,
      config: const FlatCaptureConfig(
        sensitivity: GainSensitivity(hasGain: false, hasOffset: false),
        capabilitiesKnown: true,
      ),
      lights: _lights,
    );

    expect(find.textContaining('ISO'), findsNothing);
    expect(find.text('Gain'), findsNothing);
    expect(find.text('Offset'), findsNothing);
    expect(find.text('Every filter uses these.'), findsOneWidget);
  });

  testWidgets('a gain camera without offset names only its gain',
      (tester) async {
    await _pump(
      tester,
      config: const FlatCaptureConfig(
        gain: 100,
        canSetGain: true,
        sensitivity: GainSensitivity(hasOffset: false),
        capabilitiesKnown: true,
      ),
      lights: _lights,
    );

    expect(find.textContaining('ISO'), findsNothing);
    expect(find.text('Offset'), findsNothing);
    expect(
      find.text('Every filter uses these unless its own gain is set above.'),
      findsOneWidget,
    );
  });
}
