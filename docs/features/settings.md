# Settings

The Settings screen provides comprehensive configuration options for all aspects of Skotiq. Open it from the gear button in the top bar, or with Ctrl+K. Its sections are listed in a left column.

## Settings Categories

Skotiq has the following settings categories:

1. Connection
2. General
3. Appearance
4. Location
5. Equipment Profiles
6. Catalogs
7. Imaging
8. Annotations
9. Sequencer
10. Plate Solving
11. PHD2 Guiding
12. Science
13. Notifications
14. File Paths
15. Plugins
16. About

## Connection Settings

Configure server connections for remote/local operation.

### Connection Status

- Shows current state: Connected, Local Mode, or Disconnected
- Displays server address when connected
- Color-coded status indicator

### Remote Connection

When connected to remote server:
- Server address and port displayed
- **Sync Location** button to download settings
- **Disconnect** button

### Local Mode

- All processing on local machine
- No server connection required
- Default mode for standalone use

## General Settings

Basic application behavior settings.

### Startup

| Setting | Description |
|---------|-------------|
| **Start minimized** | Launch app minimized to system tray |
| **Auto-connect equipment** | Connect to last used devices on startup |

### Behavior

| Setting | Description |
|---------|-------------|
| **Auto-save sequences** | Automatically save sequence changes |
| **Confirm before closing** | Show dialog when closing during capture |

## Appearance Settings

Customize the visual appearance.

### Theme

| Setting | Options |
|---------|---------|
| **Dark mode** | Enable/disable dark theme (recommended for night use) |
| **Accent color** | Indigo, Emerald, Amber, Red, Violet, Pink, Cyan |

### Display

| Setting | Options |
|---------|---------|
| **Font size** | Small, Medium, Large |
| **Rail collapsed** | Start with the navigation rail icon-only (64 px) rather than expanded |

## Location Settings

Configure your observing location.

### Coordinates

| Setting | Range | Description |
|---------|-------|-------------|
| **Latitude** | -90° to 90° | North positive, South negative |
| **Longitude** | -180° to 180° | East positive, West negative |
| **Elevation** | -500m to 10,000m | Height above sea level |

### Location Tools

- **Sync from Server**: Fetch location from headless server
- **Use Device Location**: Get GPS coordinates (mobile)

### Time

| Setting | Description |
|---------|-------------|
| **Timezone** | Select from 18 timezone options |
| **Use system time** | Sync time from operating system |

## Equipment Profiles

Manage complete equipment configurations. See [Equipment](equipment.md) for details.

### Profile Management

- Create, edit, duplicate, delete profiles
- Import/export profiles as JSON
- Set active profile

### Profile Contents

**Optical Configuration**
- Focal Length (mm)
- Aperture (mm)
- Focal Ratio (calculated)

**Camera Defaults**
- Default Gain
- Default Offset
- Cooling Temperature
- Binning (X and Y)

**Filter Configuration**
- Filter Names
- Focus Offsets per filter

**Device Assignments**
- Camera, Mount, Focuser
- Filter Wheel, Guider, Rotator
- Dome, Weather

## Catalog Settings

Manage astronomical catalogs. See separate Catalog Settings screen.

### Available Catalogs

| Catalog | Description | Source |
|---------|-------------|--------|
| **HYG** | Hipparcos/Yale/Gliese star database | astronexus/HYG-Database |
| **OpenNGC** | ~13,000 deep sky objects | mattiaverga/OpenNGC |
| **GLADE+** | Up to 22.5M galaxies | glade.elte.hu |

### Catalog Packages

| Package | Contents |
|---------|----------|
| **Standard** | Smallest, basic objects |
| **Extended** | More objects, moderate size |
| **Complete** | All objects, largest download |

### Management

- Download/update catalogs
- View installation status
- Delete catalogs to free space

## Imaging Settings

Configure default imaging parameters.

### File Format

| Setting | Options |
|---------|---------|
| **Image format** | FITS, XISF, TIFF |
| **Bit depth** | 16-bit, 32-bit |

### File Naming

Use placeholders for automatic naming:
- `$TARGET` - Target name
- `$FILTER` - Current filter
- `$DATE` - Date stamp
- `$SEQ` - Sequence number
- `$EXPOSURE` - Exposure duration

## Annotations Settings

Configure image annotation display.

### Display Options

