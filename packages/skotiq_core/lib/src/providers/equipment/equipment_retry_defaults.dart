/// Default retry configuration shared by all device-state notifiers.
///
/// Each device notifier (camera, mount, focuser, etc.) uses the same
/// `_connectWithRetry` pattern: try N times with linear backoff.
library;

const int kDefaultMaxRetries = 3;
const Duration kDefaultRetryDelay = Duration(seconds: 1);
