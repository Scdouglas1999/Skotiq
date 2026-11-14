//! The rig devices (filter wheel, focuser, camera, mount) behind one handle
//! each: a `&self` trait per device type, implemented once per protocol.
//!
//! # Locks, in the one order they are taken
//!
//! 1. `DeviceManager::devices`: a registry lookup or a state write.
//! 2. `DeviceManager::reconnect_cancel_tokens`.
//! 3. `DeviceManager::handles`: a map lookup, insert or remove. A std lock, so
//!    its guard never crosses an `.await`.
//! 4. A device's own lock (a held [`Slot`], or `Exclusive` for an ASCOM COM
//!    wrapper), reached through a handle that was
//!    cloned out of `handles` first. Held for one driver call, never together
//!    with 1-3 and never two devices' at once.
//! 5. What a driver call takes inside itself: a vendor SDK mutex, the INDI
//!    client lock, a simulator singleton, the ASCOM command queue.
//!
//! # Long operations
//!
//! A move, slew or exposure is a start command followed by a poll loop in the
//! trait implementation. Each poll is one driver call and the loop sleeps
//! with no lock held, so a status read, a heartbeat, an abort or a disconnect
//! waits for at most the driver call in flight. Where a single driver call is
//! itself long (an ASCOM driver that blocks in `Move`, a frame download) it
//! holds up that device only, for at most the wrapper's timeout.
//!
//! An abort is one command under the device lock; the operation it interrupts
//! sees it at its next poll. A disconnect takes the handle out of the registry
//! and then closes the driver behind the call in flight; an operation still
//! polling holds its own reference to the closed driver and ends when the
//! driver answers that it is not connected (see [`closed`]).

pub(crate) mod ascom;
pub(crate) mod camera;
pub(crate) mod filter_wheel;
pub(crate) mod focuser;
pub(crate) mod mount;

use crate::device_manager::identity::DeviceIdentity;
use async_trait::async_trait;
use skotiq_device::DriverError;
use tokio::sync::{RwLock, RwLockMappedWriteGuard, RwLockReadGuard, RwLockWriteGuard};

/// What every rig device answers besides its own operations.
#[async_trait]
pub(crate) trait RigDriver: Send + Sync {
    async fn disconnect(&self) -> Result<(), DriverError>;

    /// One cheap call that tells whether the device still answers.
    /// `Ok(false)`: it did not, or it says it is not connected. `Err`: the
    /// probe failed, with the sentence the user is shown.
    async fn heartbeat(&self) -> Result<bool, String>;

    /// What the connected device says it is: its model, its serial number
    /// and, for a camera, its sensor. `None` where the protocol gives the
    /// driver nothing to say.
    async fn identity(&self) -> Option<DeviceIdentity> {
        None
    }
}

/// An ASCOM COM wrapper, shared by taking its lock for one call at a time:
/// `read` for a call that takes `&self`, `write` for one that takes
/// `&mut self`.
///
/// The wrappers only send commands to the STA worker and would work
/// unlocked. They stay behind the lock so that a read issued while a blocking
/// COM command runs waits here, with no timeout running, instead of timing out
/// in the worker's queue and counting as a failed read.
#[cfg(windows)]
pub(crate) struct Exclusive<D>(RwLock<D>);

#[cfg(windows)]
impl<D> Exclusive<D> {
    pub(crate) fn new(driver: D) -> Self {
        Self(RwLock::new(driver))
    }

    pub(crate) async fn read(&self) -> RwLockReadGuard<'_, D> {
        self.0.read().await
    }

    pub(crate) async fn write(&self) -> RwLockWriteGuard<'_, D> {
        self.0.write().await
    }
}

/// How a handle reaches its driver for one call.
///
/// The driver traits take `&mut self` for commands. A driver that keeps
/// state between calls (a vendor SDK or serial driver) is held behind its
/// lock, one call at a time, and can be taken out when the device is closed.
/// A client of a server that keeps the state (Alpaca, INDI) is made anew for
/// every call, so no call of the device waits for another: a status read or
/// an abort goes out while a park is still being answered.
pub(crate) enum Slot<D: ?Sized> {
    Held(RwLock<Option<Box<D>>>),
    PerCall(Box<dyn Fn() -> Box<D> + Send + Sync>),
}

/// A driver reached for a call that takes `&self`.
pub(crate) enum Shared<'a, D: ?Sized> {
    Held(RwLockReadGuard<'a, D>),
    Own(Box<D>),
}

/// A driver reached for a call that takes `&mut self`.
pub(crate) enum Mutable<'a, D: ?Sized> {
    Held(RwLockMappedWriteGuard<'a, D>),
    Own(Box<D>),
}

impl<D: ?Sized> Slot<D> {
    pub(crate) fn held(driver: Box<D>) -> Self {
        Slot::Held(RwLock::new(Some(driver)))
    }

    pub(crate) fn per_call(make: impl Fn() -> Box<D> + Send + Sync + 'static) -> Self {
        Slot::PerCall(Box::new(make))
    }

    /// `None` once the driver was taken out.
    pub(crate) async fn read(&self) -> Option<Shared<'_, D>> {
        match self {
            Slot::Held(lock) => RwLockReadGuard::try_map(lock.read().await, |slot| slot.as_deref())
                .ok()
                .map(Shared::Held),
            Slot::PerCall(make) => Some(Shared::Own(make())),
        }
    }

    /// `None` once the driver was taken out.
    pub(crate) async fn write(&self) -> Option<Mutable<'_, D>> {
        match self {
            Slot::Held(lock) => {
                RwLockWriteGuard::try_map(lock.write().await, |slot| slot.as_deref_mut())
                    .ok()
                    .map(Mutable::Held)
            }
            Slot::PerCall(make) => Some(Mutable::Own(make())),
        }
    }

    /// Takes a held driver out, behind the call in flight; every later call
    /// finds the slot empty. A per-call client is made for the caller and
    /// the slot stays as it is.
    pub(crate) async fn take(&self) -> Option<Box<D>> {
        match self {
            Slot::Held(lock) => lock.write().await.take(),
            Slot::PerCall(make) => Some(make()),
        }
    }
}

impl<D: ?Sized> std::ops::Deref for Shared<'_, D> {
    type Target = D;

    fn deref(&self) -> &D {
        match self {
            Shared::Held(guard) => guard,
            Shared::Own(driver) => driver,
        }
    }
}

impl<D: ?Sized> std::ops::Deref for Mutable<'_, D> {
    type Target = D;

    fn deref(&self) -> &D {
        match self {
            Mutable::Held(guard) => guard,
            Mutable::Own(driver) => driver,
        }
    }
}

impl<D: ?Sized> std::ops::DerefMut for Mutable<'_, D> {
    fn deref_mut(&mut self) -> &mut D {
        match self {
            Mutable::Held(guard) => guard,
            Mutable::Own(driver) => driver,
        }
    }
}

/// Whether a driver error says the device was closed, which ends an
/// operation's poll loop: polling a closed driver to the deadline would only
/// repeat the same answer.
pub(crate) fn closed(error: &DriverError) -> bool {
    matches!(error, DriverError::NotConnected | DriverError::Disconnected)
}
