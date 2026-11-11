//! What an ASCOM COM call consists of, independent of the Windows COM plumbing.
//!
//! A device wrapper describes a call as a [`ComCall`]: the member name, how it
//! is dispatched, the typed arguments in positional order and the type of the
//! value it expects back. [`ComDispatch`] carries it out. On Windows that is
//! `AscomDeviceConnection`, which turns the call into one `IDispatch::Invoke`;
//! the tests use a recording stand-in, so the wrappers are checked on any host.

use crate::error::{AscomError, AscomResult};
use crate::health::ConnectionHealth;

/// One argument of a COM call. The variant is the VARIANT type the driver
/// receives, which real drivers are sensitive to.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ComArg<'a> {
    /// `VT_BOOL`
    Bool(bool),
    /// `VT_I4`
    I4(i32),
    /// `VT_R8`
    R8(f64),
    /// `VT_DATE`: an OLE Automation date (days since 1899-12-30).
    Date(f64),
    /// `VT_BSTR`
    Bstr(&'a str),
}

impl From<bool> for ComArg<'_> {
    fn from(value: bool) -> Self {
        ComArg::Bool(value)
    }
}

impl From<i32> for ComArg<'_> {
    fn from(value: i32) -> Self {
        ComArg::I4(value)
    }
}

impl From<f64> for ComArg<'_> {
    fn from(value: f64) -> Self {
        ComArg::R8(value)
    }
}

impl<'a> From<&'a str> for ComArg<'a> {
    fn from(value: &'a str) -> Self {
        ComArg::Bstr(value)
    }
}

/// The type of value a call expects back.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ComKind {
    /// Nothing is read back.
    Void,
    Bool,
    /// Any COM integer the driver returns (`VT_I4`, `VT_I2`, `VT_UI2`, or a
    /// `VT_R8` holding a whole number), as `i32`.
    I4,
    /// Any COM number (`VT_R8`, `VT_R4`, `VT_I4`, `VT_I2`, `VT_UI2`), as `f64`.
    R8,
    /// `VT_DATE` only.
    Date,
    Bstr,
    /// A SAFEARRAY of strings.
    BstrArray,
    /// A one- or two-dimensional SAFEARRAY of integers.
    I4Array,
}

/// How a member is invoked.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Dispatch {
    /// `DISPATCH_PROPERTYGET`
    Get,
    /// `DISPATCH_PROPERTYPUT`
    Put,
    /// `DISPATCH_METHOD`
    Method,
}

/// One call on an ASCOM driver.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ComCall<'a> {
    pub dispatch: Dispatch,
    /// The member name the driver's DISPID is looked up by.
    pub member: &'a str,
    /// Arguments in positional order.
    pub args: &'a [ComArg<'a>],
    pub returns: ComKind,
}

impl ComCall<'_> {
    /// The driver has no such member.
    pub fn unknown_member(&self, cause: String) -> AscomError {
        AscomError::UnknownMember {
            member: self.member.to_string(),
            cause,
        }
    }

    /// The driver refused or failed this call.
    pub fn invoke_error(&self, cause: String) -> AscomError {
        AscomError::Invoke {
            dispatch: self.dispatch,
            member: self.member.to_string(),
            cause,
        }
    }

    /// The driver answered this call with the wrong type.
    pub fn type_error(&self, vt: u16, detail: Option<String>) -> AscomError {
        AscomError::UnexpectedType {
            dispatch: self.dispatch,
            member: self.member.to_string(),
            expected: self.returns,
            vt,
            detail,
        }
    }
}

/// A value a driver returned, already copied out of its VARIANT.
#[derive(Debug, Clone, PartialEq)]
pub enum ComValue {
    Empty,
    Bool(bool),
    I4(i32),
    R8(f64),
    Date(f64),
    Bstr(String),
    BstrArray(Vec<String>),
    /// The flattened elements and the two dimension sizes (the second is 1
    /// for a one-dimensional array).
    I4Array {
        data: Vec<i32>,
        dim1: usize,
        dim2: usize,
    },
}

/// A Rust type a call can return.
pub trait ComReturn: Sized {
    const KIND: ComKind;
    fn from_value(value: ComValue) -> Option<Self>;
}

impl ComReturn for () {
    const KIND: ComKind = ComKind::Void;
    fn from_value(value: ComValue) -> Option<Self> {
        matches!(value, ComValue::Empty).then_some(())
    }
}

impl ComReturn for bool {
    const KIND: ComKind = ComKind::Bool;
    fn from_value(value: ComValue) -> Option<Self> {
        match value {
            ComValue::Bool(v) => Some(v),
            _ => None,
        }
    }
}

