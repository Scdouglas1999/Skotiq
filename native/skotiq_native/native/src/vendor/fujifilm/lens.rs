//! The electronic lens on a Fujifilm body as a focuser, for autofocus with a
//! camera lens. It shares the body's SDK session with the camera.

use super::*;

/// The lens focus motor of one Fujifilm body, through the X SDK's
/// CapFocusPos / SetFocusPos / GetFocusPos (SDK Programming Reference
/// 4.2.1.37-39), driven as the owner's NINA plugin drives it.
#[derive(Debug)]
pub struct FujifilmLens {
    id: String,
    name: String,
    /// The body's catalog address: its serial number, or its product name
    /// when it reports none.
    address: String,
    session: Option<Arc<Session>>,
    /// `None` while disconnected.
    focus: Mutex<Option<LensFocus>>,
    /// The body's focus mode before connect switched it to manual, restored
    /// at disconnect.
    focus_mode_before: Option<c_long>,
}

impl FujifilmLens {
    pub fn new(address: &str, name: &str) -> Self {
        Self {
            id: format!("native:fujifilm_lens:{address}"),
            name: name.to_string(),
            address: address.to_string(),
            session: None,
            focus: Mutex::new(None),
            focus_mode_before: None,
        }
    }

    fn handle(&self) -> Result<XsdkHandle, DriverError> {
        self.session
            .as_ref()
            .map(|s| s.handle())
            .ok_or(DriverError::NotConnected)
    }

    fn read_pulse(&self, sdk: &FujifilmSdk) -> Result<i32, DriverError> {
        let handle = self.handle()?;
        let mut pulse: c_long = 0;
        // SAFETY: `handle` is the session's open handle; GetFocusPos writes one c_long (API_PARAM_GetFocusPos = 1 in every model header) and `&mut pulse` is a valid stack c_long.
        let result = unsafe {
            (sdk.get_prop)(
                handle,
                API_CODE_GET_FOCUS_POS,
                API_PARAM_ONE_VALUE,
                &mut pulse,
            )
        };
        if result != XSDK_COMPLETE {
            return Err(sdk_error(handle, sdk, "reading the lens focus position"));
        }
        Ok(pulse as i32)
    }

    /// Switch the body to manual focus for as long as the lens is connected:
    /// SetFocusPos is defined for manual focus, and in AF-S or AF-C the body
    /// refocuses at every half press, which the bulb exposure sequence makes.
    /// Returns the mode to restore.
    fn hold_manual_focus(&self, handle: XsdkHandle, sdk: &FujifilmSdk) -> Option<c_long> {
        let mode = focus_mode(handle, sdk).filter(|&mode| mode != SDK_FOCUS_MANUAL)?;
        // SAFETY: as above; SetFocusMode takes one c_long (API_PARAM_SetFocusMode = 1).
        let set = unsafe {
            (sdk.set_prop)(
                handle,
                API_CODE_SET_FOCUS_MODE,
                API_PARAM_ONE_VALUE,
                SDK_FOCUS_MANUAL,
            )
        };
        if set == XSDK_COMPLETE {
            tracing::info!(
                "Fujifilm {}: switched the camera to manual focus while the lens is in use",
                self.id
            );
            Some(mode)
        } else {
            tracing::warn!(
                "Fujifilm {}: {}. Set the camera's focus mode switch to M, or the camera \
                 refocuses on its own at every exposure.",
                self.id,
                sdk_error(handle, sdk, "switching to manual focus")
            );
            None
        }
    }

    fn restore_focus_mode(&self, handle: XsdkHandle, sdk: &FujifilmSdk, mode: c_long) {
        // SAFETY: `handle` is the session's open handle (the lens holds the session until it leaves); SetFocusMode takes one c_long (API_PARAM_SetFocusMode = 1).
        let result =
            unsafe { (sdk.set_prop)(handle, API_CODE_SET_FOCUS_MODE, API_PARAM_ONE_VALUE, mode) };
        if result != XSDK_COMPLETE {
            tracing::warn!(
                "Fujifilm {}: {}",
                self.id,
                sdk_error(handle, sdk, "restoring the camera's focus mode")
            );
        }
    }
}

