//! How the ASCOM member lists of `skotiq_device::ascom` become Alpaca calls.
//!
//! `alpaca_member!` is the callback handed to the member-list macros: it
//! writes one `async` function per member. `alpaca_device!` writes the part
//! every device wrapper shares: the struct, its constructors, the connection
//! calls and the members common to all ASCOM devices.
//!
//! On the wire a property read is a GET of the member's path; a property
//! write is a PUT with one form field named after the member; a method is a
//! PUT with one form field per parameter; an indexed property and a method
//! that returns a value are GETs with query parameters. Values are formatted
//! with `to_string()` (`true`/`false`, shortest round-trip decimals).

/// Formats one parameter the way Alpaca expects it.
macro_rules! alpaca_param_text {
    ($value:ident, $wire:ty) => {
        $value.to_string()
    };
    // A typed enumeration is sent as its ASCOM number.
    ($value:ident, $wire:ty, $surface:ty) => {
        ($value as $wire).to_string()
    };
}

macro_rules! alpaca_put_wait {
    (standard) => {
        $crate::PutWait::Standard
    };
    (long) => {
        $crate::PutWait::Long
    };
    (very_long) => {
        $crate::PutWait::VeryLong
    };
}

macro_rules! alpaca_member {
    // Members only COM can carry.
    ($kind:ident $member:literal on(com) $($rest:tt)*) => {};

    (get $member:literal on($($on:ident)+) com $com:tt alpaca($name:ident, $vis:vis)
     sig() args() ret[$wire:ty $(, $surface:ty)?] timing($timing:ident)) => {
        $vis async fn $name(
            &self,
        ) -> Result<skotiq_device::ascom_surface_type!($wire $(, $surface)?), $crate::AlpacaError> {
            let value: $wire = self.client.get($member).await?;
            Ok(skotiq_device::ascom_surface_value!(value, $wire $(, $surface)?))
        }
    };
    (get $member:literal on($($on:ident)+) com $com:tt alpaca($name:ident, $vis:vis)
     sig($($p:ident : $pty:ty [$($psurface:ty)?] = $pname:literal),+) args $args:tt
     ret[$wire:ty $(, $surface:ty)?] timing($timing:ident)) => {
        $vis async fn $name(
            &self,
            $($p: skotiq_device::ascom_surface_type!($pty $(, $psurface)?)),+
        ) -> Result<skotiq_device::ascom_surface_type!($wire $(, $surface)?), $crate::AlpacaError> {
            let value: $wire = self
                .client
                .get_with_params(
                    $member,
                    &[$(($pname, &alpaca_param_text!($p, $pty $(, $psurface)?))),+],
                )
                .await?;
            Ok(skotiq_device::ascom_surface_value!(value, $wire $(, $surface)?))
        }
    };
    (set $member:literal on($($on:ident)+) com $com:tt alpaca($name:ident, $vis:vis)
     sig($p:ident : $pty:ty [$($psurface:ty)?] = $pname:literal) args $args:tt
     ret[] timing($timing:ident)) => {
        $vis async fn $name(
            &self,
            $p: skotiq_device::ascom_surface_type!($pty $(, $psurface)?),
        ) -> Result<(), $crate::AlpacaError> {
            self.client
                .put($member, &[($pname, &alpaca_param_text!($p, $pty $(, $psurface)?))])
                .await
        }
    };
    (call $member:literal on($($on:ident)+) com $com:tt alpaca($name:ident, $vis:vis)
     sig($($p:ident : $pty:ty [$($psurface:ty)?] = $pname:literal),*) args $args:tt
     ret[] timing($timing:ident)) => {
        $vis async fn $name(
            &self,
            $($p: skotiq_device::ascom_surface_type!($pty $(, $psurface)?)),*
        ) -> Result<(), $crate::AlpacaError> {
            self.client
                .put_with(
                    $member,
                    &[$(($pname, &alpaca_param_text!($p, $pty $(, $psurface)?))),*],
                    alpaca_put_wait!($timing),
                )
                .await
        }
    };
    (call $member:literal on($($on:ident)+) com $com:tt alpaca($name:ident, $vis:vis)
     sig($($p:ident : $pty:ty [$($psurface:ty)?] = $pname:literal),+) args $args:tt
     ret[$wire:ty $(, $surface:ty)?] timing($timing:ident)) => {
        alpaca_member! {
            get $member on($($on)+) com $com alpaca($name, $vis)
            sig($($p : $pty [$($psurface)?] = $pname),+) args $args
            ret[$wire $(, $surface)?] timing($timing)
        }
    };
    // An ASCOM DateTime is an ISO 8601 string in Alpaca.
    (get_date $member:literal on($($on:ident)+) com $com:tt alpaca($name:ident, $vis:vis)
     sig() args() ret[] timing($timing:ident)) => {
        $vis async fn $name(&self) -> Result<String, $crate::AlpacaError> {
            self.client.get($member).await
        }
    };
    (set_date $member:literal on($($on:ident)+) com $com:tt alpaca($name:ident, $vis:vis)
     sig($p:ident) args $args:tt ret[] timing($timing:ident)) => {
        $vis async fn $name(&self, $p: &str) -> Result<(), $crate::AlpacaError> {
            self.client.put($member, &[($member, $p)]).await
        }
    };
}

/// Declares an Alpaca device wrapper with everything the ten kinds share.
/// A kind may add fields of its own, each starting from its `Default`.
macro_rules! alpaca_device {
    ($(#[$meta:meta])* $name:ident, $device_type:ident $(, { $($field:ident : $fty:ty),* $(,)? })?) => {
        $(#[$meta])*
        pub struct $name {
            client: $crate::AlpacaClient,
            $($($field: $fty,)*)?
        }

        impl $name {
            pub fn new(device: &$crate::AlpacaDevice) -> Self {
                assert_eq!(device.device_type, skotiq_device::ascom::AscomDeviceType::$device_type);
                Self {
                    client: $crate::AlpacaClient::new(device),
                    $($($field: Default::default(),)*)?
                }
            }

            /// Create from server details
            pub fn from_server(base_url: &str, device_number: u32) -> Self {
                let device = $crate::AlpacaDevice::from_server(
                    skotiq_device::ascom::AscomDeviceType::$device_type,
                    base_url,
                    device_number,
                );
                Self::new(&device)
            }

            pub fn client(&self) -> &$crate::AlpacaClient {
                &self.client
            }

            pub fn base_url(&self) -> &str {
                self.client.base_url()
            }

            pub fn device_number(&self) -> u32 {
                self.client.device_number()
            }

            pub async fn connect(&self) -> Result<(), $crate::AlpacaError> {
                self.client.connect().await
            }

            pub async fn disconnect(&self) -> Result<(), $crate::AlpacaError> {
                self.client.disconnect().await
            }

            pub async fn is_connected(&self) -> Result<bool, $crate::AlpacaError> {
                self.client.is_connected().await
            }

            /// Check the connection with one quick, unretried read.
            pub async fn validate_connection(&self) -> Result<bool, $crate::AlpacaError> {
                self.client.validate_connection().await
            }

            /// Round-trip time of one quick read, in milliseconds.
            pub async fn heartbeat(&self) -> Result<u64, $crate::AlpacaError> {
                self.client.heartbeat().await
            }

            skotiq_device::ascom_common_members!(alpaca_member);
        }
    };
}
