# Skotiq API Documentation

Complete API documentation for the Skotiq astronomical imaging application.

## Overview

Skotiq is a comprehensive astronomical imaging application with multiple API layers:

- **Backend API** - High-level device control interface
- **Bridge API** - Low-level Rust FFI bindings
- **Core Services** - Business logic and data services
- **Planetarium API** - Sky rendering and catalog management
- **Web Server API** - REST API for remote control
- **Plugin API** - Extension system for custom functionality

## Documentation Index

### Core APIs

- [Backend API](./backend-api.md) - Main device control interface (`SkotiqBackend`)
- [Bridge API](./bridge-api.md) - Rust FFI bindings for native device drivers
- [Core Services](./core-services.md) - Business logic services (imaging, plate solving, etc.)

### Specialized APIs

- [Planetarium API](./planetarium-api.md) - Sky rendering, catalogs, and planning
- [Web Server API](./web-server-api.md) - REST API for remote control
- [Plugin API](./plugin-api.md) - Plugin system for extending functionality
- [Headless Secure Setup](../headless-secure-setup.md) - Authenticated LAN setup and verification
- [Supported Hardware By Platform](../supported-hardware-by-platform.md) - Driver and device support matrix
- [Known Limitations](../known-limitations.md) - Accepted release limitations and unsupported-platform summary
- [Release Notes Template](../release-notes-template.md) - Public release note evidence template
- [Migration, Backup, and Restore Guide](../migration-backup-restore.md) - Backup format, restore routes, and migration verification

### Reference

- [Data Models](./data-models.md) - All data types, enums, and models
- [Error Handling](./error-handling.md) - Error types and handling patterns

## Quick Start

### Using the Backend API

```dart
import 'package:skotiq_core/skotiq_core.dart';

// Get the backend instance
final backend = ref.read(backendProvider);

// Discover devices
final cameras = await backend.discoverDevices(DeviceType.camera);

// Connect to a camera
await backend.connectDevice(DeviceType.camera, 'camera-id');

// Start an exposure
await backend.cameraStartExposure(
  deviceId: 'camera-id',
  exposureTime: 60.0,
  frameType: FrameType.light,
);
```

### Using the Bridge API

```dart
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;

// Initialize the bridge
bridge.apiInit();

// Discover devices
final devices = await bridge.apiDiscoverDevices(deviceType: bridge.DeviceType.camera);

// Connect to device
await bridge.apiConnectDevice(
  deviceType: bridge.DeviceType.camera,
  deviceId: 'camera-id',
);
```

## Architecture

```
┌─────────────────────────────────────────┐
│         Application Layer                │
│  (Flutter UI, Screens, Widgets)          │
└──────────────┬──────────────────────────┘
               │
┌──────────────▼──────────────────────────┐
│         Backend API Layer                │
│  (SkotiqBackend - Abstract)          │
│  ├── FfiBackend (Direct FFI)            │
│  ├── NetworkBackend (REST API)          │
│  └── DisconnectedBackend (Stub)         │
└──────────────┬──────────────────────────┘
               │
┌──────────────▼──────────────────────────┐
│         Bridge API Layer                 │
│  (Rust FFI Bindings)                     │
│  ├── Device Discovery                    │
│  ├── Device Control                      │
│  ├── Image Processing                    │
│  └── Plate Solving                       │
└──────────────┬──────────────────────────┘
               │
┌──────────────▼──────────────────────────┐
│         Native Layer                     │
│  (Rust - ASCOM, Alpaca, INDI, Native)    │
└─────────────────────────────────────────┘
```

## Device Support

Skotiq supports multiple device driver protocols:

- **ASCOM** - Windows-only, industry standard
- **Alpaca** - Cross-platform, network-based
- **INDI** - INDI-server based device access, with device capability depth set by each driver
- **Native** - Capability-gated SDK access where vendor libraries are packaged and verified
- **Simulator** - For testing and development

See [Supported Hardware By Platform](../supported-hardware-by-platform.md)
before treating a driver backend or native SDK as a public release guarantee.

## Contributing

When adding new API methods:

1. Add to `SkotiqBackend` abstract class
2. Implement in all backend implementations (FFI, Network, Disconnected)
3. Add to Bridge API if needed
4. Update this documentation

## Version

This documentation covers Skotiq version 2.0.0

