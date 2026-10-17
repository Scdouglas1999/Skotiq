# Optional vendor device SDKs for local Windows development

Native camera/focuser/filter-wheel drivers are loaded at runtime by the native
bridge (`native/skotiq_native/native/src/vendor/*`). The loader
(`sdk_loader.rs`) searches **next to `skotiq.exe` first**, then the
vendor's install path (`C:\Program Files\<vendor>\...`).

The staging script does **not** copy this folder by default. For a local-only
development build, pass `-IncludeVendorSdks` to
`scripts/stage_windows_release.ps1`. The official GitHub release workflow never
passes that switch and fails if a known vendor SDK DLL appears in the output.

These vendor SDK binaries are **not committed** (license + size). Drop the
64-bit DLLs here only for local testing. Do not put them in an official release
until each vendor's redistribution terms and notices are cleared. Expected filenames
(must match exactly — the loader looks for these names):

| Vendor | DLL(s) |
| --- | --- |
| ZWO (ASI) | `ASICamera2.dll`, `EAF_focuser.dll`, `EFW_filter.dll` |
| Player One | `PlayerOneCamera.dll`, `PlayerOnePW.dll` |
| QHYCCD | `qhyccd.dll`, `gXusb.dll` |
| SVBony | `SVBCameraSDK.dll` |
| Touptek | `toupcam.dll` |
| Altair | `altaircam.dll` |
| OGMAVision | `ogmacam.dll` |
| Mallincam | `mallincam.dll` |
| Atik | `AtikCameras.dll` |
| FLI | `libfli.dll` |
| Moravian | `XAPI.dll` |
| gPhoto2 (DSLR) | `gphoto2.dll`, `libgphoto2.dll` |

All DLLs must be 64-bit (the staging script asserts this). Sources are each
vendor's official SDK download. Their presence in a local tree is not evidence
of redistribution permission.
