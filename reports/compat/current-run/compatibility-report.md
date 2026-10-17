# Skotiq Hardware Compatibility Evidence

- Generated: 2026-06-01T15:55:51.7881946Z
- Platform: `windows`
- Targets: 22 pass, 0 fail, 8 blocked, 1 skipped
- Functions: 113 pass, 0 fail, 0 blocked
- Models: 57 pass, 0 fail, 13 blocked

## Targets
| Verdict | Target | Manufacturer | Device | Driver | Tier | Reason |
|---|---|---|---|---|---|---|
| pass | `zwo-native-camera-eaf-efw` | ZWO | Camera,Focuser,FilterWheel | Native SDK | SDK runtime + Skotiq tests | declared runtime/API prerequisites and compatibility commands passed |
| pass | `zwo-fake-sdk-contract` | ZWO | Camera,Focuser,FilterWheel | Native SDK | Production driver + fake SDK shims | declared runtime/API prerequisites and compatibility commands passed |
| pass | `qhy-native-camera-cfw` | QHYCCD | Camera,FilterWheel | Native SDK | SDK runtime + Skotiq tests | declared runtime/API prerequisites and compatibility commands passed |
| pass | `qhy-fake-sdk-contract` | QHYCCD | Camera,FilterWheel | Native SDK | Production driver + fake SDK shim | declared runtime/API prerequisites and compatibility commands passed |
| pass | `playerone-native-camera` | Player One | Camera | Native SDK | SDK runtime | declared runtime/API prerequisites and compatibility commands passed |
| pass | `playerone-fake-sdk-contract` | Player One | Camera | Native SDK | Production driver + fake SDK shim | declared runtime/API prerequisites and compatibility commands passed |
| pass | `svbony-native-camera` | SVBONY | Camera | Native SDK | SDK runtime + Skotiq tests | declared runtime/API prerequisites and compatibility commands passed |
| pass | `svbony-fake-sdk-contract` | SVBONY | Camera | Native SDK | Production driver + fake SDK shim | declared runtime/API prerequisites and compatibility commands passed |
| pass | `atik-native-camera` | Atik | Camera,FilterWheel | Native SDK | SDK runtime | declared runtime/API prerequisites and compatibility commands passed |
| pass | `atik-fake-sdk-contract` | Atik | Camera | Native SDK | Production driver + fake SDK shim | declared runtime/API prerequisites and compatibility commands passed |
| pass | `fli-native-camera-focuser-filterwheel` | Finger Lakes Instrumentation | Camera,Focuser,FilterWheel | Native SDK | SDK source evidence | declared runtime/API prerequisites and compatibility commands passed |
| pass | `touptek-native-white-labels` | ToupTek/OGMA/Altair | Camera | Native SDK | SDK runtime | declared runtime/API prerequisites and compatibility commands passed |
| pass | `moravian-native-camera-filterwheel` | Moravian | Camera,FilterWheel | Native SDK | SDK runtime | declared runtime/API prerequisites and compatibility commands passed |
| pass | `fujifilm-native-camera` | Fujifilm | Camera | Native SDK | SDK runtime | declared runtime/API prerequisites and compatibility commands passed |
| pass | `fli-fake-sdk-contract` | Finger Lakes Instrumentation | Camera,Focuser,FilterWheel | Native SDK | Production driver + fake SDK shim | declared runtime/API prerequisites and compatibility commands passed |
| pass | `touptek-fake-sdk-contract` | ToupTek/OGMA/Altair | Camera | Native SDK | Production driver + fake SDK shim | declared runtime/API prerequisites and compatibility commands passed |
| pass | `moravian-fake-sdk-contract` | Moravian | Camera | Native SDK | Production driver + fake SDK shim | declared runtime/API prerequisites and compatibility commands passed |
| pass | `fujifilm-fake-sdk-contract` | Fujifilm | Camera | Native SDK | Production driver + fake SDK shim | declared runtime/API prerequisites and compatibility commands passed |
| pass | `native-sdk-abi-header-contracts` | Multiple | Camera,Focuser,FilterWheel | Native SDK | SDK header + Rust FFI ABI contract | declared runtime/API prerequisites and compatibility commands passed |
| blocked | `native-sdk-compiled-abi-probes` | Multiple | Camera,Focuser,FilterWheel | Native SDK | SDK header compiled ABI probes | command `native_sdk_compiled_abi_probes` reported blocked evidence |
| blocked | `vendor-example-compilation` | Multiple | Camera,Focuser,FilterWheel,Mount | Native SDK | Vendor example build probes | command `vendor_example_compilation` reported blocked evidence |
| blocked | `real-device-trace-replay` | Community/Test Lab | All | Native SDK,ASCOM,Alpaca,INDI,Serial | Captured real-device record/replay | command `real_device_trace_replay` reported blocked evidence |
| pass | `alpaca-simulator-contract` | ASCOM Initiative | Camera,FilterWheel,Mount | ASCOM Alpaca | Local protocol simulator | declared runtime/API prerequisites and compatibility commands passed |
| pass | `mount-protocol-source-contracts` | Sky-Watcher/iOptron/LX200-compatible | Mount | Native Serial/UDP | Protocol parser/command tests | declared runtime/API prerequisites and compatibility commands passed |
| pass | `bridge-full-workspace` | Skotiq | All | Bridge | Workspace tests | declared runtime/API prerequisites and compatibility commands passed |
| blocked | `canon-edsdk-native-camera` | Canon | Camera | Native SDK | API blocked | Canon EDSDK requires developer access and native driver implementation. |
| blocked | `nikon-native-camera` | Nikon | Camera | Native SDK | API blocked | Nikon SDK requires developer approval and native driver implementation. |
| blocked | `ascom-conformu-certification` | ASCOM Initiative | All | ASCOM COM/Alpaca | Official conformance | ConformU must be installed and run against ASCOM/Alpaca simulators.; required tool `ConformU` was not found |
| skipped | `indi-simulator-drivers` | INDI | All | INDI | Official simulator drivers | target is not applicable to windows |
| blocked | `celestron-aux-native-mount` | Celestron | Mount | Native AUX/CPWI | Roadmap | Native Celestron AUX/CPWI support is not implemented. |
| blocked | `pegasus-native-powerbox` | Pegasus Astro | Switch,Focuser,Weather,DewControl | Native Serial | Roadmap | Native Pegasus Powerbox support is not implemented. |

