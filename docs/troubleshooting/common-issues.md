# Troubleshooting Common Issues

This guide covers common Skotiq problems and first-pass fixes.

For public-release validation, confirm the feature is in scope before treating a
failure as a defect. Platform support, native SDK support, remote access, and
driver coverage must match the release notes, [supported hardware matrix](../supported-hardware-by-platform.md),
and [known limitations](../known-limitations.md).

## Protocol-Specific Guides

- [ASCOM Troubleshooting](ascom.md)
- [INDI Troubleshooting](indi.md)
- [Alpaca Troubleshooting](alpaca.md)
- [PHD2 Troubleshooting](phd2.md)
- [Driver Troubleshooting](drivers.md)
- [Permissions Troubleshooting](permissions.md)
- [Firewall Troubleshooting](firewall.md)

## Equipment Connection Issues

### Camera Not Detected

**Symptoms**
- Camera doesn't appear in device list
- "No cameras found" message
- Connection fails with error

**Solutions**

**Check Physical Connection**
1. Verify USB cable is firmly connected at both ends
2. Try a different USB port (preferably USB 3.0)
3. Try a different USB cable if available
4. For powered cameras, verify power supply is connected and on

**Verify Driver Installation (Windows)**
1. Check Device Manager (Win+X > Device Manager)
2. Look for camera under "Imaging Devices" or "Universal Serial Bus devices"
3. If yellow exclamation mark appears, driver issue exists
4. For ASCOM:
   - Verify ASCOM Platform is installed
   - Install camera's ASCOM driver
   - Test driver using ASCOM Diagnostics tool
5. For Native mode:
   - Reinstall camera vendor's SDK/drivers
   - Check vendor website for latest drivers
   - Confirm the installed Skotiq release includes the required native SDK
     library for your OS

**Linux-Specific**

Use this section only when the release notes list Linux as a shipped artifact
or you are validating a Linux build from source.

1. Check USB permissions:
   ```bash
   lsusb  # Verify camera appears
   ```
2. Add udev rules for your camera:
   ```bash
   sudo nano /etc/udev/rules.d/99-qhy.rules
   # Add: SUBSYSTEM=="usb", ATTR{idVendor}=="1618", MODE="0666"
   sudo udevadm control --reload-rules
   ```
3. Verify user is in `plugdev` group:
   ```bash
   sudo usermod -a -G plugdev $USER
   # Log out and back in
   ```

**INDI Server**

INDI requires a reachable server and a driver that exposes the needed device
properties. It can run locally or on another machine; support still depends on
the release scope and the INDI driver.

1. Verify INDI server is running:
   ```bash
   ps aux | grep indiserver
   ```
2. Start server with correct driver:
   ```bash
   indiserver indi_qhy_ccd  # Example for QHY
   ```
3. Check INDI logs:
   ```bash
   tail -f /tmp/indiserver.log
   ```

**Still Not Working?**
- Close all other astronomy software (they may have the camera locked)
- Restart Skotiq
- Restart computer
- Try camera with vendor's test software to rule out hardware issues
- Review [Driver Troubleshooting](drivers.md) for backend-specific checks

---

### Mount Not Responding

**Symptoms**
- Mount connects but won't move
- Movement commands timeout
- "Device not responding" errors

**Solutions**

