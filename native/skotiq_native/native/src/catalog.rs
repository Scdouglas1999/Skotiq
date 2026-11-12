//! The vendor catalog: one row per device family this crate can drive.
//!
//! A row says how a family is named in a device id, how its devices are
//! found and how one is opened. Discovery, the id grammar and the bridge's
//! connect path all read these rows, so adding a family is adding a row.
//!
//! Device ids are `native:<token>:<address>`. They are saved in equipment
//! profiles, so the token and address a family writes must never change.

use crate::vendor::lx200::Lx200MountType;
use crate::vendor::serial_link::sanitize_port_name;
use skotiq_device::{
    CameraDriver, DeviceKind, DriverError, FilterWheelDriver, FocuserDriver, MountDriver,
    SiteSource, Vendor,
};
use std::future::Future;
use std::pin::Pin;

pub const ID_PREFIX: &str = "native";

type BoxFuture<T> = Pin<Box<dyn Future<Output = T> + Send>>;
type DiscoverFn = fn() -> BoxFuture<Result<Vec<Found>, DriverError>>;

/// A device as its family's discovery reports it.
#[derive(Clone)]
pub struct Found {
    /// The part of the id after the family token.
    pub address: String,
    pub name: String,
    pub display_name: String,
    pub serial_number: Option<String>,
    pub sdk_version: Option<String>,
    /// Set when one scan finds devices of several families (the LX200 scan
    /// tells Meade, OnStep, Losmandy and 10Micron apart).
    pub family: Option<&'static Family>,
}

/// How a family's devices are found.
pub enum Discover {
    /// Ask the vendor SDK.
    Sdk(DiscoverFn),
    /// Probe the serial ports. Skipped while a connected mount owns one.
    SerialPorts(DiscoverFn),
    /// Reported by another family's scan.
    ByAnotherFamily,
    /// The vendor SDK does not exist for this operating system.
    NotOnThisPlatform,
}

/// What opening a device needs besides its family.
#[derive(Clone)]
pub struct OpenRequest<'a> {
    /// The part of the id after the family token.
    pub address: &'a str,
    /// The device's registered name.
    pub name: &'a str,
    /// The application's observing site, for mounts that keep none.
    pub site: SiteSource,
}

/// A driver for one device, not yet connected.
pub enum NativeHandle {
    Camera(Box<dyn CameraDriver + Send + Sync>),
    Mount(Box<dyn MountDriver + Send + Sync>),
    Focuser(Box<dyn FocuserDriver + Send + Sync>),
    FilterWheel(Box<dyn FilterWheelDriver + Send + Sync>),
}

/// The address in a device id does not name a device of this family. The
/// text is shown to the user as is.
#[derive(Debug, thiserror::Error)]
#[error("{0}")]
pub struct BadAddress(pub String);

pub enum Open {
    Now(fn(&OpenRequest) -> Result<NativeHandle, BadAddress>),
    /// Needs to ask the SDK which devices are present first.
    AfterDiscovery(fn(String, String) -> BoxFuture<Result<NativeHandle, BadAddress>>),
    /// The vendor SDK does not exist for this operating system.
    NotOnThisPlatform(&'static str),
}

pub struct Family {
    /// Vendor part of the id token, such as `zwo`.
    pub base: &'static str,
    /// Accessory part of the id token, such as `eaf` in `zwo_eaf`. An id may
    /// also carry it as its own segment (`native:zwo:eaf:0`).
    pub subtype: Option<&'static str>,
    /// Other tokens that name this family in existing ids.
    pub aliases: &'static [&'static str],
    pub kind: DeviceKind,
    pub vendor: fn() -> Vendor,
    /// Vendor name in a fallback display name.
    pub label: &'static str,
    /// Accessory name in a fallback display name.
    pub subtype_label: Option<&'static str>,
    /// What one device is called in a log line.
    pub noun: &'static str,
    /// Whether the vendor SDK this family needs is installed. `None` for
    /// families that need none (serial mounts).
    pub sdk_present: Option<fn() -> bool>,
    pub discover: Discover,
    pub open: Open,
}

impl Family {
    /// The token discovery writes into ids.
    pub fn token(&self) -> String {
        match self.subtype {
            Some(subtype) => format!("{}_{}", self.base, subtype),
            None => self.base.to_string(),
        }
    }

    pub fn device_id(&self, address: &str) -> String {
        format!("{}:{}:{}", ID_PREFIX, self.token(), address)
    }

    fn answers_to(&self, token: &str) -> bool {
        token == self.token()
            || (self.subtype.is_some() && token == self.base)
            || self.aliases.contains(&token)
    }

    /// Builds the driver for the device at `address`. The driver is not
    /// connected yet.
    pub async fn open(&self, request: OpenRequest<'_>) -> Result<NativeHandle, BadAddress> {
        // `native:zwo:eaf:0` carries the accessory as its own segment.
        let address = self
            .subtype
            .and_then(|subtype| {
                request
                    .address
                    .strip_prefix(subtype)
                    .and_then(|rest| rest.strip_prefix(':'))
            })
            .unwrap_or(request.address);
        match self.open {
            Open::Now(open) => open(&OpenRequest {
                address,
                name: request.name,
                site: request.site.clone(),
            }),
            Open::AfterDiscovery(open) => open(address.to_string(), request.name.to_string()).await,
            Open::NotOnThisPlatform(why) => Err(BadAddress(why.to_string())),
        }
    }
}