## Function Evidence
| Verdict | Target | Device | Capability | Function | Physical Required | Reason |
|---|---|---|---|---|---|---|
| pass | `zwo-native-camera-eaf-efw` | Camera | enumerate | Enumerate cameras | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `zwo-native-camera-eaf-efw` | Camera | connect | Open/close camera | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `zwo-native-camera-eaf-efw` | Camera | expose | Start exposure | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `zwo-native-camera-eaf-efw` | Camera | download_image | Download image | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `zwo-native-camera-eaf-efw` | Camera | controls | Read/write controls | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `zwo-native-camera-eaf-efw` | Focuser | move_focuser | Move focuser | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `zwo-native-camera-eaf-efw` | FilterWheel | set_filter | Set/read filter | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `zwo-fake-sdk-contract` | Camera | enumerate | Discover camera through fake ASICamera2 SDK | False | simulator/protocol/software evidence passed |
| pass | `zwo-fake-sdk-contract` | Camera | controls | Connect and read/write gain, offset, binning, cooler | False | simulator/protocol/software evidence passed |
| pass | `zwo-fake-sdk-contract` | Camera | download_image | Expose, poll completion, and download image through production driver | False | simulator/protocol/software evidence passed |
| pass | `zwo-fake-sdk-contract` | Focuser | move_focuser | Discover, connect, move, read position, read temperature | False | simulator/protocol/software evidence passed |
| pass | `zwo-fake-sdk-contract` | FilterWheel | set_filter | Discover, connect, set/read filter position | False | simulator/protocol/software evidence passed |
| pass | `qhy-native-camera-cfw` | Camera | enumerate | Initialize SDK | False | simulator/protocol/software evidence passed |
| pass | `qhy-native-camera-cfw` | Camera | enumerate | Scan cameras | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `qhy-native-camera-cfw` | Camera | connect | Open camera | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `qhy-native-camera-cfw` | Camera | controls | Read/write params | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `qhy-native-camera-cfw` | Camera | download_image | Expose/download frame | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `qhy-native-camera-cfw` | FilterWheel | set_filter | Send CFW command | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `qhy-fake-sdk-contract` | Camera | enumerate | Discover cooled mono and guide color model variants through fake qhyccd SDK | False | simulator/protocol/software evidence passed |
| pass | `qhy-fake-sdk-contract` | Camera | controls | Connect and read/write gain, offset, binning, cooler, and readout mode | False | simulator/protocol/software evidence passed |
| pass | `qhy-fake-sdk-contract` | Camera | download_image | Expose and download image through production driver | False | simulator/protocol/software evidence passed |
| pass | `qhy-fake-sdk-contract` | FilterWheel | set_filter | Discover, connect, set/read QHY CFW position | False | simulator/protocol/software evidence passed |
| pass | `qhy-fake-sdk-contract` | Camera | error_handling | Reject uncooled-camera cooler control and propagate SDK exposure errors | False | simulator/protocol/software evidence passed |
| pass | `playerone-native-camera` | Camera | enumerate | Enumerate cameras | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `playerone-native-camera` | Camera | connect | Open camera | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `playerone-native-camera` | Camera | expose | Start exposure | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `playerone-native-camera` | Camera | download_image | Download image data | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `playerone-native-camera` | Camera | controls | Read/write config | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `playerone-fake-sdk-contract` | Camera | enumerate | Discover cooled mono and uncooled color model variants through fake PlayerOneCamera SDK | False | simulator/protocol/software evidence passed |
| pass | `playerone-fake-sdk-contract` | Camera | controls | Connect and read/write gain, offset, binning, cooler | False | simulator/protocol/software evidence passed |
| pass | `playerone-fake-sdk-contract` | Camera | download_image | Expose, poll completion, and download image through production driver | False | simulator/protocol/software evidence passed |
| pass | `playerone-fake-sdk-contract` | Camera | error_handling | Handle exposure-not-ready, image transfer failure, unknown SDK error, and uncooled-camera cooler rejection | False | simulator/protocol/software evidence passed |
| pass | `svbony-native-camera` | Camera | enumerate | Enumerate cameras | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `svbony-native-camera` | Camera | connect | Open camera | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `svbony-native-camera` | Camera | stream | Stream/video capture | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `svbony-native-camera` | Camera | controls | Read/write controls | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `svbony-fake-sdk-contract` | Camera | enumerate | Discover camera through fake SVBCameraSDK | False | simulator/protocol/software evidence passed |
| pass | `svbony-fake-sdk-contract` | Camera | controls | Connect and read/write gain, offset, binning, cooler | False | simulator/protocol/software evidence passed |
| pass | `svbony-fake-sdk-contract` | Camera | download_image | Start capture and download image through production driver | False | simulator/protocol/software evidence passed |
| pass | `atik-native-camera` | Camera | enumerate | Enumerate devices | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `atik-native-camera` | Camera | connect | Connect/disconnect | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `atik-native-camera` | Camera | expose | Start/abort exposure | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `atik-native-camera` | Camera | download_image | Read image data | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `atik-native-camera` | Camera | cooler | Cooling control | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `atik-native-camera` | FilterWheel | set_filter | Filter wheel connect | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `atik-fake-sdk-contract` | Camera | enumerate | Discover camera through fake AtikCameras SDK | False | simulator/protocol/software evidence passed |
| pass | `atik-fake-sdk-contract` | Camera | controls | Connect and read/write gain, offset, binning, cooler | False | simulator/protocol/software evidence passed |
| pass | `atik-fake-sdk-contract` | Camera | download_image | Expose, poll readiness, and download image through production driver | False | simulator/protocol/software evidence passed |
| pass | `fli-native-camera-focuser-filterwheel` | Camera,Focuser,FilterWheel | enumerate | Enumerate devices | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `fli-native-camera-focuser-filterwheel` | Camera,Focuser,FilterWheel | connect | Open device | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `fli-native-camera-focuser-filterwheel` | Camera | expose | Expose frame | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `fli-native-camera-focuser-filterwheel` | FilterWheel | set_filter | Set/read filter | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `fli-native-camera-focuser-filterwheel` | Focuser | move_focuser | Move/read focuser | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `touptek-native-white-labels` | Camera | enumerate | Enumerate cameras | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `touptek-native-white-labels` | Camera | connect | Open camera | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `touptek-native-white-labels` | Camera | stream | Pull-mode acquisition | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `touptek-native-white-labels` | Camera | controls | Read/write options | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `touptek-native-white-labels` | Camera | cooler | Temperature telemetry | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `moravian-native-camera-filterwheel` | Camera | enumerate | Enumerate cameras | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `moravian-native-camera-filterwheel` | Camera | connect | Initialize/open/close | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `moravian-native-camera-filterwheel` | Camera | download_image | Expose and retrieve image | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `moravian-native-camera-filterwheel` | Camera | cooler | Set temperature | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `moravian-native-camera-filterwheel` | FilterWheel | set_filter | Enumerate/set filter | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `fujifilm-native-camera` | Camera | enumerate | Initialize SDK | False | simulator/protocol/software evidence passed |
| pass | `fujifilm-native-camera` | Camera | enumerate | Detect cameras | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `fujifilm-native-camera` | Camera | connect | Open/close session | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `fujifilm-native-camera` | Camera | release | Trigger release | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `fujifilm-native-camera` | Camera | download_image | Read captured image | True | runtime/API surface present; physical behavior still requires hardware |
| pass | `fli-fake-sdk-contract` | Camera,Focuser,FilterWheel | enumerate | Discover camera, focuser, and filter wheel through fake libfli | False | simulator/protocol/software evidence passed |
| pass | `fli-fake-sdk-contract` | Camera | download_image | Connect, set cooler/binning, expose, poll ready, and download rows | False | simulator/protocol/software evidence passed |
| pass | `fli-fake-sdk-contract` | Focuser | move_focuser | Connect, move relative, read position, and detect idle state | False | simulator/protocol/software evidence passed |
| pass | `fli-fake-sdk-contract` | FilterWheel | set_filter | Connect, set/read filter position, and enumerate slots | False | simulator/protocol/software evidence passed |
| pass | `fli-fake-sdk-contract` | Camera | error_handling | Propagate row-grab image transfer failure | False | simulator/protocol/software evidence passed |
| pass | `touptek-fake-sdk-contract` | Camera | enumerate | Discover OGMA white-label models through fake ToupTek SDK | False | simulator/protocol/software evidence passed |
| pass | `touptek-fake-sdk-contract` | Camera | controls | Connect and read/write gain, cooler, binning, ROI, and raw options | False | simulator/protocol/software evidence passed |
| pass | `touptek-fake-sdk-contract` | Camera | download_image | Start exposure and pull 16-bit image through production driver | False | simulator/protocol/software evidence passed |
| pass | `touptek-fake-sdk-contract` | Camera | model_capabilities | Verify cooled color and uncooled mono capability mapping | False | simulator/protocol/software evidence passed |
| pass | `touptek-fake-sdk-contract` | Camera | error_handling | Propagate image pull failure and reject unsupported cooler | False | simulator/protocol/software evidence passed |
| pass | `moravian-fake-sdk-contract` | Camera | enumerate | Discover cooled mono and uncooled color models through fake gXusb | False | simulator/protocol/software evidence passed |
| pass | `moravian-fake-sdk-contract` | Camera | controls | Connect and read/write gain, binning, cooler, shutter, readout, and subframe capabilities | False | simulator/protocol/software evidence passed |
| pass | `moravian-fake-sdk-contract` | Camera | download_image | Expose and retrieve 16-bit image through production driver | False | simulator/protocol/software evidence passed |
| pass | `moravian-fake-sdk-contract` | Camera | model_capabilities | Verify cooled mono and uncooled color capability mapping | False | simulator/protocol/software evidence passed |
| pass | `moravian-fake-sdk-contract` | Camera | error_handling | Propagate BeginExposure failure and reject unsupported cooler | False | simulator/protocol/software evidence passed |
| pass | `fujifilm-fake-sdk-contract` | Camera | enumerate | Discover GFX and X-series cameras through fake XAPI | False | simulator/protocol/software evidence passed |
| pass | `fujifilm-fake-sdk-contract` | Camera | connect | Open session, set priority, read device info, and close session | False | simulator/protocol/software evidence passed |
| pass | `fujifilm-fake-sdk-contract` | Camera | release | Set ISO/shutter and trigger release through production driver | False | simulator/protocol/software evidence passed |
| pass | `fujifilm-fake-sdk-contract` | Camera | model_capabilities | Verify DSLR/mirrorless capability boundaries such as no cooler/binning | False | simulator/protocol/software evidence passed |
| pass | `fujifilm-fake-sdk-contract` | Camera | error_handling | Propagate release busy/SDK error through XSDK_GetErrorNumber | False | simulator/protocol/software evidence passed |
| pass | `native-sdk-abi-header-contracts` | Camera,Focuser,FilterWheel | abi_contract | Verify ZWO SDK headers and Rust FFI symbols/struct ordering | False | simulator/protocol/software evidence passed |
| pass | `native-sdk-abi-header-contracts` | Camera,FilterWheel | abi_contract | Verify Atik SDK headers and Rust FFI symbols/struct ordering | False | simulator/protocol/software evidence passed |
| pass | `native-sdk-abi-header-contracts` | Camera | abi_contract | Verify SVBONY SDK headers and Rust FFI symbols | False | simulator/protocol/software evidence passed |
| pass | `native-sdk-abi-header-contracts` | Camera | abi_contract | Verify Player One SDK headers and Rust FFI symbols/struct ordering | False | simulator/protocol/software evidence passed |
| pass | `native-sdk-abi-header-contracts` | Camera,FilterWheel | abi_contract | Verify QHY SDK headers and Rust FFI symbols/enum values | False | simulator/protocol/software evidence passed |
| pass | `native-sdk-abi-header-contracts` | Camera | abi_contract | Verify ToupTek/Altair/OGMA SDK headers and Rust FFI symbols/struct ordering | False | simulator/protocol/software evidence passed |
| pass | `native-sdk-abi-header-contracts` | Camera,FilterWheel | abi_contract | Verify Moravian SDK headers and Rust FFI symbols | False | simulator/protocol/software evidence passed |
| pass | `native-sdk-abi-header-contracts` | Camera,Focuser,FilterWheel | abi_contract | Verify FLI SDK headers and Rust FFI symbols | False | simulator/protocol/software evidence passed |
| pass | `native-sdk-abi-header-contracts` | Camera | abi_contract | Verify Fujifilm SDK headers and Rust FFI symbols/struct ordering | False | simulator/protocol/software evidence passed |
| pass | `native-sdk-compiled-abi-probes` | All | abi_contract | Compile small C probes against acquired vendor headers where headers and compiler are available | False | simulator/protocol/software evidence passed |
| pass | `vendor-example-compilation` | All | sdk_package_integrity | Discover and compile vendor SDK example projects where packages include examples | False | simulator/protocol/software evidence passed |
| pass | `real-device-trace-replay` | All | record_replay | Validate captured SDK/API traces for replay readiness | False | simulator/protocol/software evidence passed |
| pass | `alpaca-simulator-contract` | All | enumerate | Construct typed clients for simulator endpoints | False | simulator/protocol/software evidence passed |
| pass | `alpaca-simulator-contract` | Camera | download_image | Connect/expose/download/abort against local simulator | False | simulator/protocol/software evidence passed |
| pass | `alpaca-simulator-contract` | Camera | controls | Read status/cooling/control endpoints against local simulator | False | simulator/protocol/software evidence passed |
| pass | `alpaca-simulator-contract` | FilterWheel | set_filter | Read names/set/read position against local simulator | False | simulator/protocol/software evidence passed |
| pass | `alpaca-simulator-contract` | FilterWheel | read_filter | Read filter position and names against local simulator | False | simulator/protocol/software evidence passed |
| pass | `alpaca-simulator-contract` | Mount | slew | Tracking/slew/abort/status against local simulator | False | simulator/protocol/software evidence passed |
| pass | `alpaca-simulator-contract` | Mount | tracking | Read/write tracking against local simulator | False | simulator/protocol/software evidence passed |
| pass | `alpaca-simulator-contract` | Mount | read_position | Read position/status against local simulator | False | simulator/protocol/software evidence passed |
| pass | `alpaca-simulator-contract` | Camera | error_handling | Surface Alpaca device ErrorNumber/ErrorMessage on exposure | False | simulator/protocol/software evidence passed |
| pass | `alpaca-simulator-contract` | Camera | payload_validation | Reject malformed imagearrayvariant payload | False | simulator/protocol/software evidence passed |
| pass | `mount-protocol-source-contracts` | Mount | enumerate | No-crash discovery tests | False | simulator/protocol/software evidence passed |
| pass | `mount-protocol-source-contracts` | Mount | slew | Slew command/parser contract | False | simulator/protocol/software evidence passed |
| pass | `mount-protocol-source-contracts` | Mount | tracking | Tracking command/parser contract | False | simulator/protocol/software evidence passed |

