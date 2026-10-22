# Connecting Your First Device

This guide walks through connecting your camera and mount to Skotiq for
the first time. Start with one device, verify each connection, and keep
unsupported or unsafe equipment disconnected until its release support status is
clear.

## Release Scope Notes

Before connecting hardware, review:

- [Supported Hardware By Platform](../supported-hardware-by-platform.md)
- [Known Limitations](../known-limitations.md)
- [Migration, Backup, and Restore Guide](../migration-backup-restore.md)

The visible protocol list is not a promise that every driver works on every
operating system. ASCOM COM is Windows-only, INDI requires a reachable INDI
server, Alpaca requires a reachable network device or bridge, and native SDK
support is available only where the release package includes and verifies the
needed vendor libraries. During release-candidate validation, record disabled or
missing controls as evidence instead of bypassing them.

## Understanding Device Protocols

Skotiq supports multiple ways to connect to equipment. Choose the method
that matches the release notes, support matrix, and drivers available for your
setup:

### ASCOM (Windows Only)
- **Best for**: Windows users with ASCOM-compatible devices
- **Requirements**: ASCOM Platform installed, device-specific ASCOM drivers
- **Advantages**: Native Windows integration, widest hardware support on Windows
- **Setup**: Install ASCOM Platform and your device's ASCOM driver

### Native
- **Best for**: Direct USB connections when the release includes the needed SDK
- **Requirements**: Packaged vendor SDK libraries and supported OS drivers
- **Advantages**: Direct hardware access where verified
- **Setup**: Follow release notes for the specific vendor and platform

### Alpaca
- **Best for**: Network-connected devices and ASCOM bridges
- **Requirements**: Device with Alpaca server (or ASCOM Remote running on Windows)
- **Advantages**: Works over network; device capabilities are reported by the Alpaca server
- **Setup**: Know the IP address and port of your Alpaca device

### INDI (Linux/macOS)
- **Best for**: Users with a verified INDI server and driver stack
- **Requirements**: INDI server installed, running, and reachable
- **Advantages**: Broad driver ecosystem where device properties are exposed
- **Setup**: Install INDI platform and start INDI server with appropriate drivers

## Connecting a Camera

### Step 1: Navigate to Equipment

1. Launch Skotiq
2. Click **Equipment** in the rail (plug icon, under Prepare)
3. The Equipment screen will open

### Step 2: Select Your Protocol

At the top of the Equipment screen, you'll see protocol buttons. Select the one appropriate for your setup:

- **ASCOM** (Windows with ASCOM drivers)
- **Native** (Direct USB connection where SDK support is shipped)
- **Alpaca** (Network devices)
- **INDI** (Linux/macOS)

### Step 3: Connect Your Camera

#### Using ASCOM (Windows)

1. Ensure your camera is connected via USB
2. Select the **ASCOM** protocol
3. Click on the **Connections** tab
4. In the **Camera** section, click **Choose**
5. A device selection dialog will appear showing installed ASCOM camera drivers
6. Select your camera from the list
7. Click **Properties** if you need to configure camera-specific settings
8. Click **Connect**
9. The camera status should change to "Connected" with a green indicator

#### Using Native (Direct USB)

1. Connect your camera via USB
2. Select the **Native** protocol
3. Click on the **Connections** tab
4. In the **Camera** section, Skotiq will scan for connected devices if the
   vendor SDK path is available for this release
5. Your camera should appear in the device list
6. Click **Connect** next to your camera
7. The camera status should change to "Connected"

If no device appears, check the release notes before treating it as a defect.
The vendor library, OS driver, or native device class may be out of scope for
the artifact you installed.

#### Using Alpaca (Network)

1. Ensure your Alpaca device is powered on and on the same network
2. Select the **Alpaca** protocol
3. Click on the **Connections** tab
4. Click **Discover Devices** to scan your network
   - Or manually enter the IP address and port (default: 11111)
5. Found devices will appear in the list
6. Select your camera
7. Click **Connect**
8. The camera status should change to "Connected"

If discovery works but a feature is missing, use the Alpaca server's own status
page or driver settings to confirm whether that capability is exposed.

#### Using INDI (Linux/macOS)

1. Ensure INDI server is running with your camera driver:
   ```bash
   indiserver indi_qhy_ccd  # Example for QHY cameras
   ```
2. Select the **INDI** protocol
3. Click on the **Connections** tab
4. Click **Connect to INDI Server**
5. Enter server details (default: localhost:7624)
6. Click **Connect**
7. Your camera will appear in the device list
8. Click **Connect** on the camera

If the camera appears but controls are disabled, verify the INDI driver exposes
the required properties and record the limitation for release validation.

### Step 4: Verify Camera Connection

Once connected:

1. The camera status indicator should be green
2. Camera information should appear (name, sensor size, cooling status if applicable)
3. Navigate to the **Imaging** screen from the rail
4. Select the **Camera** tab
5. You should see:
   - Current camera temperature (if cooled)
   - Gain/offset controls
   - Binning options
   - ROI (region of interest) settings

## Connecting a Mount

### Step 1: Prepare Your Mount

1. Ensure mount is powered on
2. Mount should be physically set up and polar aligned (rough alignment is fine for testing)
3. For ASCOM, ensure the mount driver is installed on Windows
4. Confirm the mount is safe to move before testing control commands

