# Core Services API Reference

Core services provide high-level business logic and data management for the Skotiq application. Services are located in `packages/skotiq_core/lib/src/services/`.

## ImagingService

Service for managing camera capture operations.

**Location:** `packages/skotiq_core/lib/src/services/imaging_service.dart`

### `captureImage`

Start a single exposure capture.

```dart
Future<CapturedImageData?> captureImage({
  required ExposureSettings settings,
  String? targetName,
  int? frameNumber,
})
```

**Parameters:**
- `settings` - Exposure settings (time, frame type, binning, etc.)
- `targetName` - Optional target name
- `frameNumber` - Optional frame number

**Returns:** Captured image data or null if cancelled

**Example:**
```dart
final service = ImagingService(ref);
final image = await service.captureImage(
  settings: ExposureSettings(
    exposureTime: 60.0,
    frameType: FrameType.light,
    binningX: 1,
    binningY: 1,
  ),
  targetName: 'M42',
);
```

## DeviceService

Service for device discovery, connection management, and communication.

**Location:** `packages/skotiq_core/lib/src/services/device_service.dart`

Handles:
- Device discovery across ASCOM, INDI, Alpaca, and native protocols
- Connection/disconnection lifecycle
- Device state management
- Error handling and recovery

## SessionService

Service for managing imaging sessions with checkpoint recovery.

**Location:** `packages/skotiq_core/lib/src/services/session_service.dart`

Features:
- Session lifecycle management (start, pause, resume, end)
- Progress tracking
- Checkpoint creation for recovery
- Statistics aggregation

## PlateSolveService

Service for plate solving operations.

**Location:** `packages/skotiq_core/lib/src/services/plate_solve_service.dart`

Provides:
- ASTAP plate solver integration
- Image coordinate determination
- Target centering via iterative solving
- WCS overlay generation

## ProfileService

Service for managing equipment profiles.

**Location:** `packages/skotiq_core/lib/src/services/profile_service.dart`

Handles:
- Equipment profile CRUD operations
- Profile activation/deactivation
- Device configuration persistence
- Filter and optical settings

## SequenceFileService

Service for sequence file I/O operations.

**Location:** `packages/skotiq_core/lib/src/services/sequence_file_service.dart`

Provides:
- Sequence JSON serialization/deserialization
- Template management
- Import/export functionality

## SequenceRepository

Repository for sequence data management and persistence.

**Location:** `packages/skotiq_core/lib/src/services/sequence_repository.dart`

Handles:
- Sequence CRUD in database
- Node tree persistence
- Template storage

## FocusModelService

Service for focus modeling and prediction.

**Location:** `packages/skotiq_core/lib/src/services/focus_model_service.dart`

Features:
- Temperature compensation modeling
- Focus position prediction
- ML-based focus estimation

## CenteringService

Service for automated target centering.

**Location:** `packages/skotiq_core/lib/src/services/centering_service.dart`

Provides:
- Iterative plate solving for centering
- Slew correction
- Centering tolerance verification

## AnnotationService

Service for image annotations and catalog overlays.

**Location:** `packages/skotiq_core/lib/src/services/annotation_service.dart`

Features:
- Celestial object identification
- Annotation overlay generation
- Object data lookup

## WcsOverlay

Service for World Coordinate System overlays on images.

**Location:** `packages/skotiq_core/lib/src/services/wcs_overlay.dart`

Provides:
- Coordinate grid rendering
- Cardinal direction indicators
- Object marking

## FlatWizardService

Service for automated flat frame capture.

**Location:** `packages/skotiq_core/lib/src/services/flat_wizard_service.dart`

Features:
- Optimal exposure calculation
- Multi-filter flat sequencing
- ADU target achievement

## MosaicService

Service for mosaic planning and execution.

**Location:** `packages/skotiq_core/lib/src/services/mosaic_service.dart`

Provides:
- Panel layout calculation
- Overlap configuration
- Coordinate generation for each panel

## SchedulerService

Service for sequence scheduling and time-based automation.

