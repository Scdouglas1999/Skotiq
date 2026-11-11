//! Alpaca Observing Conditions (Weather Station) API implementation

alpaca_device!(
    /// Alpaca Observing Conditions client
    AlpacaObservingConditions,
    ObservingConditions
);

impl AlpacaObservingConditions {
    skotiq_device::ascom_observing_conditions_members!(alpaca_member);
}
