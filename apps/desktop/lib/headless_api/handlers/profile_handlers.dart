import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/database_entities.dart' as settings_models;
// `SkotiqEvent` / `EventCategory` / `EventSeverity` /
// `settingsChangedEventType` are re-exported through
// `skotiq_backend.dart` → `backend_types.dart` → `event_types.dart`,
// so the public barrel below is enough.
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import '../validation.dart';

/// Handlers for profile and settings endpoints
class ProfileHandlers {
  final ProviderContainer container;

  /// Emit `settings.changed` events for each individual
  /// field that differs between the previous and new settings. Injected by
  /// [HeadlessApiServer.start] so the handler can fan events out to every
  /// connected WebSocket client. The callback is `broadcastEvent` on the
  /// server, which stamps `seq` + `serverInstanceId` + correlating
  /// command id before fan-out.
  ///
  /// `null` when the handler is constructed in a unit test or before the
  /// embedded server has hooked up; the broadcast is then a no-op so test
  /// containers that exercise the handler in isolation don't need a
  /// server.
  void Function(SkotiqEvent event)? emitEvent;

  ProfileHandlers(this.container, {this.emitEvent});

  LoggingService get _logger => container.read(loggingServiceProvider);

  void _logInfo(String message) =>
      _logger.info(message, source: 'ProfileHandlers');

  // Profiles

  EquipmentProfilesDao get _profilesDao =>
      container.read(equipmentProfilesDaoProvider);

  int _parseProfileId(String value) {
    final parsed = int.tryParse(value);
    if (parsed == null || parsed < 1) {
      throw BadRequestError(
        field: 'profileId',
        expected: 'positive integer',
        message: 'profileId must be a positive integer',
      );
    }
    return parsed;
  }

  Future<Response?> _profileNotFound(int profileId) async {
    final profile = await _profilesDao.getProfileById(profileId);
    if (profile != null) return null;
    return jsonNotFound({
      'error': 'profile_not_found',
      'message': 'Profile $profileId was not found.',
    });
  }

  Future<Response> handleGetProfiles(Request request) async {
    // SQLite (Drift) is the single source of truth shared with the GUI. Map the
    // real DB rows to the REST wire model via the canonical converter so the
    // slave sees the profiles the user actually built (incl.
    // meridianFlipOverrides / safetyMonitorId / switchId).
    final rows = await _profilesDao.getAllProfiles();
    final profiles = rows.map(dbProfileToRemote).toList();
    return jsonOk({"profiles": profiles.map((p) => p.toJson()).toList()});
  }

