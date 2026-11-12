//! Alpaca Rotator API implementation. What the members mean is decided in the
//! bridge, once for Alpaca and COM.

alpaca_device!(AlpacaRotator, Rotator);

impl AlpacaRotator {
    skotiq_device::ascom_rotator_members!(alpaca_member);
}
