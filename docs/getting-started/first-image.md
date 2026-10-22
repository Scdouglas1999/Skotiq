# Capturing Your First Image

This guide walks through a conservative first imaging run with Skotiq.
Start with a short, low-risk exposure and verify each device before moving to
long sequences or unattended automation.

## Release Scope Notes

Before connecting hardware, review:

- [Supported Hardware By Platform](../supported-hardware-by-platform.md)
- [Known Limitations](../known-limitations.md)
- [Migration, Backup, and Restore Guide](../migration-backup-restore.md)

Do not assume every visible control is supported by every driver or operating
system. ASCOM is Windows-only, INDI requires a running INDI server, Alpaca
requires a reachable network device or server, and native SDK support is
available only where the release package includes and verifies the vendor
library.

## Prerequisites

Before capturing images, ensure:
- [ ] Camera is connected (see [First Connection](first-connection.md))
- [ ] Mount is connected and tracking, or you are intentionally testing a
      camera-only workflow
- [ ] Save location is writable and has enough free disk space for the session
- [ ] Equipment profile and current settings are backed up if this is an upgrade
      or release-candidate validation run
- [ ] You have a target in view (Moon, bright planet, or star field)
- [ ] Camera lens cap or dust cap is removed
- [ ] Unsafe or unsupported devices are left disconnected until their support
      status is confirmed

## Quick Start: Single Exposure

The fastest way to capture your first image:

### Step 1: Navigate to Imaging Screen

1. Click **Imaging** in the rail (camera icon, under Observe)
2. The Imaging screen will open with multiple tabs

### Step 2: Configure Camera Settings

1. Select the **Camera** tab
2. Set conservative exposure parameters:

   **Exposure Time**
   - Start with 1-5 seconds for testing
   - Use shorter exposures for the Moon and bright planets
   - Move to longer deep-sky exposures only after focus, saving, and mount
     behavior are verified

   **Gain**
   - Start with Unity Gain (often around 100-150, varies by camera)
   - Lower for bright targets, higher for faint targets

   **Offset**
   - Use manufacturer's recommended value (usually 10-50)

   **Binning**
   - Start with 1x1 (no binning) for full resolution
   - Use 2x2 for faster framing/focusing

   **File Format**
   - FITS recommended for astrophotography
   - TIFF also supported

3. Set **Save Location**:
   - Click the folder icon
   - Choose where to save your images
   - Create a new folder for tonight's session

### Step 3: Cool Your Camera, If Supported

If your camera and driver expose cooling controls:

1. Enable **Cooling**
2. Set target temperature (typically -10°C to -20°C)
3. Wait for temperature to stabilize before starting calibration-sensitive work

If cooling controls are missing or disabled, treat that as a driver capability
limit and continue with uncooled test exposures rather than forcing the control.

### Step 4: Take Your First Exposure

1. Go to the **Capture** tab
2. Click the large **START EXPOSURE** button
3. Watch the progress bar as the exposure runs
4. When complete, the image will display in the preview area

### Step 5: Review Your Image

The captured image appears in the preview:

- **Zoom**: Scroll wheel or pinch to zoom
- **Pan**: Click and drag to move around
- **Stretch**: Adjust the histogram slider to see faint details
- **Statistics**: View image stats (mean, median, HFR) in the info panel

## Taking Multiple Exposures

To capture a series of images:

### Step 1: Set Up Image Series

1. In the **Capture** tab, find the exposure controls
2. Set **Count**: Number of exposures (e.g., 10)
3. Set **Delay**: Time between exposures (usually 0-5 seconds)

### Step 2: Configure File Naming

1. Click **File Settings**
2. Set naming pattern:
   - Use placeholders: `{object}_{filter}_{num}_{exp}s`
   - Example result: `M42_Lum_001_180s.fits`
3. Enable **Auto-increment** to avoid overwriting files

### Step 3: Start the Sequence

