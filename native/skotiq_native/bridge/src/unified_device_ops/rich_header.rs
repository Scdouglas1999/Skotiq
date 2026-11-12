use super::*;

/// Assemble the rich FITS header for a sequencer-saved frame.
///
/// Separate from `save_fits` so the pointing decision is exercisable without a
/// connected mount — reading the mount is the only thing `save_fits` adds.
pub(crate) fn build_rich_header(
    image_data: &ImageData,
    frame_ctx: &skotiq_sequencer::scheduling::FrameContext,
    pointing: Option<MountPointing>,
) -> crate::frame_header::FrameHeader {
    let mut header = crate::frame_header::FrameHeader::from_frame_context(frame_ctx);

    // The `FrameContext` wins over `ImageData` for every value the two both
    // carry, because the context is also what the `captured_images` row is
    // written from — one source, so a card and its column cannot disagree
    // about one frame. `ImageData` remains the fallback for callers that hand
    // us a context with the field unset, which would otherwise lose the
    // keyword outright. Gain and offset have no fallback: the context holds
    // the frame's own, and `None` there means the camera has no such control.
    if header.ccd_temp.is_none() {
        header.ccd_temp = image_data.temperature;
    }
    if frame_ctx.duration_secs <= 0.0 {
        header.exposure_time = image_data.exposure_secs;
    }

    // The mount's own report wins over the target's nominal coordinates: RA
    // and DEC mean "where the telescope was", not "where the sequence meant to
    // be". The target coordinates stay as the fallback so a run whose mount
    // cannot be read is no worse off than before.
    //
    // Preference order matters. The sequencer now samples the mount into
    // `FrameContext` at the same instant it samples the focuser and rotator,
    // and that struct is what the `captured_images` row is also stamped from —
    // so taking the pointing from it, rather than from this function's own
    // late second read, is what guarantees the header and the row agree. The
    // `pointing` argument stays as the fallback for save paths that build a
    // `FrameContext` without touching the mount (the flat wizard, one-shot
    // captures), which would otherwise regress to no RA/DEC card at all.
    let context_pointing = frame_ctx.mount_ra_hours.zip(frame_ctx.mount_dec_degrees);
    if let Some((ra_hours, dec_degrees)) = context_pointing {
        header.ra = Some(ra_hours);
        header.dec = Some(dec_degrees);
        // The altitude is allowed to come from `pointing` even when the
        // coordinates did not: a context can carry pointing and still have no
        // altitude, because the sequencer derives alt/az only when ITS OWN
        // execution context was seeded with a site, while the site the FITS
        // writer knows about lives in app settings. Without this fallback a
        // sequenced frame loses AIRMASS outright in that (entirely ordinary)
        // configuration. See `context_altitude_pointing`, which is where the
        // fallback's coordinates come from — they are this same context's, so
        // the card is still describing one instant, not two reads.
        // `.or(header.altitude)` last: an assignment cannot be allowed to
        // replace the altitude `from_frame_context` already derived from this
        // same pointing with `None`. Overwriting a good value with nothing is
        // how a keyword disappears from a file for a reason that has nothing
        // to do with whether it was knowable.
        header.altitude = frame_ctx
            .mount_altitude_deg
            .or_else(|| pointing.and_then(|p| p.altitude_deg))
            .or(header.altitude);
    } else if let Some(p) = pointing {
        header.ra = Some(p.ra_hours);
        header.dec = Some(p.dec_degrees);
        header.altitude = p.altitude_deg;
    }

    header
}
