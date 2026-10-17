# Wear OS Tile — Scaffolding plan

shipped the Apple Watch complication; Wear OS parity is parked
behind this plan. The work is non-trivial — a Wear OS Tile is a separate
Gradle module with its own manifest, Tile service, and complication data
source — but the design and file layout are documented here so a future
contributor can pick this up without re-discovering everything.

## Goal

Show the same payload the iOS complication shows on a Wear OS smart
watch:

- **Tile** (primary surface) — three rows: target name, frame counter
  (`12 / 120`), weather safety label with colour swatch.
- **ComplicationDataSource** (secondary surface) — short-text + ranged-
  value complications so users can pin Skotiq onto a Wear OS watch
  face that already has slots configured (e.g., Pixel Watch Material
  faces).

## Files to add

### 1. New Gradle module: `apps/mobile/android/wear/`

```
apps/mobile/android/wear/
├── build.gradle                 — applies com.android.application + Kotlin
├── proguard-rules.pro
└── src/main/
    ├── AndroidManifest.xml      — declares the Tile + ComplicationDataSource services
    ├── kotlin/com/skotiq/wear/
    │   ├── SkotiqTileService.kt
    │   ├── SkotiqTileRenderer.kt
    │   ├── SkotiqComplicationDataSourceService.kt
    │   ├── snapshot/
    │   │   ├── SnapshotPayload.kt              — Kotlin data class matching
    │   │   │                                     watch_complication_service.dart
    │   │   ├── SnapshotDataLayerClient.kt      — wraps
    │   │   │                                     Wearable.getDataClient(...)
    │   │   └── SnapshotKeys.kt                 — shared path constants
    │   └── ui/
    │       ├── ProgressArc.kt                  — reusable arc renderer
    │       └── theme/SkotiqWearColors.kt   — palette duplicate
    └── res/
        ├── drawable/
        │   ├── ic_target.xml
        │   └── ic_weather_safe.xml / ic_weather_unsafe.xml
        ├── values/
        │   ├── strings.xml
        │   └── colors.xml                      — mirrors Skotiq brand
        └── xml/
            └── complication_data_source.xml    — declares supported types
```

### 2. Phone-side payload publisher

The iOS path uses an App Group + `UserDefaults`. Android shares state
via Google Play Services' Wearable Data Layer API.

New files in the existing mobile module:

```
apps/mobile/lib/services/wear_os_complication_service.dart
apps/mobile/lib/services/wear_os_complication_lifecycle_provider.dart
apps/mobile/android/app/src/main/kotlin/com/skotiq/mobile/
└── WearOsComplicationBridge.kt   — DataClient.putDataItem(...) with the
                                    same JSON schema watch_complication_service
                                    publishes to iOS
```

The bridge writes to data path `/skotiq/complication/snapshot` with
an `Asset` carrying the UTF-8 JSON bytes. The Wear OS module subscribes
in `SkotiqTileService.onTileRequest(...)` and decodes the same
`SnapshotPayload` keys.

### 3. Required Gradle changes

In `apps/mobile/android/settings.gradle`:

```
include ':app', ':wear'
```

In `apps/mobile/android/app/build.gradle` (phone app — required so the
phone <-> watch pairing works automatically):

```gradle
dependencies {
    wearApp project(':wear')
    implementation 'com.google.android.gms:play-services-wearable:18.2.0'
}
```

In `apps/mobile/android/wear/build.gradle` (new):

```gradle
plugins {
    id 'com.android.application'
    id 'org.jetbrains.kotlin.android'
}

android {
    namespace 'com.skotiq.wear'
    compileSdk 34
    defaultConfig {
        applicationId 'com.skotiq.mobile'   // MUST match phone applicationId
        minSdk 30                                // Wear OS 3+
        targetSdk 34
    }
}

dependencies {
    implementation 'androidx.wear.tiles:tiles:1.3.0'
    implementation 'androidx.wear.tiles:tiles-material:1.3.0'
    implementation 'androidx.wear.protolayout:protolayout:1.1.0'
    implementation 'androidx.wear.watchface:watchface-complications-data-source-ktx:1.2.1'
    implementation 'com.google.android.gms:play-services-wearable:18.2.0'
    implementation 'org.jetbrains.kotlinx:kotlinx-coroutines-play-services:1.7.3'
}
```

## Wire format

Identical JSON schema to the iOS path so the Dart side has one source of
truth:

```dart
class WatchComplicationSnapshot {
  String targetName;
  int framesCompleted;
  int framesTotal;
  String currentFilter;
  String jobState;
  bool weatherSafe;
  String weatherLabel;
}
```

Kotlin counterpart in `snapshot/SnapshotPayload.kt`:

```kotlin
@kotlinx.serialization.Serializable
data class SnapshotPayload(
    val targetName: String,
    val framesCompleted: Int,
    val framesTotal: Int,
    val currentFilter: String,
    val jobState: String,
    val weatherSafe: Boolean,
    val weatherLabel: String,
)
```

## Manifest declarations

Inside `apps/mobile/android/wear/src/main/AndroidManifest.xml`:

```xml
<application android:label="@string/app_name">
  <service
      android:name=".SkotiqTileService"
      android:exported="true"
      android:permission="com.google.android.wearable.permission.BIND_TILE_PROVIDER">
    <intent-filter>
      <action android:name="androidx.wear.tiles.action.BIND_TILE_PROVIDER"/>
    </intent-filter>
    <meta-data
        android:name="androidx.wear.tiles.PREVIEW"
        android:resource="@drawable/tile_preview"/>
  </service>

  <service
      android:name=".SkotiqComplicationDataSourceService"
      android:exported="true"
      android:permission="com.google.android.wearable.permission.BIND_COMPLICATION_PROVIDER">
    <intent-filter>
      <action android:name="android.support.wearable.complications.ACTION_COMPLICATION_UPDATE_REQUEST"/>
    </intent-filter>
    <meta-data
        android:name="android.support.wearable.complications.SUPPORTED_TYPES"
        android:value="SHORT_TEXT,RANGED_VALUE,LONG_TEXT"/>
    <meta-data
        android:name="android.support.wearable.complications.UPDATE_PERIOD_SECONDS"
        android:value="60"/>
  </service>
</application>
```

## Throttle policy (must mirror iOS)

The phone-side `WearOsComplicationLifecycleController` MUST throttle
DataClient writes to at most one per 30 s — the Wearable Data Layer
batches writes anyway, but a Dart-side throttle keeps the contract
identical to the Apple Watch path so a future developer doesn't have
to reason about two different cadences.

## Out of scope for this scaffolding

- Tile interactivity (tap-to-pause-sequence) — would require a
  `LoadAction` from the Tile back to the host, which needs the host
  app's MainActivity to expose an intent. Doable, defer to a follow-up.
- Standalone watch face — not needed for parity with iOS; the
  complication slots on existing faces are the comparable surface.

## Verification once shipped

1. Pair a Wear OS emulator to the phone via Android Studio.
2. Install both APKs (phone + watch) — the phone build auto-pushes the
   watch APK because of `wearApp project(':wear')`.
3. Trigger a sequence on the desktop; confirm the Tile updates within
   30 seconds.
4. Add the complication to a Pixel Watch Material face slot; confirm
   the ranged value matches the iOS circular complication.

## Pointers

- Tile lifecycle and `onTileRequest` semantics:
  https://developer.android.com/training/wearables/tiles
- ComplicationDataSourceService skeleton:
  https://developer.android.com/training/wearables/wear-complications/data-sources
- Wearable Data Layer (asset transport):
  https://developer.android.com/training/wearables/data-layer/assets
