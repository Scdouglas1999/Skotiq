# Sequencing and Automation

The Sequencer is Skotiq's powerful automation engine that lets you plan and execute complex imaging sessions. Build sophisticated workflows with the visual behavior tree editor.

## Overview

The Sequencer uses a **behavior tree** architecture where you build your imaging plan from nodes:
- **Instruction Nodes**: Actions (take exposures, slew, autofocus, etc.)
- **Trigger Nodes**: Monitoring/watchdogs (check HFR, guiding, weather)
- **Logic Nodes**: Control flow (loops, conditionals, parallel execution)

## Sequencer Screen

Navigate to **Sequencer** in the rail to access three tabs:
- **Builder**: Visual sequence editor
- **Targets**: Target library and planning
- **Templates**: Pre-built sequence templates

## Builder Tab

### Interface Layout

The Builder tab has three main areas:

1. **Node Palette** (Left, 260px default, resizable): Available nodes to add to your sequence
2. **Sequence Tree** (Center): Visual workflow editor with drag-and-drop
3. **Properties Panel** (Right, 320px default, resizable): Configure selected node

### Toolbar

**Playback Controls**
- **Start/Resume** (green, pulsing glow): Start or resume sequence
- **Pause** (orange): Pause running sequence
- **Stop**: Halt sequence execution
- **Skip**: Skip to next node

**File Operations**
- **New Sequence**: Create blank sequence
- **Open Sequence**: Import .skotiq file
- **Save Sequence**: Export sequence to file

**Navigation**
- **Polar Alignment**: Link to polar alignment wizard
- **Slew to Target**: Move mount to first target (if targets exist)

**Undo/Redo**
- **Undo** (Ctrl+Z)
- **Redo** (Ctrl+Y)

**Status Display**
- Frame counter and duration
- Simulation mode badge (when enabled)
- Equipment status indicators
- Status badge: Idle | Running | Paused | Stopping | Completed | Failed

### Creating Your First Sequence

#### Step 1: Start with a Root Node

Every sequence starts with a root node:
1. Click **New Sequence** if no sequence exists
2. The root node appears in the tree
3. This is the starting point for execution

#### Step 2: Add Nodes

From the Node Palette:

**Drag and Drop**
- Drag node from palette onto tree
- Drop on parent node or between siblings
- Visual indicator shows drop location

**Or Use Context Menu**
- Right-click node in tree
- Select "Add Child" or "Add Sibling"
- Choose node type from menu

**Or Use Toolbar**
- Select parent node
- Click **Add Node** in toolbar
- Select from node list

#### Step 3: Configure Nodes

Click any node to configure in Properties Panel:
- Set parameters specific to that node
- Options vary by node type
- Invalid settings highlighted in red

#### Step 4: Organize Structure

**Move Nodes**
- Drag nodes to reorder
- Drop on new parent to change hierarchy

**Delete Nodes**
- Select node, press Delete key
- Or right-click > Delete
- Child nodes also deleted

**Copy/Paste**
- Copy: Ctrl+C (Cmd+C on Mac)
- Paste: Ctrl+V (Cmd+V on Mac)
- Duplicate: Ctrl+D (Cmd+D on Mac)

### Node Palette

The Node Palette organizes nodes into categories with search functionality.

**Search**
- Real-time filtering by name and description
- Categories collapse/expand

**Categories**
- Target
- Imaging
- Mount
- Focus
- Camera
- Logic
- Timing
- Utilities

**Adding Nodes**
- Drag from palette to tree
- Double-click to add to selected parent

### Complete Node Reference

## Instruction Nodes

Actions that control your equipment.

### Camera Exposure

Takes one or more exposures.

**Parameters**
- **Count**: Number of exposures (1-999)
- **Exposure Time**: Duration in seconds
- **Gain**: Camera gain setting
- **Offset**: Camera offset setting
- **Binning**: Pixel binning (1x1, 2x2, etc.)
- **Filter**: Which filter to use (if filter wheel connected)
- **Delay**: Seconds between exposures
- **Dither**: Enable dithering (requires guiding)

