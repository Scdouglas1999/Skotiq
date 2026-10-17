//! libgphoto2 FFI type definitions.

use super::*;

/// Opaque camera handle
pub(crate) type GPCamera = c_void;

/// Opaque context handle
pub(crate) type GPContext = c_void;

/// Opaque camera list handle
pub(crate) type CameraList = c_void;

/// Opaque camera file handle
pub(crate) type CameraFile = c_void;

/// Opaque camera widget handle (for configuration)
pub(crate) type CameraWidget = c_void;

/// Camera file type enum (GP_FILE_TYPE_*)
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub(crate) enum CameraFileType {
    Preview = 0,
    Normal = 1,
    Raw = 2,
    Audio = 3,
    Exif = 4,
    Metadata = 5,
}

/// Camera capture type
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub(crate) enum CameraCaptureType {
    Image = 0,
    Movie = 1,
    Sound = 2,
}

/// Camera widget type
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) enum CameraWidgetType {
    Window = 0,
    Section = 1,
    Text = 2,
    Range = 3,
    Toggle = 4,
    Radio = 5,
    Menu = 6,
    Button = 7,
    Date = 8,
}

/// Camera file path - returned by gp_camera_capture
#[repr(C)]
#[derive(Debug, Clone)]
pub(crate) struct CameraFilePath {
    pub(crate) name: [c_char; 128],
    pub(crate) folder: [c_char; 1024],
}

impl Default for CameraFilePath {
    fn default() -> Self {
        Self {
            name: [0; 128],
            folder: [0; 1024],
        }
    }
}

/// Camera abilities (partial - we only need a few fields)
#[repr(C)]
#[derive(Debug, Clone)]
pub(crate) struct CameraAbilities {
    pub(crate) model: [c_char; 128],
    pub(crate) status: c_int,
    pub(crate) port: c_int,
    pub(crate) speed: [c_int; 64],
    pub(crate) operations: c_int,
    pub(crate) file_operations: c_int,
    pub(crate) folder_operations: c_int,
    pub(crate) usb_vendor: c_int,
    pub(crate) usb_product: c_int,
    pub(crate) usb_class: c_int,
    pub(crate) usb_subclass: c_int,
    pub(crate) usb_protocol: c_int,
    pub(crate) library: [c_char; 1024],
    pub(crate) id: [c_char; 1024],
    pub(crate) device_type: c_int,
    pub(crate) reserved2: c_int,
    pub(crate) reserved3: c_int,
    pub(crate) reserved4: c_int,
    pub(crate) reserved5: c_int,
    pub(crate) reserved6: c_int,
    pub(crate) reserved7: c_int,
    pub(crate) reserved8: c_int,
}

impl Default for CameraAbilities {
    fn default() -> Self {
        Self {
            model: [0; 128],
            status: 0,
            port: 0,
            speed: [0; 64],
            operations: 0,
            file_operations: 0,
            folder_operations: 0,
            usb_vendor: 0,
            usb_product: 0,
            usb_class: 0,
            usb_subclass: 0,
            usb_protocol: 0,
            library: [0; 1024],
            id: [0; 1024],
            device_type: 0,
            reserved2: 0,
            reserved3: 0,
            reserved4: 0,
            reserved5: 0,
            reserved6: 0,
            reserved7: 0,
            reserved8: 0,
        }
    }
}

// GP error codes
pub(crate) const GP_OK: c_int = 0;
pub(crate) const GP_ERROR: c_int = -1;
pub(crate) const GP_ERROR_IO: c_int = -7;
pub(crate) const GP_ERROR_NOT_SUPPORTED: c_int = -5;
pub(crate) const GP_ERROR_CAMERA_BUSY: c_int = -110;
pub(crate) const GP_ERROR_MODEL_NOT_FOUND: c_int = -105;

// Camera operations flags
pub(crate) const GP_OPERATION_CAPTURE_IMAGE: c_int = 1 << 1;
pub(crate) const GP_OPERATION_CAPTURE_PREVIEW: c_int = 1 << 3;
pub(crate) const GP_OPERATION_CONFIG: c_int = 1 << 2;
pub(crate) const GP_OPERATION_TRIGGER_CAPTURE: c_int = 1 << 4;
