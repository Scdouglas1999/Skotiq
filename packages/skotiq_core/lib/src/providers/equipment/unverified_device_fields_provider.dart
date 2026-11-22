import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../backend/bridge_event_codec.dart' show equipmentEventOf;
import '../../backend/bridge_events.dart';
import '../../models/backend/backend_types.dart';
import '../backend_provider.dart';

/// The `PropertyChanged` property the read-only connect check reports under.
/// Its value is the comma-separated fields it could not verify.
const String unverifiedDeviceProperty = 'Unverified';

/// The fields the read-only connect check could not verify, per device id:
/// what Skotiq shows for them is the device's own report, which disagreed
/// with another source at connect (a recorded position, the mount's clock or
/// site, its pier side against the hour angle, the cooler against its
/// set-point). A device's entry ends when it connects again or disconnects;
/// a later check that agrees reports nothing.
///
/// A window that links to its host after the check ran does not learn of it.
final unverifiedDeviceFieldsProvider =
    NotifierProvider<UnverifiedDeviceFields, Map<String, List<String>>>(
      UnverifiedDeviceFields.new,
    );

class UnverifiedDeviceFields extends Notifier<Map<String, List<String>>> {
  @override
  Map<String, List<String>> build() {
    final subscription = ref.watch(backendProvider).eventStream.listen(_follow);
    ref.onDispose(subscription.cancel);
    return const {};
  }

  void _follow(SkotiqEvent event) {
    switch (equipmentEventOf(event)) {
      case EquipmentEvent_PropertyChanged(
            :final deviceId,
            :final property,
            :final value,
          )
          when property == unverifiedDeviceProperty:
        final fields = [
          for (final field in value.split(','))
            if (field.trim().isNotEmpty) field.trim(),
        ];
        if (fields.isEmpty) return;
        state = Map<String, List<String>>.unmodifiable({
          ...state,
          deviceId: List<String>.unmodifiable(fields),
        });
      case EquipmentEvent_Connecting(:final deviceId) ||
              EquipmentEvent_Connected(:final deviceId) ||
              EquipmentEvent_Disconnected(:final deviceId)
          when state.containsKey(deviceId):
        state = Map<String, List<String>>.unmodifiable(
          {...state}..remove(deviceId),
        );
      default:
    }
  }
}

/// The sentence a device card shows for [fields] the connect check of a
/// [noun] (camera, mount, ...) could not verify.
String unverifiedDeviceText(String noun, List<String> fields) =>
    'Not verified at connect: ${fields.join(', ')}. The $noun\'s report '
    'disagreed with what Skotiq recorded or measured; Skotiq shows the '
    'report and changed nothing. Check the $noun itself; the Log has both '
    'values.';