**Example Use**
- Capture 20x180s Ha images
- Take 50x60s luminance frames
- Shoot RGB with different exposure times per filter

### Slew to Target

Points telescope at specified coordinates.

**Parameters**
- **Target**: Select from target library or enter coordinates
- **RA/Dec**: Manual coordinate entry (J2000)
- **Settle Time**: Seconds to wait after slew
- **Center**: Re-center using plate solving (optional)

**Example Use**
- Slew to M42 at start of sequence
- Move to next target in mosaic
- Return to previous target

### Autofocus

Runs automatic focus routine.

**Parameters**
- **Filter**: Which filter to focus with
- **Temperature Change**: Trigger if temp changed by N degrees
- **Force**: Always run (ignore temperature)
- **Exposure**: Focus frame exposure time
- **Binning**: Focus frame binning

**Example Use**
- Focus at sequence start
- Re-focus after filter change
- Periodic refocus during long sequence

### Filter Change

Changes filter wheel position.

**Parameters**
- **Filter**: Target filter
- **Auto-focus**: Run autofocus after change
- **Focus Offset**: Apply saved offset instead of full AF

**Example Use**
- Switch from Lum to Red filter
- Cycle through LRGB filters
- Change to narrowband filter

### Cool Camera

Sets camera cooling target.

**Parameters**
- **Target Temperature**: Desired temp in °C
- **Wait for Stable**: Delay until temperature reached

**Example Use**
- Cool to -15°C before imaging
- Warm to 0°C at end of session

### Start/Stop Guiding

Controls PHD2 guiding.

**Parameters**
- **Settle Time**: Wait N seconds after guiding starts
- **RMS Threshold**: Require RMS better than N arcseconds

**Example Use**
- Start guiding before exposures
- Stop guiding during meridian flip
- Restart guiding after slew

### Park/Unpark Mount

Moves mount to/from park position.

**Parameters**
- **Custom Position**: Use specific park location
- **Warm Up**: Run warm-up routine after unpark

**Example Use**
- Park at end of sequence
- Unpark before imaging
- Mid-sequence park (waiting for target to rise)

### Wait Time

Waits for a specific time or condition.

**Parameters**
- **Duration**: Seconds to wait (or use Until Time)
- **Until Time**: Wait until specific clock time
- **Until Twilight**: Wait for civil/nautical/astronomical twilight

**Example Use**
- Wait for sky to darken
- Delay until target rises above trees
- Pause between targets

### Delay

Simple pause for a fixed duration.

**Parameters**
- **Seconds**: Duration to pause

### Rotator Control

Controls camera rotator position.

**Parameters**
- **Target Angle**: Desired rotation (0-360°)
- **Mode**: Absolute or Relative

### Dome Control

Controls observatory dome.

**Parameters**
- **Action**: Open, Close, or Park

### Notification

Sends user alerts during sequence.

**Parameters**
- **Message**: Alert text
- **Level**: Info, Warning, Error, Success

### Script

Executes external scripts.

**Parameters**
- **Script Path**: Path to script file
- **Arguments**: Command-line arguments
- **Timeout**: Maximum execution time

## Logic Nodes

Control sequence flow.

### Loop

Repeats child nodes with various termination conditions.

**Loop Types**
| Type | Description |
|------|-------------|
| **Fixed Count** | Repeat exact number of times |
| **Until Time** | Loop until clock time reached |
| **Until Altitude** | Loop until target below threshold |
| **Forever** | Loop indefinitely |
| **While Dark** | Loop while astronomical dark |

**Parameters**
- **Repeat Count**: Number of iterations (fixed count mode)
- **Stop Time**: Target time with quick buttons (Civil Dawn, Nautical Dawn)
- **Stop Below Altitude**: Minimum altitude threshold

**Example Use**
- Take 10 sets of LRGB
- Image until dawn
- Repeat until total integration reached
- Continue while target above 30°

### Parallel

Executes multiple branches simultaneously.

**Parameters**
- **Wait for All**: Wait for all branches to complete
- **Wait for Any**: Continue when first branch completes

**Example Use**
- Take exposures while monitoring guiding
- Image while checking weather conditions
- Capture with multiple cameras simultaneously