fn focus_mode(handle: XsdkHandle, sdk: &FujifilmSdk) -> Option<c_long> {
    let mut mode: c_long = 0;
    // SAFETY: `handle` is the session's open handle; GetFocusMode writes one c_long (API_PARAM_GetFocusMode = 1).
    let read = unsafe {
        (sdk.get_prop)(
            handle,
            API_CODE_GET_FOCUS_MODE,
            API_PARAM_ONE_VALUE,
            &mut mode,
        )
    };
    (read == XSDK_COMPLETE).then_some(mode)
}

/// The lens' focus travel, or why there is none.
fn focus_travel(handle: XsdkHandle, sdk: &FujifilmSdk) -> Result<FocusTravel, DriverError> {
    let mut size = std::mem::size_of::<SdkFocusPosCap>() as c_long;
    let mut cap = SdkFocusPosCap {
        l_size_focus_pos_cap: size,
        l_struct_ver: SDK_FOCUS_POS_CAP_VERSION,
        ..SdkFocusPosCap::default()
    };
    // SAFETY: `handle` is the session's open handle; CapFocusPos is the CapProp form that takes the structure's size (in/out) and a pointer to it (API_PARAM_CapFocusPos = 2, SDK Programming Reference 4.2.1.37); both point to live stack values and `size` is the structure's size.
    let result = unsafe {
        (sdk.cap_prop)(
            handle,
            API_CODE_CAP_FOCUS_POS,
            API_PARAM_CAP_FOCUS_POS,
            &mut size,
            &mut cap,
        )
    };
    let no_focus = || {
        DriverError::InvalidDevice(
            "the lens on this Fujifilm camera has no electronic focus. Lens focus needs an \
             electronic Fujifilm lens; a telescope or manual lens has none."
                .to_string(),
        )
    };
    if result != XSDK_COMPLETE {
        return match sdk_error(handle, sdk, "reading the lens focus range") {
            DriverError::NotSupported | DriverError::InvalidParameter(_) => Err(no_focus()),
            other => Err(other),
        };
    }
    FocusTravel::from_capability(FocusCapability {
        infinity: cap.l_focus_pls_inf as i32,
        closest: cap.l_focus_pls_mod as i32,
        over_search_infinity: cap.l_focus_over_search_pls_inf as i32,
        over_search_closest: cap.l_focus_over_search_pls_mod as i32,
        depth_of_field: cap.l_focus_pls_fcs_depth_cap as i32,
        min_drive_step: cap.l_min_drive_step_mf_drive_end_thresh as i32,
    })
    .ok_or_else(no_focus)
}

#[async_trait]
impl DeviceDriver for FujifilmLens {
    fn id(&self) -> &str {
        &self.id
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn vendor(&self) -> Vendor {
        Vendor::Fujifilm
    }

    fn is_connected(&self) -> bool {
        self.session.is_some()
    }

    async fn connect(&mut self) -> Result<(), DriverError> {
        if self.is_connected() {
            return Ok(());
        }
        let sdk = FujifilmSdk::lock().await?;
        let session = session::join(&sdk, &self.address).await?;
        let handle = session.handle();
        // A body in AF-S or AF-C reports an empty focus range (owner's NINA
        // plugin 3.1.0.0, GFX100S II), so manual focus comes first.
        let focus_mode_before = self.hold_manual_focus(handle, &sdk);
        let travel = match focus_travel(handle, &sdk) {
            Ok(travel) => travel,
            Err(error) => {
                let in_autofocus =
                    focus_mode(handle, &sdk).is_some_and(|mode| mode != SDK_FOCUS_MANUAL);
                if let Some(mode) = focus_mode_before {
                    self.restore_focus_mode(handle, &sdk, mode);
                }
                session::leave(&sdk, &session);
                return Err(match error {
                    DriverError::InvalidDevice(_) if in_autofocus => DriverError::InvalidDevice(
                        "the camera stayed in autofocus, where it reports no lens focus range. \
                         Set the camera's focus mode switch to M and connect the lens again."
                            .to_string(),
                    ),
                    other => other,
                });
            }
        };
        self.focus_mode_before = focus_mode_before;
        tracing::info!(
            "Fujifilm {}: lens focus travel 0 to {}, infinity at {} with {} past it, smallest move {}",
            self.id,
            travel.range(),
            travel.infinity_position(),
            travel.past_infinity(),
            travel.step()
        );
        if travel.past_infinity() == 0 {
            tracing::warn!(
                "Fujifilm {}: this lens has no travel past infinity, so position 0 is the \
                 infinity stop. Keep autofocus steps small enough to stay above it.",
                self.id
            );
        }
        *lock(&self.focus) = Some(LensFocus::new(travel));
        self.session = Some(session);
        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), DriverError> {
        let Some(session) = self.session.take() else {
            return Ok(());
        };
        let sdk = FujifilmSdk::lock().await?;
        if let Some(mode) = self.focus_mode_before.take() {
            self.restore_focus_mode(session.handle(), &sdk, mode);
        }
        *lock(&self.focus) = None;
        session::leave(&sdk, &session);
        Ok(())
    }
}

impl Drop for FujifilmLens {
    /// A lens the bridge replaces without disconnecting it still gives up its
    /// hold on the body's session.
    fn drop(&mut self) {
        if let Some(session) = self.session.take() {
            session::leave_later(session);
        }
    }
}

#[async_trait]
impl FocuserDriver for FujifilmLens {
    async fn move_to(&mut self, position: i32) -> Result<(), DriverError> {
        let sdk = FujifilmSdk::lock().await?;
        let handle = self.handle()?;
        let current = self.read_pulse(&sdk)?;
        let pulse = {
            let mut focus = lock(&self.focus);
            let focus = focus.as_mut().ok_or(DriverError::NotConnected)?;
            focus
                .start_move(position, current, Instant::now())
                .map_err(DriverError::InvalidParameter)?
        };
        // SAFETY: `handle` is the session's open handle; SetFocusPos takes one c_long (API_PARAM_SetFocusPos = 1), a pulse inside the travel the lens reported.
        let result = unsafe {
            (sdk.set_prop)(
                handle,
                API_CODE_SET_FOCUS_POS,
                API_PARAM_ONE_VALUE,
                pulse as c_long,
            )
        };
        if result != XSDK_COMPLETE {
            if let Some(focus) = lock(&self.focus).as_mut() {
                focus.abandon_move();
            }
            return Err(sdk_error(handle, &sdk, "moving the lens focus"));
        }
        Ok(())
    }

