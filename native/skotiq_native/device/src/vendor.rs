//! Who made the device, as far as a driver can tell.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Vendor {
    Zwo,
    Qhy,
    PlayerOne,
    Svbony,
    Atik,
    Fli,
    Touptek,
    Moravian,
    Fujifilm,
    GPhoto2,
    /// A device reached through an ASCOM driver; the maker is not known.
    Ascom,
    /// A device reached through an INDI driver; the maker is not known.
    Indi,
    SkyWatcher,
    IOptron,
    Meade,
    Other(String),
}

impl Vendor {
    pub fn as_str(&self) -> &str {
        match self {
            Vendor::Zwo => "ZWO",
            Vendor::Qhy => "QHY",
            Vendor::PlayerOne => "PlayerOne",
            Vendor::Svbony => "SVBony",
            Vendor::Atik => "Atik",
            Vendor::Fli => "FLI",
            Vendor::Touptek => "Touptek",
            Vendor::Moravian => "Moravian",
            Vendor::Fujifilm => "Fujifilm",
            Vendor::GPhoto2 => "gPhoto2",
            Vendor::Ascom => "ASCOM",
            Vendor::Indi => "INDI",
            Vendor::SkyWatcher => "Sky-Watcher",
            Vendor::IOptron => "iOptron",
            Vendor::Meade => "Meade",
            Vendor::Other(s) => s,
        }
    }
}