**Location:** `packages/skotiq_core/lib/src/services/scheduler_service.dart`

Handles:
- Target scheduling based on altitude/visibility
- Sequence timing optimization
- Twilight calculations

## Weather Services

### WeatherRadarService
**Location:** `packages/skotiq_core/lib/src/services/weather/weather_radar_service.dart`

Fetches and processes weather radar imagery.

### WeatherAlertService
**Location:** `packages/skotiq_core/lib/src/services/weather/weather_alert_service.dart`

Generates safety alerts based on conditions.

### CloudMotionAnalyzer
**Location:** `packages/skotiq_core/lib/src/services/weather/cloud_motion_analyzer.dart`

Analyzes cloud motion patterns for prediction.

## Utility Services

### BackupService
**Location:** `packages/skotiq_core/lib/src/services/backup_service.dart`

Database and settings backup/restore.

### AutoSaveService
**Location:** `packages/skotiq_core/lib/src/services/auto_save_service.dart`

Automatic state persistence.

### LoggingService
**Location:** `packages/skotiq_core/lib/src/services/logging_service.dart`

Application logging and diagnostics.

### ErrorService
**Location:** `packages/skotiq_core/lib/src/services/error_service.dart`

Error reporting and handling.

### SessionExportService
**Location:** `packages/skotiq_core/lib/src/services/session_export_service.dart`

Session data export to various formats.

### DeviceMatchingService
**Location:** `packages/skotiq_core/lib/src/services/device_matching_service.dart`

Profile-to-device matching for auto-connect.

## Providers

Core services are typically accessed through Riverpod providers. Key providers include:

### Backend & Infrastructure
- `backendProvider` - Backend instance (FfiBackend, NetworkBackend, DisconnectedBackend)
- `databaseProvider` - Drift database instance
- `deviceBackendSelectionProvider` - Per-device backend selection

### Equipment State
- `cameraStateProvider` - Camera connection and state
- `mountStateProvider` - Mount/telescope state
- `focuserStateProvider` - Focuser state
- `filterWheelStateProvider` - Filter wheel state
- `guiderStateProvider` - Guider state
- `rotatorStateProvider` - Rotator state
- `domeStateProvider` - Dome state
- `weatherStateProvider` - Weather station state
- `safetyMonitorStateProvider` - Safety monitor state
- `coverCalibratorStateProvider` - Cover calibrator state

### Imaging
- `exposureSettingsProvider` - Current exposure parameters
- `lastImageStatsProvider` - Statistics of last captured image
- `stretchParamsProvider` - Image stretch parameters
- `coolingSettingsProvider` - Camera cooling parameters
- `focusSettingsProvider` - Focus settings
- `ditherSettingsProvider` - Guiding dither settings

### Sequence & Automation
- `sequenceExecutionStateProvider` - Current sequence execution state
- `sequenceProgressProvider` - Sequence progress tracking
- `currentSequenceProvider` - Currently loaded sequence
- `sequenceExecutorProvider` - Sequence execution engine

### PHD2 Guiding
- `phd2ConnectedProvider` - PHD2 connection status
- `phd2StateProvider` - PHD2 guiding state
- `guideStatsProvider` - Guiding statistics
- `guideGraphProvider` - Guide star tracking graph

### Settings & Profiles
- `appSettingsProvider` - Application settings
- `locationSettingsProvider` - Observer location
- `outputSettingsProvider` - Output directory and format
- `plateSolveSettingsProvider` - Plate solving configuration

### Weather
- `weatherRadarServiceProvider` - Weather radar service
- `weatherAlertServiceProvider` - Weather alert service
- `isWeatherSafeProvider` - Weather safety determination

### Session
- `sessionServiceProvider` - Session service
- `sessionStateProvider` - Session state
- `isSessionActiveProvider` - Active session flag

**Example Usage:**
```dart
// Read a provider value
final backend = ref.read(backendProvider);

// Watch a provider for changes
final cameraState = ref.watch(cameraStateProvider);

// Access service via provider
final sessionService = ref.read(sessionServiceProvider);
await sessionService.startSession();
```
