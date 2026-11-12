//! The ASCOM error numbers that name a kind of failure.
//!
//! An Alpaca server sends the number as `ErrorNumber` (`0x400`-`0xFFF`); a COM
//! driver raises the same number as its exception's `scode`, offset by
//! `0x80040000`. Both transports classify through [`classify_error_number`].

use crate::DriverError;

const NOT_IMPLEMENTED: i32 = 0x400;
const INVALID_VALUE: i32 = 0x401;
const NOT_CONNECTED: i32 = 0x407;
const ACTION_NOT_IMPLEMENTED: i32 = 0x40C;

/// The driver error an ASCOM error number stands for, in either the Alpaca or
/// the COM form, or `None` when the number names a failure the app treats
/// like any other driver fault. `message` is the driver's own account.
pub fn classify_error_number(number: i32, message: &str) -> Option<DriverError> {
    let number = match number as u32 {
        0x8004_0400..=0x8004_0FFF => (number as u32 - 0x8004_0000) as i32,
        _ => number,
    };
    match number {
        NOT_CONNECTED => Some(DriverError::NotConnected),
        NOT_IMPLEMENTED | ACTION_NOT_IMPLEMENTED => Some(DriverError::NotSupported),
        INVALID_VALUE => Some(DriverError::InvalidParameter(message.to_string())),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn both_transports_name_the_same_failures() {
        for (alpaca, com) in [
            (0x407, 0x8004_0407_u32),
            (0x400, 0x8004_0400),
            (0x401, 0x8004_0401),
        ] {
            let over_http = classify_error_number(alpaca, "said the driver");
            let over_com = classify_error_number(com as i32, "said the driver");
            assert_eq!(
                std::mem::discriminant(over_http.as_ref().expect("classified")),
                std::mem::discriminant(over_com.as_ref().expect("classified")),
            );
        }
        assert!(matches!(
            classify_error_number(0x407, ""),
            Some(DriverError::NotConnected)
        ));
        assert!(matches!(
            classify_error_number(0x40C, ""),
            Some(DriverError::NotSupported)
        ));
        assert!(matches!(
            classify_error_number(0x401, "Dec out of range"),
            Some(DriverError::InvalidParameter(message)) if message == "Dec out of range"
        ));
    }

    /// Parked, slaved and invalid-operation refusals are the driver's to
    /// explain; the app has no separate handling for them.
    #[test]
    fn other_numbers_stay_driver_faults() {
        for number in [0x402, 0x408, 0x409, 0x40B, 0x500, 0x8004_0408_u32 as i32, 1] {
            assert!(classify_error_number(number, "").is_none(), "{number:#x}");
        }
    }
}
