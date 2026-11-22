//! The app's one link to PHD2 and the rules that keep its users apart.
//!
//! Three things move a link on: a connect or disconnect the app asks for
//! (the link generation), each client [`super::connect_endpoint`] opens (the
//! client epoch), and each stop or disconnect (the stop generation). A
//! reconnect after a lost socket, a settle wait and an equipment reconnect
//! each check the one that ends them.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex, OnceLock};
use tokio::sync::{Mutex, RwLock};

type ClientSlot = Arc<RwLock<Option<skotiq_phd2::Phd2Client>>>;

pub(super) struct Phd2Link {
    client: OnceLock<ClientSlot>,
    /// Bumped by every connect and disconnect the app asks for. A reconnect
    /// started for one link stops when it changes: the user disconnected, or
    /// connected again on their own.
    generation: AtomicU64,
    /// Where the last connect reached PHD2.
    endpoint: StdMutex<Option<(String, u16)>>,
    /// Numbers each client opened, so a lost connection is recovered once
    /// however many times its loss is reported.
    client_epoch: AtomicU64,
    /// The client whose lost connection a reconnect is recovering.
    recovering_epoch: AtomicU64,
    /// A PHD2 equipment reconnect is running.
    reconnecting_equipment: AtomicBool,
    /// Serializes the PHD2 operations that start guiding or move the guide
    /// star: a fresh star selection, a start with its settle, and a dither
    /// with its settle. PHD2 refuses a `guide` while an earlier guide or
    /// dither is still settling ("Cannot initiate guide while guide is in
    /// progress"), and a selection that stops capture under a running start
    /// breaks both. A stop never waits for this lock: it is how a running
    /// settle is ended.
    pub(super) guide_ops: Mutex<()>,
    /// Bumped by every stop and disconnect. A settle wait that sees it
    /// change ends at once instead of running out its timeout.
    stop_generation: AtomicU64,
}

pub(super) static LINK: Phd2Link = Phd2Link {
    client: OnceLock::new(),
    generation: AtomicU64::new(0),
    endpoint: StdMutex::new(None),
    client_epoch: AtomicU64::new(0),
    recovering_epoch: AtomicU64::new(0),
    reconnecting_equipment: AtomicBool::new(false),
    guide_ops: Mutex::const_new(()),
    stop_generation: AtomicU64::new(0),
};

impl Phd2Link {
    pub(super) fn client(&'static self) -> &'static ClientSlot {
        self.client.get_or_init(|| Arc::new(RwLock::new(None)))
    }

    /// The app asked for a connect or a disconnect.
    pub(super) fn new_generation(&self) {
        self.generation.fetch_add(1, Ordering::SeqCst);
    }

    pub(super) fn generation(&self) -> u64 {
        self.generation.load(Ordering::SeqCst)
    }

    /// A client is being opened to `host`:`port`; its epoch.
    pub(super) fn open_client(&self, host: &str, port: u16) -> u64 {
        let epoch = self.client_epoch.fetch_add(1, Ordering::SeqCst) + 1;
        *self.endpoint.lock().unwrap_or_else(|p| p.into_inner()) = Some((host.to_string(), port));
        epoch
    }

    pub(super) fn endpoint(&self) -> Option<(String, u16)> {
        self.endpoint
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .clone()
    }

    /// Whether the loss of the client of `epoch` is this caller's to
    /// recover: it is the current client and nobody recovers it yet.
    pub(super) fn claim_recovery(&self, epoch: u64) -> bool {
        self.client_epoch.load(Ordering::SeqCst) == epoch
            && self.recovering_epoch.swap(epoch, Ordering::SeqCst) != epoch
    }

    /// Whether the client of `epoch` is still the link of `generation`:
    /// nothing the app asked for replaced it.
    pub(super) fn unchanged(&self, epoch: u64, generation: u64) -> bool {
        self.client_epoch.load(Ordering::SeqCst) == epoch && self.generation() == generation
    }

    /// Whether this caller may start an equipment reconnect: none is running.
    pub(super) fn begin_equipment_reconnect(&self) -> bool {
        !self.reconnecting_equipment.swap(true, Ordering::SeqCst)
    }

    pub(super) fn end_equipment_reconnect(&self) {
        self.reconnecting_equipment.store(false, Ordering::SeqCst);
    }

    /// A stop or disconnect: settle waits end.
    pub(super) fn stop(&self) {
        self.stop_generation.fetch_add(1, Ordering::SeqCst);
    }

    pub(super) fn stop_generation(&self) -> u64 {
        self.stop_generation.load(Ordering::SeqCst)
    }
}