  Future<Response> handleSaveProfile(Request request) async {
    _logInfo('[API] POST /api/profiles');
    final payload = await readJsonObject(request);
    final profileJson = requireObject(payload, 'profile');

    // Parse the wire model defensively: a malformed shape (missing required
    // field, wrong type) becomes a structured 400 instead of letting a
    // TypeError/FormatException collapse into an opaque 500. The underlying
    // error travels in the message — it is a local type error, not sensitive,
    // and it is the only thing that knows WHICH field was wrong (L9).
    final EquipmentProfile profile;
    try {
      profile = EquipmentProfile.fromJson(profileJson);
    } on Object catch (error) {
      throw BadRequestError(
        field: 'profile',
        expected: 'equipment_profile',
        message: 'Malformed profile payload: $error',
      );
    }

    // Defense-in-depth semantic validation: a remote caller must not be able to
    // bypass the editors' input checks and push a blank/overlong name,
    // malformed optics, negative gain/offset, or an out-of-range centering
    // exposure straight into the DAO. Reject with a 400 before any mutation, so
    // the client gets an actionable error rather than a downstream DB fault.
    final semanticError = ProfileValidator.validateWireProfile(profile);
    if (semanticError != null) {
      throw BadRequestError(
        field: 'profile',
        expected: 'valid_profile',
        message: semanticError,
      );
    }

    final dao = _profilesDao;
    // Deterministic create-vs-update by id. If the payload's id parses to an
    // EXISTING row, issue a full-row update (preserving default/active/sort
    // flags via the converter's `existing` arg); otherwise create a new row and
    // capture the autoincrement id. Going through updateProfile (not
    // createProfile) for an existing row avoids createProfile's first-row
    // auto-default/auto-active side effect silently flipping a slave's flags.
    final rawId = profile.id.trim();
    final isCreate = rawId.isEmpty || rawId == '0';
    final int? parsedId;
    if (isCreate) {
      parsedId = null;
    } else {
      parsedId = int.tryParse(rawId);
      if (parsedId == null || parsedId <= 0) {
        throw BadRequestError(
          field: 'profile.id',
          expected: '0/empty for create, or a positive integer for update',
          message: 'Profile id is invalid',
        );
      }
    }
    final existing = parsedId == null
        ? null
        : await dao.getProfileById(parsedId);
    if (parsedId != null && existing == null) {
      return jsonNotFound({
        'error': 'profile_not_found',
        'message': 'Profile $parsedId was not found.',
      });
    }

    final int resultId;
    if (existing != null) {
      final row = remoteProfileToDbRow(profile, existing: existing);
      await dao.updateProfile(row);
      resultId = existing.id;
    } else {
      resultId = await dao.createProfile(remoteProfileToCompanion(profile));
    }

    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.profile,
      action: existing == null
          ? HostMutationAction.created
          : HostMutationAction.updated,
      entityId: resultId.toString(),
      extra: {'name': profile.name},
    );
    // Return the resulting id so the slave's saveProfile can resolve the row
    // deterministically instead of by (racy) name.
    return jsonOk({"status": "saved", "id": resultId.toString()});
  }

  Future<Response> handleDeleteProfile(
    Request request,
    String profileId,
  ) async {
    _logInfo('[API] DELETE /api/profiles/$profileId');
    final parsedId = _parseProfileId(profileId);
    final notFound = await _profileNotFound(parsedId);
    if (notFound != null) return notFound;
    await _profilesDao.deleteProfile(parsedId);
    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.profile,
      action: HostMutationAction.deleted,
      entityId: profileId,
    );
    return jsonOk({"status": "deleted"});
  }

  Future<Response> handleLoadProfile(Request request, String profileId) async {
    _logInfo('[API] POST /api/profiles/$profileId/load');
    final parsedId = _parseProfileId(profileId);
    final notFound = await _profileNotFound(parsedId);
    if (notFound != null) return notFound;
    await activateProfileStrictTransactional(
      dao: _profilesDao,
      backend: container.read(profileSettingsBackendProvider),
      logger: _logger,
      profileId: parsedId,
    );
    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.profile,
      action: HostMutationAction.loaded,
      entityId: profileId,
    );
    return jsonOk({"status": "loaded"});
  }

  /// Set [profileId] as the default startup profile (and active profile),
  /// atomically unsetting `isDefault` on every other row.
  ///
  /// The canonical converter's `remoteProfileToDbRow` deliberately preserves
  /// `existing.isDefault`, so a slave's saveProfile loop could never flip the
  /// default on the host. This dedicated endpoint routes through the DAO's
  /// `setDefaultProfile`, which owns the unset-others-then-set transaction.
  Future<Response> handleSetDefaultProfile(
    Request request,
    String profileId,
  ) async {
    _logInfo('[API] POST /api/profiles/$profileId/default');
    final parsedId = _parseProfileId(profileId);
    final notFound = await _profileNotFound(parsedId);
    if (notFound != null) return notFound;
    await activateProfileStrictTransactional(
      dao: _profilesDao,
      backend: container.read(profileSettingsBackendProvider),
      logger: _logger,
      profileId: parsedId,
      commit: () => _profilesDao.setDefaultProfile(parsedId, makeActive: true),
    );
    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.profile,
      action: HostMutationAction.updated,
      entityId: profileId,
    );
    return jsonOk({"status": "default-set"});
  }

  /// Clear the persisted default startup profile (unset `isDefault` on every
  /// row) without changing the current active selection.
  ///
  /// The generic saveProfile path can't do this: `remoteProfileToDbRow`
  /// preserves the existing row's `isDefault`, so a slave clearing the default
  /// would be a host-side no-op. This routes through the DAO's
  /// `clearDefaultProfile`.
  Future<Response> handleClearDefaultProfile(Request request) async {
    _logInfo('[API] POST /api/profiles/default/clear');
    await _profilesDao.clearDefaultProfile();
    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.profile,
      action: HostMutationAction.updated,
    );
    return jsonOk({"status": "default-cleared"});
  }

  /// Persist a new display order for the equipment profiles.
  ///
  /// The body is `{"profileIds": ["3","1","2"]}`; each id is assigned
  /// `sortOrder == its index`. The converter's `remoteProfileToDbRow`
  /// preserves `existing.sortOrder`, so a slave's saveProfile loop was a
  /// host-side no-op — this dedicated endpoint writes sortOrder directly via
  /// the DAO's transactional `reorderProfiles`.
  Future<Response> handleReorderProfiles(Request request) async {
    _logInfo('[API] POST /api/profiles/reorder');
    final payload = await readJsonObject(request);
    final rawIds = requireList<dynamic>(payload, 'profileIds');
    final orderedIds = <int>[];
    for (var i = 0; i < rawIds.length; i++) {
      final raw = rawIds[i];
      final parsed = int.tryParse(raw.toString());
      if (parsed == null || parsed < 1) {
        throw BadRequestError(
          field: 'profileIds[$i]',
          expected: 'positive integer',
          message: 'Every profileIds entry must be a positive integer',
        );
      }
      if (orderedIds.contains(parsed)) {
        throw BadRequestError(
          field: 'profileIds[$i]',
          expected: 'unique profile id',
          message: 'profileIds must not contain duplicates',
        );
      }
      orderedIds.add(parsed);
    }
    await _profilesDao.reorderProfiles(orderedIds);
    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.profile,
      action: HostMutationAction.updated,
    );
    return jsonOk({"status": "reordered"});
  }

  Future<Response> handleGetActiveProfile(Request request) async {
    final row = await _profilesDao.getActiveProfile();
    return jsonOk({
      "profile": row == null ? null : dbProfileToRemote(row).toJson(),
    });
  }

  // Settings

  /// The settings-document keys that mirror the observer site.
  ///
  /// The site's canonical store is the one `GET /api/settings/location`, the
  /// planetarium and the native sequencer read; these four are its projection
  /// into the flat settings document. A settings save that names none of them
  /// is not a save about the site, and must not move it.
  static const _siteKeys = <String>{
    'latitude',
    'longitude',
    'elevation',
    'location',
  };

  Future<Response> handleGetSettings(Request request) async {
    // Read from the DB-backed settings notifier (the desktop's source of
    // truth) rather than the Rust bridge, which only carries the ~7
    // engine-relevant fields and would report defaults for everything else.
    final notifier = container.read(appSettingsProvider.notifier);
    await container.read(appSettingsProvider.future);
    final settings = notifier.exportRemoteSettings().toJson();

    // The site comes from the CANONICAL store, not from the settings
    // notifier's copy of it. Two things were wrong with the copy:
    //
    //  * it is not refreshed when POST /api/settings/location writes the
    //    canonical store, so this endpoint served the pre-write coordinates
    //    for the rest of the process's life while /api/settings/location
    //    served the new ones — two endpoints on one rig disagreeing about
    //    where the rig is;
    //  * `AppSettingsState.latitude/longitude/elevation` are non-nullable
    //    doubles defaulting to 0.0, so a rig that has never had a site
    //    reported `latitude 0.0, longitude 0.0` — a real point in the Gulf of
    //    Guinea — where the canonical endpoint honestly answers null and the
    //    app's own log line says "Settings have no observer location".
    //
    // Unset therefore serializes as null on all four keys plus a
    // `locationStatus` that names it, which is what a remote client needs to
    // tell "no site configured" from "a site at 0N 0E".
    final backend = container.read(profileSettingsBackendProvider);
    final site = await backend.getLocation();
    settings['location'] = site?.toJson();
    settings['latitude'] = site?.latitude;
    settings['longitude'] = site?.longitude;
    settings['elevation'] = site?.elevation;
    settings['locationStatus'] = site == null ? 'not configured' : 'configured';

    return jsonOk({"settings": settings});
  }

  /// Global meridian-flip defaults are stored separately from the generated
  /// AppSettings wire model, but they still belong to the imaging host because
  /// they control unattended mount/guiding/focus behavior.
  Future<Response> handleGetMeridianFlipSettings(Request request) async {
    final notifier = container.read(
      globalMeridianFlipSettingsProvider.notifier,
    );
    await notifier.ensureLoaded();
    return jsonOk({'settings': notifier.settings.toJson()});
  }

  Future<Response> handleUpdateMeridianFlipSettings(Request request) async {
    _logInfo('[API] POST /api/settings/meridian-flip');
    final payload = await readJsonObject(request);
    final settingsJson = requireObject(payload, 'settings');

    final MeridianFlipSettings settings;
    try {
      settings = MeridianFlipSettings.fromJson(settingsJson);
    } on Object catch (error) {
      throw BadRequestError(
        field: 'settings',
        expected: 'valid meridian-flip settings object',
        message: 'Could not parse meridian-flip settings: $error',
      );
    }
    final validationErrors = settings.validate();
    if (validationErrors.isNotEmpty) {
      throw BadRequestError(
        field: 'settings',
        expected: 'values within supported meridian-flip ranges',
        message: validationErrors.join('; '),
      );
    }

    final notifier = container.read(
      globalMeridianFlipSettingsProvider.notifier,
    );
    await notifier.updateSettings(settings);
    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.settings,
      action: HostMutationAction.updated,
      extra: const {'namespace': 'meridian-flip'},
    );
    return jsonOk({
      'status': 'updated',
      'settings': notifier.settings.toJson(),
    });
  }

  Future<Map<String, dynamic>> _homeAssistantHostSettingsJson() async {
    final config = await container.read(homeAssistantConfigProvider.future);
    final broker = await container.read(mqttTransportConfigProvider.future);
    return {
      'config': config.toJson(),
      'broker': broker.copyWith(clearPassword: true).toJson(),
      'brokerPasswordConfigured': broker.password?.isNotEmpty ?? false,
    };
  }

  /// Host-owned Home Assistant auto-discovery configuration. This is separate
  /// from the mobile device's notification-router transports: the discovery
  /// service runs on the imaging host and must survive the phone disconnecting.
  Future<Response> handleGetHomeAssistantSettings(Request request) async {
    return jsonOk(await _homeAssistantHostSettingsJson());
  }

  Future<Response> handleUpdateHomeAssistantSettings(Request request) async {
    _logInfo('[API] POST /api/settings/home-assistant');
    final payload = await readJsonObject(request);
    final configJson = requireObject(payload, 'config');
    final brokerJson = requireObject(payload, 'broker');

    final HomeAssistantDiscoveryConfig config;
    final MqttTransportConfig parsedBroker;
    try {
      config = HomeAssistantDiscoveryConfig.fromJson(configJson);
      parsedBroker = MqttTransportConfig.fromJson(
        brokerJson,
      ).copyWith(clearPassword: true);
    } on Object catch (error) {
      throw BadRequestError(
        field: 'config',
        expected: 'valid Home Assistant and MQTT configuration objects',
        message: 'Could not parse Home Assistant configuration: $error',
      );
    }

    final rawQos = brokerJson['qos'];
    final errors = <String>[];
    if (parsedBroker.port < 1 || parsedBroker.port > 65535) {
      errors.add('MQTT port must be between 1 and 65535');
    }
    if (rawQos is! num || (rawQos.toInt() != 0 && rawQos.toInt() != 1)) {
      errors.add('MQTT QoS must be 0 or 1');
    }
    if (parsedBroker.host.trim().isNotEmpty &&
        parsedBroker.topic.trim().isEmpty) {
      errors.add('MQTT topic is required when a broker host is configured');
    }
    if (parsedBroker.host.trim().isNotEmpty &&
        parsedBroker.clientId.trim().isEmpty) {
      errors.add('MQTT client ID is required when a broker host is configured');
    }
    final discoveryPrefix = config.discoveryPrefix.trim();
    if (discoveryPrefix.isEmpty ||
        discoveryPrefix.contains('#') ||
        discoveryPrefix.contains('+')) {
      errors.add('Home Assistant discovery prefix must be a valid MQTT topic');
    }
    if (config.enabled && !parsedBroker.isConfigured) {
      errors.add(
        'Configure an MQTT broker host and topic before enabling Home Assistant',
      );
    }
    if (errors.isNotEmpty) {
      throw BadRequestError(
        field: 'config',
        expected: 'valid Home Assistant host configuration',
        message: errors.join('; '),
      );
    }

    final replacePassword = payload.containsKey('password');
    final replacementPassword = payload['password'];
    if (replacePassword && replacementPassword is! String) {
      throw BadRequestError(
        field: 'password',
        expected: 'string',
        message: 'MQTT password must be a string when supplied',
      );
    }

    final previousBroker = await container.read(
      mqttTransportConfigProvider.future,
    );
    final nextBroker = parsedBroker.copyWith(
      username: parsedBroker.username?.trim(),
      clearUsername: parsedBroker.username?.trim().isEmpty ?? true,
      password: replacePassword
          ? replacementPassword as String
          : previousBroker.password,
      clearPassword: replacePassword && (replacementPassword as String).isEmpty,
      host: parsedBroker.host.trim(),
      topic: parsedBroker.topic.trim(),
      clientId: parsedBroker.clientId.trim(),
    );
    final brokerNotifier = container.read(mqttTransportConfigProvider.notifier);
    final configNotifier = container.read(homeAssistantConfigProvider.notifier);

    await brokerNotifier.save(nextBroker);
    try {
      await configNotifier.save(
        config.copyWith(
          deviceName: config.deviceName.trim(),
          discoveryPrefix: discoveryPrefix,
        ),
      );
    } on Object catch (error, stackTrace) {
      // Keep the two host-owned blobs atomic from the caller's perspective.
      // MqttConfigNotifier already rolls its keyring write back if its own DAO
      // write fails; this restores the prior broker if the second save fails.
      try {
        await brokerNotifier.save(previousBroker);
      } on Object catch (rollbackError) {
        _logger.error(
          'Home Assistant broker rollback failed: $rollbackError',
          source: 'ProfileHandlers',
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }

    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.settings,
      action: HostMutationAction.updated,
      extra: const {'namespace': 'home-assistant'},
    );
    return jsonOk(await _homeAssistantHostSettingsJson());
  }

  Future<Response> handleUpdateSettings(Request request) async {
    _logInfo('[API] POST /api/settings');
    // [settings sync] capture the optional commandId from the
    // request header so we can stamp `correlatingCommandId` on every
    // `settings.changed` event emitted below. The originating client
    // uses this to skip its own echo and avoid re-applying a value it
    // just wrote.
    final commandId = request.headers['x-skotiq-command-id'];
    final payload = await readJsonObject(request);
    final settingsJson = requireObject(payload, 'settings');

    final backend = container.read(profileSettingsBackendProvider);
    final settingsNotifier = container.read(appSettingsProvider.notifier);
    // The site as the CANONICAL store holds it right now, read before anything
    // is written. Both halves of the site rule below are decided from it, and
    // it is what a failed write is rolled back to.
    final canonicalSite = await backend.getLocation();
    // [settings sync] capture the full previous settings (DB-backed) BEFORE
    // constructing the new state: they seed both the partial-update merge
    // below and the fine-grained `settings.changed` diff events. If the read
    // fails (first-boot / driver hiccup), fall back to treating the posted
    // map as the full document and emit a single full-snapshot event.
    settings_models.AppSettings? previous;
    try {
      await container.read(appSettingsProvider.future);
      previous = settingsNotifier.exportRemoteSettings();
    } on Object catch (e) {
      // Why: with no readable previous state there is nothing to merge onto
      // or diff against; proceeding with the posted map alone keeps the
      // update itself working.
      _logger.debug(
        'Settings update: could not read previous settings for the '
        'change diff: $e',
        source: 'ProfileHandlers',
      );
      previous = null;
    }

    // MERGE the posted keys onto the current settings instead of hydrating
    // the freezed model straight from the posted map. `AppSettings.fromJson`
    // fills every omitted key with its model DEFAULT, so hydrating from a
    // partial update (e.g. `{"settings":{"parkOnUnsafeWeather":false}}` from a
    // script or integrator) would reset the other ~150 persisted settings —
    // including `webServerEnabled`, tearing down the very server the remote
    // client is connected through. Full-snapshot writers (the mobile app's
    // settings sync) are unaffected: their maps cover every key.
    // The jsonDecode(jsonEncode(...)) round-trip flattens nested freezed
    // values (e.g. ObserverLocation) into plain maps — freezed `toJson` is
    // shallow, and `fromJson` requires pure JSON.
    final mergedJson = <String, dynamic>{
      if (previous != null)
        ...jsonDecode(jsonEncode(previous.toJson())) as Map<String, dynamic>,
      ...settingsJson,
    };

    // WHAT THIS SAVE MAY DO TO THE OBSERVER SITE.
    //
    // `latitude` / `longitude` / `elevation` / `location` live in this flat
    // document AND in the canonical observer store. The settings notifier's
    // copy of them is NOT refreshed when POST /api/settings/location writes
    // that store, so the merge above used to carry a STALE site into every
    // save: a POST touching one unrelated field rewrote the observer rows —
    // and the native settings blob the site is reloaded from at boot — with
    // coordinates the operator had already replaced. The replacement survived
    // in memory until the process ended and was gone at the next launch, and
    // nothing anywhere reported it.
    //
    // The rule has two halves:
    //  * a save naming NONE of the site keys writes the CANONICAL site back,
    //    so an unrelated field cannot move the rig;
    //  * a save that DOES name one writes BOTH stores — the canonical one
    //    first, rolled back below if the settings write then fails.
    final site = _siteRequestedBy(settingsJson, canonicalSite);
    _writeSiteInto(mergedJson, site.value);

    final settings = settings_models.AppSettings.fromJson(mergedJson);

    // The canonical store goes first so the two can only ever disagree in the
    // window this method holds, and only until the rollback below runs.
    if (site.changed) {
      await backend.setLocation(site.value);
    }

    // The database is the source of truth, shared with the desktop, so the
    // COMPLETE settings go there. The bridge then gets the engine-relevant
    // subset (location/theme/language/autoConnect) to keep the executor
    // consistent. Writing only the bridge would drop every other field.
    try {
      await settingsNotifier.applyRemoteSettings(settings);
      await backend.updateSettings(settings);
    } on Object catch (error, stackTrace) {
      if (site.changed) {
        // The site moved and the document that mirrors it did not. Put the
        // canonical store back where the caller found it rather than leaving
        // the rig at a site no settings row records.
        try {
          await backend.setLocation(canonicalSite);
        } on Object catch (rollbackError) {
          _logger.error(
            'The observer location could not be rolled back after a failed '
            'settings save; the canonical store and the settings document '
            'disagree: $rollbackError',
            source: 'ProfileHandlers',
          );
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.settings,
      action: HostMutationAction.updated,
    );
    if (site.changed) {
      publishHostMutationFromContainer(
        container,
        entityType: HostMutationEntity.settings,
        action: HostMutationAction.updated,
        extra: {'scope': 'location'},
      );
    }

    // [settings sync] emit live settings-change events so every
    // connected WS client can update its in-memory state without a GET
    // round-trip. The diff is field-by-field on the freezed `AppSettings`
    // JSON projection — the same JSON the client sends, so the keys match
    // what the receiver expects.
    _emitSettingsChanges(
      previous: previous,
      next: settings,
      commandId: commandId,
    );

    // What this save did to the site, said out loud. A caller whose flat
    // coordinates were not taken as a site learns it here rather than
    // discovering at the next restart that the rig never moved.
    return jsonOk({
      "status": "updated",
      "observerLocation": {
        "action": site.changed ? 'updated' : 'unchanged',
        if (site.note != null) "note": site.note,
      },
    });
  }

  /// What a settings patch asks to happen to the observer site.
  ///
  /// [value] is the site to write and [changed] says whether the canonical
  /// store has to be told; [note] carries the sentence for a patch that named
  /// site keys the site did not take.
  ///
  /// [patch] is the POSTED map — only the keys the caller actually wrote — and
  /// [canonical] is the site the canonical store currently holds, which is the
  /// base a partial patch updates. Reading the base from the settings document
  /// instead would build the new site on top of the stale copy this whole rule
  /// exists to stop trusting.
  ///
  /// `latitude: 0, longitude: 0` is NOT a site. It is the wire model's declared
  /// default for both fields, so it is exactly what a full-snapshot client
  /// composes for a rig whose site it does not know — the shape that pushes a
  /// rig to Null Island. A site AT 0N 0E, and clearing one, go through
  /// POST /api/settings/location, which can say `null` and this document
  /// cannot.
  ({bool changed, settings_models.ObserverLocation? value, String? note})
  _siteRequestedBy(
    Map<String, dynamic> patch,
    settings_models.ObserverLocation? canonical,
  ) {
    if (!patch.keys.any(_siteKeys.contains)) {
      return (changed: false, value: canonical, note: null);
    }

    final nested = patch['location'];
    final settings_models.ObserverLocation requested;
    if (nested is Map<String, dynamic>) {
      // A nested location is complete by construction: every field of
      // `ObserverLocation` is required, so `fromJson` refuses a partial one.
      try {
        requested = settings_models.ObserverLocation.fromJson(nested);
      } on Object catch (error) {
        throw BadRequestError(
          field: 'settings.location',
          expected: 'an object with latitude, longitude and elevation',
          message: 'The observer location could not be read: $error',
        );
      }
    } else if (nested != null) {
      throw BadRequestError(
        field: 'settings.location',
        expected:
            'an object with latitude, longitude and elevation, or the '
            'flat latitude/longitude/elevation fields',
        message: 'settings.location must be an object.',
      );
    } else {
      requested = settings_models.ObserverLocation(
        latitude: _siteCoordinate(patch, 'latitude', canonical?.latitude),
        longitude: _siteCoordinate(patch, 'longitude', canonical?.longitude),
        // Elevation alone does not locate anything, so an omitted one falls
        // back to the stored site and then to sea level rather than refusing
        // a latitude/longitude pair over the third number.
        elevation: _siteCoordinate(
          patch,
          'elevation',
          canonical?.elevation ?? 0.0,
        ),
      );
    }

    if (requested.latitude == 0.0 && requested.longitude == 0.0) {
      return (
        changed: false,
        value: canonical,
        note:
            'latitude 0 / longitude 0 is this document\'s default for a site '
            'it does not know, so it was not taken as one and the observer '
            'location is unchanged. POST /api/settings/location to set a site '
            'at 0N 0E, or to clear the one on record.',
      );
    }
    if (canonical != null &&
        requested.latitude == canonical.latitude &&
        requested.longitude == canonical.longitude &&
        requested.elevation == canonical.elevation) {
      return (changed: false, value: canonical, note: null);
    }
    return (changed: true, value: requested, note: null);
  }

  /// One coordinate of a site the settings patch is building.
  ///
  /// Falls back to [canonical] — the stored site — when the patch does not name
  /// this key, so a patch of `{"latitude": 41.0}` keeps the longitude the
  /// operator already set. With no stored site and no posted value there is no
  /// honest answer, and the caller is pointed at the endpoint that can express
  /// a whole site.
  double _siteCoordinate(
    Map<String, dynamic> patch,
    String key,
    double? canonical,
  ) {
    final raw = patch[key];
    if (raw is num) return raw.toDouble();
    if (raw != null) {
      throw BadRequestError(
        field: 'settings.$key',
        expected: 'number',
        message: '$key must be a number.',
      );
    }
    if (canonical != null) return canonical;
    throw BadRequestError(
      field: 'settings.$key',
      expected: 'latitude and longitude together',
      message:
          'This rig has no observer location, so a settings save cannot set '
          '$key on its own — there is nothing to update it against. Supply '
          'latitude and longitude together, or POST the site to '
          '/api/settings/location.',
    );
  }

  /// Project [site] into the settings document [json] writes.
  ///
  /// A null site writes `location: null` and leaves the flat mirror alone. The
  /// nested field is what the native settings blob is built from, and the blob
  /// is what `load_observer_location_from_settings` reloads at boot: written as
  /// `ObserverLocation(0, 0, 0)` — which is what the notifier's non-nullable
  /// defaults project for a rig that has never had a site — the next launch
  /// came up believing it stood in the Gulf of Guinea.
  void _writeSiteInto(
    Map<String, dynamic> json,
    settings_models.ObserverLocation? site,
  ) {
    if (site == null) {
      json['location'] = null;
      return;
    }
    json['location'] = site.toJson();
    json['latitude'] = site.latitude;
    json['longitude'] = site.longitude;
    json['elevation'] = site.elevation;
  }

  /// Fan out one `settings.changed` event per
  /// changed field between [previous] and [next]. When [previous] is
  /// null, the entire `next` snapshot is emitted as a single event with
  /// key `__snapshot__` so the client can still rehydrate.
  ///
  /// `commandId` is stamped onto `correlatingCommandId` so the
  /// originating client can filter its own echo.
  void _emitSettingsChanges({
    required settings_models.AppSettings? previous,
    required settings_models.AppSettings next,
    required String? commandId,
  }) {
    final emit = emitEvent;
    if (emit == null) return;

    final changedAt = DateTime.now().toUtc().toIso8601String();
    final nowMillis = DateTime.now().millisecondsSinceEpoch;

    SkotiqEvent buildEvent({required String key, required dynamic value}) {
      return SkotiqEvent(
        timestamp: nowMillis,
        severity: EventSeverity.info,
        category: EventCategory.system,
        eventType: settingsChangedEventType,
        data: {'key': key, 'value': value, 'changedAt': changedAt},
        correlatingCommandId: commandId,
      );
    }

    if (previous == null) {
      // First-write or recovery path: emit a full snapshot so the
      // remote applies the entire object at once.
      emit(buildEvent(key: '__snapshot__', value: next.toJson()));
      return;
    }

    final prevJson = previous.toJson();
    final nextJson = next.toJson();

    // Union of both key sets covers additions, removals, and overlaps.
    final keys = <String>{...prevJson.keys, ...nextJson.keys};
    for (final key in keys) {
      final prevValue = prevJson[key];
      final nextValue = nextJson[key];
      if (_settingsValueEquals(prevValue, nextValue)) continue;
      emit(buildEvent(key: key, value: nextValue));
    }
  }

  /// Deep-equality helper for settings-diff. `Map` / `List` get a
  /// `jsonEncode` comparison so we don't pull a deep-equality package
  /// in just for this. The values are JSON-shaped (numbers, strings,
  /// bools, lists, maps, null), so encoding is total and correct.
  static bool _settingsValueEquals(dynamic a, dynamic b) {
    if (identical(a, b)) return true;
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    if (a is Map || b is Map || a is List || b is List) {
      return jsonEncode(a) == jsonEncode(b);
    }
    return a == b;
  }

  Future<Response> handleGetLocation(Request request) async {
    final backend = container.read(profileSettingsBackendProvider);
    final location = await backend.getLocation();
    return jsonOk({"location": location?.toJson()});
  }

  Future<Response> handleSetLocation(Request request) async {
    _logInfo('[API] POST /api/settings/location');
    final payload = await readJsonObject(request);
    final locationJson = optionalObject(payload, 'location');
    final location = locationJson != null
        ? settings_models.ObserverLocation.fromJson(locationJson)
        : null;

    final backend = container.read(profileSettingsBackendProvider);
    await backend.setLocation(location);

    // Mirror the location into the settings store. The backend store above is
    // the canonical one read by GET /api/settings/location, the planetarium,
    // and the native sequencer — but the scheduler and "tonight" suggestion
    // subsystems read observer lat/lon straight from the settings rows, which
    // on a headless appliance are otherwise only ever populated by the GUI
    // settings flow (never run here). Without this mirror, a remote client that
    // sets its location through the API gets a working planetarium but a
    // permanently "No observer location configured" scheduler. Clearing (null)
    // zeroes both.
    //
    // Through the NOTIFIER, not the DAO underneath it: the DAO write moved the
    // rows while the notifier went on holding the pre-write coordinates, and
    // that in-memory copy is what GET /api/settings served and what the merge
    // in POST /api/settings built its next full snapshot from. The site the
    // operator had just set was therefore reverted by the next unrelated
    // settings save. `updateLocation` writes the same three rows in one
    // transaction and patches the state with them, so every reader agrees.
    await container.read(appSettingsProvider.future);
    await container
        .read(appSettingsProvider.notifier)
        .updateLocation(
          latitude: location?.latitude ?? 0.0,
          longitude: location?.longitude ?? 0.0,
          elevation: location?.elevation ?? 0.0,
        );

    publishHostMutationFromContainer(
      container,
      entityType: HostMutationEntity.settings,
      action: HostMutationAction.updated,
      extra: {'scope': 'location'},
    );
    return jsonOk({"status": "updated"});
  }

  Future<Response> handleGetLocationFromInternet(Request request) async {
    final backend = container.read(diagnosticsBackendProvider);
    final location = await backend.getLocationFromInternet();
    return jsonOk({
      "latitude": location.latitude,
      "longitude": location.longitude,
      "elevation": location.elevation,
    });
  }
}