    async fn move_relative(&mut self, steps: i32) -> Result<(), DriverError> {
        let position = self.get_position().await?;
        self.move_to(position.saturating_add(steps)).await
    }

    async fn get_position(&self) -> Result<i32, DriverError> {
        let sdk = FujifilmSdk::lock().await?;
        let pulse = self.read_pulse(&sdk)?;
        let mut focus = lock(&self.focus);
        let focus = focus.as_mut().ok_or(DriverError::NotConnected)?;
        Ok(focus.position(pulse))
    }

    /// Reads the lens until it reaches its target or stops; see
    /// `focus::LensFocus::observe`.
    async fn is_moving(&self) -> Result<bool, DriverError> {
        if !lock(&self.focus)
            .as_ref()
            .ok_or(DriverError::NotConnected)?
            .is_moving()
        {
            return Ok(false);
        }
        let sdk = FujifilmSdk::lock().await?;
        let pulse = self.read_pulse(&sdk)?;
        let mut focus = lock(&self.focus);
        let Some(end) = focus
            .as_mut()
            .ok_or(DriverError::NotConnected)?
            .observe(pulse, Instant::now())
        else {
            return Ok(true);
        };
        match end {
            MoveEnd::Arrived => {}
            MoveEnd::Settled { residual } => tracing::info!(
                "Fujifilm {}: the lens came to rest {residual} pulses from its target, as some \
                 lenses do; the focuser reports the target",
                self.id
            ),
            MoveEnd::DidNotMove => tracing::warn!(
                "Fujifilm {}: the lens did not move. Set the camera's focus mode to M and the \
                 lens' focus limiter to its full range.",
                self.id
            ),
        }
        Ok(false)
    }

    /// The SDK has no command that stops the lens; a move takes well under a
    /// second, so the lens finishes it.
    async fn halt(&mut self) -> Result<(), DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }
        tracing::debug!(
            "Fujifilm {}: the lens finishes its move (the SDK cannot stop it)",
            self.id
        );
        Ok(())
    }

    async fn get_temperature(&self) -> Result<Option<f64>, DriverError> {
        Ok(None)
    }

    fn get_max_position(&self) -> i32 {
        lock(&self.focus)
            .as_ref()
            .map_or(0, |focus| focus.travel().range())
    }

    /// Lens focus pulses have no known length in microns.
    fn get_step_size(&self) -> f64 {
        0.0
    }
}