/// Splits `native:<token>:<address>`.
pub fn split_id(id: &str) -> Option<(&str, &str)> {
    let rest = id.strip_prefix(ID_PREFIX)?.strip_prefix(':')?;
    let (token, address) = rest.split_once(':')?;
    (!token.is_empty() && !address.is_empty()).then_some((token, address))
}

/// The family an id token names for a device of `kind`.
///
/// Kinds this crate has no driver trait for (a guide camera registered as a
/// guider) are served by the camera family of the same token.
pub fn family(token: &str, kind: DeviceKind) -> Option<&'static Family> {
    let wanted = match kind {
        DeviceKind::Camera | DeviceKind::Mount | DeviceKind::Focuser | DeviceKind::FilterWheel => {
            kind
        }
        _ => DeviceKind::Camera,
    };
    FAMILIES
        .iter()
        .find(|f| f.kind == wanted && f.answers_to(token))
}

/// Every token that may follow `native:` in a device id.
pub fn id_tokens() -> Vec<String> {
    let mut tokens: Vec<String> = Vec::new();
    for family in FAMILIES {
        for token in std::iter::once(family.token())
            .chain(std::iter::once(family.base.to_string()))
            .chain(family.aliases.iter().map(|a| a.to_string()))
        {
            if !tokens.contains(&token) {
                tokens.push(token);
            }
        }
    }
    tokens
}

/// The accessory segments `base` may be followed by in a four-part id.
pub fn subtypes_of(base: &str) -> Vec<&'static str> {
    FAMILIES
        .iter()
        .filter(|f| f.base == base)
        .filter_map(|f| f.subtype)
        .collect()
}

/// The labels a fallback display name is built from: the vendor and, for
/// an accessory family, the accessory. `subtype` is the accessory segment of
/// a four-part id.
pub fn labels(token: &str, subtype: Option<&str>) -> Option<(&'static str, Option<&'static str>)> {
    let named = |f: &&Family| f.token() == token || f.aliases.contains(&token);
    let vendor = FAMILIES.iter().find(named)?.label;
    let accessory = FAMILIES
        .iter()
        .find(|f| f.base == token && subtype.is_some() && f.subtype == subtype)
        .or_else(|| FAMILIES.iter().find(named))
        .and_then(|f| f.subtype_label);
    Some((vendor, accessory))
}

/// Name shown in a device list: the serial number tells two of a model
/// apart; without one, the position in the scan does.
pub fn display_name(name: &str, serial_number: Option<&str>, index: Option<usize>) -> String {
    if let Some(serial) = serial_number {
        if !serial.is_empty() {
            return format!("{} ({})", name, serial);
        }
    }
    if let Some(index) = index {
        return format!("{} #{}", name, index + 1);
    }
    name.to_string()
}

/// The serial port an id address names.
///
/// [`sanitize_port_name`] cannot be undone by rule (`/dev/ttyUSB0` and a port
/// really named `_dev_ttyUSB0` write the same address), so the address is
/// matched against the ports present. A name without a replaced separator
/// (every Windows `COMn`) is used as written, without asking the system.
fn port_from_address(address: &str) -> String {
    if !address.starts_with('_') {
        return address.to_string();
    }
    serialport::available_ports()
        .ok()
        .and_then(|ports| {
            ports
                .into_iter()
                .map(|p| p.port_name)
                .find(|name| sanitize_port_name(name) == address)
        })
        .unwrap_or_else(|| address.to_string())
}

fn found(
    address: impl ToString,
    name: String,
    display_name: String,
    serial_number: Option<String>,
    sdk_version: Option<String>,
) -> Found {
    Found {
        address: address.to_string(),
        name,
        display_name,
        serial_number,
        sdk_version,
        family: None,
    }
}

fn number<T: std::str::FromStr>(address: &str, error: &str) -> Result<T, BadAddress> {
    address
        .parse::<T>()
        .map_err(|_| BadAddress(error.to_string()))
}

/// `<port>` or `<port>:<baud>`. An id written before the baud rate was
/// recorded opens at the driver's default.
fn port_and_baud(address: &str) -> Result<(String, Option<u32>), BadAddress> {
    let mut segments = address.split(':');
    let port = port_from_address(segments.next().unwrap_or_default());
    let baud = match segments.next() {
        Some(raw) => Some(
            raw.parse::<u32>()
                .map_err(|_| BadAddress(format!("Invalid native mount baud rate: {raw}")))?,
        ),
        None => None,
    };
    Ok((port, baud))
}

fn open_lx200(request: &OpenRequest, flavor: Lx200MountType) -> Result<NativeHandle, BadAddress> {
    let (port, baud) = port_and_baud(request.address)?;
    Ok(NativeHandle::Mount(Box::new(
        crate::vendor::lx200::Lx200Mount::new(port, flavor, baud),
    )))
}

fn lx200_family(flavor: &Lx200MountType) -> &'static Family {
    let token = match flavor {
        Lx200MountType::Meade => "meade",
        Lx200MountType::OnStep => "onstep",
        Lx200MountType::Losmandy => "losmandy",
        Lx200MountType::TenMicron => "10micron",
        Lx200MountType::Generic => "lx200",
    };
    FAMILIES
        .iter()
        .find(|f| f.kind == DeviceKind::Mount && f.base == token)
        .expect("every LX200 flavor has a catalog row")
}

