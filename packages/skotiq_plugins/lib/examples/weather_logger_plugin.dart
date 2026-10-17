import 'dart:async';
import 'dart:convert';

import '../src/plugin_api.dart';

/// Plugin that logs weather data from events to persistent storage.
///
/// Demonstrates:
/// - Subscribing to application events via the event bus
/// - Storing structured data in plugin storage as JSON
/// - Managing subscriptions across enable/disable cycles
/// - Aggregating data with configurable retention
///
/// Usage:
/// ```dart
/// final host = ref.read(pluginHostProvider);
/// await host.registerPlugin(WeatherLoggerPlugin());
/// ```
class WeatherLoggerPlugin extends SkotiqPlugin {
  PluginContext? _context;
  StreamSubscription? _weatherSubscription;
  StreamSubscription? _focuserSubscription;

  /// Maximum number of weather readings to retain in storage
  static const int maxReadings = 1000;

  /// Key used to store weather readings in plugin storage
  static const String storageKey = 'weatherReadings';

  /// Key used to store the reading count
  static const String countKey = 'totalReadings';

  /// In-memory buffer of weather readings since last flush
  final List<Map<String, dynamic>> _readingBuffer = [];

  /// Timer for periodic storage flushes
  Timer? _flushTimer;

  @override
  String get id => 'com.skotiq.weatherlogger';

  @override
  String get name => 'Weather Logger';

  @override
  String get version => '1.0.0';

  @override
  String get description =>
      'Logs weather station data and focuser temperature readings '
      'to persistent storage for trend analysis';

  @override
  String get author => 'Skotiq Team';

  @override
  String? get minAppVersion => '2.5.0';

  @override
  Future<void> onLoad(PluginContext context) async {
    _context = context;
    context.logger.info('Weather logger initializing');

    // Restore reading count from storage
    final totalReadings = await context.storage.getInt(countKey) ?? 0;
    context.logger.info('Previously recorded $totalReadings weather readings');
  }

  @override
  Future<void> onEnable() async {
    final context = _context;
    if (context == null) return;

    context.logger.info('Starting weather data collection');

    // Subscribe to weather station events
    _weatherSubscription = context.eventBus.on('weather.updated').listen((
      data,
    ) {
      _recordReading('weather_station', data);
    });

    // Also record temperature from focuser events (common temperature source)
    _focuserSubscription = context.eventBus.on('focuser.moved').listen((data) {
      final temperature = data['temperature'];
      if (temperature != null) {
        _recordReading('focuser_probe', {'temperature': temperature});
      }
    });

    // Flush buffered readings to storage every 5 minutes
    _flushTimer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => _flushToStorage(),
    );
  }

  @override
  Future<void> onDisable() async {
    _context?.logger.info('Stopping weather data collection');

    // Cancel subscriptions
    await _weatherSubscription?.cancel();
    _weatherSubscription = null;

    await _focuserSubscription?.cancel();
    _focuserSubscription = null;

    // Cancel flush timer
    _flushTimer?.cancel();
    _flushTimer = null;

    // Flush any remaining buffered readings
    await _flushToStorage();
  }

  @override
  Future<void> onUnload() async {
    _context?.logger.info('Weather logger unloading');

    // Final flush
    await _flushToStorage();

    // Clean up
    await _weatherSubscription?.cancel();
    await _focuserSubscription?.cancel();
    _flushTimer?.cancel();

    _weatherSubscription = null;
    _focuserSubscription = null;
    _flushTimer = null;
    _readingBuffer.clear();
    _context = null;
  }

  /// Record a weather reading to the in-memory buffer
  void _recordReading(String source, Map<String, dynamic> data) {
    final reading = {
      'source': source,
      'timestamp': DateTime.now().toIso8601String(),
      ...data,
    };

    _readingBuffer.add(reading);
    _context?.logger.debug(
      'Recorded $source reading: '
      '${data.entries.map((e) => '${e.key}=${e.value}').join(', ')}',
    );

    // Emit an event so other plugins can react to logged weather data
    _context?.eventBus.emit('plugin.weatherlogger.reading', reading);
  }

  /// Flush buffered readings to persistent storage
  Future<void> _flushToStorage() async {
    final context = _context;
    if (context == null || _readingBuffer.isEmpty) return;

    try {
      // Load existing readings from storage
      final existingJson = await context.storage.getString(storageKey);
      final List<dynamic> existing = existingJson != null
          ? jsonDecode(existingJson) as List
          : [];

      // Append new readings
      existing.addAll(_readingBuffer);

      // Trim to max retention
      if (existing.length > maxReadings) {
        existing.removeRange(0, existing.length - maxReadings);
      }

      // Persist
      await context.storage.setString(storageKey, jsonEncode(existing));

      // Update total count
      final previousTotal = await context.storage.getInt(countKey) ?? 0;
      await context.storage.setInt(
        countKey,
        previousTotal + _readingBuffer.length,
      );

      context.logger.info(
        'Flushed ${_readingBuffer.length} readings to storage '
        '(${existing.length} retained)',
      );

      _readingBuffer.clear();
    } catch (e, st) {
      context.logger.error('Failed to flush weather readings', e, st);
    }
  }

  /// Get all stored weather readings.
  ///
  /// Returns an empty list if no readings are stored or if the plugin
  /// context is not available.
  Future<List<Map<String, dynamic>>> getReadings() async {
    final context = _context;
    if (context == null) return [];

    final json = await context.storage.getString(storageKey);
    if (json == null) return [];

    try {
      final decoded = jsonDecode(json) as List;
      return decoded.cast<Map<String, dynamic>>();
    } catch (e, st) {
      context.logger.error('Failed to decode stored readings', e, st);
      return [];
    }
  }

  /// Get the total number of readings ever recorded (including pruned ones).
  Future<int> getTotalReadingCount() async {
    return await _context?.storage.getInt(countKey) ?? 0;
  }

  /// Clear all stored weather data.
  Future<void> clearReadings() async {
    _readingBuffer.clear();
    await _context?.storage.remove(storageKey);
    await _context?.storage.setInt(countKey, 0);
    _context?.logger.info('All weather readings cleared');
  }
}
