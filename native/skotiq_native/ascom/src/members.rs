//! How the ASCOM member lists of `skotiq_device::ascom` become COM calls.
//!
//! `com_member!` is the callback handed to the member-list macros: it writes
//! one synchronous function per member, each a single call through
//! [`ComDispatch`](crate::com::ComDispatch). `com_device!` writes the part
//! every device wrapper shares: the struct, its constructors, the connection
//! calls and the members common to all ASCOM devices.
//!
//! The VARIANT type of an argument follows from its Rust type (`i32` is
//! `VT_I4`, `f64` is `VT_R8`, `bool` is `VT_BOOL`, `&str` is `VT_BSTR`, a
//! DateTime is `VT_DATE`), and arguments are passed in the positional order
//! of the member list. COM returns ASCOM enumerations as plain integers.

macro_rules! com_member {
    // Members only Alpaca can carry.
    ($kind:ident $member:literal on(alpaca) $($rest:tt)*) => {};

    (get $member:literal on($($on:ident)+) com($name:ident, $vis:vis) alpaca $alpaca:tt
     sig() args() ret[$wire:ty $(, $surface:ty)?] timing $timing:tt) => {
        $vis fn $name(&self) -> $crate::AscomResult<$wire> {
            self.device.get($member)
        }
    };
    (get $member:literal on($($on:ident)+) com($name:ident, $vis:vis) alpaca $alpaca:tt
     sig($($p:ident : $pty:ty [$($psurface:ty)?] = $pname:literal),+) args($($arg:ident),+)
     ret[$wire:ty $(, $surface:ty)?] timing $timing:tt) => {
        $vis fn $name(&self, $($p: $pty),+) -> $crate::AscomResult<$wire> {
            self.device.get_indexed($member, &[$($arg.into()),+])
        }
    };
    (set $member:literal on($($on:ident)+) com($name:ident, $vis:vis) alpaca $alpaca:tt
     sig($p:ident : $pty:ty [$($psurface:ty)?] = $pname:literal) args $args:tt
     ret[] timing $timing:tt) => {
        $vis fn $name(&self, $p: $pty) -> $crate::AscomResult<()> {
            self.device.put($member, $p)
        }
    };
    (call $member:literal on($($on:ident)+) com($name:ident, $vis:vis) alpaca $alpaca:tt
     sig($($p:ident : $pty:ty [$($psurface:ty)?] = $pname:literal),*) args($($arg:ident),*)
     ret[] timing $timing:tt) => {
        $vis fn $name(&self, $($p: $pty),*) -> $crate::AscomResult<()> {
            self.device.call($member, &[$($arg.into()),*])
        }
    };
    (call $member:literal on($($on:ident)+) com($name:ident, $vis:vis) alpaca $alpaca:tt
     sig($($p:ident : $pty:ty [$($psurface:ty)?] = $pname:literal),*) args($($arg:ident),*)
     ret[$wire:ty $(, $surface:ty)?] timing $timing:tt) => {
        $vis fn $name(&self, $($p: $pty),*) -> $crate::AscomResult<$wire> {
            self.device.call($member, &[$($arg.into()),*])
        }
    };
    // An ASCOM DateTime is an OLE Automation date (days since 1899-12-30).
    (get_date $member:literal on($($on:ident)+) com($name:ident, $vis:vis) alpaca $alpaca:tt
     sig() args() ret[] timing $timing:tt) => {
        $vis fn $name(&self) -> $crate::AscomResult<f64> {
            self.device
                .get::<$crate::com::OleDate>($member)
                .map(|date| date.0)
        }
    };
    (set_date $member:literal on($($on:ident)+) com($name:ident, $vis:vis) alpaca $alpaca:tt
     sig($p:ident) args $args:tt ret[] timing $timing:tt) => {
        $vis fn $name(&self, $p: f64) -> $crate::AscomResult<()> {
            self.device.put($member, $crate::com::OleDate($p))
        }
    };
}

/// Declares an ASCOM device wrapper with everything the ten kinds share.
macro_rules! com_device {
    ($(#[$meta:meta])* $name:ident) => {
        $(#[$meta])*
        pub struct $name<D> {
            pub(crate) device: D,
        }

        #[cfg(windows)]
        impl $name<$crate::windows::AscomDeviceConnection> {
            /// Create the driver's COM object. Call on the thread that
            /// initialized COM; every later call must stay on it.
            pub fn new(prog_id: &str) -> $crate::AscomResult<Self> {
                Ok(Self {
                    device: $crate::windows::AscomDeviceConnection::new(prog_id)?,
                })
            }
        }

        impl<D: $crate::com::ComDispatch> $name<D> {
            /// Wrap a connection that already exists.
            pub fn over(device: D) -> Self {
                Self { device }
            }

            pub fn connect(&mut self) -> $crate::AscomResult<()> {
                self.device.connect()
            }

            pub fn disconnect(&mut self) -> $crate::AscomResult<()> {
                self.device.disconnect()
            }

            /// Query the underlying ASCOM driver for its current `Connected` state.
            ///
            /// Used by capability probes that must NOT kick an active UI connection:
            /// if the driver reports `Ok(true)`, the probe reuses the connection
            /// instead of opening/closing its own session.
            pub fn is_connected(&self) -> $crate::AscomResult<bool> {
                self.device.get("Connected")
            }

            pub fn heartbeat(&self) -> $crate::AscomResult<()> {
                self.device.heartbeat()
            }

            pub fn get_health(&self) -> $crate::ConnectionHealth {
                self.device.health()
            }

            skotiq_device::ascom_common_members!(com_member);
        }
    };
}
