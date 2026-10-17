# Planetarium

The Planetarium is Skotiq's GPU-rendered interactive sky visualization system. Use it to explore the night sky, plan observations, select targets, and preview framing for your imaging sessions.

## Overview

The Planetarium provides:
- Real-time 3D sky rendering with stars, DSOs, and planets
- Interactive pan, zoom, and time controls
- Object selection with detailed information
- Equipment framing preview
- Direct mount control integration
- Catalog support (Messier, NGC, IC, and more)

## Main Interface

### Sky View

The central area displays an interactive view of the night sky.

**Visual Elements**
- **Stars**: Rendered by magnitude with accurate colors based on spectral type
- **Deep Sky Objects**: Galaxies, nebulae, clusters with type-specific icons
- **Constellations**: Lines connecting stars with optional labels
- **Planets**: Sun, Moon (with phase), and planets with real-time positions
- **Coordinate Grid**: Equatorial (RA/Dec) or horizontal (Alt/Az) grid lines
- **Ecliptic**: Path of the sun through the zodiac
- **Milky Way**: Dense star field visualization
- **Horizon**: Ground plane showing local horizon with atmospheric glow

**Rendering Features**
- Magnitude-based star sizing and brightness
- Star twinkling animation (configurable)
- Selection pulse animation for highlighted objects
- Smooth zoom transitions with star pop-in effects
- Stereographic, orthographic, and azimuthal projections

### Navigation Controls

**Mouse/Touch**
- **Pan**: Click and drag (or two-finger drag on touch)
- **Zoom**: Mouse wheel or pinch gesture
- **Select**: Click on object to select
- **Double-tap**: Reset to default 60° field of view

**Keyboard (Desktop)**
- **Arrow keys**: Pan view in cardinal directions
- **+/=**: Zoom in
- **-**: Zoom out
- **R**: Reset view
- **G**: Toggle coordinate grid
- **C**: Toggle constellation lines
- **M**: Toggle minimap

**Zoom Range**
- Wide field: 180° (full hemisphere)
- Narrow field: 0.5° (deep zoom for framing)
- Smooth scaling with finer control at narrow FOV

### Filter Sidebar

Toggle visibility of sky elements:

| Toggle | Description |
|--------|-------------|
| **Stars** | Show/hide star rendering |
| **Planets** | Show/hide solar system objects |
| **Deep Sky** | Show/hide DSO objects |
| **Grid** | Show/hide coordinate grid |
| **Constellations** | Show/hide constellation lines |
| **Ground** | Show/hide horizon ground plane |

**Sidebar Controls**
- Click filter icon to expand/collapse sidebar
- Toggle switches for each element
- Settings persist across sessions

## Object Selection

### Selecting Objects

Click on any star or DSO to select it:
- Brightness-based hit detection (brighter = larger tap target)
- Angular size detection for extended DSOs
- Selection pulse animation indicates selected object

### Details Panel

When an object is selected, the details panel shows:

**Basic Information**
- Object name (common and catalog names)
- Object type with icon (Galaxy, Nebula, Cluster, Star, etc.)
- Visual magnitude

**Coordinates**
- RA/Dec in both decimal and HMS/DMS formats
- Current altitude and azimuth
- Constellation assignment

**Catalog IDs**
- Messier number (if applicable)
- NGC/IC designations
- Color-coded catalog tags

**Physical Properties**
- Size in arcminutes (for DSOs)
- Position angle (if applicable)
- Spectral type (for stars)

**Visibility Information**
- Current altitude with "Above/Below Horizon" indicator
- Visibility score (0-100): Excellent, Fair, or Poor
- 24-hour altitude graph showing visibility over time
- Rise, Transit, and Set times
- Moon distance (for planning around lunar interference)

### Action Buttons

- **Go To**: Slew mount to selected object
- **Add Target**: Add object to observation sequence
- **Send to Framing**: Open in Framing Assistant for detailed planning

## Compass HUD

The head-up display shows orientation information.

**Compass Ring**
- Circular compass showing viewing direction
- Cardinal directions (N, E, S, W) with North highlighted in red
- Intercardinal tick marks (NE, SE, SW, NW)
- Current azimuth value in center

**Altitude Arc** (optional)
- Right-side altitude scale from horizon (0°) to zenith (90°)
- Current altitude indicator with fill
- Altitude labels at 0° and 90°

**Responsive Sizing**
- Adapts to screen size (phone, tablet, desktop)
- Smaller on mobile for more sky view

## Sky Minimap

The minimap provides an all-sky overview.

**Fisheye Projection**
- Center = zenith (top of sky)
- Edge = horizon
- Concentric circles at 30° and 60° altitude

**Features**
- Cardinal direction markers (N in red)
- Zenith marker at center
- Current field of view indicator (rectangle)
- Equipment FOV overlay (when configured)
- Tap-to-navigate: Jump view to tapped location

**Warning Indicators**
- Shows if pointing below horizon
- Helps avoid ground obstruction

## Time Controls

Control the simulated time for planning observations.

### Compact Mode

- Real-time clock display (HH:MM:SS)
- Play/Pause button
- Speed increase/decrease buttons
- NOW button for instant reset

### Full Mode

**Date/Time Selection**
- Date picker (calendar icon)
- Large time display

**Speed Controls**
- Fast rewind (-1 day/sec to -1 hour/sec)
- Step back (-1 hour)
- Play/Pause
- Step forward (+1 hour)
- Fast forward (+1 day/sec to +1 hour/sec)