### Conditional

Executes child only if condition met.

**Condition Types**
| Condition | Description |
|-----------|-------------|
| **Altitude** | Target altitude threshold |
| **Time** | Current time range |
| **Guiding RMS** | Guiding accuracy threshold |
| **HFR** | Star sharpness threshold |
| **Weather** | Weather conditions |
| **Moon Separation** | Angular distance from moon |
| **Safety Monitor** | Safety device status |

**Parameters**
- **Condition Type**: What to check
- **Comparison**: Equals, greater than, less than, etc.
- **Value**: Threshold value

**Example Use**
- Only image if target altitude > 30°
- Skip if moon too close to target
- Abort if guiding RMS > 2.0"

### Recovery Node

Handles errors with automatic recovery actions.

**Recovery Conditions**
| Condition | Description |
|-----------|-------------|
| **HFR Degradation** | Stars becoming softer |
| **Meridian Flip** | Mount needs to flip |
| **Guiding Failure** | Guide star lost |
| **Altitude Limit** | Target too low |
| **Weather** | Conditions degraded |
| **Temperature** | Temperature changed significantly |
| **Filter Change** | Filter change failed |

**Parameters**
- **Trigger Condition**: What triggers recovery
- **Recovery Action**: What to do (refocus, recalibrate, pause, etc.)
- **Retry Count**: Number of recovery attempts

### Sequence

Groups nodes together.

**Parameters**
- **Name**: Descriptive label
- **Enabled**: Disable without deleting

**Example Use**
- Group related actions (Slew + Focus + Expose)
- Create reusable sub-sequences
- Organize complex workflows

## Trigger Nodes

Background monitors that run in parallel with your sequence.

### HFR Monitor

Checks star sharpness and triggers refocus if needed.

**Parameters**
- **Check Interval**: How often to measure (every N exposures)
- **HFR Threshold**: Maximum acceptable HFR
- **Action on Fail**: Abort, refocus, or alert

**Example Use**
- Auto-refocus if HFR increases (focus drift)
- Alert if seeing degrades
- Pause imaging during poor conditions

### Guiding Monitor

Watches PHD2 guiding performance.

**Parameters**
- **RMS Threshold**: Maximum acceptable RMS
- **Duration**: Must exceed threshold for N seconds
- **Action on Fail**: Abort, recalibrate, or alert

**Example Use**
- Abort if guiding fails
- Re-calibrate if drift detected
- Alert user to check mount

### Weather Monitor

Monitors weather conditions (requires weather station).

**Parameters**
- **Check**: Sky temperature, humidity, wind, rain, clouds
- **Threshold**: Maximum safe value
- **Action on Fail**: Abort, park, or alert

**Example Use**
- Park and abort if rain detected
- Pause if clouds increase
- Alert if wind exceeds limit

### Time Trigger

Executes action at specific time.

**Parameters**
- **Time**: Clock time to trigger
- **Action**: What to do (abort, park, run child nodes)

**Example Use**
- Park at dawn
- Switch targets at midnight
- End session at specific time

### Meridian Flip Trigger

Handles automatic meridian flips.

**Parameters**
- **Degrees Past Meridian**: When to flip
- **Auto-center**: Re-center after flip
- **Auto-focus**: Refocus after flip
- **Resume Guiding**: Restart guiding

**Example Use**
- Auto-flip when 5° past meridian
- Recenter and refocus after flip
- Continue sequence seamlessly

**When the mount stops at its own tracking limit**

Some mounts stop tracking on their own before the target reaches the
meridian, because the tube would hit the pier or tripod. When tracking stops
during a run while the mount is on the west side of the pier, from an hour
before transit on, Skotiq treats the stop as the mount's limit. It holds
exposures and guiding, marks the frame that was exposing as rejected, and
then does what the setting **When the mount stops at its limit**
(Settings > Sequencer > Meridian flip) says:

- **Flip right away** (the default): the mount flips to the east side at
  once and imaging resumes within minutes. Many mounts accept an east-side
  pointing a little before the meridian. If the mount will not take the east
  side yet (it stays on the west side after the slew), the run waits for the
  flip window instead.
