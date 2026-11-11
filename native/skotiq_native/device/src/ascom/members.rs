//! The member-list language the ASCOM interface definitions are written in.
//!
//! Each device kind has one macro (`ascom_focuser_members!`, ...) holding its
//! member list. A transport crate invokes it with the name of its own
//! per-member macro, inside the `impl` block of its wrapper, and gets one
//! function per member. COM calls stay synchronous on the driver's apartment
//! thread and Alpaca calls stay `async`: the list is shared, the expansion is
//! the transport's.
//!
//! A member statement is one of
//!
//! ```text
//! get  rust_name() -> Type = "AscomName";                    property read
//! get  rust_name(p: Type = "ParamName") -> Type = "Name";    indexed property read
//! set  rust_name(p: Type) = "AscomName";                     property write
//! call rust_name(p: Type = "ParamName", ...) = "AscomName";  method
//! call rust_name(...) -> Type = "AscomName";                 method returning a value
//! get_date rust_name() = "AscomName";                        DateTime property read
//! set_date rust_name(p) = "AscomName";                       DateTime property write
//! ```
//!
//! - `"AscomName"` is the member name of the ASCOM standard. COM looks the
//!   member up by it; Alpaca uses it in lower case as the URL path.
//! - Parameters are listed in the positional order of the COM method, each
//!   with its ASCOM name, which is the Alpaca parameter name. A `set` takes
//!   one value, which Alpaca sends under the member's own name.
//! - `Type` is the value on the wire. `Type as Enum` marks an integer that is
//!   an ASCOM enumeration where a transport hands the typed value out
//!   (Alpaca does; COM returns the integer).
//! - A DateTime is an OLE Automation date (`f64`, `VT_DATE`) over COM and an
//!   ISO 8601 string over Alpaca.
//!
//! Options follow the member name in brackets, comma separated:
//!
//! - `long`, `very_long`: the operation can take minutes (a slew, a park, a
//!   shutter). Alpaca waits with its long or very long timeout and does not
//!   retry; COM calls are not timed here.
//! - `rust_args_reversed`: the Rust function takes its two parameters in the
//!   opposite order of the COM method (`(altitude, azimuth)` for the
//!   `(Azimuth, Altitude)` members), as its callers always have.
//! - `com_wrapped(name)`, `alpaca_wrapped(name)`: that transport generates
//!   the member as a private function `name`, and a hand-written function
//!   with the member's own name wraps it (a range check, a log line).
//! - `com_only`, `alpaca_only`: the other transport cannot carry the member
//!   (a setup dialog needs a desktop; a collection object has no VARIANT form
//!   here).
//!
//! Members that do not fit a statement are written by hand in each transport,
//! next to the generated ones: the camera's `ImageArray` (a SAFEARRAY over
//! COM, a JSON or ImageBytes download over Alpaca).

/// Expands member statements into one `$callback!` invocation per member.
#[macro_export]
macro_rules! ascom_members {
    ($callback:ident; $(
        $kind:ident $name:ident ( $($params:tt)* ) $(-> $ty:ty $(as $surface:ty)?)? = $member:literal $([ $($option:tt)* ])? ;
    )*) => {
        $(
            $crate::__ascom_member! {
                $callback; $kind $member ($($params)*) [$($ty $(, $surface)?)?];
                com($name, pub); alpaca($name, pub); timing(standard); order(positional);
                on(com alpaca); options($($($option)*)?)
            }
        )*
    };
}

