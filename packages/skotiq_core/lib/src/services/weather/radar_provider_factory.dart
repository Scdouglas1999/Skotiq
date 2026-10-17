import '../../models/weather/weather_models.dart';
import 'radar_provider.dart';

/// Factory for selecting and managing radar data providers.
///
/// Maintains a registry of available providers and selects the best one
/// based on geographic coverage and user preferences.
class RadarProviderFactory {
  /// Internal registry of providers by type.
  final Map<RadarProviderType, RadarProvider> _providers = {};

  /// Auto-selection priority, most-preferred first.
  ///
  /// GOES Satellite shows actual cloud cover (ideal for astrophotography);
  /// NOAA NEXRAD and RainViewer show precipitation; Open-Meteo provides a
  /// numerical cloud forecast; MET Norway is the independent numerical fallback
  /// for when Open-Meteo's single host degrades — hence last.
  static const List<RadarProviderType> autoPriority = [
    RadarProviderType.goesSatellite,
    RadarProviderType.noaa,
    RadarProviderType.rainviewer,
    RadarProviderType.openmeteo,
    RadarProviderType.metno,
  ];

  /// Registers a provider with the factory.
  ///
  /// If a provider of the same type already exists, it will be disposed
  /// and replaced.
  void registerProvider(RadarProvider provider) {
    // Dispose existing provider if present
    final existing = _providers[provider.providerType];
    if (existing != null) {
      existing.dispose();
    }

    _providers[provider.providerType] = provider;
  }

  /// Returns all registered providers.
  List<RadarProvider> get allProviders => _providers.values.toList();

  /// Selects the best provider for a given location and preference.
  ///
  /// Selection logic:
  /// 1. If [preferredProvider] is not [RadarProviderType.auto], attempt to use it
  ///    if it covers the location.
  /// 2. If [preferredProvider] is [RadarProviderType.auto], select automatically
  ///    with priority: NOAA > RainViewer > OpenMeteo.
  /// 3. Returns null if no provider covers the location.
  ///
  /// Parameters:
  /// - [latitude]: Location latitude in degrees
  /// - [longitude]: Location longitude in degrees
  /// - [preferredProvider]: Preferred provider type
  ///
  /// Returns the selected [RadarProvider] or null if none available.
  RadarProvider? selectProvider({
    required double latitude,
    required double longitude,
    required RadarProviderType preferredProvider,
  }) {
    // Handle non-auto preference
    if (preferredProvider != RadarProviderType.auto) {
      final provider = _providers[preferredProvider];
      if (provider != null && provider.coversLocation(latitude, longitude)) {
        return provider;
      }
      // Preferred provider doesn't cover location, fall through to auto
    }

    // Auto-select using the shared priority order (most-preferred first).
    for (final type in autoPriority) {
      final provider = _providers[type];
      if (provider != null && provider.coversLocation(latitude, longitude)) {
        return provider;
      }
    }

    // No provider covers this location
    return null;
  }

  /// Builds the ordered failover candidate list for a location.
  ///
  /// The [selected] provider (the one [selectProvider] chose) leads, followed
  /// by every other registered provider that covers the location in
  /// [autoPriority] order, de-duplicated. This lets [WeatherRadarService] try
  /// the user's choice first and then fall through to alternatives — e.g.
  /// Open-Meteo → MET Norway — when the leading provider fails outright.
  List<RadarProvider> failoverCandidates({
    required double latitude,
    required double longitude,
    required RadarProvider selected,
  }) {
    final ordered = <RadarProvider>[selected];
    for (final type in autoPriority) {
      final provider = _providers[type];
      if (provider == null) continue;
      if (provider == selected) continue;
      if (!provider.coversLocation(latitude, longitude)) continue;
      ordered.add(provider);
    }
    return ordered;
  }

  /// Gets a specific provider by type.
  ///
  /// Returns null if the provider type is not registered or is [RadarProviderType.auto].
  RadarProvider? getProvider(RadarProviderType type) {
    if (type == RadarProviderType.auto) {
      return null;
    }
    return _providers[type];
  }

  /// Checks if any registered provider covers the given location.
  bool hasProviderForLocation(double latitude, double longitude) {
    return _providers.values.any(
      (provider) => provider.coversLocation(latitude, longitude),
    );
  }

  /// Disposes all registered providers and clears the registry.
  void dispose() {
    for (final provider in _providers.values) {
      provider.dispose();
    }
    _providers.clear();
  }

  /// Returns the number of registered providers.
  int get providerCount => _providers.length;

  /// Checks if a specific provider type is registered.
  bool hasProvider(RadarProviderType type) {
    return type != RadarProviderType.auto && _providers.containsKey(type);
  }
}