## Model Capability Evidence
| Verdict | Manufacturer | Model | Device | Family | Grade | Reason |
|---|---|---|---|---|---|---|
| pass | ZWO | ASI2600MM Pro | Camera | ASI cooled APS-C mono | sdk-family | declared capabilities and model contracts map to passing evidence |
| pass | ZWO | ASI2600MC Pro | Camera | ASI cooled APS-C color | sdk-family | declared capabilities and model contracts map to passing evidence |
| pass | ZWO | ASI533MM Pro | Camera | ASI cooled square mono | sdk-family | declared capabilities and model contracts map to passing evidence |
| pass | ZWO | ASI533MC Pro | Camera | ASI cooled square color | sdk-family | declared capabilities and model contracts map to passing evidence |
| pass | ZWO | ASI6200MM Pro | Camera | ASI cooled full-frame mono | sdk-family | declared capabilities and model contracts map to passing evidence |
| pass | ZWO | ASI120MM Mini | Camera | ASI guide camera | sdk-family | declared capabilities and model contracts map to passing evidence |
| pass | ZWO | EAF 5V | Focuser | ZWO EAF | sdk-family | declared capabilities and model contracts map to passing evidence |
| pass | ZWO | EFW 7x36mm | FilterWheel | ZWO EFW | sdk-family | declared capabilities and model contracts map to passing evidence |
| pass | QHYCCD | QHY268M | Camera | QHY cooled APS-C mono | sdk-family | declared capabilities and model contracts map to passing evidence |
| pass | QHYCCD | QHY268C | Camera | QHY cooled APS-C color | sdk-family | declared capabilities and model contracts map to passing evidence |
| pass | QHYCCD | QHY600M | Camera | QHY cooled full-frame mono | sdk-family | declared capabilities and model contracts map to passing evidence |
| pass | QHYCCD | QHY5III462C | Camera | QHY planetary/guide | sdk-family | declared capabilities and model contracts map to passing evidence |
| pass | QHYCCD | QHYCFW3 | FilterWheel | QHY CFW | sdk-family | declared capabilities and model contracts map to passing evidence |
| pass | QHYCCD | QHY268M | Camera | QHY cooled APS-C mono | fake-sdk-model-contract | declared capabilities and model contracts map to passing evidence |
| pass | QHYCCD | QHY5III462C | Camera | QHY planetary/guide | fake-sdk-model-contract | declared capabilities and model contracts map to passing evidence |
| pass | QHYCCD | QHYCFW3 | FilterWheel | QHY CFW | fake-sdk-model-contract | declared capabilities and model contracts map to passing evidence |
| pass | Player One | Poseidon-M Pro | Camera | Player One cooled mono | sdk-family | declared capabilities and model contracts map to passing evidence |
| pass | Player One | Poseidon-C Pro | Camera | Player One cooled color | sdk-family | declared capabilities and model contracts map to passing evidence |
| pass | Player One | Uranus-C Pro | Camera | Player One cooled planetary | sdk-family | declared capabilities and model contracts map to passing evidence |
| pass | Player One | Neptune-C II | Camera | Player One planetary | sdk-family | declared capabilities and model contracts map to passing evidence |
| pass | Player One | Poseidon-M Pro | Camera | Player One cooled mono | fake-sdk-model-contract | declared capabilities and model contracts map to passing evidence |
| pass | Player One | Neptune-C II | Camera | Player One planetary | fake-sdk-model-contract | declared capabilities and model contracts map to passing evidence |
| pass | SVBONY | SV405CC | Camera | SVBONY cooled color | sdk-family | declared capabilities and model contracts map to passing evidence |
| pass | SVBONY | SV605CC | Camera | SVBONY cooled color | sdk-family | declared capabilities and model contracts map to passing evidence |
| pass | SVBONY | SV305 Pro | Camera | SVBONY planetary/guide | sdk-family | declared capabilities and model contracts map to passing evidence |
| pass | Atik | Atik 460EX | Camera | Atik CCD | sdk-family | declared capabilities and model contracts map to passing evidence |
| pass | Atik | Atik Horizon II | Camera | Atik CMOS | sdk-family | declared capabilities and model contracts map to passing evidence |
| pass | Atik | Atik EFW2 | FilterWheel | Atik EFW | sdk-family | declared capabilities and model contracts map to passing evidence |
| pass | ToupTek/OGMA | OGMA AP26CC | Camera | ToupTek/OGMA cooled color | sdk-family | declared capabilities and model contracts map to passing evidence |
| pass | ToupTek/OGMA | ToupTek ATR3CMOS26000KPA | Camera | ToupTek cooled APS-C color | sdk-family | declared capabilities and model contracts map to passing evidence |
| pass | Altair | Hypercam 26C | Camera | ToupTek white-label | sdk-family | declared capabilities and model contracts map to passing evidence |
| pass | Moravian | C3-26000 | Camera | Moravian C3 CMOS | sdk-family | declared capabilities and model contracts map to passing evidence |
| pass | Moravian | C4-16000 | Camera | Moravian C4 CCD | sdk-family | declared capabilities and model contracts map to passing evidence |
| pass | Moravian | SFW | FilterWheel | Moravian filter wheel | sdk-family | declared capabilities and model contracts map to passing evidence |
| pass | Fujifilm | GFX100 II | Camera | Fujifilm GFX | sdk-header | declared capabilities and model contracts map to passing evidence |
| pass | Fujifilm | GFX100S II | Camera | Fujifilm GFX | sdk-header | declared capabilities and model contracts map to passing evidence |
| pass | Fujifilm | X-H2 | Camera | Fujifilm X | sdk-header | declared capabilities and model contracts map to passing evidence |
| pass | Fujifilm | X-H2S | Camera | Fujifilm X | sdk-header | declared capabilities and model contracts map to passing evidence |
| pass | Fujifilm | X-T5 | Camera | Fujifilm X | sdk-header | declared capabilities and model contracts map to passing evidence |
| pass | Finger Lakes Instrumentation | ProLine PL16803 | Camera | FLI cooled CCD camera | fake-sdk-model-contract | declared capabilities and model contracts map to passing evidence |
| pass | Finger Lakes Instrumentation | PDF Focuser | Focuser | FLI focuser | fake-sdk-model-contract | declared capabilities and model contracts map to passing evidence |
| pass | Finger Lakes Instrumentation | CFW-5-7 | FilterWheel | FLI filter wheel | fake-sdk-model-contract | declared capabilities and model contracts map to passing evidence |
| pass | ToupTek/OGMA | OGMA AP26CC | Camera | ToupTek/OGMA cooled color | fake-sdk-model-contract | declared capabilities and model contracts map to passing evidence |
| pass | ToupTek/OGMA | OGMA GP2000M | Camera | ToupTek/OGMA guide mono | fake-sdk-model-contract | declared capabilities and model contracts map to passing evidence |
| pass | Moravian | C3-61000 Pro | Camera | Moravian cooled mono | fake-sdk-model-contract | declared capabilities and model contracts map to passing evidence |
| pass | Moravian | G1-1600 | Camera | Moravian uncooled color | fake-sdk-model-contract | declared capabilities and model contracts map to passing evidence |
| pass | Fujifilm | GFX100 II | Camera | Fujifilm GFX | fake-sdk-model-contract | declared capabilities and model contracts map to passing evidence |
| pass | Fujifilm | X-T5 | Camera | Fujifilm X | fake-sdk-model-contract | declared capabilities and model contracts map to passing evidence |
| pass | ASCOM Initiative | Alpaca Camera Simulator | Camera | Alpaca v1 | local-simulator | declared capabilities and model contracts map to passing evidence |
| pass | ASCOM Initiative | Alpaca Telescope Simulator | Mount | Alpaca v1 | local-simulator | declared capabilities and model contracts map to passing evidence |
| pass | ASCOM Initiative | Alpaca FilterWheel Simulator | FilterWheel | Alpaca v1 | local-simulator | declared capabilities and model contracts map to passing evidence |
| pass | Sky-Watcher | EQ6-R Pro | Mount | SynScan/EQMOD | protocol-contract | declared capabilities and model contracts map to passing evidence |
| pass | Sky-Watcher | HEQ5 Pro | Mount | SynScan/EQMOD | protocol-contract | declared capabilities and model contracts map to passing evidence |
| pass | iOptron | CEM70 | Mount | iOptron serial | protocol-contract | declared capabilities and model contracts map to passing evidence |
| pass | iOptron | GEM45 | Mount | iOptron serial | protocol-contract | declared capabilities and model contracts map to passing evidence |
| pass | Meade/OnStep/etc. | OnStep | Mount | LX200-compatible | protocol-contract | declared capabilities and model contracts map to passing evidence |
| pass | Meade | LX200 | Mount | LX200-compatible | protocol-contract | declared capabilities and model contracts map to passing evidence |
| blocked | ASCOM Initiative | Omni Camera Simulator | Camera | ASCOM COM/Alpaca simulator | blocked-until-conformu | missing evidence for: enumerate, connect, expose, download_image, controls, cooler |
| blocked | ASCOM Initiative | Omni Telescope Simulator | Mount | ASCOM COM/Alpaca simulator | blocked-until-conformu | missing evidence for: enumerate, connect, slew, tracking, read_position |
| blocked | ASCOM Initiative | Omni FilterWheel Simulator | FilterWheel | ASCOM COM/Alpaca simulator | blocked-until-conformu | missing evidence for: enumerate, connect, set_filter, read_filter |
| blocked | Canon | EOS Ra | Camera | Canon EOS astro DSLR/mirrorless | sdk-access-blocked | missing evidence for: enumerate, connect, expose, download_image, controls |
| blocked | Canon | EOS R5 | Camera | Canon EOS mirrorless | sdk-access-blocked | missing evidence for: enumerate, connect, expose, download_image, controls |
| blocked | Canon | EOS 6D Mark II | Camera | Canon EOS DSLR | sdk-access-blocked | missing evidence for: enumerate, connect, expose, download_image, controls |
| blocked | Nikon | D810A | Camera | Nikon astro DSLR | sdk-access-blocked | missing evidence for: enumerate, connect, expose, download_image, controls |
| blocked | Nikon | Z8 | Camera | Nikon mirrorless | sdk-access-blocked | missing evidence for: enumerate, connect, expose, download_image, controls |
| blocked | Nikon | Z6 III | Camera | Nikon mirrorless | sdk-access-blocked | missing evidence for: enumerate, connect, expose, download_image, controls |
| blocked | Celestron | NexStar Evolution | Mount | Celestron AUX/CPWI | native-driver-roadmap | missing evidence for: enumerate, connect, slew, tracking, read_position |
| blocked | Celestron | CGX | Mount | Celestron AUX/CPWI | native-driver-roadmap | missing evidence for: enumerate, connect, slew, tracking, read_position |
| blocked | Pegasus Astro | Ultimate Powerbox v3 | Switch,Power,Weather,DewControl | Pegasus Powerbox | native-driver-roadmap | missing evidence for: enumerate, connect, controls |
| blocked | Pegasus Astro | FocusCube 3 | Focuser | Pegasus focuser | native-driver-roadmap | missing evidence for: enumerate, connect, move_focuser, read_position |

