//! FLI device discovery, opening a device by its id, and SDK status.

use super::*;
use crate::vendor::serial_link::sanitize_port_name;

#[derive(Debug, Clone)]
pub struct FliDiscoveryInfo {
    pub device_path: String,
    pub name: String,
    pub serial_number: Option<String>,
    pub sdk_version: Option<String>,
    pub device_type: FliDeviceType,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FliDeviceType {
    Camera,
    Focuser,
    FilterWheel,
}

impl FliDeviceType {
    fn flag(self) -> c_long {
        match self {
            FliDeviceType::Camera => FLIDEVICE_CAMERA,
            FliDeviceType::Focuser => FLIDEVICE_FOCUSER,
            FliDeviceType::FilterWheel => FLIDEVICE_FILTERWHEEL,
        }
    }

    fn noun(self) -> &'static str {
        match self {
            FliDeviceType::Camera => "camera",
            FliDeviceType::Focuser => "focuser",
            FliDeviceType::FilterWheel => "filter wheel",
        }
    }

    fn domain(self) -> c_long {
        FLIDOMAIN_USB | self.flag()
    }
}

pub async fn discover_cameras() -> Result<Vec<FliDiscoveryInfo>, DriverError> {
    discover_devices_by_type(FliDeviceType::Camera).await
}

pub async fn discover_focusers() -> Result<Vec<FliDiscoveryInfo>, DriverError> {
    discover_devices_by_type(FliDeviceType::Focuser).await
}

pub async fn discover_filter_wheels() -> Result<Vec<FliDiscoveryInfo>, DriverError> {
    discover_devices_by_type(FliDeviceType::FilterWheel).await
}

/// One entry of libfli's device list: the file name FLIOpen takes and the
/// model libfli read for it.
pub(crate) struct ListedDevice {
    pub(crate) filename: String,
    pub(crate) name: String,
}

/// libfli's list of the attached devices of one kind. The caller holds the
/// SDK lock.
fn list_devices(sdk: &FliSdk, domain: c_long) -> Vec<ListedDevice> {
    let mut devices = Vec::new();
    // SAFETY: FLICreateList takes a pass-by-value c_long with no pointer arguments.
    if unsafe { (sdk.create_list)(domain) } != 0 {
        return devices;
    }

    let mut dev_domain: c_long = 0;
    let mut filename = [0 as c_char; 256];
    let mut name_buf = [0 as c_char; 256];

    // SAFETY: all four out-pointers point to stack buffers (dev_domain c_long and 256-byte arrays); lengths are passed correctly so SDK can't overrun.
    let mut result = unsafe {
        (sdk.list_first)(
            &mut dev_domain,
            filename.as_mut_ptr(),
            filename.len(),
            name_buf.as_mut_ptr(),
            name_buf.len(),
        )
    };
    while result == 0 {
        devices.push(ListedDevice {
            // SAFETY: filename is 256 bytes and libfli NUL-terminates it after a successful list call (result == 0).
            filename: unsafe { CStr::from_ptr(filename.as_ptr()) }
                .to_string_lossy()
                .to_string(),
            // SAFETY: name_buf is 256 bytes and libfli NUL-terminates it after a successful list call.
            name: unsafe { CStr::from_ptr(name_buf.as_ptr()) }
                .to_string_lossy()
                .to_string(),
        });
        // SAFETY: same buffer-pointer invariants as FLIListFirst above.
        result = unsafe {
            (sdk.list_next)(
                &mut dev_domain,
                filename.as_mut_ptr(),
                filename.len(),
                name_buf.as_mut_ptr(),
                name_buf.len(),
            )
        };
    }

    // SAFETY: FLIDeleteList takes no arguments and releases the SDK-internal list created by FLICreateList above.
    let _ = unsafe { (sdk.delete_list)() };
    devices
}

/// The libfli file name a device id's address stands for.
///
/// Ids carry the file name with `/` and `\` replaced (`sanitize_port_name`),
/// so `/dev/fliusb0`, the name FLI's own Linux driver gives a device, arrives
/// as `_dev_fliusb0`, which FLIOpen cannot open. An address that matches no
/// listed device is used as written.
pub(crate) fn device_filename(listed: &[ListedDevice], address: &str) -> String {
    listed
        .iter()
        .find(|device| device.filename == address)
        .or_else(|| {
            listed
                .iter()
                .find(|device| sanitize_port_name(&device.filename) == address)
        })
        .map(|device| device.filename.clone())
        .unwrap_or_else(|| address.to_string())
}

/// Open the device a driver was created for. Returns the handle and the file
/// name that opened. The caller holds the SDK lock.
///
/// The address is tried as written first (every libfli name except the Linux
/// driver's `/dev/fliusbN`), so a connect lists devices only when it has to:
/// libfli's list opens every attached device of the kind.
pub(crate) fn open_device(
    sdk: &FliSdk,
    address: &str,
    device_type: FliDeviceType,
) -> Result<(FliDev, String), DriverError> {
    let domain = device_type.domain();
    let first = try_open(sdk, address, domain)?;
    let (result, filename) = match first {
        Ok(handle) => return Ok((handle, address.to_string())),
        Err(code) => {
            let filename = device_filename(&list_devices(sdk, domain), address);
            if filename == address {
                (code, filename)
            } else {
                match try_open(sdk, &filename, domain)? {
                    Ok(handle) => return Ok((handle, filename)),
                    Err(code) => (code, filename),
                }
            }
        }
    };
    let noun = device_type.noun();
    tracing::error!("FLIOpen failed for the {noun} at '{filename}': libfli code {result}");
    Err(DriverError::SdkError(format!(
        "Could not open the FLI {noun} at '{filename}': {}. Check that it is plugged in and powered and that no other program is using it, then search for devices again.",
        fli_error_text(result)
    )))
}

