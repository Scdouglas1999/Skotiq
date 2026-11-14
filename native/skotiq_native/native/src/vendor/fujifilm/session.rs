//! One SDK session per body, shared by the body's camera and its lens focuser.
//!
//! The SDK refuses to open a body that is already open, and the refusal
//! (XSDK_ERRCODE_SEQUENCE) clears only when the body is power-cycled (owner's
//! NINA plugin 3.1.2.0). So the camera and the lens of one body hold the same
//! session, and it is closed when the last of them leaves. Every function here
//! is called with the SDK lock held, which also orders the table's changes.

use super::*;
use std::sync::atomic::{AtomicPtr, Ordering};
use std::sync::{Arc, Mutex};

#[derive(Debug)]
pub(crate) struct Session {
    serial: String,
    /// Replaced in place when the body is opened again after it went away,
    /// so every holder of the session uses the new handle.
    handle: AtomicPtr<c_void>,
    product: String,
    firmware: String,
}

impl Session {
    pub(crate) fn handle(&self) -> XsdkHandle {
        self.handle.load(Ordering::Acquire)
    }

    /// The product name the body reports, such as "X-T5".
    pub(crate) fn product(&self) -> &str {
        &self.product
    }

    pub(crate) fn firmware(&self) -> &str {
        &self.firmware
    }
}

struct Entry {
    session: Arc<Session>,
    users: usize,
}

static OPEN: Mutex<Vec<Entry>> = Mutex::new(Vec::new());

fn table() -> std::sync::MutexGuard<'static, Vec<Entry>> {
    OPEN.lock().unwrap_or_else(|e| e.into_inner())
}

/// The session on the body with this address, opening the body if no one
/// holds it yet.
pub(crate) async fn join(sdk: &FujifilmSdk, address: &str) -> Result<Arc<Session>, DriverError> {
    let existing = table()
        .iter()
        .find(|e| e.session.serial == address)
        .map(|e| e.session.clone());
    let session = match existing {
        Some(session) => {
            if frames_in_buffer(session.handle(), sdk).is_err() {
                // The body went away under the open session (unplugged or
                // switched off) and is being connected again.
                tracing::info!(
                    "Fujifilm {address}: reopening the camera after it stopped answering"
                );
                close_camera(session.handle(), sdk);
                session
                    .handle
                    .store(std::ptr::null_mut(), Ordering::Release);
                let opened = open(sdk, address).await?;
                session.handle.store(opened.handle, Ordering::Release);
            }
            session
        }
        None => {
            let opened = open(sdk, address).await?;
            let session = Arc::new(Session {
                serial: address.to_string(),
                handle: AtomicPtr::new(opened.handle),
                product: opened.product,
                firmware: opened.firmware,
            });
            table().push(Entry {
                session: session.clone(),
                users: 0,
            });
            session
        }
    };
    if let Some(entry) = table()
        .iter_mut()
        .find(|e| Arc::ptr_eq(&e.session, &session))
    {
        entry.users += 1;
    }
    Ok(session)
}

/// Give up one hold on the session; the last one closes the body.
pub(crate) fn leave(sdk: &FujifilmSdk, session: &Arc<Session>) {
    let mut open = table();
    let Some(index) = open.iter().position(|e| Arc::ptr_eq(&e.session, session)) else {
        return;
    };
    open[index].users = open[index].users.saturating_sub(1);
    if open[index].users == 0 {
        open.remove(index);
        drop(open);
        close_camera(session.handle(), sdk);
        tracing::info!("Fujifilm {}: closed the camera", session.serial);
    }
}

/// [`leave`] for a driver dropped without being disconnected, which cannot
/// wait for the SDK lock: done now if the lock is free, else as soon as it is.
pub(crate) fn leave_later(session: Arc<Session>) {
    let Ok(installed) = FujifilmSdk::installed() else {
        return;
    };
    if let Some(sdk) = installed.try_lock() {
        leave(&sdk, &session);
        return;
    }
    match tokio::runtime::Handle::try_current() {
        Ok(runtime) => {
            runtime.spawn(async move {
                let sdk = installed.lock().await;
                leave(&sdk, &session);
            });
        }
        Err(_) => tracing::warn!(
            "Fujifilm {}: the camera stays open until Skotiq exits",
            session.serial
        ),
    }
}