1. Click **START EXPOSURE**
2. Skotiq will capture the specified number of images
3. Progress shows: "Capturing 3 of 10..."
4. Each image auto-saves to your chosen location

### Step 4: Stop if Needed

- Click **STOP** to abort the current exposure
- Click **ABORT SEQUENCE** to stop the entire series

## Setting Up for Deep Sky Imaging

For longer exposures:

### Step 1: Frame Your Target

1. Use short exposures (1-2 seconds) with high binning (2x2)
2. Slew the mount to your target only after confirming it is unparked, tracking,
   and safe to move:
   - Use **Imaging** > **Mount** tab for manual slewing
   - Or use **Planetarium** screen to select and slew to objects
3. Adjust mount position with small moves until the target is centered

Stop if coordinates do not update, the mount reports a parked state, or the
target is below the horizon or obstructed from your observing location.

### Step 2: Focus Your Telescope

Critical for sharp images:

1. Go to **Imaging** > **Focus** tab
2. Select a bright star
3. Click **Auto Focus** to run automatic focusing routine
   - Skotiq will take a series of exposures at different focus positions
   - Automatically finds the sharpest focus
4. Or use **Manual Focus**:
   - Click **Start** to begin live focusing mode
   - Adjust focuser in/out
   - Watch HFR (Half-Flux Radius) value - lower is better
   - When HFR is minimized, you're in focus

### Step 3: Start Guiding, If Available

For exposures longer than 30-60 seconds, use guiding when your setup supports it:

1. Go to **Imaging** > **Guiding** tab
2. Ensure PHD2 is installed, running, and connected to the guide setup
3. Click **Start Guiding** in Skotiq
4. PHD2 will calibrate (if needed) and begin guiding
5. Wait for "Guiding" status before starting exposures

### Step 4: Configure Long Exposure Settings

1. Return to **Imaging** > **Camera** tab
2. Set exposure time (e.g., 180 seconds = 3 minutes)
3. Set appropriate gain for your target
4. Enable dithering (in Guiding tab) to reduce noise patterns

### Step 5: Start Imaging

1. Go to **Capture** tab
2. Set number of exposures (e.g., 30-50 for a deep sky target)
3. Click **START EXPOSURE**
4. Monitor progress:
   - Watch guiding graph for tracking quality
   - Check histogram to ensure you're not over/underexposed
   - Monitor temperature if using cooled camera

## Using Filter Wheels

If you have a supported filter wheel connected:

1. In **Camera** tab, you'll see **Filter** dropdown
2. Select desired filter (Lum, Red, Green, Blue, Ha, OIII, etc.)
3. Filter wheel will rotate to the selected position if the driver supports
   remote position changes
4. Wait for "Filter: [Name]" status before exposing

To capture through multiple filters:
- Take exposures with one filter
- Change filter
- Take exposures with next filter
- Or use **Sequencer** to automate filter changes

If no filter wheel is detected, or if the platform support matrix lists your
driver path as unsupported, capture a single-filter or no-filter test first.

## Image Preview and Plate Solving

### Live Preview

Each captured image displays automatically:
- Latest image shows in preview pane
- Previous images accessible via thumbnail strip
- Click thumbnail to view earlier exposures

### Plate Solving

To verify your framing and get precise coordinates:

1. Capture a test image (30+ seconds for better star detection)
2. Click **Plate Solve** button in the image toolbar
3. Skotiq will analyze star patterns and determine:
   - Exact RA/Dec of image center
   - Field of view
   - Image rotation angle
4. Results overlay on the image
5. If solving fails, ensure:
   - Image has enough stars (may need longer exposure)
   - Approximate coordinates are known (helps solver)

## Saving and Managing Images

### Auto-Save Settings

1. Go to **Equipment** > **Settings** tab, or the current settings surface for
   image storage in your build
