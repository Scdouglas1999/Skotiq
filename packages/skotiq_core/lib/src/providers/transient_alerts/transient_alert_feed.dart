part of '../transient_alert_provider.dart';

// Active transient alerts provider

/// Polling interval for fetching alerts (15 minutes)
const Duration _alertPollingInterval = Duration(minutes: 15);

/// What the last completed poll of the transient feed actually did.
///
/// An empty alert list means two very different things — "we asked and there is
/// nothing" and "we asked nobody" — and the alert card cannot tell them apart
/// from the list alone. Today only TNS is fetchable
/// ([kFetchableTransientSources]), so a user who enables AAVSO alone gets an
/// authoritative-looking empty feed that was never polled.
class TransientFeedCheck {
  /// When the poll completed.
  final DateTime checkedAt;

  /// Sources that were really queried. Empty means nothing was asked.
  final Set<TransientSource> queriedSources;

  /// Sources the user enabled that this build never queries, with why.
  final Map<TransientSource, String> skippedSources;

  const TransientFeedCheck({
    required this.checkedAt,
    required this.queriedSources,
    this.skippedSources = const {},
  });

  bool get contactedAnySource => queriedSources.isNotEmpty;
}

/// The last [TransientFeedCheck], or null before the first poll completes.
final transientFeedCheckProvider = StateProvider<TransientFeedCheck?>(
  (ref) => null,
);