**Speed Multipliers**
| Speed | Description |
|-------|-------------|
| -1 day/sec | Fast rewind |
| -1 hour/sec | Medium rewind |
| -1 min/sec | Slow rewind |
| 1× | Real time |
| +1 min/sec | Slow forward |
| +1 hour/sec | Medium forward |
| +1 day/sec | Fast forward |

**Quick Actions**
- **NOW**: Jump to current real time
- **TONIGHT**: Jump to astronomical dusk

## Framing View

Preview how targets will appear in your camera's field of view.

### Equipment FOV Overlay

When equipment is configured:
- FOV rectangle matching camera/scope configuration
- Dimensions displayed (e.g., "0.50° × 0.33°")
- Rotation handle for camera orientation

### Framing Controls

- **Draggable FOV frame**: Position target within frame
- **Rotation handle**: Rotate camera angle
- **Grid overlay**: Spatial reference
- **Scale indicator**: 10 arcminute reference bar

### Mosaic Preview

For mosaic planning:
- Multi-panel overlay showing planned tiles
- Panel numbering
- Overlap visualization
- Individual panel selection

## Catalog Support

### Star Catalogs

**Bright Star Catalog**
- Configurable magnitude limit (default: 6.0)
- Multiple identification systems (Hipparcos, proper names)
- Spectral type and color data

### Deep Sky Catalogs

| Catalog | Description | Objects |
|---------|-------------|---------|
| **Messier** | Famous bright DSOs | 110 |
| **NGC** | New General Catalogue | ~7,840 |
| **IC** | Index Catalogue | ~5,386 |
| **HyperLEDA** | Galaxy data | Extended |

### Catalog Management

Download and manage catalogs in Settings → Catalogs:
- Download status and progress
- Installation date tracking
- Magnitude-limited packages (Standard, Extended, Complete)
- Delete/reinstall options

### Object Types

17 DSO types are supported:
- Galaxies (spiral, elliptical, irregular)
- Emission nebulae
- Reflection nebulae
- Planetary nebulae
- Dark nebulae
- Open clusters
- Globular clusters
- Galaxy clusters
- Asterisms
- And more...

## Mount Integration

### Slew Mode

Enable tap-to-slew for direct mount control:
1. Toggle **Slew Mode** in toolbar
2. Tap anywhere in sky
3. Mount slews to tapped location
4. Confirm before slew (optional)

### Mount Position Indicator

- Real-time mount position shown on sky view
- Color-coded status:
  - Green: Tracking
  - Yellow: Slewing
  - Red: Stopped/Error
  - Gray: Disconnected

### Go To Object

1. Select object in planetarium
2. Click **Go To** in details panel
3. Mount slews to object coordinates
4. Optional: Enable plate solve and center after slew

## Planning Features

### Target Visibility

For any selected object:
- **24-hour altitude graph**: See when target is highest
- **Rise/Set times**: Plan observation window
- **Transit time**: Optimal imaging time
- **Visibility score**: Quick assessment of conditions

### Moon Avoidance

- Moon position always visible
- Moon distance displayed for selected targets
- Plan around lunar interference
- Moon phase indicator

### Twilight Times

- Civil, Nautical, Astronomical twilight markers
- Dawn/Dusk indicators
- "TONIGHT" quick jump to astronomical dusk

## Performance Features

### Optimization

- Minute-precision time updates (efficient rendering)
- FOV-filtered object queries (only visible objects rendered)
- Animation-isolated rendering (smooth performance)
- Spatial indexing for fast object lookup
- Label layout manager preventing text overlap

### Adaptive Layout

The interface adapts to your device:

| Device | Layout |
|--------|--------|
| **Phone** | Bottom sheets, condensed HUD, smaller touch targets |
| **Tablet** | Medium HUD, balanced layout |
| **Desktop** | Full side panels, larger minimap, extended options |

## Settings

Configure planetarium behavior in Settings → Appearance/Catalogs:

**Display Options**
- Star magnitude limit
- DSO magnitude limit
- Constellation line visibility
- Grid type (Equatorial/Horizontal)
- Star twinkling (on/off)

**Catalog Options**
- Download catalogs
- Configure magnitude limits
- Enable/disable specific catalogs

**Performance**
- Animation quality
- Rendering quality

## Keyboard Shortcuts

| Key | Action |
|-----|--------|
| Arrow keys | Pan view |
| +/= | Zoom in |
| - | Zoom out |
| R | Reset view |
| G | Toggle grid |
| C | Toggle constellations |
| M | Toggle minimap |
| Space | Toggle time play/pause |
| N | Jump to now |

## Tips and Best Practices

### Target Planning

1. Use time controls to preview target visibility
2. Check 24-hour altitude graph for optimal window
3. Verify moon distance for faint targets
4. Preview framing before imaging session

### Session Planning

1. Set time to start of imaging session
2. Identify targets visible at different times
3. Plan order based on altitude and meridian
4. Add targets to sequence from planetarium

### Framing

1. Configure equipment in Settings → Equipment Profiles
2. Select target and click "Send to Framing"
3. Adjust FOV position and rotation
4. Save framing coordinates to target

### Performance

- Reduce star magnitude limit if performance is slow
- Disable twinkling animation on older hardware
- Use "Standard" catalog package for faster loading

## Next Steps

- [Framing Assistant](framing.md) - Detailed framing planning
- [Sequencing](sequencing.md) - Add targets to sequences
- [Equipment](equipment.md) - Configure your gear
