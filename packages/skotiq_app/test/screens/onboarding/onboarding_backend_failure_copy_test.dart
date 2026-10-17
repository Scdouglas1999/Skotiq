// The first-run device steps must not print a Rust error chain at the user: on
// a machine with no Alpaca server (the shipped default has the backend ON) the
// raw failure is an enum dump, a URL, a Rust error chain and an errno, four
// wrapped red lines twice over on the third screen of the product.
//
// The same block is what pushes the device-picker step into overprinting
// itself, because the picker is handed a fixed-height box and its chrome is
// not fixed.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/onboarding/steps/device_picker_step.dart';
import 'package:skotiq_app/screens/onboarding/steps/filter_wheel_step.dart';
import 'package:skotiq_core/skotiq_core.dart';

const _rawAlpacaError =
    'Alpaca server connection failed: SkotiqError.connectionFailed('
    'deviceId: localhost:11111, reason: Failed to connect to Alpaca server: '
    'error sending request for url '
    '(http://localhost:11111/management/v1/configureddevices): error trying to '
    'connect: tcp connect error: Connection refused (os error 111))';

const _rawIndiError =
    'INDI server connection failed: SkotiqError.connectionFailed('
    'deviceId: localhost:7624, reason: error trying to connect: tcp connect '
    'error: Connection refused (os error 111))';

const _sevenFilters = ['L', 'R', 'G', 'B', 'Ha', 'OIII', 'SII'];
const _footnote =
    'No matching device? You can skip this step and add it later from the '
    'Equipment screen.';

class _FailedBackendsDiscovery extends UnifiedDiscoveryNotifier {
  _FailedBackendsDiscovery(super.ref) {
    state = UnifiedDiscoveryState(
      backendStates: {
        DriverType.alpaca: const BackendDiscoveryState(
          backend: DriverType.alpaca,
          status: DiscoveryStatus.error,
          error: _rawAlpacaError,
        ),
        DriverType.indi: const BackendDiscoveryState(
          backend: DriverType.indi,
          status: DiscoveryStatus.error,
          error: _rawIndiError,
        ),
      },
    );
  }

  @override
  Future<void> discoverAll({
    bool includeIndi = true,
    bool includeAlpaca = true,
  }) async {}
}

/// Same two failed backends, plus the simulated wheel the operator selects.
class _FailedBackendsWithWheel extends _FailedBackendsDiscovery {
  _FailedBackendsWithWheel(super.ref) {
    const info = DeviceInfo(
      id: 'sim-fw',
      name: 'Simulated Filter Wheel',
      deviceType: DeviceType.filterWheel,
      driverType: DriverType.simulator,
      description: 'Sim',
      driverVersion: '1.0',
    );
    state = state.copyWith(
      groupedDevices: const [
        UnifiedDevice(
          canonicalName: 'simulated filter wheel',
          displayName: 'Simulated Filter Wheel',
          type: DeviceType.filterWheel,
          availableBackends: {DriverType.simulator: info},
        ),
      ],
    );
  }
}

class _WheelDraft extends OnboardingNotifier {
  _WheelDraft(super.ref) {
    // ignore: invalid_use_of_protected_member
    state = const OnboardingDraft(
      currentStep: OnboardingStep.filterWheel,
      filterWheelId: 'sim-fw',
      filterWheelName: 'Simulated Filter Wheel',
      filterNames: _sevenFilters,
      selectedDrivers: {
        DriverType.alpaca,
        DriverType.indi,
        DriverType.simulator,
      },
    );
  }
}

class _ConnectedWheel extends FilterWheelStateNotifier {
  _ConnectedWheel(super.ref) {
    state = const FilterWheelState(
      connectionState: DeviceConnectionState.connected,
      deviceId: 'sim-fw',
      deviceName: 'Simulated Filter Wheel',
      filterNames: _sevenFilters,
    );
  }
}