/// In scan order. The order is the order vendor SDKs are called in and
/// serial ports are probed in; keep it.
pub static FAMILIES: &[Family] = &[
    Family {
        base: "zwo",
        subtype: None,
        aliases: &[],
        kind: DeviceKind::Camera,
        vendor: || Vendor::Zwo,
        label: "ZWO",
        subtype_label: None,
        noun: "ZWO camera",
        sdk_present: Some(crate::vendor::zwo::is_sdk_available),
        // The ASI SDK reports a serial number only for an open camera, and
        // opening every camera during a scan would fight any other program
        // holding one. So the id is the SDK index, which re-orders across a
        // replug; the serial is read at connect and checked by the bridge.
        discover: Discover::Sdk(|| {
            Box::pin(async {
                Ok(crate::vendor::zwo::discover_devices()
                    .await?
                    .into_iter()
                    .map(|d| {
                        let display = display_name(&d.name, None, Some(d.discovery_index));
                        found(d.camera_id, d.name, display, None, d.sdk_version)
                    })
                    .collect())
            })
        }),
        open: Open::Now(|r| {
            Ok(NativeHandle::Camera(Box::new(
                crate::vendor::zwo::ZwoCamera::new(number(r.address, "Invalid ZWO camera ID")?),
            )))
        }),
    },
    Family {
        base: "qhy",
        subtype: None,
        aliases: &[],
        kind: DeviceKind::Camera,
        vendor: || Vendor::Qhy,
        label: "QHY",
        subtype_label: None,
        noun: "QHY camera",
        sdk_present: Some(crate::vendor::qhy::is_sdk_available),
        discover: Discover::Sdk(|| {
            Box::pin(async {
                Ok(crate::vendor::qhy::discover_devices()
                    .await?
                    .into_iter()
                    .map(|d| {
                        let display = display_name(&d.name, d.serial_number.as_deref(), None);
                        found(d.camera_id, d.name, display, d.serial_number, d.sdk_version)
                    })
                    .collect())
            })
        }),
        open: Open::Now(|r| {
            Ok(NativeHandle::Camera(Box::new(
                crate::vendor::qhy::QhyCamera::new(r.address.to_string()),
            )))
        }),
    },
    Family {
        base: "playerone",
        subtype: None,
        aliases: &["player_one"],
        kind: DeviceKind::Camera,
        vendor: || Vendor::PlayerOne,
        label: "Player One",
        subtype_label: None,
        noun: "Player One camera",
        sdk_present: Some(crate::vendor::player_one::is_sdk_available),
        discover: Discover::Sdk(|| {
            Box::pin(async {
                Ok(crate::vendor::player_one::discover_devices()
                    .await?
                    .into_iter()
                    .map(|d| {
                        let display = display_name(&d.name, d.serial_number.as_deref(), None);
                        found(d.camera_id, d.name, display, d.serial_number, d.sdk_version)
                    })
                    .collect())
            })
        }),
        open: Open::Now(|r| {
            Ok(NativeHandle::Camera(Box::new(
                crate::vendor::player_one::PlayerOneCamera::new(number(
                    r.address,
                    "Invalid Player One camera ID",
                )?),
            )))
        }),
    },
    Family {
        base: "playerone",
        subtype: Some("pw"),
        aliases: &[],
        kind: DeviceKind::FilterWheel,
        vendor: || Vendor::PlayerOne,
        label: "playerone_pw",
        subtype_label: None,
        noun: "Player One Phoenix filter wheel",
        sdk_present: Some(crate::vendor::player_one::is_pw_sdk_available),
        discover: Discover::Sdk(|| {
            Box::pin(async {
                Ok(crate::vendor::player_one::discover_filter_wheels()
                    .await?
                    .into_iter()
                    .map(|d| {
                        let display = display_name(&d.name, d.serial_number.as_deref(), None);
                        found(d.handle, d.name, display, d.serial_number, d.sdk_version)
                    })
                    .collect())
            })
        }),
        open: Open::Now(|r| {
            Ok(NativeHandle::FilterWheel(Box::new(
                crate::vendor::player_one::PlayerOneFilterWheel::new(number(
                    r.address,
                    "Invalid Player One filter wheel handle",
                )?),
            )))
        }),
    },
    Family {
        base: "zwo",
        subtype: Some("eaf"),
        aliases: &[],
        kind: DeviceKind::Focuser,
        vendor: || Vendor::Zwo,
        label: "ZWO",
        subtype_label: Some("EAF"),
        noun: "ZWO EAF focuser",
        sdk_present: Some(crate::vendor::zwo::is_eaf_sdk_available),
        discover: Discover::Sdk(|| {
            Box::pin(async {
                Ok(crate::vendor::zwo::discover_focusers()
                    .await?
                    .into_iter()
                    .map(|d| {
                        let display = display_name(
                            &d.name,
                            d.serial_number.as_deref(),
                            Some(d.discovery_index),
                        );
                        found(
                            d.focuser_id,
                            d.name,
                            display,
                            d.serial_number,
                            d.sdk_version,
                        )
                    })
                    .collect())
            })
        }),
        open: Open::Now(|r| {
            Ok(NativeHandle::Focuser(Box::new(
                crate::vendor::zwo::ZwoFocuser::new(number(r.address, "Invalid ZWO focuser ID")?),
            )))
        }),
    },
    Family {
        base: "zwo",
        subtype: Some("efw"),
        aliases: &[],
        kind: DeviceKind::FilterWheel,
        vendor: || Vendor::Zwo,
        label: "ZWO",
        subtype_label: Some("EFW"),
        noun: "ZWO EFW filter wheel",
        sdk_present: Some(crate::vendor::zwo::is_efw_sdk_available),
        discover: Discover::Sdk(|| {
            Box::pin(async {
                Ok(crate::vendor::zwo::discover_filter_wheels()
                    .await?
                    .into_iter()
                    .map(|d| {
                        let display = display_name(
                            &d.name,
                            d.serial_number.as_deref(),
                            Some(d.discovery_index),
                        );
                        found(
                            d.filterwheel_id,
                            d.name,
                            display,
                            d.serial_number,
                            d.sdk_version,
                        )
                    })
                    .collect())
            })
        }),
        open: Open::Now(|r| {
            Ok(NativeHandle::FilterWheel(Box::new(
                crate::vendor::zwo::ZwoFilterWheel::new(number(
                    r.address,
                    "Invalid ZWO filter wheel ID",
                )?),
            )))
        }),
    },
    Family {
        base: "qhy",
        subtype: Some("cfw"),
        aliases: &[],
        kind: DeviceKind::FilterWheel,
        vendor: || Vendor::Qhy,
        label: "QHY",
        subtype_label: Some("CFW"),
        noun: "QHY CFW",
        sdk_present: Some(crate::vendor::qhy::is_sdk_available),
        // A CFW hangs off a camera and is addressed by that camera's id; it
        // has no serial number of its own.
        discover: Discover::Sdk(|| {
            Box::pin(async {
                Ok(crate::vendor::qhy::discover_filter_wheels()
                    .await?
                    .into_iter()
                    .map(|d| {
                        let display = format!("{} ({})", d.name, d.camera_id);
                        found(d.camera_id, d.name, display, None, d.sdk_version)
                    })
                    .collect())
            })
        }),
        open: Open::Now(|r| {
            Ok(NativeHandle::FilterWheel(Box::new(
                crate::vendor::qhy::QhyFilterWheel::new(r.address.to_string()),
            )))
        }),
    },
    Family {
        base: "svbony",
        subtype: None,
        aliases: &[],
        kind: DeviceKind::Camera,
        vendor: || Vendor::Svbony,
        label: "SVBony",
        subtype_label: None,
        noun: "SVBony camera",
        sdk_present: Some(crate::vendor::svbony::is_sdk_available),
        discover: Discover::Sdk(|| {
            Box::pin(async {
                Ok(crate::vendor::svbony::discover_devices()
                    .await?
                    .into_iter()
                    .map(|d| {
                        let display = display_name(
                            &d.name,
                            d.serial_number.as_deref(),
                            Some(d.discovery_index),
                        );
                        found(d.camera_id, d.name, display, d.serial_number, d.sdk_version)
                    })
                    .collect())
            })
        }),
        open: Open::Now(|r| {
            Ok(NativeHandle::Camera(Box::new(
                crate::vendor::svbony::SvbonyCamera::new(number(
                    r.address,
                    "Invalid SVBony camera ID",
                )?),
            )))
        }),
    },
    Family {
        base: "atik",
        subtype: None,
        aliases: &[],
        kind: DeviceKind::Camera,
        vendor: || Vendor::Atik,
        label: "Atik",
        subtype_label: None,
        noun: "Atik camera",
        sdk_present: Some(crate::vendor::atik::is_sdk_available),
        discover: Discover::Sdk(|| {
            Box::pin(async {
                Ok(crate::vendor::atik::discover_devices()
                    .await?
                    .into_iter()
                    .map(|d| {
                        let display = display_name(
                            &d.name,
                            d.serial_number.as_deref(),
                            Some(usize::try_from(d.device_index).unwrap_or(0)),
                        );
                        found(
                            d.device_index,
                            d.name,
                            display,
                            d.serial_number,
                            d.sdk_version,
                        )
                    })
                    .collect())
            })
        }),
        open: Open::Now(|r| {
            Ok(NativeHandle::Camera(Box::new(
                crate::vendor::atik::AtikCamera::new(number(r.address, "Invalid Atik camera ID")?),
            )))
        }),
    },
    Family {
        base: "atik",
        subtype: Some("efw"),
        aliases: &[],
        kind: DeviceKind::FilterWheel,
        vendor: || Vendor::Atik,
        label: "atik_efw",
        subtype_label: None,
        noun: "Atik EFW filter wheel",
        sdk_present: Some(crate::vendor::atik::is_sdk_available),
        discover: Discover::Sdk(|| {
            Box::pin(async {
                Ok(crate::vendor::atik::discover_filter_wheels()
                    .await?
                    .into_iter()
                    .map(|d| {
                        let display = display_name(
                            &d.name,
                            d.serial_number.as_deref(),
                            Some(usize::try_from(d.device_index).unwrap_or(0)),
                        );
                        found(
                            d.device_index,
                            d.name,
                            display,
                            d.serial_number,
                            d.sdk_version,
                        )
                    })
                    .collect())
            })
        }),
        open: Open::Now(|r| {
            Ok(NativeHandle::FilterWheel(Box::new(
                crate::vendor::atik::AtikFilterWheel::new(number(
                    r.address,
                    "Invalid Atik EFW filter wheel ID",
                )?),
            )))
        }),
    },
    Family {
        base: "fli",
        subtype: None,
        aliases: &[],
        kind: DeviceKind::Camera,
        vendor: || Vendor::Fli,
        label: "FLI",
        subtype_label: None,
        noun: "FLI camera",
        sdk_present: Some(crate::vendor::fli::is_sdk_available),
        discover: Discover::Sdk(|| {
            Box::pin(async { Ok(fli_found(crate::vendor::fli::discover_cameras().await?)) })
        }),
        open: Open::Now(|r| {
            Ok(NativeHandle::Camera(Box::new(
                crate::vendor::fli::FliCamera::new(r.address.to_string()),
            )))
        }),
    },
    Family {
        base: "fli",
        subtype: Some("focuser"),
        aliases: &[],
        kind: DeviceKind::Focuser,
        vendor: || Vendor::Fli,
        label: "FLI",
        subtype_label: Some("Focuser"),
        noun: "FLI focuser",
        sdk_present: Some(crate::vendor::fli::is_sdk_available),
        discover: Discover::Sdk(|| {
            Box::pin(async { Ok(fli_found(crate::vendor::fli::discover_focusers().await?)) })
        }),
        open: Open::Now(|r| {
            Ok(NativeHandle::Focuser(Box::new(
                crate::vendor::fli::FliFocuser::new(r.address.to_string()),
            )))
        }),
    },
    Family {
        base: "fli",
        subtype: Some("fw"),
        aliases: &[],
        kind: DeviceKind::FilterWheel,
        vendor: || Vendor::Fli,
        label: "FLI",
        subtype_label: Some("Filter Wheel"),
        noun: "FLI filter wheel",
        sdk_present: Some(crate::vendor::fli::is_sdk_available),
        discover: Discover::Sdk(|| {
            Box::pin(async {
                Ok(fli_found(
                    crate::vendor::fli::discover_filter_wheels().await?,
                ))
            })
        }),
        open: Open::Now(|r| {
            Ok(NativeHandle::FilterWheel(Box::new(
                crate::vendor::fli::FliFilterWheel::new(r.address.to_string()),
            )))
        }),
    },
    Family {
        base: "touptek",
        subtype: None,
        aliases: &[],
        kind: DeviceKind::Camera,
        vendor: || Vendor::Touptek,
        label: "Touptek",
        subtype_label: None,
        noun: "Touptek camera",
        sdk_present: Some(crate::vendor::touptek::is_sdk_available),
        // Touptek sells one SDK under several brands; the address is
        // `<brand>:<index within that brand's SDK>`.
        discover: Discover::Sdk(|| {
            Box::pin(async {
                Ok(crate::vendor::touptek::discover_devices()
                    .await?
                    .into_iter()
                    .map(|d| {
                        let display = display_name(
                            &d.name,
                            d.serial_number.as_deref(),
                            Some(d.discovery_index),
                        );
                        found(
                            format!("{}:{}", d.brand.to_lowercase(), d.discovery_index),
                            d.name,
                            display,
                            d.serial_number,
                            d.sdk_version,
                        )
                    })
                    .collect())
            })
        }),
        open: Open::Now(|r| {
            let (brand, index) = r
                .address
                .split_once(':')
                .ok_or_else(|| BadAddress("Invalid Touptek camera ID: missing index".into()))?;
            Ok(NativeHandle::Camera(Box::new(
                crate::vendor::touptek::TouptekCamera::new(
                    number(index, "Invalid Touptek camera index")?,
                    brand,
                ),
            )))
        }),
    },
    Family {
        base: "moravian",
        subtype: None,
        aliases: &[],
        kind: DeviceKind::Camera,
        vendor: || Vendor::Moravian,
        label: "Moravian",
        subtype_label: None,
        noun: "Moravian camera",
        sdk_present: Some(crate::vendor::moravian::is_sdk_available),
        discover: Discover::Sdk(|| {
            Box::pin(async {
                Ok(crate::vendor::moravian::discover_devices()
                    .await?
                    .into_iter()
                    .map(|d| {
                        let display = display_name(
                            &d.name,
                            d.serial_number.as_deref(),
                            Some(d.discovery_index),
                        );
                        found(d.address(), d.name, display, d.serial_number, None)
                    })
                    .collect())
            })
        }),
        open: Open::Now(|r| {
            Ok(NativeHandle::Camera(Box::new(
                crate::vendor::moravian::MoravianCamera::from_address(r.address)
                    .map_err(BadAddress)?,
            )))
        }),
    },
    Family {
        base: "fujifilm",
        subtype: None,
        aliases: &[],
        kind: DeviceKind::Camera,
        vendor: || Vendor::Fujifilm,
        label: "Fujifilm",
        subtype_label: None,
        noun: "Fujifilm camera",
        sdk_present: FUJIFILM_SDK_PRESENT,
        discover: FUJIFILM_DISCOVER,
        open: FUJIFILM_OPEN,
    },
    Family {
        base: "fujifilm",
        subtype: Some("lens"),
        aliases: &[],
        kind: DeviceKind::Focuser,
        vendor: || Vendor::Fujifilm,
        label: "Fujifilm",
        subtype_label: Some("Lens"),
        noun: "Fujifilm lens",
        sdk_present: None,
        // The camera scan lists each body's lens with the body.
        discover: Discover::ByAnotherFamily,
        open: FUJIFILM_LENS_OPEN,
    },
    Family {
        base: "gphoto2",
        subtype: None,
        aliases: &[],
        kind: DeviceKind::Camera,
        vendor: || Vendor::GPhoto2,
        label: "gPhoto2",
        subtype_label: None,
        noun: "gPhoto2 camera",
        sdk_present: Some(crate::vendor::gphoto2::is_sdk_available),
        discover: Discover::Sdk(|| {
            Box::pin(async {
                Ok(crate::vendor::gphoto2::detect_gphoto2_cameras()
                    .into_iter()
                    .map(|d| {
                        let display = display_name(&d.model, None, Some(d.index));
                        let address = d
                            .device_id
                            .strip_prefix("native:gphoto2:")
                            .map(str::to_string)
                            .unwrap_or_else(|| d.index.to_string());
                        found(address, d.model, display, None, d.sdk_version)
                    })
                    .collect())
            })
        }),
        // `<index>:<port as hex>:<model>`. libgphoto2 opens by index; an id
        // written before the port was recorded, or a port that does not
        // decode, leaves the port empty and libgphoto2 finds it by index.
        open: Open::Now(|r| {
            let mut segments = r.address.split(':');
            let index = number(
                segments.next().unwrap_or_default(),
                "Invalid gPhoto2 camera index",
            )?;
            let port = segments
                .next()
                .and_then(crate::vendor::gphoto2::decode_port_component)
                .unwrap_or_default();
            Ok(NativeHandle::Camera(Box::new(
                crate::vendor::gphoto2::GPhoto2Camera::new(index, r.name, &port),
            )))
        }),
    },
    Family {
        base: "skywatcher",
        subtype: None,
        aliases: &[],
        kind: DeviceKind::Mount,
        vendor: || Vendor::SkyWatcher,
        label: "Sky-Watcher",
        subtype_label: None,
        noun: "Sky-Watcher mount",
        sdk_present: None,
        discover: Discover::SerialPorts(|| {
            Box::pin(async {
                Ok(crate::vendor::skywatcher::discover_mounts()
                    .await?
                    .into_iter()
                    .map(|d| serial_found(&d.port, d.baud_rate, d.name, d.firmware_version))
                    .collect())
            })
        }),
        open: Open::Now(|r| {
            let (port, baud) = port_and_baud(r.address)?;
            Ok(NativeHandle::Mount(Box::new(
                crate::vendor::skywatcher::SkyWatcherMount::new_serial(port, baud, r.site.clone()),
            )))
        }),
    },
    Family {
        base: "ioptron",
        subtype: None,
        aliases: &[],
        kind: DeviceKind::Mount,
        vendor: || Vendor::IOptron,
        label: "iOptron",
        subtype_label: None,
        noun: "iOptron mount",
        sdk_present: None,
        discover: Discover::SerialPorts(|| {
            Box::pin(async {
                Ok(crate::vendor::ioptron::discover_mounts()
                    .await?
                    .into_iter()
                    .map(|d| serial_found(&d.port, d.baud_rate, d.name, d.firmware_version))
                    .collect())
            })
        }),
        open: Open::Now(|r| {
            let (port, baud) = port_and_baud(r.address)?;
            Ok(NativeHandle::Mount(Box::new(
                crate::vendor::ioptron::IOptronMount::new(port, baud),
            )))
        }),
    },
    Family {
        base: "lx200",
        subtype: None,
        aliases: &[],
        kind: DeviceKind::Mount,
        vendor: || Lx200MountType::Generic.vendor(),
        label: "LX200",
        subtype_label: None,
        noun: "LX200 mount",
        sdk_present: None,
        // One scan tells the LX200 dialects apart; each mount is reported
        // under its own family.
        discover: Discover::SerialPorts(|| {
            Box::pin(async {
                Ok(crate::vendor::lx200::discover_mounts()
                    .await?
                    .into_iter()
                    .map(|d| Found {
                        family: Some(lx200_family(&d.mount_type)),
                        ..serial_found(&d.port, d.baud_rate, d.name, d.firmware_version)
                    })
                    .collect())
            })
        }),
        // An id written as plain `lx200` is driven as a Meade.
        open: Open::Now(|r| open_lx200(r, Lx200MountType::Meade)),
    },
    Family {
        base: "meade",
        subtype: None,
        aliases: &[],
        kind: DeviceKind::Mount,
        vendor: || Lx200MountType::Meade.vendor(),
        label: "meade",
        subtype_label: None,
        noun: "Meade mount",
        sdk_present: None,
        discover: Discover::ByAnotherFamily,
        open: Open::Now(|r| open_lx200(r, Lx200MountType::Meade)),
    },
    Family {
        base: "onstep",
        subtype: None,
        aliases: &[],
        kind: DeviceKind::Mount,
        vendor: || Lx200MountType::OnStep.vendor(),
        label: "onstep",
        subtype_label: None,
        noun: "OnStep mount",
        sdk_present: None,
        discover: Discover::ByAnotherFamily,
        open: Open::Now(|r| open_lx200(r, Lx200MountType::OnStep)),
    },
    // The Pegasus NYX-101 runs OnStep firmware.
    Family {
        base: "pegasus",
        subtype: None,
        aliases: &[],
        kind: DeviceKind::Mount,
        vendor: || Lx200MountType::OnStep.vendor(),
        label: "pegasus",
        subtype_label: None,
        noun: "Pegasus mount",
        sdk_present: None,
        discover: Discover::ByAnotherFamily,
        open: Open::Now(|r| open_lx200(r, Lx200MountType::OnStep)),
    },
    Family {
        base: "losmandy",
        subtype: None,
        aliases: &[],
        kind: DeviceKind::Mount,
        vendor: || Lx200MountType::Losmandy.vendor(),
        label: "losmandy",
        subtype_label: None,
        noun: "Losmandy mount",
        sdk_present: None,
        discover: Discover::ByAnotherFamily,
        open: Open::Now(|r| open_lx200(r, Lx200MountType::Losmandy)),
    },
    Family {
        base: "10micron",
        subtype: None,
        aliases: &[],
        kind: DeviceKind::Mount,
        vendor: || Lx200MountType::TenMicron.vendor(),
        label: "10Micron",
        subtype_label: None,
        noun: "10Micron mount",
        sdk_present: None,
        discover: Discover::ByAnotherFamily,
        open: Open::Now(|r| open_lx200(r, Lx200MountType::TenMicron)),
    },
];