- **Wait for the flip window**: tracking stays off until the target is past
  the configured flip point, then the flip runs.

Tracking is never switched back on into the limit. Stops that Skotiq made
itself (a park, a home, a slew, the pre-meridian hold) are never treated as
a limit. Switching tracking off from Skotiq's own mount controls during a run
pauses the run instead; when you resume, tracking is switched back on. A stop
made at the hand controller or by another program looks the same to the
driver as a limit stop, so the notice says how the stop was read; pause or
stop the run if you stopped tracking yourself.

After any flip, the run continues once the mount is verified on its new side.
A recenter that finds no solution, a guider that will not restart, or high
guiding RMS is reported and the run goes on (unless **Stop the run for
quality problems** is on). The flip slews with tracking on, and frames are
released only after the mount's position shows it is tracking. A mount that
reports tracking but does not move is caught the same way; tracking recovery
then keeps trying, with growing waits, and says so each time.

## Building Common Sequences

### Basic Single Target Sequence

```
Root
├── Slew to Target (M42)
├── Autofocus
├── Start Guiding
├── Loop (50 times)
│   └── Camera Exposure (180s, Ha)
└── Park Mount
```

### LRGB Sequence

```
Root
├── Slew to Target
├── Autofocus (Luminance)
├── Start Guiding
├── Sequence (Luminance)
│   ├── Filter Change (Lum)
│   └── Loop (30 times)
│       └── Camera Exposure (180s)
├── Sequence (Red)
│   ├── Filter Change (Red)
│   ├── Autofocus
│   └── Loop (20 times)
│       └── Camera Exposure (120s)
├── Sequence (Green)
│   ├── Filter Change (Green)
│   ├── Autofocus
│   └── Loop (20 times)
│       └── Camera Exposure (120s)
├── Sequence (Blue)
│   ├── Filter Change (Blue)
│   ├── Autofocus
│   └── Loop (20 times)
│       └── Camera Exposure (120s)
└── Park Mount
```

### Multi-Target Night

```
Root
├── Cool Camera (-15°C)
├── Unpark Mount
├── Sequence (M42 - Evening)
│   ├── Wait Until Time (19:00)
│   ├── Slew to Target (M42)
│   ├── Autofocus
│   ├── Start Guiding
│   └── Loop (30 times)
│       └── Camera Exposure (180s, Ha)
├── Sequence (M31 - Late Night)
│   ├── Wait Until Time (23:00)
│   ├── Slew to Target (M31)
│   ├── Autofocus
│   └── Loop (40 times)
│       └── Camera Exposure (180s, Lum)
├── Sequence (M81 - Pre-dawn)
│   ├── Wait Until Time (04:00)
│   ├── Slew to Target (M81)
│   ├── Autofocus
│   └── Loop Until Time (06:00)
│       └── Camera Exposure (180s, Lum)
└── Park Mount
```

### Advanced with Triggers

```
Root
├── Parallel
│   ├── Sequence (Main Workflow)
│   │   ├── Slew to Target
│   │   ├── Autofocus
│   │   ├── Start Guiding
│   │   └── Loop (100 times)
│   │       └── Camera Exposure (180s)
│   ├── HFR Monitor
│   │   ├── Check Every: 5 exposures
│   │   ├── Max HFR: 2.5
│   │   └── Action: Refocus
│   ├── Guiding Monitor
│   │   ├── Max RMS: 1.2"
│   │   └── Action: Alert
│   ├── Meridian Flip Trigger
│   │   ├── Degrees Past: 5
│   │   ├── Auto-center: Yes
│   │   └── Auto-focus: Yes
│   └── Time Trigger
│       ├── Time: 06:00
│       └── Action: Abort and Park
└── Park Mount
```

## Targets Tab

### Target Library

Manage your imaging targets:

**Adding Targets**
1. Click **Add Target**
2. Enter details:
   - Name (e.g., "M42 - Orion Nebula")
   - RA/Dec coordinates (J2000)
   - Or search by name (queries astronomical catalogs)
