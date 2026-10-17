# Weather Monitoring

Skotiq's Weather screen provides real-time weather monitoring with radar visualization, satellite imagery, cloud motion analysis, and automated safety alerts to protect your equipment during imaging sessions.

## Overview

The Weather screen displays:
- Interactive radar/satellite map
- Cloud coverage indicators
- Weather alerts and safety status
- Cloud motion prediction
- Automated safety responses

## Weather Map

### Radar Display

The main map shows weather radar overlaid on a dark base map.

**Map Features**
- OpenStreetMap base tiles (dark theme)
- Weather radar overlay (RainViewer)
- GOES satellite imagery (optional)
- Your location marker
- Alert radius circle

**Map Controls**
- **Zoom in/out**: Buttons or pinch gesture
- **Pan**: Click and drag
- **Recenter**: Click location button to return to your position

**Radar Overlays**
- Precipitation intensity (color scale)
- Cloud cover (satellite infrared)
- Adjustable overlay opacity (0-100%)

### Location Marker

Your observing location is shown with:
- Animated pulsing ring (1500ms cycle)
- Three-layer design for visibility
- Alert radius circle around location

### Alert Radius

The alert radius circle shows:
- Distance threshold for weather monitoring
- Semi-transparent fill with colored border
- Configurable in settings (km)

## Satellite Imagery

### GOES Infrared

View cloud cover using satellite data:
- Real-time infrared imagery
- Shows cloud top temperatures
- Higher/brighter = colder cloud tops = thicker clouds

**Legend Interpretation**
| Appearance | Meaning |
|------------|---------|
| Dark/warm | Clear sky |
| Gray | Thin clouds |
| White/bright | Cold thick clouds |

### Satellite Legend

The legend explains the color scale:
- Gradient from clear to overcast
- Temperature correlation explained
- Compact or full-size mode

## Timeline Scrubber

Animate through radar data over time.

### Playback Controls

- **Play/Pause**: Toggle animation
- **Step backward**: Previous frame
- **Step forward**: Next frame
- **Speed selector**: 0.5×, 1×, 2×, 4×

### Timeline Display

- Frame tick marks (live vs forecast)
- "NOW" marker (green highlight)
- Progress indicator
- Draggable thumb for scrubbing

### Time Display

- Timestamp of current frame
- Forecast frames highlighted in warning color
- Relative time formatting

## Cloud Motion Analysis

### Direction Indicator

An arrow overlay shows cloud movement:
- Points direction clouds are moving FROM
- Gradient fill for visibility
- Rotating based on detected direction

### Motion Metrics

The status card shows:
- **Cloud density**: Percentage (%)
- **Distance to storm**: Kilometers
- **Speed**: km/h
- **Direction**: 16-point compass (N, NNE, NE, etc.)

### ETA Countdown

When weather is approaching:
- Time until arrival at your location
- Pulsing animation for critical alerts (< 5 min)
- "Imminent" warning for < 2 minutes

## Weather Alerts

### Alert Levels

| Level | Icon | Color | Description |
|-------|------|-------|-------------|
| **Clear** | ✓ | Green | Safe conditions |
| **Watch** | 👁 | Yellow | Monitor conditions |
| **Warning** | ⚠ | Orange | Prepare to secure equipment |
| **Critical** | ⛔ | Red | Immediate action required |

### Alert Status Card

Expandable card showing:
- Current alert level with icon
- Alert message text
- Last update timestamp
- Expand/collapse for details

### Cloud Cover Indicator

Real-time cloud coverage display:

| Coverage | Label | Color |
|----------|-------|-------|
| ≤20% | Clear | Green |
| ≤40% | Mostly Clear | Light green |
| ≤60% | Partly Cloudy | Yellow |
| ≤80% | Mostly Cloudy | Orange |
| >80% | Overcast | Red |

**Display Features**
- Percentage value
- Semantic label
- Circular progress indicator (60px)
- Matching weather icon

## Safety System

### Safety Status Card

Shows current safety state:
- **Safe**: Shield check icon, green
- **Unsafe**: Shield alert icon, red

### Snooze Controls

Temporarily ignore alerts:
- **15-minute snooze**: Short delay
- **30-minute snooze**: Longer delay
- **Cancel snooze**: Resume monitoring
- Countdown display during snooze

### Automated Responses

Configure automatic actions when weather becomes unsafe:

| Setting | Action |
|---------|--------|
| **Auto-park** | Park mount when unsafe |
| **Auto-resume** | Resume when conditions clear |
| **Sequence pause** | Pause active sequences |

## Settings Quick Access

View current weather settings from the Weather screen:
- Alert radius (km)
- Cloud density threshold (%)
- Lead time (minutes)
- Auto-park status
- Auto-resume status

Full configuration in Settings → Weather.

## Layout

### Wide Screen (>1200px)

- Map on left (70% width)
- Status panel on right (30% width)

### Medium Screen (800-1200px)

- Map on top
- Safety and settings in horizontal row
- Status cards below

### Narrow Screen (<800px)

- Full vertical stack
- Map full width
- Cards stacked below

## Weather Data Sources

### RainViewer API

Primary radar data:
- Global coverage
- 10-minute updates
- Historical playback
- Forecast frames

### GOES Satellite

NOAA satellite imagery:
- Infrared channels
- Cloud top temperature
- Wide area coverage

### Location Services

Weather data centered on your location:
- Configured in Settings → Location
- GPS available on mobile devices
- "Location Not Configured" warning if not set

## Configuration

### Weather Settings (Settings → Weather)

**Alert Radius**
- Distance from location to monitor
- Typical: 25-100 km

**Cloud Density Threshold**
- Percentage to trigger alert
- Default: 60%

**Lead Time**
- Minutes warning before weather arrives
- Typical: 15-30 minutes

**Auto-Park**
- Enable automatic mount parking
- Recommended for unattended sessions

**Auto-Resume**
- Resume sequence when conditions clear
- Requires stable clear period

**Alert Level Thresholds**
- Customize when each level triggers
- Based on cloud density, proximity, speed

## Integration with Sequencer

### Weather Trigger Node

Add weather monitoring to sequences:
- Monitors conditions during imaging
- Actions: Pause, park, abort
- Configurable thresholds

### Automatic Pause

When weather becomes unsafe:
1. Current exposure completes
2. Sequence pauses automatically
3. Mount parks (if enabled)
4. Notification sent
5. Resumes when safe (if enabled)

## Best Practices

### Setup

1. Configure accurate location coordinates
2. Set appropriate alert radius for your area
3. Test weather alerts before critical sessions
4. Enable auto-park for unattended imaging

### Monitoring

1. Check weather before starting session
2. Review cloud motion direction
3. Set appropriate lead time
4. Monitor during session

### Safety

1. Always enable auto-park for unattended sessions
2. Don't rely solely on automation
3. Have manual override plan
4. Secure sensitive equipment

## Troubleshooting

### Map Not Loading

- Check internet connection
- Verify location configured
- Wait for tile download

### No Radar Data

- RainViewer may have regional outages
- Try satellite view instead
- Check data provider status

### Alerts Not Triggering

- Verify thresholds configured
- Check alert radius covers expected area
- Review lead time settings

### Location Wrong

- Update coordinates in Settings → Location
- Use "Use Device Location" on mobile
- Verify timezone setting

## Next Steps

- [Settings](settings.md) - Configure weather settings
- [Sequencing](sequencing.md) - Add weather triggers
- [Tonight](../getting-started/first-image.md) - View weather summary