/// Brings one member statement into the form the transports consume:
///
/// ```text
/// $callback! {
///     kind "AscomName" on(transports)
///     com(function, visibility) alpaca(function, visibility)
///     sig(p: Type [Enum] = "ParamName", ...)   parameters in Rust order
///     args(p, ...)                             the same in COM positional order
///     ret[Type, Enum]
///     timing(standard | long | very_long)
/// }
/// ```
#[doc(hidden)]
#[macro_export]
macro_rules! __ascom_member {
    ($callback:ident; $kind:ident $member:literal $params:tt $ret:tt;
     com $com:tt; alpaca $alpaca:tt; timing $timing:tt; order $order:tt; on $on:tt;
     options(long $(, $($rest:tt)*)?)) => {
        $crate::__ascom_member! {
            $callback; $kind $member $params $ret;
            com $com; alpaca $alpaca; timing(long); order $order; on $on;
            options($($($rest)*)?)
        }
    };
    ($callback:ident; $kind:ident $member:literal $params:tt $ret:tt;
     com $com:tt; alpaca $alpaca:tt; timing $timing:tt; order $order:tt; on $on:tt;
     options(very_long $(, $($rest:tt)*)?)) => {
        $crate::__ascom_member! {
            $callback; $kind $member $params $ret;
            com $com; alpaca $alpaca; timing(very_long); order $order; on $on;
            options($($($rest)*)?)
        }
    };
    ($callback:ident; $kind:ident $member:literal $params:tt $ret:tt;
     com $com:tt; alpaca $alpaca:tt; timing $timing:tt; order $order:tt; on $on:tt;
     options(rust_args_reversed $(, $($rest:tt)*)?)) => {
        $crate::__ascom_member! {
            $callback; $kind $member $params $ret;
            com $com; alpaca $alpaca; timing $timing; order(reversed); on $on;
            options($($($rest)*)?)
        }
    };
    ($callback:ident; $kind:ident $member:literal $params:tt $ret:tt;
     com $com:tt; alpaca $alpaca:tt; timing $timing:tt; order $order:tt; on $on:tt;
     options(com_wrapped($raw:ident) $(, $($rest:tt)*)?)) => {
        $crate::__ascom_member! {
            $callback; $kind $member $params $ret;
            com($raw, pub(self)); alpaca $alpaca; timing $timing; order $order; on $on;
            options($($($rest)*)?)
        }
    };
    ($callback:ident; $kind:ident $member:literal $params:tt $ret:tt;
     com $com:tt; alpaca $alpaca:tt; timing $timing:tt; order $order:tt; on $on:tt;
     options(alpaca_wrapped($raw:ident) $(, $($rest:tt)*)?)) => {
        $crate::__ascom_member! {
            $callback; $kind $member $params $ret;
            com $com; alpaca($raw, pub(self)); timing $timing; order $order; on $on;
            options($($($rest)*)?)
        }
    };
    ($callback:ident; $kind:ident $member:literal $params:tt $ret:tt;
     com $com:tt; alpaca $alpaca:tt; timing $timing:tt; order $order:tt; on $on:tt;
     options(com_only $(, $($rest:tt)*)?)) => {
        $crate::__ascom_member! {
            $callback; $kind $member $params $ret;
            com $com; alpaca $alpaca; timing $timing; order $order; on(com);
            options($($($rest)*)?)
        }
    };
    ($callback:ident; $kind:ident $member:literal $params:tt $ret:tt;
     com $com:tt; alpaca $alpaca:tt; timing $timing:tt; order $order:tt; on $on:tt;
     options(alpaca_only $(, $($rest:tt)*)?)) => {
        $crate::__ascom_member! {
            $callback; $kind $member $params $ret;
            com $com; alpaca $alpaca; timing $timing; order $order; on(alpaca);
            options($($($rest)*)?)
        }
    };

    ($callback:ident; set $member:literal ($p:ident : $pty:ty $(as $psurface:ty)?) [];
     com($com_fn:ident, $com_vis:vis); alpaca($alpaca_fn:ident, $alpaca_vis:vis);
     timing($timing:ident); order($order:ident); on($($on:ident)+); options()) => {
        $callback! {
            set $member on($($on)+)
            com($com_fn, $com_vis) alpaca($alpaca_fn, $alpaca_vis)
            sig($p : $pty [$($psurface)?] = $member) args($p) ret[] timing($timing)
        }
    };
    ($callback:ident; set_date $member:literal ($p:ident) [];
     com($com_fn:ident, $com_vis:vis); alpaca($alpaca_fn:ident, $alpaca_vis:vis);
     timing($timing:ident); order($order:ident); on($($on:ident)+); options()) => {
        $callback! {
            set_date $member on($($on)+)
            com($com_fn, $com_vis) alpaca($alpaca_fn, $alpaca_vis)
            sig($p) args($p) ret[] timing($timing)
        }
    };
    ($callback:ident; get_date $member:literal () [];
     com($com_fn:ident, $com_vis:vis); alpaca($alpaca_fn:ident, $alpaca_vis:vis);
     timing($timing:ident); order($order:ident); on($($on:ident)+); options()) => {
        $callback! {
            get_date $member on($($on)+)
            com($com_fn, $com_vis) alpaca($alpaca_fn, $alpaca_vis)
            sig() args() ret[] timing($timing)
        }
    };
    ($callback:ident; $kind:ident $member:literal
     ($a:ident : $aty:ty = $aname:literal, $b:ident : $bty:ty = $bname:literal) [$($ret:tt)*];
     com($com_fn:ident, $com_vis:vis); alpaca($alpaca_fn:ident, $alpaca_vis:vis);
     timing($timing:ident); order(reversed); on($($on:ident)+); options()) => {
        $callback! {
            $kind $member on($($on)+)
            com($com_fn, $com_vis) alpaca($alpaca_fn, $alpaca_vis)
            sig($b : $bty [] = $bname, $a : $aty [] = $aname) args($a, $b)
            ret[$($ret)*] timing($timing)
        }
    };
    ($callback:ident; $kind:ident $member:literal
     ($($p:ident : $pty:ty $(as $psurface:ty)? = $pname:literal),*) [$($ret:tt)*];
     com($com_fn:ident, $com_vis:vis); alpaca($alpaca_fn:ident, $alpaca_vis:vis);
     timing($timing:ident); order(positional); on($($on:ident)+); options()) => {
        $callback! {
            $kind $member on($($on)+)
            com($com_fn, $com_vis) alpaca($alpaca_fn, $alpaca_vis)
            sig($($p : $pty [$($psurface)?] = $pname),*) args($($p),*)
            ret[$($ret)*] timing($timing)
        }
    };
}

/// The type a transport that hands out typed enumerations returns: the
/// enumeration when the member has one, otherwise the wire type.
#[macro_export]
macro_rules! ascom_surface_type {
    ($wire:ty) => { $wire };
    ($wire:ty, $surface:ty) => { $surface };
}

/// Converts a wire value to the type [`ascom_surface_type!`] names.
#[macro_export]
macro_rules! ascom_surface_value {
    ($value:expr, $wire:ty) => {
        $value
    };
    ($value:expr, $wire:ty, $surface:ty) => {
        <$surface as $crate::ascom::FromWire<$wire>>::from_wire($value)
    };
}
