/// The tap payload of a phone notification: `type[:argument]`. The phone
/// writes most of them; a host writes the deep link it pushes (the dawn
/// Darkroom draft), and the phone's route table reads every one.
library;

enum NotificationPayloadType {
  imageReady('image_ready'),
  sequenceComplete('sequence_complete'),
  sequenceFailed('sequence_failed'),
  meridianFlip('meridian_flip'),
  targetCompleted('target_completed'),
  autofocusFailed('autofocus_failed'),
  exposureFailed('exposure_failed'),
  plateSolveFailed('plate_solve_failed'),
  centeringFailed('centering_failed'),
  polarAlignmentFailed('polar_alignment_failed'),
  guidingLost('guiding_lost'),
  safety('safety'),
  equipmentDisconnected('equipment_disconnected'),
  mountFault('mount_fault'),
  lowBattery('low_battery'),
  lowDiskSpace('low_disk_space'),
  ownershipTakenOver('ownership_taken_over'),
  ownershipAutoReleased('ownership_auto_released'),
  darkroomDraft('darkroom_draft'),
  push('push');

  const NotificationPayloadType(this.wire);

  final String wire;

  /// The payload for this type, with [argument] after a colon when given.
  String payload([Object? argument]) =>
      argument == null ? wire : '$wire:$argument';

  /// The type [payload] starts with and the text after its first colon;
  /// null type for a payload this build does not know.
  static ({NotificationPayloadType? type, String? argument}) parse(
    String payload,
  ) {
    final colon = payload.indexOf(':');
    final wire = colon == -1 ? payload : payload.substring(0, colon);
    final argument = colon == -1 ? null : payload.substring(colon + 1);
    NotificationPayloadType? type;
    for (final candidate in values) {
      if (candidate.wire == wire) type = candidate;
    }
    return (type: type, argument: argument);
  }
}
