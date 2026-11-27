// An autofocus the operator started by hand is told once, by the notification
// router from the sweep's outcome event, with the sweep's HFR.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/bridge_events.dart' as sk;
import 'package:skotiq_core/src/models/imaging/autofocus_request.dart';
import 'package:skotiq_core/src/providers/current_screen_provider.dart';
import 'package:skotiq_core/src/providers/device_service_providers.dart';
import 'package:skotiq_core/src/providers/equipment_provider.dart';
import 'package:skotiq_core/src/providers/notification_router_provider.dart';
import 'package:skotiq_core/src/providers/profiles_provider.dart';
import 'package:skotiq_core/src/providers/settings_provider.dart';
import 'package:skotiq_core/src/providers/ui_notification_provider.dart';
import 'package:skotiq_core/src/models/app_screen.dart';
import 'package:skotiq_core/src/models/backend/backend_types.dart';
import 'package:skotiq_core/src/providers/backend_provider.dart';
import 'package:skotiq_core/src/settings/app_settings_state.g.dart';

void main() {
  for (final screen in [AppScreen.dashboard, AppScreen.imaging]) {
    test('a hand-started autofocus raises one notice on the $screen', () async {
      final backend = _AutofocusBackend();
      addTearDown(backend.close);
      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith((ref) => _Fixed(ref, backend)),
          appSettingsProvider.overrideWith(
            () => _FixedSettings(
              const AppSettingsState(useFilterFocusOffsets: false),
            ),
          ),
          activeEquipmentProfileProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      await container.read(appSettingsProvider.future);
      container.read(notificationRouterProvider);
      container.read(currentScreenProvider.notifier).state = screen;
      container
          .read(cameraStateProvider.notifier)
          .setConnecting('camera-1', 'Camera');
      container.read(cameraStateProvider.notifier).setConnected();
      container
          .read(focuserStateProvider.notifier)
          .setConnecting('focuser-1', 'Focuser');
      container.read(focuserStateProvider.notifier).setConnected();
      container.read(focuserStateProvider.notifier).updatePosition(12000);

      await container
          .read(deviceServiceProvider)
          .runAutofocus(exposureTime: 1, stepSize: 1, stepsOut: 1);
      await pumpEventQueue();

      expect(
        container
            .read(uiNotificationProvider)
            .map((n) => '${n.title} / ${n.message}'),
        ['Autofocus complete / Autofocus run completed (HFR: 1.80).'],
      );
    });
  }
}

class _Fixed extends BackendNotifier {
  _Fixed(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

class _FixedSettings extends AppSettingsNotifier {
  _FixedSettings(this.settings);
  final AppSettingsState settings;

  @override
  Future<AppSettingsState> build() async => settings;
}

/// Runs a sweep the way the native one-shot autofocus does: the outcome goes
/// out as the focuser's `AutofocusFinished` property, then the call returns.
class _AutofocusBackend extends DisconnectedBackend {
  final _events = StreamController<SkotiqEvent>.broadcast();

  @override
  Stream<SkotiqEvent> get eventStream => _events.stream;

  Future<void> close() => _events.close();

  @override
  Future<AutofocusResult> autofocusStart(AutofocusRequest request) async {
    _events.add(
      wireEventFromTyped(
        sk.SkotiqEvent(
          eventId: BigInt.zero,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: sk.EventSeverity.info,
          category: sk.EventCategory.equipment,
          payload: sk.EventPayload.equipment(
            sk.EquipmentEvent.propertyChanged(
              deviceType: 'focuser',
              deviceId: 'focuser-1',
              property: 'AutofocusFinished',
              value: jsonEncode({
                'status': 'Success',
                'message': null,
                'result': {'best_position': 12345, 'best_hfr': 1.8},
                'in_run': false,
              }),
            ),
          ),
        ),
      ),
    );
    await pumpEventQueue();
    return const AutofocusResult(
      bestPosition: 12345,
      bestHfr: 1.8,
      focusData: [],
      method: 'Hyperbolic',
      timestamp: 1,
      curveFitQuality: 0.95,
      backlashApplied: true,
    );
  }
}