Future<void> _pumpFilterWheelStep(
  WidgetTester tester,
  Size size, {
  bool withWheelListed = false,
}) async {
  final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        onboardingDraftProvider.overrideWith(_WheelDraft.new),
        filterWheelStateProvider.overrideWith(_ConnectedWheel.new),
        unifiedDiscoveryProvider.overrideWith(withWheelListed
            ? _FailedBackendsWithWheel.new
            : _FailedBackendsDiscovery.new),
        activeProfileProvider.overrideWith((ref) => Stream.value(null)),
        allProfilesProvider.overrideWith((ref) => Stream.value(const [])),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: EdgeInsets.all(24),
            child: OnboardingFilterWheelStep(),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

List<String> _renderedText(WidgetTester tester) => tester
    .widgetList<Text>(
      find.byType(Text),
    )
    .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
    .toList();

void main() {
  group('the failure line is human copy', () {
    test('a refused connection names the endpoint, not the error chain', () {
      final described = describeBackendFailure(_rawAlpacaError);
      expect(described, 'nothing is listening at localhost:11111');
      expect(described, isNot(contains('SkotiqError')));
      expect(described, isNot(contains('os error')));
    });

    test('unrecognised transports never leak developer debris', () {
      expect(
        describeBackendFailure('SomeInternalEnum.blewUp(0xdeadbeef)'),
        'the scan did not complete',
      );
      // A backend that already reports a sentence keeps it: flattening that
      // would throw away the only thing anyone knows about the failure.
      expect(
        describeBackendFailure('No Alpaca server answered on this network'),
        'No Alpaca server answered on this network',
      );
      expect(describeBackendFailure(null), 'the scan did not complete');
      expect(
        describeBackendFailure('operation timed out after 5s (10.0.0.4:11111)'),
        '10.0.0.4:11111 did not answer in time',
      );
    });

    testWidgets('no step renders the Rust error chain', (tester) async {
      await _pumpFilterWheelStep(tester, const Size(1600, 900));

      for (final text in _renderedText(tester)) {
        expect(text, isNot(contains('SkotiqError')));
        expect(text, isNot(contains('os error 111')));
        expect(text, isNot(contains('tcp connect')));
        expect(text, isNot(contains('http://')));
      }
      expect(
        find.textContaining('nothing is listening at localhost:11111'),
        findsOneWidget,
      );
    });
  });

  group('step 6 must not paint two texts on top of each other', () {
    for (final size in const [Size(1600, 900), Size(1280, 800)]) {
      testWidgets(
          'filter-wheel step lays out cleanly with two failed backends at '
          '${size.width.toInt()}x${size.height.toInt()}', (tester) async {
        await _pumpFilterWheelStep(tester, size);
        expect(
          tester.takeException(),
          isNull,
          reason: 'the picker overflowed its fixed-height box',
        );

        final caption = find.textContaining('positions on this wheel');
        final footnote = find.text(_footnote);
        expect(caption, findsOneWidget);
        expect(footnote, findsOneWidget);
        expect(
          tester.getRect(footnote).overlaps(tester.getRect(caption)),
          isFalse,
          reason: 'the hint ${tester.getRect(footnote)} overprints the slot '
              'caption ${tester.getRect(caption)}',
        );
      });
    }
  });

  // With the two backend-failure lines present, the just-selected device card
  // is cut through the middle of its subtitle — "Sim" drawn with its lower half
  // missing, no bottom border, and nothing on screen saying the box scrolls (a
  // mouse wheel reveals the rest). The truncated row is the one the operator
  // just chose.
  group('the picker says it scrolls, and shows what was picked', () {
    testWidgets('the device list carries a permanently visible scrollbar', (
      tester,
    ) async {
      await _pumpFilterWheelStep(
        tester,
        const Size(1600, 900),
        withWheelListed: true,
      );

      final scrollbars = tester
          .widgetList<Scrollbar>(find.byType(Scrollbar))
          .where((s) => s.thumbVisibility == true);
      expect(
        scrollbars,
        isNotEmpty,
        reason: 'a box that scrolls with no affordance reads as a paint bug',
      );
    });

    testWidgets('the selected device row is not left clipped', (tester) async {
      await _pumpFilterWheelStep(
        tester,
        const Size(1600, 900),
        withWheelListed: true,
      );
      await tester.pumpAndSettle();

      final row = find.text('Simulated Filter Wheel');
      expect(row, findsWidgets);

      final viewport = tester.getRect(
        find.byType(OnboardingDevicePickerBody).first,
      );
      final card = tester.getRect(row.first);
      expect(
        card.bottom,
        lessThanOrEqualTo(viewport.bottom + 0.5),
        reason: 'the chosen row was drawn half outside the picker box',
      );
      expect(card.top, greaterThanOrEqualTo(viewport.top - 0.5));
    });
  });
}