### Step 2: Connect the Mount

The process is similar to connecting a camera:

1. Go to **Equipment** screen
2. Select your protocol (ASCOM/Native/Alpaca/INDI)
3. Click the **Connections** tab
4. In the **Mount** section:
   - For ASCOM: Click **Choose** and select your mount driver
   - For Native: Select from detected mounts only where that native path is
     listed as verified for the release
   - For Alpaca: Discover or manually add your mount
   - For INDI: Connect to server, then connect to mount device

5. Click **Connect**

### Step 3: Verify Mount Connection

Once connected:

1. Mount status should show green "Connected"
2. Current coordinates (RA/Dec) should display
3. Navigate to **Imaging** screen
4. Select the **Mount** tab
5. You should see:
   - Current position
   - Slew controls
   - Tracking status
   - Park/Unpark buttons

### Step 4: Test Mount Control

To verify the mount is responding:

1. Confirm the telescope has clearance, the mount is not near a hard stop, and
   any remote observer is aware of the test
2. In the **Mount** tab, find the direction controls
3. Try the smallest available movement in a safe direction
4. The mount should move and coordinates should update
5. Click **Stop** to halt movement

**Note**: If your mount has a home/park position, you may need to unpark it first before it will accept movement commands.

## Connecting Additional Devices

### Focuser

1. Go to Equipment > Connections
2. In the **Focuser** section, follow the same protocol-specific steps
3. Once connected, you can control it from the **Imaging** > **Focus** tab

If the focuser controls are disabled, confirm that the connected driver exposes
position and movement capabilities before continuing.

### Filter Wheel

1. Go to Equipment > Connections
2. In the **Filter Wheel** section, connect using a verified protocol path
3. Define your filters in Equipment > Settings
4. Control it from the **Imaging** > **Camera** tab

Do not include filter-wheel movement in release smoke evidence unless the driver
path is listed as supported or explicitly being validated.

### Guide Camera (PHD2)

Skotiq integrates with PHD2 for autoguiding:

1. Start PHD2 separately
2. Connect your guide camera in PHD2
3. In Skotiq, go to **Imaging** > **Guiding** tab
4. Click **Connect to PHD2**
5. PHD2 status should show "Connected"

PHD2 is the primary public-release guiding path. Direct guide camera behavior is
driver-dependent and should be verified separately before being advertised.

## Saving Equipment Profiles

Once you have your equipment connected, save it as a profile:

1. Go to **Equipment** > **Profiles** tab
2. Click **Save Current as Profile**
3. Name your profile (e.g., "Backyard Setup", "Travel Rig")
4. Click **Save**

Next time you use this equipment:
1. Go to Equipment > Profiles
2. Select your saved profile
3. Click **Load Profile**
4. Devices will reconnect where their drivers and saved settings are still
   available

## Common Connection Issues

### Camera not detected
- **Check USB connection**: Try a different cable or port
- **Driver installed**: Verify ASCOM driver or vendor SDK is installed
- **Device powered**: Some cameras need external power
- **Permissions**: On Linux, you may need udev rules for USB access
- **Release scope**: Check whether the installed artifact includes the needed
  native SDK or platform backend

### Mount won't connect
- **COM port conflict**: Check if another application is using the mount's COM port
- **Driver mismatch**: Ensure you've selected the correct ASCOM driver
- **Handshake issues**: Try power cycling the mount
- **Baud rate**: Some mounts require specific baud rate settings in driver properties

### "Device already in use" error
- Another application (like ASCOM driver test tool) may have the device open
- Close all other astronomy software
- Restart Skotiq

### INDI server not connecting
- Verify INDI server is running: `ps aux | grep indiserver`
- Check firewall isn't blocking port 7624
- Ensure correct server address (localhost or IP)

### Alpaca device not found
- Check device is on same network
- Verify IP address and port
- Check firewall settings on device and computer
- Try manual entry instead of discovery

## Next Steps

Now that your equipment is connected:
- [Capture Your First Image](first-image.md) - Take your first exposure
- [Configure Equipment Settings](../features/imaging.md) - Fine-tune your device settings
- [Create an Imaging Sequence](../features/sequencing.md) - Automate your imaging session
- [Headless Secure Setup](../headless-secure-setup.md) - Enable LAN or remote
  access only after local hardware behavior is verified

## Tips for Success

1. **Start Simple**: Connect one device at a time to isolate issues
2. **Save Profiles**: Once working, save your configuration to quickly reconnect
3. **Test Movement**: Always test mount movement with small slews before automated sequences
4. **Check Logs**: If something fails, check Equipment > Settings for connection logs
5. **Simulator Mode**: Practice with ASCOM, Alpaca, or INDI simulator drivers
   where they are listed in the release validation plan

## Getting Help

If you're having trouble connecting devices:
- Check the [Troubleshooting Guide](../troubleshooting/common-issues.md)
- Check [Driver Troubleshooting](../troubleshooting/drivers.md)
- Check [Firewall Troubleshooting](../troubleshooting/firewall.md) for network
  devices or remote access
- Review your device's ASCOM/INDI driver documentation
- Report issues on [GitHub](https://github.com/Scdouglas1999/Skotiq/issues) with specific error messages