## Model Capability Details
| Verdict | Manufacturer | Model | Capability | Evidence Check | Physical Required |
|---|---|---|---|---|---|
| pass | ZWO | ASI2600MM Pro | enumerate | `zwo-camera-enumerate` | True |
| pass | ZWO | ASI2600MM Pro | connect | `zwo-camera-connect` | True |
| pass | ZWO | ASI2600MM Pro | expose | `zwo-camera-expose` | True |
| pass | ZWO | ASI2600MM Pro | download_image | `zwo-camera-download` | True |
| pass | ZWO | ASI2600MM Pro | controls | `zwo-camera-controls` | True |
| pass | ZWO | ASI2600MM Pro | cooler | `zwo-camera-controls` | True |
| pass | ZWO | ASI2600MC Pro | enumerate | `zwo-camera-enumerate` | True |
| pass | ZWO | ASI2600MC Pro | connect | `zwo-camera-connect` | True |
| pass | ZWO | ASI2600MC Pro | expose | `zwo-camera-expose` | True |
| pass | ZWO | ASI2600MC Pro | download_image | `zwo-camera-download` | True |
| pass | ZWO | ASI2600MC Pro | controls | `zwo-camera-controls` | True |
| pass | ZWO | ASI2600MC Pro | cooler | `zwo-camera-controls` | True |
| pass | ZWO | ASI533MM Pro | enumerate | `zwo-camera-enumerate` | True |
| pass | ZWO | ASI533MM Pro | connect | `zwo-camera-connect` | True |
| pass | ZWO | ASI533MM Pro | expose | `zwo-camera-expose` | True |
| pass | ZWO | ASI533MM Pro | download_image | `zwo-camera-download` | True |
| pass | ZWO | ASI533MM Pro | controls | `zwo-camera-controls` | True |
| pass | ZWO | ASI533MM Pro | cooler | `zwo-camera-controls` | True |
| pass | ZWO | ASI533MC Pro | enumerate | `zwo-camera-enumerate` | True |
| pass | ZWO | ASI533MC Pro | connect | `zwo-camera-connect` | True |
| pass | ZWO | ASI533MC Pro | expose | `zwo-camera-expose` | True |
| pass | ZWO | ASI533MC Pro | download_image | `zwo-camera-download` | True |
| pass | ZWO | ASI533MC Pro | controls | `zwo-camera-controls` | True |
| pass | ZWO | ASI533MC Pro | cooler | `zwo-camera-controls` | True |
| pass | ZWO | ASI6200MM Pro | enumerate | `zwo-camera-enumerate` | True |
| pass | ZWO | ASI6200MM Pro | connect | `zwo-camera-connect` | True |
| pass | ZWO | ASI6200MM Pro | expose | `zwo-camera-expose` | True |
| pass | ZWO | ASI6200MM Pro | download_image | `zwo-camera-download` | True |
| pass | ZWO | ASI6200MM Pro | controls | `zwo-camera-controls` | True |
| pass | ZWO | ASI6200MM Pro | cooler | `zwo-camera-controls` | True |
| pass | ZWO | ASI120MM Mini | enumerate | `zwo-camera-enumerate` | True |
| pass | ZWO | ASI120MM Mini | connect | `zwo-camera-connect` | True |
| pass | ZWO | ASI120MM Mini | expose | `zwo-camera-expose` | True |
| pass | ZWO | ASI120MM Mini | download_image | `zwo-camera-download` | True |
| pass | ZWO | ASI120MM Mini | controls | `zwo-camera-controls` | True |
| pass | ZWO | EAF 5V | enumerate | `zwo-camera-enumerate` | True |
| pass | ZWO | EAF 5V | connect | `zwo-camera-connect` | True |
| pass | ZWO | EAF 5V | move_focuser | `zwo-eaf-move` | True |
| pass | ZWO | EAF 5V | read_position | `zwo-eaf-move` | True |
| pass | ZWO | EFW 7x36mm | enumerate | `zwo-camera-enumerate` | True |
| pass | ZWO | EFW 7x36mm | connect | `zwo-camera-connect` | True |
| pass | ZWO | EFW 7x36mm | set_filter | `zwo-efw-position` | True |
| pass | ZWO | EFW 7x36mm | read_filter | `zwo-efw-position` | True |
| pass | QHYCCD | QHY268M | enumerate | `qhy-sdk-init` | False |
| pass | QHYCCD | QHY268M | connect | `qhy-camera-connect` | True |
| pass | QHYCCD | QHY268M | expose | `qhy-camera-expose-download` | True |
| pass | QHYCCD | QHY268M | download_image | `qhy-camera-expose-download` | True |
| pass | QHYCCD | QHY268M | controls | `qhy-camera-controls` | True |
| pass | QHYCCD | QHY268M | cooler | `qhy-camera-controls` | True |
| pass | QHYCCD | QHY268C | enumerate | `qhy-sdk-init` | False |
| pass | QHYCCD | QHY268C | connect | `qhy-camera-connect` | True |
| pass | QHYCCD | QHY268C | expose | `qhy-camera-expose-download` | True |
| pass | QHYCCD | QHY268C | download_image | `qhy-camera-expose-download` | True |
| pass | QHYCCD | QHY268C | controls | `qhy-camera-controls` | True |
| pass | QHYCCD | QHY268C | cooler | `qhy-camera-controls` | True |
| pass | QHYCCD | QHY600M | enumerate | `qhy-sdk-init` | False |
| pass | QHYCCD | QHY600M | connect | `qhy-camera-connect` | True |
| pass | QHYCCD | QHY600M | expose | `qhy-camera-expose-download` | True |
| pass | QHYCCD | QHY600M | download_image | `qhy-camera-expose-download` | True |
| pass | QHYCCD | QHY600M | controls | `qhy-camera-controls` | True |
| pass | QHYCCD | QHY600M | cooler | `qhy-camera-controls` | True |
| pass | QHYCCD | QHY5III462C | enumerate | `qhy-sdk-init` | False |
| pass | QHYCCD | QHY5III462C | connect | `qhy-camera-connect` | True |
| pass | QHYCCD | QHY5III462C | expose | `qhy-camera-expose-download` | True |
| pass | QHYCCD | QHY5III462C | download_image | `qhy-camera-expose-download` | True |
| pass | QHYCCD | QHY5III462C | controls | `qhy-camera-controls` | True |
| pass | QHYCCD | QHYCFW3 | set_filter | `qhy-cfw-command` | True |
| pass | QHYCCD | QHY268M | enumerate | `qhy-shim-multi-model-discovery` | False |
| pass | QHYCCD | QHY268M | connect | `qhy-shim-camera-expose-download` | False |
| pass | QHYCCD | QHY268M | expose | `qhy-shim-camera-expose-download` | False |
| pass | QHYCCD | QHY268M | download_image | `qhy-shim-camera-expose-download` | False |
| pass | QHYCCD | QHY268M | controls | `qhy-shim-camera-connect-controls` | False |
| pass | QHYCCD | QHY268M | cooler | `qhy-shim-camera-connect-controls` | False |
| pass | QHYCCD | QHY5III462C | enumerate | `qhy-shim-multi-model-discovery` | False |
| pass | QHYCCD | QHY5III462C | connect | `qhy-shim-camera-expose-download` | False |
| pass | QHYCCD | QHY5III462C | expose | `qhy-shim-camera-expose-download` | False |
| pass | QHYCCD | QHY5III462C | download_image | `qhy-shim-camera-expose-download` | False |
| pass | QHYCCD | QHY5III462C | controls | `qhy-shim-camera-connect-controls` | False |
| pass | QHYCCD | QHYCFW3 | set_filter | `qhy-shim-cfw-flow` | False |
| pass | QHYCCD | QHYCFW3 | read_filter | `qhy-shim-cfw-flow` | False |
| pass | Player One | Poseidon-M Pro | enumerate | `poa-enumerate` | True |
| pass | Player One | Poseidon-M Pro | connect | `poa-connect` | True |
| pass | Player One | Poseidon-M Pro | expose | `poa-expose` | True |
| pass | Player One | Poseidon-M Pro | download_image | `poa-download` | True |
| pass | Player One | Poseidon-M Pro | controls | `poa-config` | True |
| pass | Player One | Poseidon-M Pro | cooler | `poa-config` | True |
| pass | Player One | Poseidon-C Pro | enumerate | `poa-enumerate` | True |
| pass | Player One | Poseidon-C Pro | connect | `poa-connect` | True |
| pass | Player One | Poseidon-C Pro | expose | `poa-expose` | True |
| pass | Player One | Poseidon-C Pro | download_image | `poa-download` | True |
| pass | Player One | Poseidon-C Pro | controls | `poa-config` | True |
| pass | Player One | Poseidon-C Pro | cooler | `poa-config` | True |
| pass | Player One | Uranus-C Pro | enumerate | `poa-enumerate` | True |
| pass | Player One | Uranus-C Pro | connect | `poa-connect` | True |
| pass | Player One | Uranus-C Pro | expose | `poa-expose` | True |
| pass | Player One | Uranus-C Pro | download_image | `poa-download` | True |
| pass | Player One | Uranus-C Pro | controls | `poa-config` | True |
| pass | Player One | Uranus-C Pro | cooler | `poa-config` | True |
| pass | Player One | Neptune-C II | enumerate | `poa-enumerate` | True |
| pass | Player One | Neptune-C II | connect | `poa-connect` | True |
| pass | Player One | Neptune-C II | expose | `poa-expose` | True |
| pass | Player One | Neptune-C II | download_image | `poa-download` | True |
| pass | Player One | Neptune-C II | controls | `poa-config` | True |
| pass | Player One | Poseidon-M Pro | enumerate | `poa-shim-multi-model-discovery` | False |
| pass | Player One | Poseidon-M Pro | connect | `poa-shim-camera-expose-download` | False |
| pass | Player One | Poseidon-M Pro | expose | `poa-shim-camera-expose-download` | False |
| pass | Player One | Poseidon-M Pro | download_image | `poa-shim-camera-expose-download` | False |
| pass | Player One | Poseidon-M Pro | controls | `poa-shim-camera-connect-controls` | False |
| pass | Player One | Poseidon-M Pro | cooler | `poa-shim-camera-connect-controls` | False |
| pass | Player One | Neptune-C II | enumerate | `poa-shim-multi-model-discovery` | False |
| pass | Player One | Neptune-C II | connect | `poa-shim-camera-expose-download` | False |
| pass | Player One | Neptune-C II | expose | `poa-shim-camera-expose-download` | False |
| pass | Player One | Neptune-C II | download_image | `poa-shim-camera-expose-download` | False |
| pass | Player One | Neptune-C II | controls | `poa-shim-camera-connect-controls` | False |
| pass | SVBONY | SV405CC | enumerate | `svb-enumerate` | True |
| pass | SVBONY | SV405CC | connect | `svb-connect` | True |
| pass | SVBONY | SV405CC | stream | `svb-stream` | True |
| pass | SVBONY | SV405CC | download_image | `svb-stream` | True |
| pass | SVBONY | SV405CC | controls | `svb-controls` | True |
| pass | SVBONY | SV405CC | cooler | `svb-controls` | True |
| pass | SVBONY | SV605CC | enumerate | `svb-enumerate` | True |
| pass | SVBONY | SV605CC | connect | `svb-connect` | True |
| pass | SVBONY | SV605CC | stream | `svb-stream` | True |
| pass | SVBONY | SV605CC | download_image | `svb-stream` | True |
| pass | SVBONY | SV605CC | controls | `svb-controls` | True |
| pass | SVBONY | SV605CC | cooler | `svb-controls` | True |
| pass | SVBONY | SV305 Pro | enumerate | `svb-enumerate` | True |
| pass | SVBONY | SV305 Pro | connect | `svb-connect` | True |
| pass | SVBONY | SV305 Pro | stream | `svb-stream` | True |
| pass | SVBONY | SV305 Pro | download_image | `svb-stream` | True |
| pass | SVBONY | SV305 Pro | controls | `svb-controls` | True |
| pass | Atik | Atik 460EX | enumerate | `atik-enumerate` | True |
| pass | Atik | Atik 460EX | connect | `atik-connect` | True |
| pass | Atik | Atik 460EX | expose | `atik-expose` | True |
| pass | Atik | Atik 460EX | download_image | `atik-download` | True |
| pass | Atik | Atik 460EX | cooler | `atik-cooler` | True |
| pass | Atik | Atik Horizon II | enumerate | `atik-enumerate` | True |
| pass | Atik | Atik Horizon II | connect | `atik-connect` | True |
| pass | Atik | Atik Horizon II | expose | `atik-expose` | True |
| pass | Atik | Atik Horizon II | download_image | `atik-download` | True |
| pass | Atik | Atik Horizon II | cooler | `atik-cooler` | True |
| pass | Atik | Atik EFW2 | enumerate | `atik-enumerate` | True |
| pass | Atik | Atik EFW2 | connect | `atik-connect` | True |
| pass | Atik | Atik EFW2 | set_filter | `atik-efw` | True |
| pass | Atik | Atik EFW2 | read_filter | `atik-efw` | True |
| pass | ToupTek/OGMA | OGMA AP26CC | enumerate | `touptek-enumerate` | True |
| pass | ToupTek/OGMA | OGMA AP26CC | connect | `touptek-open` | True |
| pass | ToupTek/OGMA | OGMA AP26CC | stream | `touptek-stream` | True |
| pass | ToupTek/OGMA | OGMA AP26CC | download_image | `touptek-stream` | True |
| pass | ToupTek/OGMA | OGMA AP26CC | controls | `touptek-controls` | True |
| pass | ToupTek/OGMA | OGMA AP26CC | cooler | `touptek-temperature` | True |
| pass | ToupTek/OGMA | ToupTek ATR3CMOS26000KPA | enumerate | `touptek-enumerate` | True |
| pass | ToupTek/OGMA | ToupTek ATR3CMOS26000KPA | connect | `touptek-open` | True |
| pass | ToupTek/OGMA | ToupTek ATR3CMOS26000KPA | stream | `touptek-stream` | True |
| pass | ToupTek/OGMA | ToupTek ATR3CMOS26000KPA | download_image | `touptek-stream` | True |
| pass | ToupTek/OGMA | ToupTek ATR3CMOS26000KPA | controls | `touptek-controls` | True |
| pass | ToupTek/OGMA | ToupTek ATR3CMOS26000KPA | cooler | `touptek-temperature` | True |
| pass | Altair | Hypercam 26C | enumerate | `touptek-enumerate` | True |
| pass | Altair | Hypercam 26C | connect | `touptek-open` | True |
| pass | Altair | Hypercam 26C | stream | `touptek-stream` | True |
| pass | Altair | Hypercam 26C | download_image | `touptek-stream` | True |
| pass | Altair | Hypercam 26C | controls | `touptek-controls` | True |
| pass | Altair | Hypercam 26C | cooler | `touptek-temperature` | True |
| pass | Moravian | C3-26000 | enumerate | `moravian-enumerate` | True |
| pass | Moravian | C3-26000 | connect | `moravian-open` | True |
| pass | Moravian | C3-26000 | expose | `moravian-expose` | True |
| pass | Moravian | C3-26000 | download_image | `moravian-expose` | True |
| pass | Moravian | C3-26000 | cooler | `moravian-cooler` | True |
| pass | Moravian | C4-16000 | enumerate | `moravian-enumerate` | True |
| pass | Moravian | C4-16000 | connect | `moravian-open` | True |
| pass | Moravian | C4-16000 | expose | `moravian-expose` | True |
| pass | Moravian | C4-16000 | download_image | `moravian-expose` | True |
| pass | Moravian | C4-16000 | cooler | `moravian-cooler` | True |
| pass | Moravian | SFW | enumerate | `moravian-enumerate` | True |
| pass | Moravian | SFW | set_filter | `moravian-filter` | True |
| pass | Moravian | SFW | read_filter | `moravian-filter` | True |
| pass | Fujifilm | GFX100 II | enumerate | `fujifilm-init` | False |
| pass | Fujifilm | GFX100 II | connect | `fujifilm-session` | True |
| pass | Fujifilm | GFX100 II | release | `fujifilm-release` | True |
| pass | Fujifilm | GFX100 II | download_image | `fujifilm-image` | True |
| pass | Fujifilm | GFX100S II | enumerate | `fujifilm-init` | False |
| pass | Fujifilm | GFX100S II | connect | `fujifilm-session` | True |
| pass | Fujifilm | GFX100S II | release | `fujifilm-release` | True |
| pass | Fujifilm | GFX100S II | download_image | `fujifilm-image` | True |
| pass | Fujifilm | X-H2 | enumerate | `fujifilm-init` | False |
| pass | Fujifilm | X-H2 | connect | `fujifilm-session` | True |
| pass | Fujifilm | X-H2 | release | `fujifilm-release` | True |
| pass | Fujifilm | X-H2 | download_image | `fujifilm-image` | True |
| pass | Fujifilm | X-H2S | enumerate | `fujifilm-init` | False |
| pass | Fujifilm | X-H2S | connect | `fujifilm-session` | True |
| pass | Fujifilm | X-H2S | release | `fujifilm-release` | True |
| pass | Fujifilm | X-H2S | download_image | `fujifilm-image` | True |
| pass | Fujifilm | X-T5 | enumerate | `fujifilm-init` | False |
| pass | Fujifilm | X-T5 | connect | `fujifilm-session` | True |
| pass | Fujifilm | X-T5 | release | `fujifilm-release` | True |
| pass | Fujifilm | X-T5 | download_image | `fujifilm-image` | True |
| pass | Finger Lakes Instrumentation | ProLine PL16803 | enumerate | `fli-shim-discovery` | False |
| pass | Finger Lakes Instrumentation | ProLine PL16803 | download_image | `fli-shim-camera-flow` | False |
| pass | Finger Lakes Instrumentation | ProLine PL16803 | error_handling | `fli-shim-edge-errors` | False |
| pass | Finger Lakes Instrumentation | PDF Focuser | enumerate | `fli-shim-discovery` | False |
| pass | Finger Lakes Instrumentation | PDF Focuser | move_focuser | `fli-shim-focuser-flow` | False |
| pass | Finger Lakes Instrumentation | CFW-5-7 | enumerate | `fli-shim-discovery` | False |
| pass | Finger Lakes Instrumentation | CFW-5-7 | set_filter | `fli-shim-filterwheel-flow` | False |
| pass | ToupTek/OGMA | OGMA AP26CC | enumerate | `touptek-shim-white-label-discovery` | False |
| pass | ToupTek/OGMA | OGMA AP26CC | controls | `touptek-shim-camera-controls` | False |
| pass | ToupTek/OGMA | OGMA AP26CC | download_image | `touptek-shim-camera-download` | False |
| pass | ToupTek/OGMA | OGMA AP26CC | model_capabilities | `touptek-shim-model-variants` | False |
| pass | ToupTek/OGMA | OGMA AP26CC | error_handling | `touptek-shim-edge-errors` | False |
| pass | ToupTek/OGMA | OGMA GP2000M | enumerate | `touptek-shim-white-label-discovery` | False |
| pass | ToupTek/OGMA | OGMA GP2000M | model_capabilities | `touptek-shim-model-variants` | False |
| pass | ToupTek/OGMA | OGMA GP2000M | error_handling | `touptek-shim-edge-errors` | False |
| pass | Moravian | C3-61000 Pro | enumerate | `moravian-shim-multi-model-discovery` | False |
| pass | Moravian | C3-61000 Pro | controls | `moravian-shim-camera-controls` | False |
| pass | Moravian | C3-61000 Pro | download_image | `moravian-shim-camera-download` | False |
| pass | Moravian | C3-61000 Pro | model_capabilities | `moravian-shim-model-variants` | False |
| pass | Moravian | C3-61000 Pro | error_handling | `moravian-shim-edge-errors` | False |
| pass | Moravian | G1-1600 | enumerate | `moravian-shim-multi-model-discovery` | False |
| pass | Moravian | G1-1600 | model_capabilities | `moravian-shim-model-variants` | False |
| pass | Moravian | G1-1600 | error_handling | `moravian-shim-edge-errors` | False |
| pass | Fujifilm | GFX100 II | enumerate | `fujifilm-shim-discovery` | False |
| pass | Fujifilm | GFX100 II | connect | `fujifilm-shim-session` | False |
| pass | Fujifilm | GFX100 II | release | `fujifilm-shim-release` | False |
| pass | Fujifilm | GFX100 II | model_capabilities | `fujifilm-shim-capabilities` | False |
| pass | Fujifilm | GFX100 II | error_handling | `fujifilm-shim-edge-errors` | False |
| pass | Fujifilm | X-T5 | enumerate | `fujifilm-shim-discovery` | False |
| pass | Fujifilm | X-T5 | connect | `fujifilm-shim-session` | False |
| pass | Fujifilm | X-T5 | release | `fujifilm-shim-release` | False |
| pass | Fujifilm | X-T5 | model_capabilities | `fujifilm-shim-capabilities` | False |
| pass | ASCOM Initiative | Alpaca Camera Simulator | enumerate | `alpaca-discovery-contract` | False |
| pass | ASCOM Initiative | Alpaca Camera Simulator | connect | `alpaca-camera-flow` | False |
| pass | ASCOM Initiative | Alpaca Camera Simulator | expose | `alpaca-camera-flow` | False |
| pass | ASCOM Initiative | Alpaca Camera Simulator | download_image | `alpaca-camera-flow` | False |
| pass | ASCOM Initiative | Alpaca Camera Simulator | controls | `alpaca-camera-controls` | False |
| pass | ASCOM Initiative | Alpaca Camera Simulator | cooler | `alpaca-camera-controls` | False |
| pass | ASCOM Initiative | Alpaca Telescope Simulator | connect | `alpaca-camera-flow` | False |
| pass | ASCOM Initiative | Alpaca Telescope Simulator | slew | `alpaca-mount-flow` | False |
| pass | ASCOM Initiative | Alpaca Telescope Simulator | tracking | `alpaca-mount-tracking` | False |
| pass | ASCOM Initiative | Alpaca Telescope Simulator | read_position | `alpaca-mount-position` | False |
| pass | ASCOM Initiative | Alpaca FilterWheel Simulator | connect | `alpaca-camera-flow` | False |
| pass | ASCOM Initiative | Alpaca FilterWheel Simulator | set_filter | `alpaca-filterwheel-flow` | False |
| pass | ASCOM Initiative | Alpaca FilterWheel Simulator | read_filter | `alpaca-filterwheel-read` | False |
| pass | Sky-Watcher | EQ6-R Pro | connect | `mount-protocol-slew` | False |
| pass | Sky-Watcher | EQ6-R Pro | slew | `mount-protocol-slew` | False |
| pass | Sky-Watcher | EQ6-R Pro | tracking | `mount-protocol-tracking` | False |
| pass | Sky-Watcher | HEQ5 Pro | connect | `mount-protocol-slew` | False |
| pass | Sky-Watcher | HEQ5 Pro | slew | `mount-protocol-slew` | False |
| pass | Sky-Watcher | HEQ5 Pro | tracking | `mount-protocol-tracking` | False |
| pass | iOptron | CEM70 | connect | `mount-protocol-slew` | False |
| pass | iOptron | CEM70 | slew | `mount-protocol-slew` | False |
| pass | iOptron | CEM70 | tracking | `mount-protocol-tracking` | False |
| pass | iOptron | GEM45 | connect | `mount-protocol-slew` | False |
| pass | iOptron | GEM45 | slew | `mount-protocol-slew` | False |
| pass | iOptron | GEM45 | tracking | `mount-protocol-tracking` | False |
| pass | Meade/OnStep/etc. | OnStep | connect | `mount-protocol-slew` | False |
| pass | Meade/OnStep/etc. | OnStep | slew | `mount-protocol-slew` | False |
| pass | Meade/OnStep/etc. | OnStep | read_position | `mount-protocol-slew` | False |
| pass | Meade/OnStep/etc. | OnStep | tracking | `mount-protocol-tracking` | False |
| pass | Meade | LX200 | connect | `mount-protocol-slew` | False |
| pass | Meade | LX200 | slew | `mount-protocol-slew` | False |
| pass | Meade | LX200 | read_position | `mount-protocol-slew` | False |
| pass | Meade | LX200 | tracking | `mount-protocol-tracking` | False |
| blocked | ASCOM Initiative | Omni Camera Simulator | enumerate |  | True |
| blocked | ASCOM Initiative | Omni Camera Simulator | connect |  | True |
| blocked | ASCOM Initiative | Omni Camera Simulator | expose |  | True |
| blocked | ASCOM Initiative | Omni Camera Simulator | download_image |  | True |
| blocked | ASCOM Initiative | Omni Camera Simulator | controls |  | True |
| blocked | ASCOM Initiative | Omni Camera Simulator | cooler |  | True |
| blocked | ASCOM Initiative | Omni Telescope Simulator | enumerate |  | True |
| blocked | ASCOM Initiative | Omni Telescope Simulator | connect |  | True |
| blocked | ASCOM Initiative | Omni Telescope Simulator | slew |  | True |
| blocked | ASCOM Initiative | Omni Telescope Simulator | tracking |  | True |
| blocked | ASCOM Initiative | Omni Telescope Simulator | read_position |  | True |
| blocked | ASCOM Initiative | Omni FilterWheel Simulator | enumerate |  | True |
| blocked | ASCOM Initiative | Omni FilterWheel Simulator | connect |  | True |
| blocked | ASCOM Initiative | Omni FilterWheel Simulator | set_filter |  | True |
| blocked | ASCOM Initiative | Omni FilterWheel Simulator | read_filter |  | True |
| blocked | Canon | EOS Ra | enumerate |  | True |
| blocked | Canon | EOS Ra | connect |  | True |
| blocked | Canon | EOS Ra | expose |  | True |
| blocked | Canon | EOS Ra | download_image |  | True |
| blocked | Canon | EOS Ra | controls |  | True |
| blocked | Canon | EOS R5 | enumerate |  | True |
| blocked | Canon | EOS R5 | connect |  | True |
| blocked | Canon | EOS R5 | expose |  | True |
| blocked | Canon | EOS R5 | download_image |  | True |
| blocked | Canon | EOS R5 | controls |  | True |
| blocked | Canon | EOS 6D Mark II | enumerate |  | True |
| blocked | Canon | EOS 6D Mark II | connect |  | True |
| blocked | Canon | EOS 6D Mark II | expose |  | True |
| blocked | Canon | EOS 6D Mark II | download_image |  | True |
| blocked | Canon | EOS 6D Mark II | controls |  | True |
| blocked | Nikon | D810A | enumerate |  | True |
| blocked | Nikon | D810A | connect |  | True |
| blocked | Nikon | D810A | expose |  | True |
| blocked | Nikon | D810A | download_image |  | True |
| blocked | Nikon | D810A | controls |  | True |
| blocked | Nikon | Z8 | enumerate |  | True |
| blocked | Nikon | Z8 | connect |  | True |
| blocked | Nikon | Z8 | expose |  | True |
| blocked | Nikon | Z8 | download_image |  | True |
| blocked | Nikon | Z8 | controls |  | True |
| blocked | Nikon | Z6 III | enumerate |  | True |
| blocked | Nikon | Z6 III | connect |  | True |
| blocked | Nikon | Z6 III | expose |  | True |
| blocked | Nikon | Z6 III | download_image |  | True |
| blocked | Nikon | Z6 III | controls |  | True |
| blocked | Celestron | NexStar Evolution | enumerate |  | True |
| blocked | Celestron | NexStar Evolution | connect |  | True |
| blocked | Celestron | NexStar Evolution | slew |  | True |
| blocked | Celestron | NexStar Evolution | tracking |  | True |
| blocked | Celestron | NexStar Evolution | read_position |  | True |
| blocked | Celestron | CGX | enumerate |  | True |
| blocked | Celestron | CGX | connect |  | True |
| blocked | Celestron | CGX | slew |  | True |
| blocked | Celestron | CGX | tracking |  | True |
| blocked | Celestron | CGX | read_position |  | True |
| blocked | Pegasus Astro | Ultimate Powerbox v3 | enumerate |  | True |
| blocked | Pegasus Astro | Ultimate Powerbox v3 | connect |  | True |
| blocked | Pegasus Astro | Ultimate Powerbox v3 | controls |  | True |
| blocked | Pegasus Astro | FocusCube 3 | enumerate |  | True |
| blocked | Pegasus Astro | FocusCube 3 | connect |  | True |
| blocked | Pegasus Astro | FocusCube 3 | move_focuser |  | True |
| blocked | Pegasus Astro | FocusCube 3 | read_position |  | True |

