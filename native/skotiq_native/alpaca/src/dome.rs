//! Alpaca Dome API implementation

alpaca_device!(AlpacaDome, Dome);

impl AlpacaDome {
    skotiq_device::ascom_dome_members!(alpaca_member);
}
