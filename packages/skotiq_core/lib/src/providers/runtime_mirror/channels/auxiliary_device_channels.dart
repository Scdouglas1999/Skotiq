import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../backend/ffi_backend.dart';
import '../../../models/equipment/equipment_models.dart';
import '../../../services/device_service.dart';
import '../../backend_provider.dart';
import '../../equipment/device_capability_provider.dart';
import '../../equipment/switch_state_provider.dart';
import '../runtime_mirror_channel.dart';
import '../runtime_mirror_codec.dart';

/// The host's cover/calibrator readings, so a client's card shows the
/// device as the host last read it instead of a reading fetched once when
/// the card first opened.
class CoverCalibratorChannel
    extends
        RuntimeMirrorChannel<Map<String, CoverCalibratorCapabilitySnapshot>> {
  const CoverCalibratorChannel();

  @override
  String get key => 'coverCalibrator';

  @override
  get source => liveCoverCalibratorSnapshotsProvider;

  @override
  Map<String, dynamic>? encode(
    Map<String, CoverCalibratorCapabilitySnapshot> value,
  ) => value.isEmpty
      ? null
      : {
          'devices': {
            for (final entry in value.entries) entry.key: entry.value.toJson(),
          },
        };

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    final raw = value?['devices'];
    context.read(liveCoverCalibratorSnapshotsProvider.notifier).state = {
      if (raw is Map)
        for (final entry in raw.entries)
          if (entry.value is Map)
            '${entry.key}': CoverCalibratorCapabilitySnapshot.fromJson(
              entry.value as Map,
            ),
    };
  }
}

/// The host's switch channels (names, on/off, analog values), so a client's
/// switch card follows a channel changed on the host or by another client.
/// The card used to read the channels once when it opened.
class SwitchChannelsChannel extends RuntimeMirrorChannel<SwitchState> {
  const SwitchChannelsChannel();

  @override
  String get key => 'switchChannels';

  @override
  get source => switchStateProvider;

  @override
  Map<String, dynamic>? encode(SwitchState value) {
    final deviceId = value.deviceId;
    if (deviceId == null ||
        value.connectionState != DeviceConnectionState.connected ||
        value.channelCount == 0) {
      return null;
    }
    return {
      'deviceId': deviceId,
      'count': value.channelCount,
      'names': value.channelNames,
      'states': value.channelStates,
      'descriptions': value.channelDescriptions,
      'isBoolean': value.channelIsBoolean,
      'values': [for (final v in value.channelValues) finiteOrNull(v)],
      'minValues': [for (final v in value.channelMinValues) finiteOrNull(v)],
      'maxValues': [for (final v in value.channelMaxValues) finiteOrNull(v)],
      'steps': [for (final v in value.channelSteps) finiteOrNull(v)],
      'canWrite': value.channelCanWrite,
    };
  }

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    if (value == null) return;
    final state = context.read(switchStateProvider);
    // Channels belong to one device; a client that shows another (or none)
    // keeps what it has until its own equipment state catches up.
    if (state.deviceId != jsonString(value['deviceId'])) return;
    // Every list is written by [encode]; a missing or mistyped entry means
    // the two ends disagree, and the update is dropped.
    List<T> listOf<T>(String key) {
      final raw = value[key];
      if (raw is! List) throw FormatException('Switch channels without "$key"');
      return [
        for (final item in raw)
          if (item is T)
            item
          else
            throw FormatException('Switch channel "$key" entry is not a $T'),
      ];
    }

    List<double> doublesOf(String key) => [
      for (final n in listOf<num>(key)) n.toDouble(),
    ];
    context
        .read(switchStateProvider.notifier)
        .setChannels(
          count: requireInt(value, 'count'),
          names: listOf<String>('names'),
          states: listOf<bool>('states'),
          descriptions: listOf<String>('descriptions'),
          isBoolean: listOf<bool>('isBoolean'),
          values: doublesOf('values'),
          minValues: doublesOf('minValues'),
          maxValues: doublesOf('maxValues'),
          steps: doublesOf('steps'),
          canWrite: listOf<bool>('canWrite'),
          refreshedAt: DateTime.now(),
        );
  }
}

/// Host only: re-reads the connected switch's channels every
/// [switchChannelPollInterval]. Nothing native reports a channel change, and
/// one can come from a linked client's command, so the host has to look.
/// After a failed read it waits [switchChannelPollBackoff] before trying
/// again, so a broken driver is not hammered (or reported) every tick.
final switchChannelPollerProvider = Provider<void>((ref) {
  Timer? timer;
  var inFlight = false;
  DateTime? retryAfter;
  void stop() {
    timer?.cancel();
    timer = null;
  }

  ref.onDispose(stop);

  void bind() {
    stop();
    retryAfter = null;
    if (ref.read(backendProvider) is! FfiBackend) return;
    final state = ref.read(switchStateProvider);
    if (state.deviceId == null ||
        state.connectionState != DeviceConnectionState.connected) {
      return;
    }
    timer = Timer.periodic(switchChannelPollInterval, (_) async {
      final wait = retryAfter;
      if (inFlight || (wait != null && DateTime.now().isBefore(wait))) return;
      inFlight = true;
      try {
        await ref.read(deviceServiceProvider).refreshSwitchChannels();
        retryAfter = null;
      } on Object {
        retryAfter = DateTime.now().add(switchChannelPollBackoff);
      } finally {
        inFlight = false;
      }
    });
  }

  ref.listen(backendProvider, (_, __) => bind());
  ref.listen(
    switchStateProvider.select((s) => (s.deviceId, s.connectionState)),
    (_, __) => bind(),
  );
  bind();
});

const Duration switchChannelPollInterval = Duration(seconds: 2);
const Duration switchChannelPollBackoff = Duration(seconds: 30);
