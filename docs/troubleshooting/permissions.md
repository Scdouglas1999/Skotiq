# Permissions Troubleshooting

Permission problems usually appear as devices not opening, images not saving, or
headless services failing to read/write their data paths.

## Windows

- Check folder permissions on the image save directory.
- If Windows Defender Controlled Folder Access is enabled, allow Skotiq to
  write to the imaging folder.
- Install device drivers with an administrator account when required by the
  vendor.
- Avoid installing Skotiq into a protected directory that blocks runtime
  updates or logs.

## Linux

Add the imaging user to the groups required by the connected hardware:

```bash
sudo usermod -a -G dialout $USER
sudo usermod -a -G video $USER
sudo usermod -a -G plugdev $USER
```

Then log out and back in.

Install udev rules from the device vendor when USB cameras, filter wheels, or
mount adapters are not accessible to a normal user. Reload rules after changes:

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger
```

## macOS

- Check privacy prompts for removable volumes, Documents, Desktop, and network
  locations.
- If the app is quarantined after download or manual copying, reinstall from the
  release package before troubleshooting device access.
- Prefer Alpaca or INDI server access unless the release notes explicitly list a
  native macOS driver path as verified.

## Save Path Checks

- Confirm the folder exists.
- Confirm the user running Skotiq can create and delete a test file there.
- Avoid network shares for high-rate capture unless that exact workflow has been
  tested.
- Keep enough free disk space for the entire imaging run.

## Release-Gate Evidence

For public-release sign-off, record the OS, user account type, save path, device
path or port, required groups or security prompts, and whether Skotiq reports
permission failures clearly.
