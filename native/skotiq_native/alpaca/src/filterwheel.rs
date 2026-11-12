//! Alpaca Filter Wheel API implementation. What the members mean is decided
//! in the bridge, once for Alpaca and COM.

alpaca_device!(AlpacaFilterWheel, FilterWheel);

impl AlpacaFilterWheel {
    skotiq_device::ascom_filter_wheel_members!(alpaca_member);
}