2. Under **Imaging**:
   - **Auto-save captures**: Enabled by default
   - **Save location**: Choose default folder
   - **File naming**: Set pattern and auto-increment
   - **Create subfolders**: Organize by date/session

### Manual Save

To save a specific image:
1. Select image in preview
2. Click **Save** button
3. Choose location and filename
4. Select format (FITS/TIFF)

### Image Library

All captured images are tracked:
1. Go to **Analytics** screen
2. Browse by session, date, or target
3. View statistics and thumbnail previews
4. Click to open full image

## Troubleshooting First Exposures

### Image is completely black
- Check lens/dust cap is removed
- Verify camera is actually exposing (check progress bar)
- Stretch the histogram - very faint targets may appear black at linear stretch
- Try brighter target (Moon, Jupiter) for testing

### Image is completely white (saturated)
- Exposure too long or gain too high for your target
- Reduce exposure time
- Lower gain setting
- Use neutral density filter for very bright objects

### Image is blurry/elongated stars
- **Out of focus**: Use Focus tab to achieve critical focus
- **Tracking issues**: Check mount is tracking and polar aligned
- **Wind/vibration**: Wait for calmer conditions or add weight to mount
- **Exposure too long**: Reduce exposure time for unguided imaging

### Camera not responding during exposure
- Don't disconnect USB during exposure
- Don't close Skotiq during exposure
- If frozen, wait for exposure timeout, then reconnect camera
- Check USB power delivery is sufficient

### Files not saving
- Check disk space at save location
- Verify write permissions to folder
- Check folder path is valid
- Look for error messages in Equipment > Settings > Logs

### A control is disabled or missing
- Check [Supported Hardware By Platform](../supported-hardware-by-platform.md)
- Confirm the connected driver exposes that capability
- Use a simpler first run if filter wheel, rotator, dome, weather, or safety
  devices are not available in your setup
- Do not bypass disabled controls for a public-release smoke pass; record the
  missing capability as evidence instead

### Remote or mobile control does not connect
- Start with local desktop control first
- For headless or LAN use, follow
  [Headless Secure Setup](../headless-secure-setup.md)
- Verify token authentication before enabling LAN exposure
- Emulator or localhost tests do not replace a second-device LAN/firewall check
  for release validation

## Next Steps

Now that you've captured your first images:

- [Sequencer Guide](../features/sequencing.md) - Automate multi-filter sequences
- [Imaging Features Guide](../features/imaging.md) - Camera, mount, focusing,
  capture, and preview controls
- [Framing Assistant](../features/framing.md) - Plan and frame targets precisely
- [Guiding Guide](../features/guiding.md) - PHD2 setup and guiding workflow
- [Migration, Backup, and Restore Guide](../migration-backup-restore.md) -
  Protect profiles before upgrades or release-candidate testing

## Tips for Great Images

1. **Master the Basics First**
   - Start with bright targets (M42, M45, M31)
   - Perfect your focus technique
   - Learn your camera's optimal gain and exposure settings

2. **Monitor Conditions**
   - Check weather, seeing, and transparency
   - Use Analytics screen to track session quality
   - Save detailed notes for each session

3. **Take Calibration Frames**
   - Darks (same exposure/temp as lights)
   - Flats (use Flat Wizard)
   - Bias frames for calibration
   - Essential for high-quality final images

4. **Build Imaging Plans**
   - Use Sequencer for automated multi-hour sessions
   - Save successful sequences as templates
   - Plan for entire nights with multiple targets

5. **Practice, Practice, Practice**
   - Start with single exposures
   - Graduate to sequences
   - Experiment with different targets and settings
   - Learn from each session

## Getting Help

Questions about imaging?
- [Imaging Features Guide](../features/imaging.md) - Detailed feature documentation
- [Troubleshooting Guide](../troubleshooting/common-issues.md) - Common problems and solutions
- [GitHub Issues](https://github.com/Scdouglas1999/Skotiq/issues) - Report bugs or ask for help

Clear skies and happy imaging!
