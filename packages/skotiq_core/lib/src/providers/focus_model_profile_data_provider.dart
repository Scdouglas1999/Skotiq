import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/remote_host.dart';
import '../services/focus_model_service.dart';
import 'focus_model_service_providers.dart';
import 'host_role.dart';

/// The autofocus history, temperature model and per-filter offsets of
/// whichever machine is the imaging host, where autofocus runs.
///
/// The host keeps them per equipment profile. A linked host serves the ones
/// of its active profile, so [profileId] is not sent to it.
abstract interface class FocusHistory {
  Future<ProfileFocusData?> profileData(String profileId);

  Future<void> addPoint({
    required String profileId,
    required double temperatureCelsius,
    required int focusPosition,
    required double hfr,
    String? filterName,
  });

  /// The profile's focus data as indented JSON.
  Future<String> export(String profileId);

  Future<void> import(String profileId, Map<String, dynamic> data);

  Future<void> clear(String profileId);

  /// The per-filter offsets in steps and the filter they are measured from.
  Future<FilterOffsets> filterOffsets(String profileId);

  /// Stores [changed] among the profile's offsets, which are [all] once it
  /// is in.
  Future<void> setFilterOffset({
    required String profileId,
    required String referenceFilter,
    required MapEntry<String, int> changed,
    required Map<String, int> all,
  });

  Future<void> setReferenceFilter(String profileId, String filterName);
}

typedef FilterOffsets = ({Map<String, int> offsets, String? referenceFilter});

final focusHistoryProvider = hostRoleProvider<FocusHistory>(
  here: (ref) => _LocalFocusHistory(ref.watch(focusModelServiceProvider)),
  linked: (ref, host) => _HostFocusHistory(host.focusModels),
);

/// The stored focus history of [profileId], once it has been read from disk.
final focusProfileDataProvider = FutureProvider.autoDispose
    .family<ProfileFocusData?, String>(
      (ref, profileId) =>
          ref.watch(focusHistoryProvider).profileData(profileId),
    );

final class _LocalFocusHistory implements FocusHistory {
  _LocalFocusHistory(this._service);

  final FocusModelService _service;

  @override
  Future<ProfileFocusData?> profileData(String profileId) async {
    await _service.initialize();
    return _service.getProfileData(profileId);
  }

  @override
  Future<void> addPoint({
    required String profileId,
    required double temperatureCelsius,
    required int focusPosition,
    required double hfr,
    String? filterName,
  }) => _service.addDataPoint(
    profileId: profileId,
    temperatureCelsius: temperatureCelsius,
    focusPosition: focusPosition,
    hfr: hfr,
    filterName: filterName,
  );

  @override
  Future<String> export(String profileId) async =>
      _service.exportData(profileId);

  @override
  Future<void> import(String profileId, Map<String, dynamic> data) =>
      _service.importData(profileId, jsonEncode(data));

  @override
  Future<void> clear(String profileId) => _service.clearProfileData(profileId);

  @override
  Future<FilterOffsets> filterOffsets(String profileId) async {
    final data = await profileData(profileId);
    return (
      offsets: {
        for (final entry
            in (data?.filterOffsets ?? const <String, FilterOffset>{}).entries)
          entry.key: entry.value.offsetSteps,
      },
      referenceFilter: data?.referenceFilter,
    );
  }

  @override
  Future<void> setFilterOffset({
    required String profileId,
    required String referenceFilter,
    required MapEntry<String, int> changed,
    required Map<String, int> all,
  }) => _service.updateFilterOffsets(profileId, {
    for (final entry in all.entries)
      entry.key: FilterOffset(
        filterName: entry.key,
        referenceFilter: referenceFilter,
        offsetSteps: entry.value,
        measurementCount: 1,
        confidence: 1.0,
      ),
  }, referenceFilter: referenceFilter);

  @override
  Future<void> setReferenceFilter(String profileId, String filterName) =>
      _service.setReferenceFilter(profileId, filterName);
}

final class _HostFocusHistory implements FocusHistory {
  _HostFocusHistory(this._host);

  final HostFocusModels _host;

  @override
  Future<ProfileFocusData?> profileData(String profileId) async {
    final responses = await Future.wait<Map<String, dynamic>>([
      _host.getFocusModelData(),
      _host.getFocusModel(),
    ]);
    return parseRemoteFocusProfileData(responses[0], responses[1]);
  }

  @override
  Future<void> addPoint({
    required String profileId,
    required double temperatureCelsius,
    required int focusPosition,
    required double hfr,
    String? filterName,
  }) => _host.addFocusDataPoint(
    temperature: temperatureCelsius,
    position: focusPosition,
    hfr: hfr,
    filter: filterName,
  );

  @override
  Future<String> export(String profileId) async => const JsonEncoder.withIndent(
    '  ',
  ).convert(await _host.exportFocusModel());

  @override
  Future<void> import(String profileId, Map<String, dynamic> data) =>
      _host.importFocusModel(data);

  @override
  Future<void> clear(String profileId) => _host.clearFocusModelData();

  @override
  Future<FilterOffsets> filterOffsets(String profileId) async {
    final response = await _host.getFilterFocusOffsets();
    final offsets = response['offsets'];
    return (
      offsets: {
        if (offsets is Map)
          for (final entry in offsets.entries)
            if (entry.value case {'offsetSteps': final num steps})
              entry.key.toString(): steps.toInt(),
      },
      referenceFilter: response['referenceFilter'] as String?,
    );
  }

  @override
  Future<void> setFilterOffset({
    required String profileId,
    required String referenceFilter,
    required MapEntry<String, int> changed,
    required Map<String, int> all,
  }) => _host.setFilterFocusOffsets(
    referenceFilter: referenceFilter,
    offsets: {changed.key: changed.value},
  );

  @override
  Future<void> setReferenceFilter(String profileId, String filterName) => _host
      .setFilterFocusOffsets(referenceFilter: filterName, offsets: const {});
}

/// Combines the host's split focus-history and fitted-model response shapes
/// into the same value object local UI already consumes.
ProfileFocusData parseRemoteFocusProfileData(
  Map<String, dynamic> dataResponse,
  Map<String, dynamic> modelResponse,
) {
  final profileId =
      dataResponse['profileId'] ?? modelResponse['profileId'] ?? '';
  final rawPoints = dataResponse['dataPoints'];
  final points = rawPoints is List
      ? rawPoints
            .whereType<Map>()
            .map((point) => Map<String, dynamic>.from(point))
            .toList(growable: false)
      : const <Map<String, dynamic>>[];
  final rawModel = modelResponse['hasModel'] == true
      ? modelResponse['model']
      : null;

  return ProfileFocusData.fromJson({
    'profileId': profileId.toString(),
    'dataPoints': points,
    'temperatureModel': rawModel is Map
        ? Map<String, dynamic>.from(rawModel)
        : null,
    'referenceFilter': dataResponse['referenceFilter'] as String?,
  });
}
