# Equipment Management

The Equipment screen is your central hub for discovering, connecting, and managing all your astrophotography devices. Skotiq supports multiple connection protocols to ensure compatibility with virtually any equipment.

## Overview

The Equipment screen is organized into three tabs:
- **Discovery**: Find and connect new devices
- **Connected**: Manage currently connected equipment
- **Settings**: Configure device-specific options

## Connection Protocols

Skotiq supports four connection protocols, each with different strengths:

| Protocol | Platform | Best For | Requirements |
|----------|----------|----------|--------------|
| **ASCOM** | Windows only | Direct driver access, widest Windows compatibility | ASCOM Platform + device drivers |
| **INDI** | Linux/macOS | Native Unix support, open-source drivers | INDI server + drivers |
| **Alpaca** | All platforms | Network devices, remote imaging | Alpaca server on device |
| **Native** | All platforms | Direct SDK access, best performance | Vendor SDK (bundled) |

### ASCOM (Windows)

The industry standard for Windows astronomy software.

**Setup**
1. Install [ASCOM Platform](https://ascom-standards.org/)
2. Install manufacturer's ASCOM driver for each device
3. In Skotiq Discovery tab, select "ASCOM" protocol
4. Available devices appear in the list

**Supported Devices**
- Cameras (including cooled CCD/CMOS)
- Mounts (GoTo, tracking control)
- Focusers (absolute and relative)
- Filter wheels
- Rotators
- Domes
- Weather stations
- Safety monitors

### INDI (Linux/macOS)

The standard protocol for astronomy on Unix-like systems.

**Setup**
1. Install INDI server: `sudo apt install indi-full` (Ubuntu/Debian)
2. Start INDI server with your drivers, or let Skotiq auto-start
3. In Skotiq Discovery tab, select "INDI" protocol
4. Enter INDI server address (default: localhost:7624)

**Auto-Start Feature**
- Skotiq can automatically start INDI drivers
- Configure drivers in Settings → Equipment → INDI Drivers
- No need to manually run `indiserver`

### Alpaca (Network)

ASCOM's network-based protocol for cross-platform device access.

**Setup**
1. Run Alpaca server on device (e.g., ASCOM Remote, INDIGO)
2. In Skotiq Discovery tab, select "Alpaca" protocol
3. Enter device IP address and port
4. Scan for available devices

**Use Cases**
- Remote observatory control
- Accessing Windows ASCOM devices from Mac/Linux
- Network-attached astronomy cameras
- Distributed setups

### Native SDKs

Direct vendor SDK integration for maximum performance and features.

**Supported Cameras**
- ZWO ASI (full SDK integration)
- QHY (QHYCCD SDK)
- PlayerOne (POA SDK)
- SVBony (SVB SDK)
- Atik (Atik SDK)
- FLI (Finger Lakes Instrumentation)
- Moravian (Moravian SDK)
- Touptek (Toupcam SDK)

**Supported Mounts**
- SkyWatcher/Synta (EQMod-style serial)
- iOptron (serial protocol)
- LX200 (Meade protocol)

**Advantages**
- No middleware required
- Access to all camera features
- Optimal performance
- Works on all platforms

## Discovery Tab

### Finding Devices

**Protocol Selection**
1. Select protocol from dropdown (ASCOM, INDI, Alpaca, Native)
2. Click **Scan** or **Refresh**
3. Discovered devices appear in the list

**Device List**
Each discovered device shows:
- Device icon (camera, mount, focuser, etc.)
- Device name and model
- Protocol badge (ASCOM/INDI/Alpaca/Native)
- Connection status indicator
- **Connect** button

**Filtering**
- Filter by device type (Camera, Mount, Focuser, etc.)
- Search by name
- Show/hide already connected devices

### Connecting Devices

**Single Device**
1. Click **Connect** on desired device
2. Wait for connection (progress indicator)
3. Device moves to Connected tab
4. Status changes to green checkmark

**Multiple Devices**
- Connect devices one at a time for reliability
- Or use Equipment Profiles (see below) for batch connection

**Connection Failures**
- Error message displays reason
- Common issues:
  - Device in use by another application
  - Driver not installed
  - Hardware disconnected
  - Permission denied (Linux: add user to dialout group)

### Device Cards

Each device card displays:
- **Header**: Device name, type icon, status badge
- **Details**: Model, driver version, protocol
- **Actions**: Connect/Disconnect button
- **Expand**: Click for additional info

## Connected Tab

### Active Devices

View and manage currently connected equipment.

**Device Status Cards**

Each connected device shows:
- Device name and type
- Connection status (green = connected, yellow = busy, red = error)
- Quick actions (disconnect, settings)
- Real-time status information

**Camera Card**
- Current state (Idle, Exposing, Downloading)
- Temperature and cooling status
- Cooler power percentage
- Gain/Offset settings

**Mount Card**
- Current RA/Dec coordinates
- Altitude/Azimuth
- Tracking status (Tracking, Stopped, Slewing)
- Pier side (for GEM mounts)

**Focuser Card**
- Current position
- Temperature (if available)
- Movement status

**Filter Wheel Card**
- Current filter position
- Filter name
- Movement status

### Quick Actions

**Camera**
- Cool/Warm toggle
- Set temperature
- Quick exposure test

**Mount**
- Start/Stop tracking
- Park/Unpark
- Abort slew

**Focuser**
- Move in/out
- Go to position
- Halt movement

**Filter Wheel**
- Select filter
- View filter names

### Disconnecting

1. Click **Disconnect** on device card
2. Confirm if capturing/tracking is active
3. Device returns to Discovery tab
4. Equipment properly releases resources

## Equipment Profiles

Save and restore complete equipment configurations.

### Creating a Profile

1. Connect all your devices
2. Click **Save as Profile**
3. Enter profile name (e.g., "Main Setup", "Portable Rig")
4. Add optional description
5. Click **Save**

**Profile Contents**
- All connected devices and their IDs
- Device settings (gain, offset, cooling temp)
- Filter configuration
- Focus offsets
- Camera defaults

### Using Profiles

**Activate Profile**
1. Go to Equipment → Settings tab
2. Select profile from dropdown
3. Click **Activate**
4. All devices connect with saved settings

**Switch Profiles**
- Select different profile
- Click **Activate**
- Previous devices disconnect
- New devices connect

### Managing Profiles

**Edit Profile**
1. Select profile
2. Click **Edit**
3. Modify settings
4. Click **Save**

**Duplicate Profile**
- Create copy with new name
- Useful for variations (e.g., "Setup - Narrowband")

**Delete Profile**
- Select profile
- Click **Delete**
- Confirm deletion

**Export/Import**
- Export profiles as JSON files
- Share with other Skotiq users
- Import on different computer
- Backup your configurations

## Settings Tab

### Per-Device Settings

Select a device to configure its specific settings.

**Camera Settings**
- Default gain and offset
- Default binning
- Cooling target temperature
- Readout modes (if supported)
- USB bandwidth (for USB3 cameras)

**Mount Settings**
- Slew rates
- Guide rates
- Park position
- Meridian flip settings
- Tracking rates

**Focuser Settings**
- Step size
- Backlash compensation
- Temperature coefficient
- Maximum position

**Filter Wheel Settings**
- Filter names
- Focus offsets per filter
- Filter order

### Optical Configuration

Define your optical setup:

**Telescope**
- Focal length (mm)
- Aperture (mm)
- Focal ratio (calculated)

**Camera**
- Pixel size (μm) - auto-detected if available
- Sensor dimensions (pixels)

**Calculated Values**
- Image scale (arcsec/pixel)
- Field of view (degrees)

### Filter Configuration

**Filter Names**
1. Enter name for each filter position
2. Standard names: L, R, G, B, Ha, OIII, SII
3. Custom names supported

**Focus Offsets**
1. Select reference filter (usually L or clear)
2. Enter offset for each other filter
3. Offsets in focuser steps (positive or negative)
4. Use **Measure Offsets** wizard for accuracy

**Sync from Hardware**
- Click **Sync** to read filter names from wheel
- Updates Skotiq configuration

## Device-Specific Features

### Cooled Cameras

**Temperature Control**
- Set target temperature (-50°C to +50°C typically)
- Enable/disable cooler
- Monitor actual temperature
- View cooler power percentage
- Temperature stability indicator

**Cooling Best Practices**
- Cool gradually (2-5°C per minute)
- Set target 20-30°C below ambient
- Avoid condensation (use dew heaters)
- Warm gradually before shutdown

### German Equatorial Mounts

**Pier Side Management**
- Current side displayed (East/West)
- Time to meridian shown
- Auto-flip settings

**Meridian Flip**
- Configure degrees past meridian
- Enable auto-flip
- Set re-centering after flip
- Auto-refocus option

### Focusers

**Absolute vs Relative**
- Absolute: Has position counter
- Relative: Only move commands

**Backlash Compensation**
- Configure in settings
- Skotiq compensates automatically
- Test with autofocus to verify

## Troubleshooting

### Device Not Found

**ASCOM**
- Verify ASCOM Platform installed
- Check driver installed for device
- Try ASCOM Device Hub for testing
- Restart ASCOM service

**INDI**
- Verify INDI server running
- Check driver loaded: `indi_getprop`
- Review INDI server logs
- Verify correct server address

**Native**
- Check USB connection
- Try different USB port
- Verify device powered on
- Check for driver conflicts

### Connection Fails

**Permission Issues (Linux)**
```bash
# Add user to dialout group
sudo usermod -a -G dialout $USER
# Log out and back in
```

**Device Busy**
- Close other software using device
- Check for hung processes
- Restart device

**Driver Issues**
- Update to latest driver
- Reinstall driver
- Check manufacturer support

### Device Disconnects

**During Imaging**
- Check USB cable quality
- Use powered USB hub
- Verify stable power supply
- Check for USB power saving settings

**Intermittent**
- Enable connection watchdog
- Set auto-reconnect
- Review logs for patterns

## Best Practices

### Connection Order

Recommended order for connecting equipment:

1. **Mount first** - Foundation for everything else
2. **Camera** - May need to set cooling
3. **Focuser** - Needed before focusing
4. **Filter wheel** - For filter changes
5. **Guider** - After main camera ready
6. **Auxiliary** - Weather, dome, etc.

### Profile Organization

- Create profiles for different setups
- Name clearly: "Backyard - Main", "Remote Observatory"
- Include notes about equipment combinations
- Export backups periodically

### Pre-Session Checklist

1. ✓ All devices powered on
2. ✓ USB/network connections secure
3. ✓ Activate equipment profile
4. ✓ Verify all devices connected
5. ✓ Check camera cooling started
6. ✓ Verify mount tracking
7. ✓ Test filter wheel movement
8. ✓ Check focuser response

## Keyboard Shortcuts

- **Ctrl+E**: Open Equipment screen
- **Ctrl+R**: Refresh device list
- **Ctrl+P**: Activate profile

## Next Steps

- [First Connection Guide](../getting-started/first-connection.md) - Step-by-step setup
- [Imaging Features](imaging.md) - Start capturing images
- [Settings](settings.md) - Configure all options
