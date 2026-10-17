# Guiding (PHD2 Integration)

Skotiq integrates fully with PHD2 for autoguiding, providing real-time monitoring, control, and advanced guiding statistics directly within the application.

## Overview

The Guiding screen provides:
- Full PHD2 control and monitoring
- Real-time guiding graphs and statistics
- Guide star visualization
- Calibration management
- PHD2 Brain algorithm settings
- Dithering controls

## Screen Layout

### Three-Panel Design

**Left Panel**
- Guide Star View
- Target Display
- Star Statistics

**Center Panel**
- Advanced Guiding Graph
- Time-series error visualization

**Right Panel**
- Control Panel
- Calibration Panel
- PHD2 Brain Settings

## PHD2 Connection

### Where guiding state is shown

The page header carries one chip with the PHD2 state (Stopped, Looping, Calibrating, Guiding,
Paused, Settling, Lost Lock). RMS (RA / Dec / Total) reads out above the guide graph, and the
guider's connection dot sits in the instrument bar at the bottom of the window, where it is
visible from every screen. The state is not repeated anywhere else.

### Connecting to PHD2

1. Ensure PHD2 is running
2. Open Guiding screen in Skotiq
3. Click **Connect** button
4. Enter PHD2 host and port (default: localhost:4400)
5. Click **Connect**

**Connection Settings**
- Host: PHD2 server address (localhost for local)
- Port: Default 4400
- Configure in Settings → PHD2 Guiding

### PHD2 States

| State | Description |
|-------|-------------|
| **Stopped** | PHD2 idle, no camera looping |
| **Looping** | Camera exposing, no guiding |
| **Calibrating** | Running calibration routine |
| **Guiding** | Actively guiding |
| **Paused** | Guiding paused |
| **Settling** | Waiting for guiding to settle |
| **Lost Lock** | Guide star lost |

## Guide Star View

### Star Image Display

Shows the guide star from PHD2:
- 16-bit grayscale image with auto-stretch
- Red crosshairs at star position
- 1:1 aspect ratio display

### SNR Indicator

Color-coded signal-to-noise ratio:
- **Green**: SNR > 10 (excellent)
- **Orange**: SNR 5-10 (acceptable)
- **Red**: SNR < 5 (poor)

### Star Selection

- Click **Auto Select** to have PHD2 find a star
- Click **Deselect** to clear selection
- Tap image to manually select star position

## Target Display

### Error Visualization

Concentric rings showing guiding error:
- Historical error positions (fading blue dots)
- Current error marker (red X with glow)
- Configurable scale per ring (arcseconds)

### Ring Scale

Rings represent error thresholds:
- Inner ring: Excellent guiding
- Middle rings: Acceptable guiding
- Outer ring: Poor guiding
- Scale adjustable (default: 1 arcsec per ring)

### Error History

- Maximum 50 points tracked
- Older points fade out
- Pattern shows guiding consistency
- RA = horizontal (X), Dec = vertical (Y)

## Guiding Graph

### Advanced Graph Display

Dual-trace graph showing error over time:
- **Red line**: RA error (arcseconds)
- **Blue line**: Dec error (arcseconds)
- Zero line always visible
- Grid overlay (optional)

### Graph Controls

**Time Scale**
- 1 minute
- 5 minutes
- 15 minutes
- 30 minutes

**Y-Axis Scale**
- ±1 arcsecond
- ±2 arcseconds
- ±4 arcseconds
- ±8 arcseconds

**Additional Controls**
- Show/Hide Grid
- Clear Graph

### RMS Statistics

Header shows real-time RMS values:
- RA RMS (arcseconds)
- Dec RMS (arcseconds)
- Total RMS (arcseconds)

## Star Statistics Card

Quick reference statistics:
- **SNR**: Signal-to-Noise Ratio
- **Star Mass**: Guide star brightness
- **Frame Count**: Exposures since guiding started

## Control Panel

### Main Controls

**Start/Stop Buttons**
- **Start Guiding**: Begin autoguiding
- **Stop**: Halt guiding
- Button changes based on current state

**Loop Exposures**
- Start camera looping without guiding
- Useful for star selection

### Star Selection

- **Auto Select**: PHD2 finds guide star automatically
- **Deselect**: Clear current star selection

### Dither Controls

Configure dithering during imaging:

**Dither Amount**
- Slider: 1-20 pixels
- Typical: 3-10 pixels

**RA Only Toggle**
- Enabled: Only dither in RA
- Recommended for most setups

**Dither Now Button**
- Manually trigger immediate dither
- Useful for testing

### Settle Settings

Configure when PHD2 considers guiding "settled":