impl ComReturn for i32 {
    const KIND: ComKind = ComKind::I4;
    fn from_value(value: ComValue) -> Option<Self> {
        match value {
            ComValue::I4(v) => Some(v),
            _ => None,
        }
    }
}

impl ComReturn for f64 {
    const KIND: ComKind = ComKind::R8;
    fn from_value(value: ComValue) -> Option<Self> {
        match value {
            ComValue::R8(v) => Some(v),
            _ => None,
        }
    }
}

/// An OLE Automation date (days since 1899-12-30), read from and written as
/// `VT_DATE`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct OleDate(pub f64);

impl ComReturn for OleDate {
    const KIND: ComKind = ComKind::Date;
    fn from_value(value: ComValue) -> Option<Self> {
        match value {
            ComValue::Date(v) => Some(OleDate(v)),
            _ => None,
        }
    }
}

impl<'a> From<OleDate> for ComArg<'a> {
    fn from(value: OleDate) -> Self {
        ComArg::Date(value.0)
    }
}

impl ComReturn for String {
    const KIND: ComKind = ComKind::Bstr;
    fn from_value(value: ComValue) -> Option<Self> {
        match value {
            ComValue::Bstr(v) => Some(v),
            _ => None,
        }
    }
}

impl ComReturn for Vec<String> {
    const KIND: ComKind = ComKind::BstrArray;
    fn from_value(value: ComValue) -> Option<Self> {
        match value {
            ComValue::BstrArray(v) => Some(v),
            _ => None,
        }
    }
}

impl ComReturn for Vec<i32> {
    const KIND: ComKind = ComKind::I4Array;
    fn from_value(value: ComValue) -> Option<Self> {
        match value {
            ComValue::I4Array { data, .. } => Some(data),
            _ => None,
        }
    }
}

/// An integer array with its two dimension sizes, as `ImageArray` returns it.
impl ComReturn for (Vec<i32>, usize, usize) {
    const KIND: ComKind = ComKind::I4Array;
    fn from_value(value: ComValue) -> Option<Self> {
        match value {
            ComValue::I4Array { data, dim1, dim2 } => Some((data, dim1, dim2)),
            _ => None,
        }
    }
}

/// Something that can carry out ASCOM COM calls for one device.
///
/// Everything a wrapper sends a driver goes through [`invoke`](Self::invoke);
/// `get`, `get_indexed`, `put` and `call` only build the [`ComCall`].
pub trait ComDispatch {
    /// Carry out one call and return the value copied out of the reply.
    fn invoke(&self, call: &ComCall<'_>) -> AscomResult<ComValue>;

    /// Set `Connected = true` and confirm the driver agrees.
    fn connect(&mut self) -> AscomResult<()>;

    /// Set `Connected = false`.
    fn disconnect(&mut self) -> AscomResult<()>;

    /// Read `Connected` and record the outcome in the health monitor.
    fn heartbeat(&self) -> AscomResult<()>;

    fn health(&self) -> ConnectionHealth;

    /// Invoke `call` and convert the reply to `T`.
    fn invoke_as<T: ComReturn>(&self, call: &ComCall<'_>) -> AscomResult<T> {
        let value = self.invoke(call)?;
        T::from_value(value).ok_or_else(|| call.type_error(0, None))
    }

    /// Read a property.
    fn get<T: ComReturn>(&self, member: &str) -> AscomResult<T> {
        self.get_indexed(member, &[])
    }

    /// Read a property that takes arguments (ASCOM indexed properties such as
    /// `TimeSinceLastUpdate(PropertyName)`).
    fn get_indexed<T: ComReturn>(&self, member: &str, args: &[ComArg<'_>]) -> AscomResult<T> {
        self.invoke_as(&ComCall {
            dispatch: Dispatch::Get,
            member,
            args,
            returns: T::KIND,
        })
    }

    /// Write a property.
    fn put<'a>(&self, member: &str, value: impl Into<ComArg<'a>>) -> AscomResult<()> {
        self.invoke_as(&ComCall {
            dispatch: Dispatch::Put,
            member,
            args: &[value.into()],
            returns: ComKind::Void,
        })
    }

    /// Call a method. With `T = ()` no result is requested from the driver.
    fn call<T: ComReturn>(&self, member: &str, args: &[ComArg<'_>]) -> AscomResult<T> {
        self.invoke_as(&ComCall {
            dispatch: Dispatch::Method,
            member,
            args,
            returns: T::KIND,
        })
    }
}