fn try_open(
    sdk: &FliSdk,
    filename: &str,
    domain: c_long,
) -> Result<Result<FliDev, c_long>, DriverError> {
    let path = CString::new(filename).map_err(|_| {
        DriverError::InvalidParameter(format!("FLI device name '{filename}' contains a NUL byte"))
    })?;
    let mut handle: FliDev = FLI_INVALID_DEVICE;
    // SAFETY: `handle` is a valid stack out-pointer; `path` is a NUL-terminated CString that outlives the call.
    let result = unsafe { (sdk.open)(&mut handle, path.as_ptr(), domain) };
    Ok(if result == 0 { Ok(handle) } else { Err(result) })
}

/// FLIGetModel for an open device, when it answers with a name.
pub(crate) fn read_model(sdk: &FliSdk, handle: FliDev) -> Option<String> {
    let mut buf = [0 as c_char; 128];
    // SAFETY: handle is open; buf is a 128-byte stack array and its length is passed truthfully.
    if unsafe { (sdk.get_model)(handle, buf.as_mut_ptr(), buf.len()) } != 0 {
        return None;
    }
    // SAFETY: libfli NUL-terminates the model on success.
    let model = unsafe { CStr::from_ptr(buf.as_ptr()) }
        .to_string_lossy()
        .trim()
        .to_string();
    (!model.is_empty()).then_some(model)
}

/// FLIGetSerialString for an open device, when it has one.
pub(crate) fn read_serial(sdk: &FliSdk, handle: FliDev) -> Option<String> {
    let mut buf = [0 as c_char; 64];
    // SAFETY: handle is open; buf is a 64-byte stack array and its length is passed truthfully.
    if unsafe { (sdk.get_serial_string)(handle, buf.as_mut_ptr(), buf.len()) } != 0 {
        return None;
    }
    // SAFETY: libfli NUL-terminates the serial on success.
    let serial = unsafe { CStr::from_ptr(buf.as_ptr()) }
        .to_string_lossy()
        .trim()
        .to_string();
    (!serial.is_empty()).then_some(serial)
}

async fn discover_devices_by_type(
    device_type: FliDeviceType,
) -> Result<Vec<FliDiscoveryInfo>, DriverError> {
    let sdk = match FliSdk::installed() {
        Ok(sdk) => sdk,
        Err(_) => return Ok(Vec::new()),
    };

    // Hold the FLI SDK lock for the whole scan
    let sdk = sdk.lock().await;

    let domain = device_type.domain();
    let sdk_version = sdk_version_from_sdk(&sdk);

    Ok(list_devices(&sdk, domain)
        .into_iter()
        .map(|device| {
            let serial = match try_open(&sdk, &device.filename, domain) {
                Ok(Ok(mut handle)) => {
                    let serial = read_serial(&sdk, handle);
                    close_fli_handle(&sdk, &mut handle);
                    serial
                }
                _ => None,
            };
            FliDiscoveryInfo {
                device_path: device.filename,
                name: device.name,
                serial_number: serial,
                sdk_version: sdk_version.clone(),
                device_type,
            }
        })
        .collect())
}

pub fn is_sdk_available() -> bool {
    FliSdk::is_available()
}

pub(crate) fn sdk_version_from_sdk(sdk: &FliSdk) -> Option<String> {
    let mut version_buf = [0 as c_char; 64];
    // SAFETY: version_buf is a 64-byte stack array; the length is passed truthfully so the SDK can't overrun. FLIGetLibVersion has no device handle to validate.
    if unsafe { (sdk.get_lib_version)(version_buf.as_mut_ptr(), version_buf.len()) } != 0 {
        return None;
    }
    // SAFETY: version_buf is 64 bytes; FLI SDK guarantees NUL-termination on success.
    let version = unsafe { CStr::from_ptr(version_buf.as_ptr()) }
        .to_string_lossy()
        .trim()
        .to_string();
    (!version.is_empty()).then_some(format!("FLI libfli v{version}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn listed(names: &[&str]) -> Vec<ListedDevice> {
        names
            .iter()
            .map(|name| ListedDevice {
                filename: name.to_string(),
                name: "FLI".to_string(),
            })
            .collect()
    }

    /// The catalog writes `/dev/fliusb0` into the id as `_dev_fliusb0`.
    #[test]
    fn sanitized_address_names_the_listed_device() {
        let devices = listed(&["/dev/fliusb0", "/dev/fliusb1"]);
        assert_eq!(device_filename(&devices, "_dev_fliusb1"), "/dev/fliusb1");
        assert_eq!(device_filename(&devices, "/dev/fliusb0"), "/dev/fliusb0");
    }

    /// Windows (`flicam0`) and libusb (`FLI-0102`) names need no mapping.
    #[test]
    fn plain_address_is_used_as_written() {
        let devices = listed(&["flicam0", "FLI-0102"]);
        assert_eq!(device_filename(&devices, "flicam0"), "flicam0");
        assert_eq!(device_filename(&devices, "FLI-0102"), "FLI-0102");
        assert_eq!(device_filename(&[], "_dev_fliusb3"), "_dev_fliusb3");
    }
}