/// The Fujifilm X Acquire SDK ships for Windows only.
#[cfg(not(target_os = "windows"))]
const FUJIFILM_DISCOVER: Discover = Discover::NotOnThisPlatform;
#[cfg(not(target_os = "windows"))]
const FUJIFILM_SDK_PRESENT: Option<fn() -> bool> = Some(|| false);
#[cfg(not(target_os = "windows"))]
const FUJIFILM_OPEN: Open = Open::NotOnThisPlatform("Fujifilm cameras need the Windows build");
#[cfg(not(target_os = "windows"))]
const FUJIFILM_LENS_OPEN: Open = Open::NotOnThisPlatform("Fujifilm lenses need the Windows build");

#[cfg(target_os = "windows")]
const FUJIFILM_SDK_PRESENT: Option<fn() -> bool> = Some(crate::vendor::fujifilm::is_sdk_available);

/// The address is the body's serial number. A body that reports none at
/// enumeration is addressed by its product name. Every body is listed twice:
/// as a camera and as the focuser of its lens, which may have no electronic
/// focus; finding that out needs the body opened, which a scan never does.
#[cfg(target_os = "windows")]
const FUJIFILM_DISCOVER: Discover = Discover::Sdk(|| {
    Box::pin(async {
        let lens = FAMILIES
            .iter()
            .find(|f| f.kind == DeviceKind::Focuser && f.base == "fujifilm")
            .expect("the Fujifilm lens has a catalog row");
        Ok(crate::vendor::fujifilm::discover_devices()
            .await?
            .into_iter()
            .flat_map(|d| {
                let address = d.serial_number.clone().unwrap_or_else(|| d.name.clone());
                let lens_name = format!("{} lens", d.name);
                let lens_found = Found {
                    family: Some(lens),
                    ..found(
                        address.clone(),
                        lens_name.clone(),
                        display_name(&lens_name, d.serial_number.as_deref(), None),
                        d.serial_number.clone(),
                        d.firmware_version.clone(),
                    )
                };
                let display = display_name(&d.name, d.serial_number.as_deref(), None);
                [
                    found(
                        address,
                        d.name,
                        display,
                        d.serial_number,
                        d.firmware_version,
                    ),
                    lens_found,
                ]
            })
            .collect())
    })
});