3. Optional info:
   - Object type (galaxy, nebula, etc.)
   - Size (arcminutes)
   - Notes
   - Framing data

**Import from Catalogs**
- Search Messier, NGC, IC, Caldwell catalogs
- Import from Stellarium
- Load from CSV file

**Target Details**
Each target shows:
- Current altitude and azimuth
- Rise/set times for tonight
- Transit time (highest altitude)
- Moon separation
- Imaging months (best season)

**Planning Features**
- **Tonight's Targets**: Targets visible tonight
- **Altitude Chart**: Visualize target paths across night
- **Best Imaging Window**: Optimal time range for each target
- **Moon Avoidance**: Highlight targets too close to moon

### Using Targets in Sequences

1. In sequence builder, add "Slew to Target" node
2. Click **Select from Library**
3. Choose target
4. Target coordinates automatically filled

## Templates Tab

### Pre-built Sequences

Save time with ready-to-use templates:

**Built-in Templates**
- **Quick Start**: Simple single-target sequence
- **LRGB Standard**: Full LRGB imaging with autofocus
- **Narrowband Ha-OIII-SII**: Hubble palette workflow
- **Mosaic Panel**: Sequence for mosaic tiles
- **Meridian Flip Safe**: Handles flip with all safety checks

**Using Templates**
1. Browse templates
2. Click **Load Template**
3. Customize parameters
4. Save as new sequence or template

### Creating Templates

Save your sequences as reusable templates:

1. Build sequence in Builder tab
2. Click **Save as Template**
3. Name your template
4. Add description and tags
5. Template appears in library

**Template Parameters**
Make templates flexible with parameters:
- Target (user selects when using template)
- Exposure time
- Number of exposures
- Filters to use

### Sharing Templates

- Export template as JSON file
- Share with other users
- Import others' templates
- Community template library (coming soon)

## Running Sequences

### Pre-flight Validation Dialog

Before running, Skotiq validates your sequence with a comprehensive check.

**Validation Process**
1. Click **Run** to open Pre-Flight Validation Dialog
2. Loading spinner with "Running validation checks..."
3. Results display with summary

**Results Summary Card**
| Status | Color | Description |
|--------|-------|-------------|
| **Cannot Start** | Red | Blocking errors found |
| **Ready with Warnings** | Orange | Non-blocking issues |
| **All Checks Passed** | Green | Ready to run |

**Issue Categories**
| Category | Examples |
|----------|----------|
| **Structure** | Empty sequence, no root, orphaned nodes |
| **Targets** | Invalid coordinates, empty targets, low altitude |
| **Imaging** | No exposures, invalid exposure time, high binning |
| **Equipment** | Missing camera, mount, focuser, guider |
| **Timing** | Wait times passed, loop end times passed |
| **Settings** | Default names, long sequences |

**Issue Display**
Each issue shows:
- Severity icon (red X, orange ⚠, blue ℹ)
- Issue title and category badge
- Description text
- Resolution suggestion (lightbulb icon)

**Actions**
- **Re-check**: Run validation again
- **Cancel**: Close dialog
- **Start/Start Anyway**: Begin sequence (if no blocking errors)

### Starting Execution

1. Click **Run Sequence** (play button)
2. Confirmation dialog shows:
   - Estimated duration
   - Targets to image
   - Total exposures
3. Click **Start**
4. Sequence begins executing

### Monitoring Execution

**Sequence Progress Bar** (Visible when running)

*Current Node Info*
- Pulsing indicator (green when running, pause badge when paused)
- Node name (truncated if long)
- Progress message if available

*Target & Filter Display*
- Current target name with icon
- Current filter name with icon

*Progress Metrics*
- "Progress" label
- Exposure counter: "X/Y" (completed/total)
- Percentage badge with number
- Gradient progress bar
- Integration progress overlay

*Timing Information*
- Elapsed time (HhMmSs format)
- Estimated remaining time

**Sequence Tree Updates**
- Current node highlighted in tree
- Status indicators on each node:
  - Running (spinning icon)
  - Success (green check)
  - Failed (red X)
  - Skipped (gray)
- Progress percentage on running nodes

