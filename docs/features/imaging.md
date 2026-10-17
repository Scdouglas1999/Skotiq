# Imaging Features

The Imaging screen is your central hub for capturing images, controlling your mount, focusing, and managing guiding. This guide covers all imaging features in detail.

## Overview

The Imaging screen is organized into five tabs:
- **Capture**: Main imaging controls and live preview
- **Camera**: Camera settings, cooling, and sensor configuration
- **Mount**: Telescope mount control, slewing, and polar alignment
- **Focus**: Automatic and manual focusing tools with filter offsets
- **Guiding**: PHD2 integration and guiding status

### Screen Layout

- **The frame** fills everything left of the side panel, edge to edge under one 44 px toolbar.
  Readouts and the capture bar float over it in glass panels rather than taking height from it.
- **The side panel** is a fixed 320 px column on the right with a 44 px vertical icon strip that
  selects its section. Toggle it from the icon button in the page header.

## Capture Tab

### Main Imaging Interface

The Capture tab is where you'll spend most of your imaging time.

#### Exposure Controls

**Start/Stop Exposure**
- Large **START EXPOSURE** button begins capture
- **STOP** button aborts current exposure
- **ABORT SEQUENCE** stops multi-exposure sequence
- Progress bar shows exposure progress and remaining time

**Exposure Parameters**
- **Count**: Number of exposures to capture (1-999)
- **Delay**: Seconds between exposures (0-60)
- **Loop Forever**: Continuous imaging until manually stopped

**Quick Exposure Buttons**
- Pre-configured exposure times for rapid testing
- Default: 1s, 2s, 5s, 10s, 30s
- Customizable in Settings

#### Image Preview