struct Opened {
    handle: XsdkHandle,
    product: String,
    firmware: String,
}

async fn open(sdk: &FujifilmSdk, address: &str) -> Result<Opened, DriverError> {
    // SAFETY: XSDK_Init accepts a NULL reserved parameter per XAPI.h. LOADLIB means the SDK is already initialized.
    let result = unsafe { (sdk.init)(std::ptr::null_mut()) };
    if result != XSDK_COMPLETE {
        let (api_code, err_code) = last_error(std::ptr::null_mut(), sdk);
        if err_code != XSDK_ERRCODE_LOADLIB {
            return Err(sdk_failure("starting the Fujifilm SDK", api_code, err_code));
        }
    }

    // XSDK_OpenEx names a camera as "ENUM:<n>", n being its place in the list
    // the last XSDK_Detect built (SDK Programming Reference 4.1.3.1), not by
    // serial number.
    let listed = list_cameras(sdk).await?;
    let (index, body) = listed
        .iter()
        .enumerate()
        .find_map(|(i, c)| {
            c.as_ref()
                .filter(|c| c.address() == address)
                .map(|c| (i, c))
        })
        .ok_or_else(|| {
            DriverError::DeviceNotFound(format!(
                "Fujifilm camera {address} is not attached. Check the USB cable, that the camera \
                 is on, and that its PC CONNECTION MODE is USB TETHER SHOOTING AUTO."
            ))
        })?;
    let device = CString::new(format!("ENUM:{index}"))
        .map_err(|_| DriverError::InvalidParameter("Invalid camera index".into()))?;

    let mut handle: XsdkHandle = std::ptr::null_mut();
    let mut camera_mode: c_long = 0;
    for attempt in 1..=3 {
        wait_for_close_settle();
        // SAFETY: `device.as_ptr()` is a NUL-terminated CString owned by `device` for the whole loop; `&mut handle` and `&mut camera_mode` are valid stack out-pointers; the trailing NULL is the documented "use defaults for options" sentinel per XAPI.h.
        let result = unsafe {
            (sdk.open_ex)(
                device.as_ptr(),
                &mut handle,
                &mut camera_mode,
                std::ptr::null_mut(),
            )
        };
        if result == XSDK_COMPLETE {
            break;
        }
        let (api_code, err_code) = last_error(std::ptr::null_mut(), sdk);
        if attempt == 3 || err_code != XSDK_ERRCODE_SEQUENCE {
            return Err(sdk_failure("opening the camera", api_code, err_code));
        }
        // A blocking pause: the raw handle must not be held across an await.
        std::thread::sleep(Duration::from_millis(100 * (1 << attempt)));
    }

    let mut info = XsdkDeviceInformation::default();
    // SAFETY: `handle` was just opened; `&mut info` is a valid stack out-pointer to a `#[repr(C, packed)]` XsdkDeviceInformation that the SDK fills. `cstr_to_string` reads its packed [c_char; N] fields through slice references (no misaligned pointer reads).
    unsafe { (sdk.get_device_info)(handle, &mut info) };
    let serial = cstr_to_string(&info.str_serial_no);
    let product = cstr_to_string(&info.str_product);
    // Compared field by field: either record may leave the serial empty, and
    // a product name never matches a serial number.
    let other_body = match (
        body.serial_number.as_deref(),
        serial.as_str(),
        product.as_str(),
    ) {
        (Some(listed), opened, _) if !opened.is_empty() => (opened != listed).then_some(opened),
        (_, _, opened) if !opened.is_empty() => (opened != body.name).then_some(opened),
        _ => None,
    };
    if let Some(opened) = other_body {
        close_camera(handle, sdk);
        return Err(DriverError::DeviceNotFound(format!(
            "Fujifilm camera {address} moved in the SDK's camera list (ENUM:{index} is now \
             {opened}). Search for devices again and reconnect."
        )));
    }

    // Live view, lens focus and remote shooting all need PC priority.
    // SAFETY: `handle` is open; XSDK_SetPriorityMode takes (handle, c_long) POD per XAPI.h.
    unsafe { (sdk.set_priority_mode)(handle, XSDK_PRIORITY_PC) };
    std::thread::sleep(Duration::from_millis(100));

    Ok(Opened {
        handle,
        product,
        firmware: cstr_to_string(&info.str_firmware),
    })
}