**Equipment Status**
- Live equipment state
- Current exposure countdown
- Guiding graph
- Temperature monitoring

### Controlling Execution

**Pause**
- Click **Pause** to halt after current action
- Equipment stays connected
- Resume when ready

**Stop**
- Click **Stop** to abort sequence
- Completes current exposure
- Returns to idle state

**Skip Node**
- Right-click running node
- Select "Skip"
- Moves to next node

### Sequence Logs

Every sequence execution is logged:
- Start/end times for each node
- Equipment status
- Errors and warnings
- Captured images
- Guiding statistics

View logs in **Analytics** screen.

## Advanced Features

### Variables and Expressions

Use variables for dynamic sequences:

**System Variables**
- `$time` - Current time
- `$date` - Current date
- `$target_alt` - Target altitude
- `$target_az` - Target azimuth
- `$moon_phase` - Moon phase %
- `$lst` - Local sidereal time

**Custom Variables**
- Define in sequence properties
- Use in conditional nodes
- Update during execution

**Example**
```
Conditional: if $target_alt > 30
  Slew to Target
  Image
else
  Wait 30 minutes
  Check again
```

### Event Handlers

Respond to events:
- On guiding start/stop
- On meridian flip
- On temperature change
- On error

### Mosaic Wizard

Special tool for creating mosaic sequences:

1. Click **Mosaic Wizard** in toolbar
2. Define mosaic:
   - Center coordinates
   - Tile count (e.g., 3x3)
   - Overlap percentage
3. Wizard generates sequence:
   - Slew to each panel
   - Center and rotate
   - Image each panel
   - Combine all panels

### Flat Wizard Integration

Integrate calibration frames:

1. In sequence, add "Flat Wizard" node
2. Configure:
   - When to run (start or end of sequence)
   - Which filters
   - Number of flats per filter
3. Wizard automatically:
   - Positions scope
   - Adjusts exposure time
   - Captures flats

## Tips and Best Practices

### Sequence Design

1. **Start Simple**: Build basic sequences first
2. **Test Small**: Run with low exposure counts initially
3. **Add Safety**: Use trigger nodes for monitoring
4. **Plan Timing**: Account for focus, filter changes, dithering
5. **Estimate Duration**: Verify sequence fits in available time

### Trigger Nodes

1. **Always Monitor**: Use at least guiding and HFR triggers
2. **Set Thresholds**: Don't make too sensitive (false alarms)
3. **Choose Actions**: Decide if abort, alert, or auto-fix
4. **Test Triggers**: Verify they activate correctly

### Multi-Target Sequences

1. **Order by Altitude**: Image targets in optimal order
2. **Account for Meridian**: Plan flips or avoid meridian crossing
3. **Re-focus**: Run autofocus when switching targets
4. **Weather Buffer**: Leave time for conditions to change

### Performance

1. **Avoid Nested Loops**: Can slow execution planning
2. **Limit Parallel Branches**: Too many can overwhelm system
3. **Batch Actions**: Group similar actions together
4. **Disable Unused**: Disable nodes instead of deleting

## Keyboard Shortcuts

- **Ctrl+N**: New sequence
- **Ctrl+S**: Save sequence
- **Ctrl+Z**: Undo
- **Ctrl+Y**: Redo
- **Delete**: Delete selected node
- **Ctrl+D**: Duplicate node
- **Space**: Run/pause sequence
- **Esc**: Stop sequence

## Troubleshooting

### Sequence won't start
- Run validation to check for errors
- Verify all equipment connected
- Check target is visible
- Review pre-flight warnings

### Sequence stops unexpectedly
- Check logs for error messages
- Review trigger node thresholds
- Verify equipment didn't disconnect
- Check disk space

### Poor performance
- Simplify complex sequences
- Reduce parallel branches
- Check system resource usage
- Update to latest version

## Next Steps

- [Imaging Guide](imaging.md) - Master manual imaging first
- [Imaging Focus Tab](imaging.md#focus-tab) - Understand autofocus before automating
- [Framing Assistant](framing.md) - Plan target framing
- [Analytics](analytics.md) - Review sequence performance
