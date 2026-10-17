# Radar Providers

This directory contains implementations of radar data providers for weather monitoring.

## Available Providers

### RainViewer (`rainviewer_radar_provider.dart`)

Global radar provider using the free RainViewer API.

**Features:**
- Global coverage (entire world)
- No API key required
- ~2 hours of historical data
- ~30 minutes of forecast (nowcast) data
- Updates every 10 minutes

**Usage Example:**

```dart
import 'package:skotiq_core/src/services/weather/providers/rainviewer_radar_provider.dart';

// Create provider instance
final provider = RainViewerRadarProvider();

// Fetch radar frames for a location
final result = await provider.fetchRadarFrames(
  latitude: 40.7128,
  longitude: -74.0060,
  radiusKm: 100.0,
);

if (result.isSuccess) {
  // Process radar frames
  for (final frame in result.frames) {
    print('Frame at ${frame.timestamp}');
    print('Is forecast: ${frame.isForecast}');

    // Build tile URL for map rendering
    final tileUrl = provider.buildTileUrl(frame, z: 8, x: 123, y: 456);
    print('Tile URL: $tileUrl');
  }
} else {
  print('Error: ${result.errorMessage}');
}

// Clean up when done
provider.dispose();
```

**API Response Format:**

The RainViewer API returns data in this format:
```json
{
  "version": "2.0",
  "generated": 1234567890,
  "host": "https://tilecache.rainviewer.com",
  "radar": {
    "past": [
      {"time": 1234567200, "path": "/v2/radar/1234567200/256/{z}/{x}/{y}/2/1_1.png"}
    ],
    "nowcast": [
      {"time": 1234568400, "path": "/v2/radar/1234568400/256/{z}/{x}/{y}/2/1_1.png"}
    ]
  }
}
```

**Implementation Notes:**
- Uses `http` package for API requests
- Combines `host` + `path` to create complete tile URL templates
- Sets global bounds (-90 to 90 lat, -180 to 180 lon) on all frames
- Sorts frames by timestamp for animation playback
- Handles missing/malformed data gracefully
- Provides detailed error messages for debugging

## Adding New Providers

To add a new radar provider:

1. Create a new file in this directory (e.g., `new_provider_radar_provider.dart`)
2. Extend the `RadarProvider` abstract class
3. Implement all required methods:
   - `name` - Human-readable provider name
   - `providerType` - Enum value from `RadarProviderType`
   - `coverageBounds` - Geographic coverage area
   - `fetchRadarFrames()` - Fetch radar data from the API
   - `getAvailableTimeRange()` - Return (history, forecast) durations
   - `buildTileUrl()` - Convert frame + coordinates to tile URL
   - `dispose()` - Clean up resources (don't forget to call `super.dispose()`)
4. Add comprehensive tests in `test/services/weather/`
5. Export the provider in `providers.dart`
6. Register with `RadarProviderFactory` in your app initialization

**Testing Tip:** Use `http.testing.MockClient` for HTTP request mocking in tests.