/// Provider that streams active transient alerts with periodic polling.
///
/// Fetches alerts immediately on subscription, then polls every 15 minutes.
/// Alerts are filtered based on current settings.
///
/// In remote mode (NetworkBackend), fetches from the headless server API.
/// In local mode, fetches directly from AAVSO/TNS APIs.
final activeTransientAlertsProvider =
    StreamProvider.autoDispose<List<TransientAlert>>((ref) {
      final backend = ref.watch(backendProvider);
      final service = ref.watch(transientAlertServiceProvider);
      final settings = ref.watch(transientAlertSettingsProvider);
      final logger = ref.watch(loggingServiceProvider);
      final secretsStore = ref.watch(secretsStoreProvider);
      final scienceSettings = ref.watch(scienceSettingsProvider).valueOrNull;
      final networkBackend = backend is NetworkBackend ? backend : null;

      // Create a controller for the stream
      final controller = StreamController<List<TransientAlert>>();

      // Pillar B ("First Light"): self-discovered transients flow through the
      // same alert surfaces. Watch the local difference-imaging detections and
      // merge the non-dismissed ones (most confident first) ahead of the
      // external feed so a fresh discovery sits at the top of the bell.
      var currentDetections =
          ref.read(allTransientDetectionsProvider).valueOrNull ?? const [];
      List<TransientAlert> localFirstLightAlerts() {
        return currentDetections
            .where((d) => !d.dismissed)
            .map(transientAlertFromDetection)
            .toList(growable: false);
      }

      void recordCheck({
        required Set<TransientSource> queried,
        Map<TransientSource, String> skipped = const {},
      }) {
        ref
            .read(transientFeedCheckProvider.notifier)
            .state = TransientFeedCheck(
          checkedAt: DateTime.now(),
          queriedSources: queried,
          skippedSources: skipped,
        );
      }

      // A single fetch round-trip. Wrapped by [fetchAlerts] below so that
      // overlapping triggers (immediate + poll + detections-change) never run
      // concurrently and out-of-order completion cannot overwrite fresher data.
      Future<void> runFetch() async {
        try {
          List<TransientAlert> alerts;

          if (networkBackend != null) {
            // Fetch from headless server API
            final response = await networkBackend.getActiveTransients();
            final alertsJson = response['alerts'];
            if (alertsJson is! List) {
              throw const FormatException(
                'GET /api/transients returned no alerts list',
              );
            }
            alerts = <TransientAlert>[];
            for (var index = 0; index < alertsJson.length; index++) {
              final item = alertsJson[index];
              if (item is! Map) {
                throw FormatException(
                  'GET /api/transients returned a non-object alerts[$index]',
                );
              }
              final alert = _tryParseTransientAlertFromJson(
                Map<String, dynamic>.from(item),
              );
              if (alert == null) {
                throw FormatException(
                  'GET /api/transients returned malformed alerts[$index]',
                );
              }
              alerts.add(alert);
            }
            logger.debug(
              'Fetched ${alerts.length} transient alerts from remote server',
              source: 'activeTransientAlertsProvider',
            );
            // The imaging host owns source selection in remote mode; the round
            // trip itself is the evidence that something was asked.
            recordCheck(queried: {TransientSource.tns});
          } else {
            // Fetch directly from AAVSO/TNS APIs
            var tnsApiKey = '';
            if (settings.enabledSources.contains(TransientSource.tns) &&
                scienceSettings != null &&
                scienceSettings.tnsBotId > 0 &&
                scienceSettings.tnsBotName.trim().isNotEmpty) {
              try {
                tnsApiKey = await secretsStore.read(SecretField.tnsApiKey);
              } catch (error) {
                // A keyring outage must not hide the independent AAVSO feed.
                logger.warning(
                  'Could not read the TNS API key; fetching other transient '
                  'sources only: $error',
                  source: 'activeTransientAlertsProvider',
                );
              }
            }
            alerts = await service.getAllAlerts(
              settings.copyWith(
                tnsApiKey: tnsApiKey.isEmpty ? null : tnsApiKey,
              ),
              tnsBotId: scienceSettings?.tnsBotId,
              tnsBotName: scienceSettings?.tnsBotName,
              tnsUseSandbox: scienceSettings?.tnsUseSandbox ?? false,
            );
            logger.debug(
              'Fetched ${alerts.length} transient alerts from local service',
              source: 'activeTransientAlertsProvider',
            );
            final queried = <TransientSource>{};
            final skipped = <TransientSource, String>{};
            for (final source in settings.enabledSources) {
              if (source == TransientSource.manual) continue;
              if (!kFetchableTransientSources.contains(source)) {
                skipped[source] =
                    'this build has no ${source.name.toUpperCase()} feed';
              } else if (source == TransientSource.tns && tnsApiKey.isEmpty) {
                skipped[source] =
                    'TNS bot credentials are not set in Science settings';
              } else {
                queried.add(source);
              }
            }
            recordCheck(queried: queried, skipped: skipped);
          }

          // Merge local First Light discoveries ahead of the external feed.
          final merged = _mergeAlerts(localFirstLightAlerts(), alerts);

          if (!controller.isClosed) {
            controller.add(merged);
          }
        } catch (e) {
          logger.error(
            'Error fetching transient alerts: $e',
            source: 'activeTransientAlertsProvider',
          );
          // Even if the external feed failed, still surface local discoveries —
          // a self-found transient must never be hidden by a dead uplink.
          final local = localFirstLightAlerts();
          if (local.isNotEmpty) {
            if (!controller.isClosed) controller.add(local);
          } else if (!controller.isClosed) {
            controller.addError(e);
          }
        }
      }

      // Coalesce overlapping triggers: only one fetch runs at a time, and any
      // trigger that arrives mid-flight schedules exactly one follow-up run so
      // the newest data always wins (no out-of-order overwrite, no thundering
      // herd of concurrent requests).
      var fetchInProgress = false;
      var fetchPending = false;
      Future<void> fetchAlerts() async {
        if (fetchInProgress) {
          fetchPending = true;
          return;
        }
        fetchInProgress = true;
        try {
          do {
            fetchPending = false;
            await runFetch();
          } while (fetchPending && !controller.isClosed);
        } finally {
          fetchInProgress = false;
        }
      }

      // Fetch immediately
      fetchAlerts();

      // Set up periodic polling
      final timer = Timer.periodic(_alertPollingInterval, (_) {
        fetchAlerts();
      });

      // Re-merge whenever the local detections change (a fresh scan persisted a
      // new transient) so the bell updates without waiting for the poll tick.
      ref.listen(allTransientDetectionsProvider, (_, next) {
        currentDetections = next.valueOrNull ?? currentDetections;
        fetchAlerts();
      });

      // Clean up on dispose
      ref.onDispose(() {
        timer.cancel();
        controller.close();
      });

      return controller.stream;
    });