| Setting | Description |
|---------|-------------|
| **Enable annotations** | Show object annotations on images |
| **Show labels** | Display object names |
| **Show magnitudes** | Display magnitude values |
| **Max objects** | Limit for performance (50-2000) |

### Magnitude Filter

| Setting | Range | Description |
|---------|-------|-------------|
| **Minimum magnitude** | -5 to 10 | Lower = brighter objects |
| **Maximum magnitude** | 8 to 22 | Higher = fainter objects |

### Object Types

Toggle visibility for each type:
- Galaxies
- Nebulae
- Star Clusters
- Planetary Nebulae
- Stars
- Other Objects

### Fade Effects

| Setting | Description |
|---------|-------------|
| **Fade when not hovering** | Dim annotations when mouse leaves |
| **Hover opacity** | Brightness when mouse over (30-100%) |
| **Idle opacity** | Brightness when mouse away (0-50%) |
| **Fade duration** | Animation speed (100-1000ms) |

### Click to Identify

| Setting | Description |
|---------|-------------|
| **Enable** | Click image to identify objects |
| **Search radius** | Distance to search (5-120 arcsec) |

### Marker Styles

| Setting | Range |
|---------|-------|
| **Stroke width** | 0.5-4.0px |
| **Label font size** | 8-18px |
| **Scale by object size** | Toggle |

### Automation

| Setting | Description |
|---------|-------------|
| **Auto-annotate** | Annotate plate-solved images automatically |

## Sequencer Settings

Configure sequence automation behavior.

### Safety

| Setting | Description |
|---------|-------------|
| **Park on unsafe weather** | Auto-park mount when weather unsafe |
| **Park before dawn** | Auto-park before astronomical dawn |

### Meridian Flip

| Setting | Range |
|---------|-------|
| **Flip before meridian** | 0-60 minutes |
| **When the mount stops at its limit** | Flip right away (default) or Wait for the flip window. See Sequencing > Meridian Flip Trigger. |

### Auto Focus

| Setting | Description |
|---------|-------------|
| **Focus on filter change** | Run autofocus after filter changes |
| **Focus interval** | Periodic refocus (0-240 minutes) |

### Dithering

| Setting | Description |
|---------|-------------|
| **Enable dithering** | Move mount between exposures |
| **Dither every** | Frames between dithers (1-20) |

### Development

| Setting | Description |
|---------|-------------|
| **Native execution** | Use Rust sequencer engine |
| **Simulation mode** | Use simulated devices |

## Plate Solving Settings

Configure plate solving software.

### Solver Selection

| Setting | Options |
|---------|---------|
| **Primary solver** | ASTAP, Astrometry.net, PlateSolve2 |

### Solver Paths

- **ASTAP path**: Browse to installation
- **Astrometry.net path**: Browse to installation

### Solve Parameters

| Setting | Range | Description |
|---------|-------|-------------|
| **Timeout** | 10-300 sec | Maximum solve time |
| **Search radius** | 1-180 deg | Area around expected position |
| **Blind solve** | Toggle | Solve without position hint |

## PHD2 Guiding Settings

Configure PHD2 connection.

### Connection

| Setting | Default | Description |
|---------|---------|-------------|
| **Host** | localhost | PHD2 server address |
| **Port** | 4400 | PHD2 server port |

### PHD2 Path

- **Executable path**: Optional, for auto-detection

## Science Settings

Configure the scientific-analysis pipeline. Everything here is informational-only — no frames are auto-deleted.

### Mode

| Setting | Description |
|---------|-------------|
| **Show advanced overlay controls** | Adds PSF, residual, and tile-map layers to the Imaging overlays menu. The Science destination, HUD, calibration readout, and photometry are always available regardless of this toggle — it only controls the advanced overlay *layers*. |
| **Science overlays** | Master switch for science overlays such as the PSF map, residual vectors, and moving-object tracks. |

### Features

Per-feature toggles for each science product. Disabling one stops that processing stage without affecting the others:

| Setting | Description |
|---------|-------------|
| **Live differential photometry** | Target/comparison tracking and live light curves |
| **Per-frame photometric calibration** | Compute zeropoint and limiting magnitude |
| **Transparency and extinction** | Track atmospheric transparency over time |
| **PSF field map** | Analyze field-wide seeing and tilt patterns |
| **Astrometric residuals** | Build residual heatmaps and mount feedback |
| **Moving object mode** | Detect and track moving candidates |
| **Narrowband line ratios** | Generate SII/Ha, OIII/Ha, and SII/OIII products |
| **Frame quality maps** | Compute clipping, uniformity, background, and SNR tile maps |
| **3D science surfaces** | Enable the surface explorer and interactive mesh rendering |
| **Auto-reject bad frames** | After each light frame, reject captures that exceed the thresholds set in Analytics → Science → Grade frames (files are never deleted) |
| **Write science keywords to FITS** | Stamp MAGZP / MAGZPERR / TRANSPAR back into the FITS header so PixInsight, AstroPixelProcessor, and Siril can read Skotiq's measurements directly from the frame |

### Photometric Catalog

| Setting | Description |
|---------|-------------|
| **Deep catalog lookups (APASS DR9)** | Fetch B/V photometry to ~mag 16 from VizieR for zero-point calibration and the transform wizard. Cached per field for offline reuse; falls back to the bundled star catalog when off or unreachable. |

### Observer Codes

| Setting | Description |
|---------|-------------|
| **AAVSO observer code** | Your assigned AAVSO observer initials (1–5 characters). Required for AAVSO Extended Format export. |
| **MPC observatory code** | Your 3-character MPC observatory code (e.g., "G40"). Required for MPC report export. |

### Camera

Read-noise, gain, and saturation values used for limiting-magnitude and photometry calculations. **Auto-configure from camera** keeps them synced with the connected camera or active profile; editing any value by hand flips auto-configure off so your value is never overwritten.

## Notifications Settings

Configure alerts and notifications.

### General

| Setting | Description |
|---------|-------------|
| **Enable notifications** | Send notifications for events |
| **Sound alerts** | Play sounds for notifications |

### Events

Toggle notifications for:
- Sequence complete
- Errors
- Meridian flip

### Discord Integration

| Setting | Description |
|---------|-------------|
| **Webhook URL** | Discord channel webhook |
| **Test Discord** | Send test notification |

### Pushover Integration

| Setting | Description |
|---------|-------------|
| **API Key** | Pushover application key |
| **User Key** | Pushover user/group key |
| **Test Pushover** | Send test notification |

## File Paths Settings

Configure storage locations.

| Path | Description |
|------|-------------|
| **Image output** | Where captured images are saved |
| **Sequences** | Where sequence files are stored |
| **Database** | Database file location |
| **Logs** | Log files location |

## Plugins Settings

Manage Skotiq plugins.

### Plugin List

Each plugin shows:
- Name and version
- Description
- Enable/disable toggle
- Status (Enabled/Disabled/Error)

### Plugin Details

Expanded view shows:
- Plugin ID
- Author
- Load timestamp

### Plugin Types

- **Base Plugin**: Core functionality
- **UI Plugin**: Custom panels/widgets
- **Device Plugin**: Hardware support
- **Sequence Plugin**: Automation nodes

## Backup & Restore

Manage data backup and recovery.

### Auto-Save Status

- Last sequence save timestamp
- Last full backup timestamp
- Error display if applicable

### Quick Actions

- **Create Backup**: Full data backup
- **Import Backup**: Load from file

### Recent Backups

List of available backups:
- File name and size
- Creation timestamp
- Restore and delete actions

## Pairing (Remote Connection)

Pair mobile devices for remote control.

### Start Pairing

1. Click "Start Pairing Mode"
2. Pairing code displayed
3. 5-minute timeout

### Pairing Code

- Large monospace display
- Copy to clipboard button
- Countdown timer
- Cancel button

### Paired Devices

- Device list with icons
- Device name and paired date
- Last connected timestamp
- Revoke access option

## About

View application information.

### Application Info

- Skotiq logo
- Version number
- Tagline

### Links

- GitHub repository
- Documentation
- Discord community

### System Info

- Platform (Windows/macOS/Linux)
- OS version
- Dart version

## Best Practices

### Initial Setup

1. Configure location first
2. Create equipment profile
3. Download catalogs
4. Set file paths
5. Configure notifications

### Regular Maintenance

1. Check for updates
2. Back up settings periodically
3. Review equipment profiles
4. Update catalogs as needed

### Troubleshooting

1. Check file path permissions
2. Verify location coordinates
3. Test notifications
4. Review solver paths

## Next Steps

- [Equipment](equipment.md) - Configure devices
- [First Connection](../getting-started/first-connection.md) - Initial setup
- [Imaging](imaging.md) - Start capturing
