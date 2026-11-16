part of '../network_backend.dart';

/// Settings a linked imaging host serves through their own endpoints.
mixin HostRigSettings on NetworkBackendTransport {
  /// Load the imaging host's global meridian-flip defaults.
  ///
  /// These settings drive unattended hardware behavior and therefore belong
  /// to the host, not the phone rendering the settings screen.
  Future<MeridianFlipSettings> getMeridianFlipSettings() async {
    final response = await _get(ProfileApi.getMeridianFlipSettings);
    final raw = response['settings'];
    if (raw is! Map<String, dynamic>) {
      throw const FormatException(
        'GET /api/settings/meridian-flip returned no settings object',
      );
    }
    return MeridianFlipSettings.fromJson(raw);
  }

  /// Replace the imaging host's global meridian-flip defaults.
  Future<void> updateMeridianFlipSettings(MeridianFlipSettings settings) async {
    await _post(
      ProfileApi.updateMeridianFlipSettings,
      body: {'settings': settings.toJson()},
    );
  }

  /// Load the headless/desktop host's Home Assistant discovery and broker
  /// configuration. The returned broker never contains its password.
  Future<HomeAssistantHostSettings> getHomeAssistantHostSettings() async {
    final response = await _get(ProfileApi.getHomeAssistantSettings);
    return HomeAssistantHostSettings.fromJson(response);
  }

  /// POST only the [patch] keys of the typed settings document. The host
  /// merges them onto its current settings, so fields this client did not
  /// change keep whatever value the host holds now.
  Future<void> updateSettingsPatchWithCommandId(
    Map<String, dynamic> patch, {
    required String? commandId,
  }) async {
    final extraHeaders = commandId == null
        ? null
        : <String, String>{'X-Skotiq-Command-Id': commandId};
    await _post(
      ProfileApi.updateSettings,
      body: {'settings': patch},
      headers: extraHeaders,
    );
  }

  /// The host's `app_settings` key/value rows that are not part of the
  /// [models.AppSettings] wire model.
  Future<HostSettingsRows> getSettingsStore() {
    return _retryableRequest(() async {
      final endpoint = _endpointPath(
        ProfileApi.getSettingsStore,
        ApiMethod.get,
      );
      final response = await _sendWithAuthRefresh(
        endpoint: endpoint,
        send: (headers) => _http.get(_apiUri(endpoint), headers: headers),
      );
      if (response.statusCode != 200) {
        throw _errorFromResponse(
          response.statusCode,
          response.body,
          'GET',
          endpoint,
        );
      }
      final json = jsonDecode(response.body);
      final settings = json is Map<String, dynamic> ? json['settings'] : null;
      if (settings is! Map) {
        throw StateError(
          'GET /api/settings/store returned no settings object (HTTP 200)',
        );
      }
      final adminAccess = json['adminAccess'];
      return HostSettingsRows(
        settings.map(
          (key, value) => MapEntry(key.toString(), value?.toString() ?? ''),
        ),
        adminAccess: adminAccess is bool ? adminAccess : null,
      );
    });
  }

  /// Write [settings] into the host's key/value store and delete [remove].
  Future<void> updateSettingsStore(
    Map<String, String> settings, {
    List<String> remove = const [],
  }) async {
    await _post(
      ProfileApi.updateSettingsStore,
      body: {'settings': settings, if (remove.isNotEmpty) 'remove': remove},
    );
  }

  /// Merge [fields] into the JSON-object rows of the host's key/value store:
  /// the host lays them over its own row (or over [base] when it has none).
  /// Returns the values the host stored.
  Future<Map<String, String>> mergeSettingsStore(
    Map<String, Map<String, Object?>> fields, {
    Map<String, Map<String, Object?>> base = const {},
  }) async {
    final response = await _post(
      ProfileApi.updateSettingsStore,
      body: {'merge': fields, if (base.isNotEmpty) 'mergeBase': base},
    );
    final merged = response['merged'];
    if (merged is! Map || !fields.keys.every(merged.containsKey)) {
      throw const FormatException(
        'settings/store did not return the merged values',
      );
    }
    return {
      for (final entry in merged.entries)
        entry.key.toString(): entry.value?.toString() ?? '',
    };
  }

  Future<Map<String, String>> getScienceSettings() async {
    final response = await _get(ScienceApi.getScienceSettings);
    return _sessionScienceObject(
      response,
      'settings',
      'GET /api/science/settings',
    ).map((key, value) => MapEntry(key, value.toString()));
  }

  Future<void> updateScienceSettings(Map<String, String> settings) async {
    await _post(ScienceApi.updateScienceSettings, body: {'settings': settings});
  }

  Future<Map<String, String>> getSmartNightSettings() async {
    final response = await _get(ScienceApi.getSmartNightSettings);
    return _sessionScienceObject(
      response,
      'settings',
      'GET /api/smart-night/settings',
    ).map((key, value) => MapEntry(key, value.toString()));
  }

  Future<void> updateSmartNightSettings(Map<String, String> settings) async {
    await _post(
      ScienceApi.updateSmartNightSettings,
      body: {'settings': settings},
    );
  }
}

/// The imaging host's key/value settings rows as this client may see them.
class HostSettingsRows {
  const HostSettingsRows(this.values, {this.adminAccess});

  final Map<String, String> values;

  /// Whether this client's credential has admin access to the host, which
  /// credential settings need. Null when the host does not say.
  final bool? adminAccess;
}