**Live Display**
- Latest captured image displays automatically
- Auto-stretch applied for visibility (doesn't affect saved file)
- Zoom: Mouse wheel or pinch gesture
- Pan: Click and drag

**Stretch Controls**
- **Auto**: Automatic histogram stretch
- **Linear**: No stretch (raw data)
- **Custom**: Manual black/white point sliders
- **Asinh**: Preserves bright details while showing faint signal

**Zoom Controls** (Floating buttons, bottom-right)
- **Zoom In** (+): Increase magnification
- **Zoom Out** (-): Decrease magnification
- **Fit to Screen**: Auto-fit entire image to window
- **1:1 (100%)**: View at actual pixel size
- **Zoom percentage**: Current zoom level displayed when zoomed

**Image Overlays**
- **Crosshair**: Toggleable center crosshair overlay
- **Grid**: Coordinate grid overlay
- **Stars**: Detected star annotations

**Bottom Stats Row** (Three cards side-by-side)

*Image Stats Card*
| Metric | Description |
|--------|-------------|
| HFR | Half-flux radius (lower = sharper) |
| Stars | Detected star count |
| Mean | Average pixel value |
| Median | Middle pixel value |

*Histogram Card*
- Interactive logarithmic histogram (40px height)
- Clipping indicators for over/underexposure

*Annotations Card*
- Toggle chips: Stars, Grid, Crosshair

#### Thumbnail Strip

- Bottom panel shows recent captures
- Click thumbnail to view that image
- Right-click for options:
  - Open in external viewer
  - Plate solve
  - Delete
  - Show in folder

### Dithering

Dithering moves the mount slightly between exposures to reduce noise patterns.

**Enable Dithering**
1. Check **Enable Dithering** in Capture tab
2. Set dither amount (pixels, typically 3-10)
3. Requires PHD2 guiding to be active

**Dither Settings**
- **Every N frames**: Dither frequency (e.g., every 3 exposures)
- **Settle time**: Seconds to wait after dither before exposing
- **RA only**: Only dither right ascension (recommended)

## Camera Tab

### Camera Configuration

#### Cooling Control (Cooled Cameras Only)

**Temperature Management**
- Enable/disable cooler with toggle
- Set target temperature (-50°C to +50°C)
- Current temperature displayed with graph
- Cooling power percentage shown
- "At Temp" indicator when stabilized

**Cooling Best Practices**
- Cool gradually (5-10°C increments)
- Set target 10-20°C below ambient
- Warm up gradually before power off
- Monitor for condensation in humid conditions

#### Gain and Offset

**Gain**
- Controls sensor sensitivity
- Higher gain = more sensitive but more noise
- Unity gain (often 100-150) balances signal and noise
- Lower for bright targets, higher for faint

**Offset**
- Sets baseline pixel value
- Prevents clipping shadows
- Use manufacturer recommended value
- Typically 10-50 depending on camera

**Presets**
- Save gain/offset combinations as presets
- Quick switching between configurations
- Examples: "High Gain Ha", "Low Gain RGB", "Unity"

#### Binning

Combines pixels for faster readout and better signal-to-noise:
- **1x1**: Full resolution
- **2x2**: 4x faster, 1/4 resolution
- **3x3**: 9x faster, 1/9 resolution
- **4x4**: 16x faster, 1/16 resolution

**When to Bin**
- 2x2 or 3x3 for framing and focusing
- 2x2 for narrowband imaging (oversampled)
- 1x1 for maximum detail

#### Region of Interest (ROI)

Capture only part of the sensor:
- Faster download and processing
- Useful for off-axis guider frames
- Planetary imaging with small chip area

**Setting ROI**
1. Click **Set ROI**
2. Drag rectangle on preview image
3. Or manually enter X, Y, Width, Height
4. Click **Full Chip** to reset

#### File Settings

**Format**
- **FITS**: Standard for astrophotography (recommended)
- **TIFF**: 16-bit TIFF for compatibility

**File Naming**
- Use placeholders for automatic naming:
  - `{object}`: Target name
  - `{filter}`: Current filter
  - `{num}`: Auto-incrementing number
  - `{exp}`: Exposure duration
  - `{gain}`: Gain value
  - `{temp}`: Sensor temperature
  - `{date}`: Date stamp
  - `{time}`: Time stamp

- Example: `{object}_{filter}_{num:4}_{exp}s.fits`
  - Produces: `M42_Ha_0001_180s.fits`

**Auto-Save Options**
- Auto-increment number (prevents overwrites)
- Create dated subfolders
- Compress FITS files (saves disk space)

### Filter Wheel Control

If a filter wheel is connected:

**Filter Selection**
- Dropdown shows all configured filters
- Click to change filters
- Status shows current position and movement

**Filter Configuration**
1. Go to **Equipment** > **Settings**
2. Define filter names and offsets
3. Set focus offsets (auto-refocus when changing filters)

**Filter Sets**
- Create filter sets for common combinations
- Example: "LRGB", "Narrowband", "Ha-OIII-SII"
- Quick switching between sets

## Mount Tab

### Mount Control

#### Position Display

**Current Coordinates**
- **RA/Dec**: Equatorial coordinates (J2000)
- **Alt/Az**: Horizon coordinates
- **Pier Side**: East or West (for German equatorial mounts)
- **Tracking**: On/Off status

#### Slewing Controls

**Direction Pad**
- Click and hold to move in cardinal directions
- Speed controlled by slew rate setting
- Release to stop

**Slew Rates**
- **Guide**: Slowest (guiding speed)
- **Center**: Slow (fine positioning)
- **Find**: Medium (moving between targets)
- **Slew**: Fastest (large movements)

**Goto Commands**
- Enter RA/Dec coordinates manually
- Click **GOTO** to slew to coordinates
- Or use Planetarium to select targets visually

#### Tracking Control

**Tracking Modes**
- **Sidereal**: Match Earth's rotation (stars)
- **Lunar**: Track the Moon
- **Solar**: Track the Sun (with proper solar filter!)
- **Custom**: Specify custom rate

**Tracking On/Off**
- Toggle tracking on/off
- Tracking must be on for long exposures

### Target Centering

The **Center Target** button opens the Target Centering Dialog for precise target positioning.

**Centering Process**
1. Takes image
2. Plate solves for exact coordinates
3. Calculates offset from target
4. Slews to reduce offset
5. Repeats until within tolerance
6. Reports final accuracy

**Centering Dialog Features**
- Target coordinates display (RA/Dec)
- Status indicator showing current step
- Iteration counter (e.g., "Iteration 2/5")
- Progress bar showing offset vs tolerance
- Iteration history with success/failure status

**Centering Settings**
- Accuracy threshold (arcseconds)
- Maximum attempts (1-20)

### Pulse Guide Controls

Manual fine adjustment of mount position:
- **North/South** buttons: Vertical adjustment
- **East/West** buttons: Horizontal adjustment
- Each press sends 500ms pulse guide command

#### Parking

**Park Mount**
- Move mount to safe park position
- Stops tracking
- Ready for shutdown

**Unpark Mount**
- Wake from park position
- Required before slewing or tracking

**Set Park Position**
- Set current position as new park location
- Useful for custom park positions

#### Meridian Flip

**Automatic Flip**
- Enable **Auto Meridian Flip**
- Set degrees past meridian to trigger flip
- Skotiq will:
  1. Complete current exposure
  2. Flip mount to other pier side
  3. Re-center target
  4. Auto-focus (if enabled)
  5. Resume guiding and imaging

**Manual Flip**
- Click **Flip Now** to manually flip sides
- Useful when approaching meridian

### Safety Features

**Horizon Limits**
- Set minimum altitude (avoid trees, buildings)
- Mount won't slew below limit

**Meridian Limits**
- Define how far past meridian before flip required
- Prevents tube/tripod collisions

**Emergency Stop**
- Large **STOP** button halts all motion immediately
- Use if mount behavior is unexpected

## Focus Tab

Sharp focus is critical for quality images. Skotiq offers both automatic and manual focusing.

### Automatic Focusing

**V-Curve Autofocus**

The most reliable autofocus method:

1. Click **Auto Focus**
2. Skotiq will:
   - Take exposures at different focus positions
   - Measure HFR (Half-Flux Radius) for each
   - Create V-curve graph
   - Move to position with lowest HFR
3. Results show:
   - Best focus position
   - Achieved HFR
   - V-curve graph

**Autofocus Settings**
- **Step Size**: Focuser steps between measurements (50-500)
- **Number of Steps**: Total measurements (7-15 typical)
- **Exposure**: Duration for focus images (1-10s)
- **Binning**: Higher binning for speed (2x2 or 3x3)
- **Backlash**: Compensation for focuser gear backlash (0-500 steps)

**Best Practices**
- Use bright star for focusing
- Start with larger steps to find approximate focus
- Refine with smaller steps
- Run autofocus:
  - At start of session
  - After filter changes
  - When temperature changes >2-3°C
  - If stars look soft

### Manual Focusing

**Manual Focus Mode**

For fine-tuning or when autofocus isn't available:

1. Click **Start** in Manual Focus section
2. Select a bright star (double-click on preview)
3. Take a focus frame (continuous loop)
4. Use focuser in/out buttons
5. Watch HFR value decrease
6. Stop when HFR is minimized

**Focus Aids**
- **HFR Display**: Real-time star sharpness (lower = better)
- **FWHM**: Full-width half-maximum (alternative metric)
- **Star Profile**: Graph showing star intensity profile
- **Bahtinov Mask**: Overlay for Bahtinov pattern (requires mask)

**Step Size**
- Coarse: Large steps (100-1000) for initial focusing
- Fine: Small steps (10-100) for critical focus

### Focus Graph

- Tracks focus position over time
- Plots HFR vs. time or temperature
- Visualize focus drift
- Useful for determining refocus intervals

### Temperature Compensation

**Auto Refocus by Temperature**
- Enable temperature-based autofocus
- Set temperature change threshold (e.g., 2°C)
- Skotiq auto-refocuses when threshold exceeded

**Focus vs. Temperature Curve**
- Learn relationship between temperature and focus
- After several data points, predict focus position
- Auto-adjust focus as temperature changes

### Filter Focus Offsets

Manage focus position differences between filters.

**Filter Offset Controls**
Each filter shows:
- Filter name (large, bold)
- "REF" badge if reference filter
- Star icon to set as reference
- Current offset value
- +/- buttons (±10 steps per click)

**Reference Filter**
- Set one filter as the reference (offset = 0)
- All other filters offset relative to reference
- Typically use Luminance or Clear as reference

**Managing Offsets**
1. Focus with reference filter
2. Change to next filter
3. Focus and note position difference
4. Set offset value (+/- steps)
5. Repeat for all filters

**Buttons**
- **Clear All**: Reset all offsets to zero
- **Measure Offsets**: Automatic offset measurement wizard

## Guiding Tab

### PHD2 Integration

Skotiq integrates with PHD2 for autoguiding.

**Setup**
1. Launch PHD2 separately
2. Connect your guide camera in PHD2
3. In Skotiq Guiding tab, click **Connect to PHD2**
4. PHD2 status shows "Connected"

**Start Guiding**
1. Click **Start Guiding** in Skotiq
2. If not calibrated, PHD2 will calibrate first
3. PHD2 will select guide star and begin guiding
4. Status changes to "Guiding"

**Stop Guiding**
- Click **Stop Guiding** to halt
- Guiding automatically resumes after dithers

### Guiding Graph

Real-time visualization of guiding performance:

**Graph Display**
- **RA Error**: Right ascension drift (blue line)
- **Dec Error**: Declination drift (red line)
- **RMS**: Root mean square error (trend line)
- Time axis shows last N minutes

**Graph Controls**
- Zoom in/out on time axis
- Show/hide RA, Dec, or both
- Clear graph
- Export data

**Reading the Graph**
- Goal: Lines stay close to zero
- Oscillation: PHD2 may need better settings
- Drift: Polar alignment or tracking issue
- Spikes: Wind gusts, cable snags, etc.

### Guiding Statistics

- **RMS Total**: Overall guiding accuracy
- **RA RMS**: RA-only accuracy
- **Dec RMS**: Dec-only accuracy
- Goal: <1.0 arcsecond RMS for good guiding
- <0.5 arcsecond for excellent guiding

### Dithering Status

When dithering is enabled:
- Shows dither in progress
- Settle timer counts down
- Graph shows dither events as vertical lines

### PHD2 Alerts

Skotiq monitors PHD2 for issues:
- **Star Lost**: Guide star disappeared
- **Calibration Failed**: PHD2 couldn't calibrate
- **Poor Guiding**: RMS exceeds threshold
- Alerts appear as notifications

## Image History

The Capture tab maintains a session history:
- All images from current session
- Thumbnails with key metadata
- Click to review
- Export list as CSV

## Advanced Features

### Framing Preview Overlay

While imaging, overlay framing from Framing Assistant:
- Shows target position relative to frame
- Helps verify you're on target
- Update after plate solving

### Science overlays & HUD

A compact Science HUD sits on the Imaging screen and is **ungated** — it appears without enabling any preference. It mirrors the science pipeline status (plate-solve, calibration, transparency) in real time and surfaces one-tap offers (moving-object detection once you have a few light frames, narrowband ratios once Ha/OIII/SII are present). Tapping the HUD opens the full Science destination.

Each captured frame also carries a small **science chip** in the thumbnail strip showing its plate-solve state and photometric zero point; tapping it jumps to the Science destination. The advanced overlay *layers* (PSF map, residual vectors, tile maps) live behind **Show advanced overlay controls** in Settings → Science, but the HUD and per-frame chip do not.

### Drift Alignment Tool

For polar alignment:
1. Point scope at celestial equator
2. Take exposures without guiding
3. Skotiq measures drift
4. Provides adjustment instructions

### Auto-Exposure Planning

Set total integration time goal:
- Specify total hours desired
- Skotiq calculates number of subs needed
- Accounts for filter changes, meridian flip

## Tips and Best Practices

### Camera
- Cool camera to stable temperature before imaging
- Use Unity Gain as starting point
- Save presets for different targets/filters
- Monitor temperature stability

### Mount
- Verify tracking before starting sequence
- Set appropriate horizon limits
- Enable auto-meridian flip for long sessions
- Test slew to target before full sequence

### Focusing
- Focus at start of session and after filter changes
- Use autofocus for consistency
- Refocus if temperature changes significantly
- Focus on bright star, but not too bright (no saturation)

### Guiding
- Achieve RMS <1.0" before starting imaging
- Enable dithering to reduce noise patterns
- Monitor guiding graph during session
- Have PHD2 alert you to issues

## Keyboard Shortcuts

- **Space**: Start/stop exposure
- **F**: Run autofocus
- **G**: Toggle guiding
- **Esc**: Abort current action
- **+/-**: Zoom in/out
- **Arrow Keys**: Move mount (when mount tab active)

## Troubleshooting

### Camera issues
- [Camera Not Detected](../troubleshooting/common-issues.md#camera-not-detected)
- [Images Not Saving](../troubleshooting/common-issues.md#images-not-saving)

### Mount issues
- [Mount Not Responding](../troubleshooting/common-issues.md#mount-not-responding)

### Focus issues
- [Autofocus Fails](../troubleshooting/common-issues.md#autofocus-fails)

### Guiding issues
- [PHD2 Not Connecting](../troubleshooting/common-issues.md#phd2-not-connecting)
- [Poor Guiding Performance](../troubleshooting/common-issues.md#poor-guiding-performance)

## Next Steps

- [Sequencing](sequencing.md) - Automate your imaging with sequences
- [Focus Tab](#focus-tab) - Master focusing tools before long sequences
- [Framing Tools](framing.md) - Precisely center your targets