**Settle Pixels**
- Threshold: 0.5-5 pixels
- Guiding settled when error below this

**Settle Time**
- Duration: 5-60 seconds
- Must maintain below threshold for this long

**Settle Timeout**
- Maximum: 30-180 seconds
- Fail if not settled within timeout

## Calibration Panel

### Calibration Status

Shows current calibration state:
- **Not Calibrated**: No calibration data
- **Calibrating**: Running calibration
- **Calibrated**: Ready to guide

### Calibration Data

When calibrated, displays:
- RA Angle (degrees)
- Dec Angle (degrees)
- RA Rate (px/s)
- Dec Rate (px/s)
- Calibration timestamp

### Calibration Actions

**Calibrate**
- Start new calibration
- Progress bar during calibration

**Clear**
- Remove current calibration
- Requires recalibration

**Flip**
- Apply meridian flip correction
- Use after German equatorial mount flip

## PHD2 Brain Settings

### Algorithm Parameters

Access PHD2's guiding algorithm settings:
- RA axis parameters
- Dec axis parameters
- Real-time parameter updates

### Parameter Editing

Each parameter shows:
- Parameter name (readable format)
- Current value (editable)
- Apply/Reset buttons

### Common Parameters

**RA Settings**
- RA Aggressiveness
- RA Hysteresis
- RA Minimum Move

**Dec Settings**
- Dec Aggressiveness
- Dec Hysteresis
- Dec Minimum Move

**Reset to Defaults**
- Restore PHD2 default values

## Guiding Workflow

### Initial Setup

1. Launch PHD2 separately
2. Connect guide camera in PHD2
3. Open Skotiq Guiding screen
4. Click Connect to PHD2
5. Verify connection status

### Start Guiding

1. Click **Loop** to start exposures
2. Wait for star to appear
3. Click **Auto Select** or click on star
4. Click **Start Guiding**
5. If not calibrated, PHD2 calibrates first
6. Watch for "Guiding" state

### Monitor Performance

1. Watch guiding graph for errors
2. Check RMS values (goal: < 1.0 arcsec)
3. Monitor target display pattern
4. Verify SNR stays acceptable

### Troubleshooting

**Star Lost**
- Check for clouds or obstructions
- Verify focus hasn't drifted
- Try selecting brighter star

**High RMS**
- Check polar alignment
- Adjust Brain parameters
- Verify mount balance
- Check for cable snag

## Integration with Imaging

### Dithering During Capture

1. Enable dithering in Capture tab
2. Set dither every N frames
3. Skotiq coordinates with PHD2
4. Waits for settle between exposures

### Guiding Status in Capture

The Guiding tab in Imaging shows:
- PHD2 connection status
- Guiding graph
- RMS statistics
- Quick controls

### Sequence Integration

Add guiding nodes to sequences:
- Start/Stop Guiding nodes
- Guiding Monitor trigger
- Automatic pause on lost star

## Best Practices

### Calibration

1. Calibrate near declination 0° when possible
2. Calibrate near the meridian
3. Recalibrate after significant mount adjustments
4. Use "Flip" after meridian flip

### Star Selection

1. Choose star with SNR > 10
2. Avoid saturated stars
3. Select star away from edge of frame
4. Avoid double stars

### Parameter Tuning

1. Start with default Brain settings
2. Adjust aggressiveness if oscillating
3. Increase hysteresis for PE
4. Test changes over several minutes

### During Imaging

1. Monitor RMS periodically
2. Enable guiding alerts
3. Set RMS threshold for sequence pause
4. Review guiding logs after session

## Troubleshooting

### Cannot Connect to PHD2

- Verify PHD2 is running
- Check firewall settings
- Verify correct port (4400)
- Try restarting PHD2

### Calibration Fails

- Check for clouds or obstructions
- Verify star selected properly
- Increase exposure time
- Check for mount issues

### High RMS Values

- Verify polar alignment
- Check guide scope focus
- Review seeing conditions
- Adjust Brain parameters

### Guiding Oscillates

- Reduce aggressiveness
- Increase minimum move
- Check for flexure
- Verify calibration valid

### Star Keeps Getting Lost

- Select brighter star
- Increase exposure time
- Check for intermittent clouds
- Verify focus stability

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| G | Start/Stop guiding |
| L | Toggle looping |
| D | Dither now |
| C | Clear graph |

## Next Steps

- [Imaging Features](imaging.md) - Capture with guiding
- [Sequencing](sequencing.md) - Automate guiding in sequences
- [Settings](settings.md) - Configure PHD2 connection
- [Analytics](analytics.md) - Review guiding performance