## Model Contract Details
| Verdict | Manufacturer | Model | Property | Expectation | Evidence Check |
|---|---|---|---|---|---|
| pass | QHYCCD | QHY268M | cooler | cooled camera accepts set_cooler and reports target temperature | `qhy-shim-camera-connect-controls` |
| pass | QHYCCD | QHY268M | sensor | mono 64x48 16-bit sensor profile in fake SDK | `qhy-shim-multi-model-discovery` |
| pass | QHYCCD | QHY268M | readout_modes | two readout modes are enumerated and selectable | `qhy-shim-camera-connect-controls` |
| pass | QHYCCD | QHY5III462C | sensor | color BGGR guide/planetary profile in fake SDK | `qhy-shim-multi-model-discovery` |
| pass | QHYCCD | QHY5III462C | cooler | uncooled camera rejects cooler control | `qhy-shim-edge-errors` |
| pass | QHYCCD | QHYCFW3 | filter_slots | seven-slot CFW is discovered and can move/read position | `qhy-shim-cfw-flow` |
| pass | Player One | Poseidon-M Pro | cooler | cooled camera accepts set_cooler and reports cooler state | `poa-shim-camera-connect-controls` |
| pass | Player One | Poseidon-M Pro | sensor | mono 64x48 16-bit sensor profile in fake SDK | `poa-shim-multi-model-discovery` |
| pass | Player One | Poseidon-M Pro | error_handling | not-ready exposure, unknown SDK error, and image transfer failure are surfaced | `poa-shim-edge-errors` |
| pass | Player One | Neptune-C II | sensor | color 12-bit planetary profile in fake SDK | `poa-shim-multi-model-discovery` |
| pass | Player One | Neptune-C II | cooler | uncooled camera rejects cooler control | `poa-shim-edge-errors` |
| pass | Finger Lakes Instrumentation | ProLine PL16803 | image_transfer | row-based 16-bit image download succeeds and row-grab failures propagate | `fli-shim-camera-flow` |
| pass | Finger Lakes Instrumentation | PDF Focuser | focuser_motion | relative move updates position and idle state is reported | `fli-shim-focuser-flow` |
| pass | Finger Lakes Instrumentation | CFW-5-7 | filter_slots | five-slot wheel is discovered and can move/read position | `fli-shim-filterwheel-flow` |
| pass | ToupTek/OGMA | OGMA AP26CC | sensor | cooled color 80x60 16-bit profile maps to cooler/binning/subframe support | `touptek-shim-model-variants` |
| pass | ToupTek/OGMA | OGMA AP26CC | image_transfer | PullImageV3 produces a 16-bit frame and transfer errors propagate | `touptek-shim-camera-download` |
| pass | ToupTek/OGMA | OGMA GP2000M | cooler | uncooled mono model rejects cooler control | `touptek-shim-edge-errors` |
| pass | Moravian | C3-61000 Pro | sensor | cooled mono model maps shutter, cooler, binning, gain, and subframe capabilities | `moravian-shim-model-variants` |
| pass | Moravian | C3-61000 Pro | image_transfer | GetImage16b returns a binned 16-bit image and BeginExposure failure propagates | `moravian-shim-camera-download` |
| pass | Moravian | G1-1600 | cooler | uncooled color model rejects cooler control and reports Bayer sensor | `moravian-shim-edge-errors` |
| pass | Fujifilm | GFX100 II | session | GFX model opens an XAPI session, sets ISO/shutter, and triggers release | `fujifilm-shim-release` |
| pass | Fujifilm | GFX100 II | capabilities | mirrorless camera exposes ISO/release controls but no cooler | `fujifilm-shim-capabilities` |
| pass | Fujifilm | X-T5 | enumeration | X-series body is discovered from XAPI append list | `fujifilm-shim-discovery` |

## Blocked
- `native-sdk-compiled-abi-probes`: command `native_sdk_compiled_abi_probes` reported blocked evidence
- `vendor-example-compilation`: command `vendor_example_compilation` reported blocked evidence
- `real-device-trace-replay`: command `real_device_trace_replay` reported blocked evidence
- `canon-edsdk-native-camera`: Canon EDSDK requires developer access and native driver implementation.
- `nikon-native-camera`: Nikon SDK requires developer approval and native driver implementation.
- `ascom-conformu-certification`: ConformU must be installed and run against ASCOM/Alpaca simulators.; required tool `ConformU` was not found
- `celestron-aux-native-mount`: Native Celestron AUX/CPWI support is not implemented.
- `pegasus-native-powerbox`: Native Pegasus Powerbox support is not implemented.