**Check Mount Power and Handbox**
1. Verify mount is powered on
2. Check handcontroller (if equipped) is working
3. Try moving mount with handcontroller to verify hardware works
4. Ensure mount is tracking (many won't respond to commands while parked)

**Unpark the Mount**
1. In Skotiq, go to Imaging > Mount tab
2. Look for **Park Status** indicator
3. If parked, click **Unpark**
4. Wait for mount to complete unpark routine

**COM Port Issues (Windows)**
1. Verify correct COM port is selected:
   - Go to Equipment > Connections
   - Click Properties on mount driver (ASCOM)
   - Verify COM port number
2. Check Device Manager (Win+X > Device Manager)
3. Expand "Ports (COM & LPT)"
4. Find your mount's serial adapter
5. Note the COM port number, update driver if needed

**Check for Port Conflicts**
1. Only one application can use a serial port at once
2. Close other apps that might be using the mount:
   - EQMOD (if separate instance running)
   - Stellarium with telescope control
   - Cartes du Ciel
   - ASCOM driver test utilities
3. Restart Skotiq

**Cable Issues**
1. Check serial/USB cable is firmly connected
2. Try different USB port
3. For USB-to-serial adapters, ensure driver is current
4. Long USB cables can cause issues - try shorter cable

**Baud Rate Mismatch**
1. Some mounts require specific baud rate
2. In ASCOM driver properties, check baud rate setting
3. Common rates: 9600, 19200, 115200
4. Consult mount manual for correct rate

**Communication Protocol**
1. Verify correct mount driver is selected
2. For example, Celestron mounts:
   - "Celestron Unified" for modern mounts
   - Specific model driver for older mounts
3. Check vendor website for recommended ASCOM driver
4. If using Alpaca or INDI, confirm the server exposes mount movement, tracking,
   park, and unpark capabilities before expecting Skotiq controls to enable

---

### Images Not Saving

**Symptoms**
- Exposures complete but no file appears
- "Failed to save image" error
- Files save but are empty or corrupted

**Solutions**

**Check Disk Space**
1. Verify destination drive has sufficient space
2. Images can be large (10-50+ MB each)
3. Check available space: Windows (right-click drive > Properties), Linux (`df -h`)

**Verify Save Path**
1. Go to Imaging > Camera tab
2. Check **Save Location** path
3. Ensure path exists and is accessible
4. Avoid network drives (can be slow/unreliable)
5. Use local SSD if possible for speed

**Check Write Permissions**
1. Windows: Right-click save folder > Properties > Security
2. Ensure your user account has "Write" permission
3. Linux: Check folder permissions with `ls -la`
4. Try saving to Documents folder to test
5. Review [Permissions Troubleshooting](permissions.md) for platform-specific
   save-path checks

**File Naming Issues**
1. Check file naming template doesn't have invalid characters
2. Windows forbidden characters: `< > : " / \ | ? *`
3. Avoid extremely long file names (>255 characters)
4. Verify placeholders in template are valid

**Anti-virus / Ransomware Protection**
1. Some security software blocks new executables from writing files
2. Windows Defender > Ransomware Protection > Allow app through
3. Add Skotiq to allowed apps list
4. Or temporarily disable to test

**Corrupted Images**
1. If files save but won't open:
   - Check file size (should be >10KB for typical image)
   - Zero-byte files indicate write failure
   - Try different file format (FITS vs. TIFF)
2. Verify camera is capturing properly:
   - Check preview shows image
   - Statistics show non-zero values

---

### Connection Lost During Imaging

**Symptoms**
- Camera/mount disconnects mid-sequence
- "Device connection lost" error
- USB disconnect sound (Windows)

**Solutions**

**USB Power Issues**
1. USB ports may not provide enough power for camera
2. Use powered USB hub
3. Connect camera to rear motherboard USB ports (not front panel)
4. For cooled cameras, ensure external power supply is adequate
5. Disable USB Selective Suspend (Windows):
   - Control Panel > Power Options > Change plan settings
   - Change advanced power settings
   - USB settings > USB selective suspend setting > Disabled

**USB Cable Quality**
1. Use high-quality USB 3.0 cable
2. Keep cable length under 15 feet (5 meters)
3. Avoid USB extension cables (use powered hub instead)
4. Replace if cable shows wear or damage

**Driver Stability**
1. Update to latest camera drivers
2. Update motherboard USB drivers
3. For USB 3.0 cameras, try USB 2.0 port (slower but more stable)
4. Windows: Device Manager > USB Controllers > Update driver

**Computer Power Management**
1. Prevent computer from sleeping:
   - Windows: Settings > System > Power & sleep > Never
   - macOS: System Preferences > Energy Saver
   - Linux: Settings > Power
2. Disable hibernation
3. Consider "presentation mode" during imaging

**Interference**
1. Keep USB cables away from power cables
2. Use ferrite chokes on USB cables to reduce EMI
3. Turn off nearby devices (phones, WiFi routers)

**Overheating**
1. Ensure camera has adequate cooling
2. Check computer isn't overheating (throttling can cause USB issues)
3. Monitor camera temperature

---

### PHD2 Not Connecting

**Symptoms**
- "Cannot connect to PHD2" error
- Guiding tab shows disconnected
- PHD2 is running but Skotiq can't see it

**Solutions**

**Verify PHD2 is Running**
1. Launch PHD2 before connecting from Skotiq
2. PHD2 must be running for Skotiq to connect

**Check PHD2 Server Settings**
1. In PHD2: Tools > Enable Server
2. Verify "Enable Server" is checked
3. Note the port number (default: 4400)

**Firewall Blocking Connection**
1. Windows Firewall may block local connection
2. Windows: Settings > Update & Security > Windows Security > Firewall
3. Click "Allow an app through firewall"
4. Ensure PHD2 and Skotiq are allowed
5. Or disable firewall temporarily to test

**Port Conflict**
1. Another application may be using port 4400
2. Change PHD2 server port:
   - PHD2: Tools > Advanced Settings > Server Port
   - Change to different port (e.g., 4401)
3. Update Skotiq to match (Equipment > Settings)

**Localhost Resolution**
1. Verify connection address in Skotiq
2. Should be `localhost` or `127.0.0.1`
3. Try the other if one doesn't work

**PHD2 Version**
1. Ensure PHD2 is up to date
2. Use a PHD2 version compatible with the Skotiq release notes
3. Download latest from the PHD2 website when compatibility is unclear

---

## Imaging Issues

### Autofocus Fails

**Symptoms**
- "Autofocus failed" error
- V-curve is flat or erratic
- Focus never finds minimum HFR

**Solutions**

**Star Selection**
1. Ensure bright star is in frame
2. Not too bright (saturated)
3. Not too faint (noisy)
4. Move scope if no suitable star available

**Focus Range Too Small**
1. In Focus tab, increase step size
2. Increase number of steps
3. May need wider range to find focus

**Starting Position Out of Range**
1. Manually focus approximately first
2. Then run autofocus for fine-tuning

**Exposure Settings**
1. Increase focus exposure time (3-5 seconds typical)
2. Use higher binning for faster frames (2x2)
3. Ensure gain is appropriate (not too low)

**Seeing Conditions**
1. Turbulent air causes erratic HFR readings
2. Wait for calmer conditions
3. Or increase number of measurements to average out

**Backlash**
1. Enable backlash compensation in Focus settings
2. Set backlash amount (50-300 steps typical)
3. Ensures focuser always approaches from same direction

**Temperature Compensation**
1. If temperature is changing rapidly, disable temp compensation
2. Focus may drift during autofocus run
3. Wait for temperature to stabilize

**Mechanical Issues**
1. Check focuser isn't binding or slipping
2. Verify focuser responds to commands
3. Test manual focus movement first

---

### Plate Solving Fails

**Symptoms**
- "Solve failed" error
- Solving times out
- Wrong coordinates returned

**Solutions**

**Image Quality**
1. Ensure image has enough stars (50+ visible)
2. May need longer exposure for faint fields
3. Stars should be in focus
4. Avoid oversaturated images

**Search Region**
1. Provide approximate coordinates to solver
2. Narrow search region speeds up solving
3. In Equipment > Settings, set observatory location

**Solve Scale**
1. Verify image scale is correct
2. Calculate: (Pixel size × 206) / Focal length
3. Example: (3.76 µm × 206) / 430mm = 1.8 arcsec/pixel
4. Enter in solver settings

**Catalog Data**
1. Ensure astrometry index files are installed
2. Download from Astrometry.net
3. Place in correct directory (see Skotiq settings)

**Solve Timeout**
1. Increase timeout value in settings
2. Wide-field images take longer to solve
3. First solve may take longer (builds index)

**Oversized Images**
1. Very large images (>20MP) may need downsampling
2. Enable downsample option in solve settings
3. Or bin image before solving

---

### Poor Guiding Performance

**Symptoms**
- RMS >1.5 arcseconds
- Oscillating corrections
- Stars drift or trail despite guiding

**Solutions**

**PHD2 Calibration**
1. Re-calibrate PHD2
2. PHD2: Brain icon > Calibrate
3. Ensure declination movement is detected
4. If calibration fails, check mount is tracking

**Aggressiveness Settings**
1. In PHD2, lower aggressiveness (start with 60-70%)
2. Too high causes oscillation
3. RA and Dec may need different values
4. Adjust one at a time, monitor results

**Minimum Move**
1. Set minimum move to prevent over-correction
2. PHD2: Advanced Settings > Minimum Move
3. Start with 0.3 pixels
4. Prevents reacting to noise

**Backlash**
1. Enable declination backlash compensation
2. PHD2: Mount tab > Enable Dec Backlash Comp
3. Adjust amount until oscillation stops

**Polar Alignment**
1. Poor polar alignment causes large Dec drift
2. Use Skotiq drift alignment tool or PHD2 drift align
3. Improve alignment iteratively
4. Goal: <5 arcminutes error for good guiding

**Equipment Issues**
1. Check for cable snags during movement
2. Verify mount isn't binding
3. Tighten all mechanical connections
4. Check for loose camera/guide scope mounting

**Seeing Conditions**
1. Turbulent air limits guiding performance
2. Guide on brighter star for better SNR
3. Increase guide exposure time
4. Accept higher RMS on poor nights

**Wind and Vibration**
1. Add weight to tripod/mount
2. Shorten guide exposures (less time for gusts)
3. Use wind screen
4. Wait for calmer conditions

**Dithering Interference**
1. Ensure dither settle time is adequate
2. Typically 5-10 seconds
3. Increase if guiding hasn't settled before next exposure

---

### Images Come Out Black

**Symptoms**
- Saved images are completely black
- Preview shows black frame
- Statistics show very low values

**Solutions**

**Lens Cap / Obstruction**
1. Remove lens cap (yes, really!)
2. Check for dust cap on camera or scope
3. Ensure telescope is pointed at sky, not wall/ground

**Shutter / Darkslide**
1. Check camera's mechanical shutter is open
2. For filter wheels with darkslide, verify it's retracted

**Exposure Settings**
1. Verify exposure time is set (not 0 seconds)
2. Check exposure actually started (progress bar moves)
3. Camera may be in "bias" or "dark" mode

**Night Sky is Dark!**
1. Night sky is genuinely very dark
2. You may need to stretch the histogram to see anything
3. Try exposing on Moon or bright planet to test
4. Use Auto Stretch in preview

**Shutter Not Opening**
1. Some cameras have mechanical shutter that can fail
2. Take "dark" frame (cover scope) and light frame
3. If both are identical, shutter may not be opening
4. Contact camera vendor

**Camera Malfunction**
1. Restart camera (disconnect/reconnect)
2. Test with vendor's software
3. Check for firmware updates

---

### Saturated / Blown Out Images

**Symptoms**
- Images are completely white
- Preview shows all white
- Statistics show maximum values

**Solutions**

**Exposure Too Long**
1. Reduce exposure time
2. Bright targets (Moon, planets) need very short exposures
3. Start with 1 second and adjust

**Gain Too High**
1. Lower gain setting
2. For bright targets, use lowest gain
3. Try Unity Gain as starting point

**Bright Light Pollution**
1. Use light pollution filter
2. Reduce exposure time
3. Choose darker location if possible

**Daylight Imaging**
1. If imaging Sun (with proper solar filter!), use very short exposures
2. Milliseconds to seconds typical
3. Very low gain

**Flat Panel Too Bright**
1. When taking flats, adjust panel brightness
2. Or reduce exposure time
3. Goal: ~50% saturation for good flats

---

## Application Issues

### Skotiq Won't Start

**Symptoms**
- Double-click icon, nothing happens
- Splash screen appears then closes
- Crash immediately on launch

**Solutions**

**Check Logs**
1. Windows: `%APPDATA%\Skotiq\logs\`
2. macOS: `~/Library/Application Support/Skotiq/logs/` when macOS is
   shipped or being validated
3. Linux: `~/.local/share/skotiq/logs/` when Linux is shipped or being
   validated
4. Open latest log file for error messages

**Graphics Driver Issue**
1. Update graphics drivers
2. Check the runtime requirements in the release notes for your platform
3. Older integrated graphics may not be supported

**Missing Dependencies**
1. Windows: Install Visual C++ Redistributable
2. Windows: Install .NET Framework 4.8 if ASCOM COM support is in scope
3. Linux: `ldd skotiq` to check missing libraries when validating a Linux
   package

**Corrupted Settings**
1. Rename or delete settings folder:
   - Windows: `%APPDATA%\Skotiq\settings.db`
   - macOS: `~/Library/Application Support/Skotiq/settings.db` when macOS
     is in scope
   - Linux: `~/.local/share/skotiq/settings.db` when Linux is in scope
2. Skotiq will recreate with defaults

**Permission Issues**
1. Run as administrator (Windows) to test
2. Check file permissions on install directory
3. Reinstall to different location

**Antivirus Blocking**
1. Some antivirus software blocks unknown executables
2. Add Skotiq to whitelist
3. Or temporarily disable to test

---

### Application Crashes During Use

**Symptoms**
- Skotiq closes unexpectedly
- "Application has stopped working" error
- Freeze requiring force quit

**Solutions**

**Update Skotiq**
1. Check for latest version
2. Update may fix known bugs

**Check System Resources**
1. Open Task Manager (Windows) or Activity Monitor (macOS/Linux)
2. Check RAM usage - Skotiq needs 4-8GB available
3. Close other applications
4. Avoid very large images if RAM limited

**Graphics Driver**
1. Update to latest stable driver
2. Disable graphics acceleration in Skotiq settings if issues persist

**Database Corruption**
1. Skotiq uses SQLite database
2. If corrupt, can cause crashes
3. Backup and delete: `%APPDATA%\Skotiq\skotiq.db`
4. Skotiq will recreate

**Plugin Issues**
1. Disable plugins one by one to identify culprit
2. Remove problematic plugin
3. Report to plugin developer

**Report Bug**
1. Collect log files
2. Note exact steps to reproduce
3. Post to GitHub Issues with details

---

### Slow Performance / UI Lag

**Symptoms**
- Interface is sluggish
- Image preview updates slowly
- Mouse cursor lags

**Solutions**

**Large Image Files**
1. Very large images (50MP+) can slow preview
2. Use binning to reduce file size
3. Enable downsampling for preview

**Many Saved Images**
1. Clear image history/cache
2. Move old images to archive folder
3. Limit number of thumbnails loaded

**Planetarium Rendering**
1. Planetarium feature is GPU-intensive
2. Reduce star count in planetarium settings
3. Disable DSO (deep sky object) rendering if not needed
4. Lower resolution

**Background Processes**
1. Close other applications
2. Disable background downloads/updates
3. Check for malware/crypto miners

**Old Hardware**
1. Skotiq benefits from modern CPU and GPU
2. 8GB+ RAM recommended
3. SSD for operating system improves responsiveness

**Database Maintenance**
1. Periodically vacuum database:
   - Equipment > Settings > Database > Vacuum
2. Removes fragmentation, improves speed

---

## Platform-Specific Issues

### Windows: ASCOM Driver Not Found

**Solutions**
1. Install ASCOM Platform 6.6 or later
2. Download from https://ascom-standards.org/
3. After installing platform, install device-specific drivers
4. Restart Skotiq after driver installation

### macOS: "App is damaged" Message

Use this section only when the completed release notes list a macOS artifact as
shipped or limited for the build you installed.

**Solutions**
1. This is Gatekeeper security feature
2. Open Terminal and run:
   ```bash
   xattr -cr /Applications/Skotiq.app
   ```
3. Try launching again

### Linux: Permission Denied Errors

Use this section only when the completed release notes list a Linux artifact as
shipped or you are validating a Linux build from source.

**Solutions**
1. Add user to dialout group for serial ports:
   ```bash
   sudo usermod -a -G dialout $USER
   ```
2. Add user to video group for cameras:
   ```bash
   sudo usermod -a -G video $USER
   ```
3. Log out and back in for groups to take effect
4. For USB devices, create udev rules (see Camera Not Detected above)

---

## Getting More Help

### Collecting Diagnostic Information

When asking for help, provide:

1. **Skotiq Version**: Help > About
2. **Operating System**: Windows/macOS/Linux version
3. **Log Files**: From logs folder
4. **Error Messages**: Exact text of errors
5. **Steps to Reproduce**: What were you doing when issue occurred?
6. **Equipment**: Camera, mount, focuser models
7. **Connection Method**: ASCOM/INDI/Alpaca/Native
8. **Release Scope**: Whether the platform/backend/device is listed as shipped,
   limited, or unsupported in the release notes

### Support Resources

**Official Support**
- Documentation: This documentation
- GitHub Issues: https://github.com/Scdouglas1999/Skotiq/issues

**Community Help**
- Cloudy Nights forum
- Reddit: r/astrophotography
- Facebook groups

**Before Posting**
1. Search existing issues/posts for solution
2. Try basic troubleshooting steps above
3. Update to latest version
4. Collect diagnostic info
5. Post detailed description with logs

### Emergency Procedures

**Camera Stuck During Exposure**
1. Wait for exposure timeout (don't interrupt)
2. Don't unplug USB during exposure
3. After timeout, disconnect in Skotiq
4. Power cycle camera if needed

**Mount Behaving Erratically**
1. Click Emergency Stop in Mount tab
2. If that fails, disconnect mount in Equipment
3. As last resort, power off mount
4. Never let mount crash into tripod or pier

**Lost in the Sky**
1. Slew to known bright star (Polaris, Vega, etc.)
2. Plate solve to determine actual position
3. Sync mount to correct coordinates
4. Continue session

---

## Still Having Issues?

If you've tried these solutions and still experiencing problems:

1. Post detailed issue on [GitHub Issues](https://github.com/Scdouglas1999/Skotiq/issues) with logs
2. Include Skotiq version, OS, equipment, and steps to reproduce

Use the exact error text and evidence above so support can distinguish a bug
from an unsupported platform, driver, or release artifact.
