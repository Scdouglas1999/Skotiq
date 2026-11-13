// Navigation callback and injectable notification sink contract.
part of '../notification_service.dart';

/// Callback the app installs so notification taps can drive go_router.
///
/// The notification plugin fires on a platform thread without access to a
/// BuildContext, so the app supplies a function that performs the navigation
/// via the GoRouter instance it owns.
typedef NotificationNavigator = void Function(String location);

/// What a notification tap actually did.
///
/// A tap that goes nowhere is the failure mode this names: the payload was
/// absent, no route matched it, or the app has no router yet. Each is logged
/// where it happens AND returned, so a test can pin the reason rather than
/// asserting on a log line nobody reads.
enum NotificationTapOutcome {
  /// The payload mapped to a location and the navigator was called.
  routed,

  /// The notification carried no payload, so there is nothing to route by.
  noPayload,

  /// The payload's `type` matches no arm of the route table.
  unknownPayload,

  /// The route resolved, but the app has not installed its router yet — the
  /// cold-start window.
  noNavigator,
}

/// Surface area of [MobileNotificationService] consumed by mobile-side
/// subscribers (battery, foreground service, mobile-direct event notifier).
///
/// Extracted so unit tests can supply a recording double without touching
/// the flutter_local_notifications plugin (which has no in-test host
/// implementation). Production code continues to use the singleton
/// [MobileNotificationService] directly; the abstraction exists purely for
/// dependency injection at test boundaries.
abstract class MobileNotificationSink {
  Future<void> notifySequenceComplete(String targetName, int imageCount);
  Future<void> notifySequenceFailed(String targetName, String errorMessage);
  Future<void> notifyMeridianFlip(String targetName, DateTime flipTime);
  Future<void> notifyLowDiskSpace(String message);
  Future<void> notifyLowBattery(int percentage);
  Future<void> notifySafety({required String title, required String body});
  Future<void> notifyGuidingLost(String reason);
  Future<void> notifyExposureFailed(String errorMessage);
  Future<void> notifyAutofocusFailed();
  Future<void> notifyEquipmentDisconnected(String deviceType, String deviceId);
  Future<void> notifyTargetCompleted(String targetName);
  Future<void> notifyPush(Map<String, dynamic> data);

  /// a long-running plate-solve job (`JobFailed` event with
  /// `operation == 'plate-solve'`) gave up. Surfaced as a warning so the
  /// operator can decide whether to retry — astrometry can fail for many
  /// transient reasons (clouds, bad seeing, mount offset) and a failure
  /// here usually doesn't stop the sequence on its own.
  Future<void> notifyPlateSolveFailed(String errorMessage);

  /// `framing.center-on-target` job aborted. We separate this
  /// from plate-solve because centering chains *multiple* solves with
  /// slew corrections; a centering failure usually means the mount drifted
  /// off-target or pointing is bad enough that the loop won't converge.
  Future<void> notifyCenteringFailed(String errorMessage);

  /// `polar-alignment.start` or `polar-alignment.all-sky.start`
  /// failed. Operator-driven workflow — they're almost certainly looking at
  /// the polar align screen when this fires, but we still page them in case
  /// they're across the field.
  Future<void> notifyPolarAlignmentFailed(String errorMessage);

  /// another client called `claim?force=true` (or POSTed
  /// `/api/session/take-over`) while we were the operator. Important UX
  /// signal — without it, the user's actions will start returning 409
  /// "not the operator" with no obvious cause.
  Future<void> notifyOwnershipTakenOver({
    String? displacingClientName,
    String? reason,
  });

  /// heartbeat timeout swept our ownership slot. Informational —
  /// the user knows they walked away; we just confirm somebody (or
  /// nobody) now owns the rig.
  Future<void> notifyOwnershipAutoReleased(String reason);
}
