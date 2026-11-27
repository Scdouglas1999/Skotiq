import 'package:skotiq_core/services.dart' show ConstellationErrorKind;

/// The REST status the host answers when a hub call failed with [kind].
///
/// A hub fault must not reach the generic trap as a 500 `internal_error`:
/// "your hub is switched off" would read as "the appliance is broken", and a
/// remote client could not tell a retryable outage from a request it must
/// fix. [unknown] is the surface's answer for a failure the hub clients could
/// not classify.
int hubStatusFor(ConstellationErrorKind kind, {required int unknown}) =>
    switch (kind) {
      // No answer from the hub at all: this appliance is the gateway.
      ConstellationErrorKind.network => 502,
      // The hub answered, but is itself unhealthy; retry later.
      ConstellationErrorKind.server => 503,
      // Not signed in / no hub configured: the client prompts a sign-in
      // instead of retrying a 5xx as transient.
      ConstellationErrorKind.auth => 401,
      ConstellationErrorKind.notFound => 404,
      ConstellationErrorKind.conflict => 409,
      ConstellationErrorKind.geometryMismatch => 409,
      // The hub rejected the request itself: the caller must change it.
      ConstellationErrorKind.protocol => 400,
      ConstellationErrorKind.unknown => unknown,
    };