/// The body must be in the SDK's current camera list: connecting opens it by
/// its place in that list, found from this address, and the sensor geometry
/// comes from the product name the list reports.
#[cfg(target_os = "windows")]
const FUJIFILM_OPEN: Open = Open::AfterDiscovery(|address, _name| {
    Box::pin(async move {
        let present = crate::vendor::fujifilm::discover_devices()
            .await
            .map_err(|e| BadAddress(format!("Fujifilm camera detection failed: {e}")))?;
        let info = present
            .into_iter()
            .find(|d| d.serial_number.as_deref().unwrap_or(&d.name) == address)
            .ok_or_else(|| BadAddress(format!("Fujifilm camera {address} is not attached")))?;
        Ok(NativeHandle::Camera(Box::new(
            crate::vendor::fujifilm::FujifilmCamera::new(&info),
        )))
    })
});

/// The lens is driven through the body's session, which the camera may
/// already hold; the body is found when it is opened.
#[cfg(target_os = "windows")]
const FUJIFILM_LENS_OPEN: Open = Open::Now(|r| {
    Ok(NativeHandle::Focuser(Box::new(
        crate::vendor::fujifilm::FujifilmLens::new(r.address, r.name),
    )))
});

fn fli_found(devices: Vec<crate::vendor::fli::FliDiscoveryInfo>) -> Vec<Found> {
    devices
        .into_iter()
        .map(|d| {
            let display = display_name(&d.name, d.serial_number.as_deref(), None);
            found(
                sanitize_port_name(&d.device_path),
                d.name,
                display,
                d.serial_number,
                d.sdk_version,
            )
        })
        .collect()
}

