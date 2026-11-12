//! Alpaca Focuser API implementation. What the members mean is decided in the
//! bridge, once for Alpaca and COM.

alpaca_device!(AlpacaFocuser, Focuser);

impl AlpacaFocuser {
    skotiq_device::ascom_focuser_members!(alpaca_member);
}