/// The baud rate found by the scan goes into the id: a 115200-baud OnStep
/// reopened at the LX200 default of 9600 times out on every command.
fn serial_found(port: &str, baud_rate: u32, name: String, firmware: Option<String>) -> Found {
    found(
        format!("{}:{}", sanitize_port_name(port), baud_rate),
        name.clone(),
        name,
        None,
        firmware,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The ids below are in saved equipment profiles. A change here strands
    /// every profile that names such a device.
    #[test]
    fn id_tokens_are_the_ones_profiles_hold() {
        let ids: Vec<String> = FAMILIES.iter().map(|f| f.device_id("0")).collect();
        let expected = vec![
            "native:zwo:0",
            "native:qhy:0",
            "native:playerone:0",
            "native:playerone_pw:0",
            "native:zwo_eaf:0",
            "native:zwo_efw:0",
            "native:qhy_cfw:0",
            "native:svbony:0",
            "native:atik:0",
            "native:atik_efw:0",
            "native:fli:0",
            "native:fli_focuser:0",
            "native:fli_fw:0",
            "native:touptek:0",
            "native:moravian:0",
            "native:fujifilm:0",
            "native:fujifilm_lens:0",
            "native:gphoto2:0",
            "native:skywatcher:0",
            "native:ioptron:0",
            "native:lx200:0",
            "native:meade:0",
            "native:onstep:0",
            "native:pegasus:0",
            "native:losmandy:0",
            "native:10micron:0",
        ];
        assert_eq!(ids, expected);
    }

    #[test]
    fn only_families_behind_a_vendor_sdk_have_a_presence_probe() {
        for family in FAMILIES {
            let needs_sdk = matches!(
                family.discover,
                Discover::Sdk(_) | Discover::NotOnThisPlatform
            );
            assert_eq!(family.sdk_present.is_some(), needs_sdk, "{}", family.noun);
        }
    }

    #[test]
    fn a_token_and_kind_name_one_family() {
        let pick = |token, kind| family(token, kind).map(|f| f.token());
        assert_eq!(pick("zwo", DeviceKind::Camera).as_deref(), Some("zwo"));
        assert_eq!(pick("zwo", DeviceKind::Focuser).as_deref(), Some("zwo_eaf"));
        assert_eq!(
            pick("zwo_eaf", DeviceKind::Focuser).as_deref(),
            Some("zwo_eaf")
        );
        assert_eq!(
            pick("zwo", DeviceKind::FilterWheel).as_deref(),
            Some("zwo_efw")
        );
        assert_eq!(
            pick("player_one", DeviceKind::Camera).as_deref(),
            Some("playerone")
        );
        assert_eq!(
            pick("playerone", DeviceKind::Camera).as_deref(),
            Some("playerone")
        );
        assert_eq!(
            pick("pegasus", DeviceKind::Mount).as_deref(),
            Some("pegasus")
        );
        assert_eq!(
            pick("fujifilm", DeviceKind::Camera).as_deref(),
            Some("fujifilm")
        );
        assert_eq!(
            pick("fujifilm", DeviceKind::Focuser).as_deref(),
            Some("fujifilm_lens")
        );
        assert_eq!(pick("fujifilm_lens", DeviceKind::Camera), None);
        assert_eq!(pick("zwo", DeviceKind::Guider).as_deref(), Some("zwo"));
        assert_eq!(pick("zwo_eaf", DeviceKind::Camera), None);
        assert_eq!(pick("nikon", DeviceKind::Camera), None);
    }

    #[test]
    fn ids_split_into_token_and_address() {
        assert_eq!(split_id("native:zwo:1"), Some(("zwo", "1")));
        assert_eq!(
            split_id("native:onstep:COM4:115200"),
            Some(("onstep", "COM4:115200"))
        );
        assert_eq!(split_id("native:zwo"), None);
        assert_eq!(split_id("ascom:ASCOM.Simulator.Telescope"), None);
    }

    #[test]
    fn serial_addresses_keep_the_scanned_baud_rate() {
        assert_eq!(
            port_and_baud("COM4:115200").unwrap(),
            ("COM4".to_string(), Some(115200))
        );
        assert_eq!(port_and_baud("COM3").unwrap(), ("COM3".to_string(), None));
        assert_eq!(
            port_and_baud("COM4:fast").unwrap_err().to_string(),
            "Invalid native mount baud rate: fast"
        );
    }

    #[tokio::test]
    async fn an_accessory_segment_is_not_part_of_the_address() {
        let eaf = family("zwo", DeviceKind::Focuser).unwrap();
        for address in ["3", "eaf:3"] {
            let handle = eaf
                .open(OpenRequest {
                    address,
                    name: "EAF",
                    site: std::sync::Arc::new(|| None),
                })
                .await
                .unwrap();
            assert!(matches!(handle, NativeHandle::Focuser(_)));
        }
        let err = eaf
            .open(OpenRequest {
                address: "x",
                name: "EAF",
                site: std::sync::Arc::new(|| None),
            })
            .await
            .err()
            .unwrap();
        assert_eq!(err.to_string(), "Invalid ZWO focuser ID");
    }

    #[test]
    fn fallback_labels_match_the_token() {
        assert_eq!(labels("zwo", None), Some(("ZWO", None)));
        assert_eq!(labels("zwo_eaf", None), Some(("ZWO", Some("EAF"))));
        assert_eq!(labels("zwo", Some("efw")), Some(("ZWO", Some("EFW"))));
        assert_eq!(labels("fli_fw", None), Some(("FLI", Some("Filter Wheel"))));
        assert_eq!(
            labels("fujifilm_lens", None),
            Some(("Fujifilm", Some("Lens")))
        );
        assert_eq!(labels("fujifilm", None), Some(("Fujifilm", None)));
        assert_eq!(labels("player_one", None), Some(("Player One", None)));
        assert_eq!(labels("atik", Some("efw")), Some(("Atik", None)));
        assert_eq!(labels("nikon", None), None);
    }
}
