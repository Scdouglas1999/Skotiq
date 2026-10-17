//! Image download paths for `AlpacaCamera`.
//!
//! These are the members of the property-wrapper impl that drive the
//! ImageArray / ImageBytes decoders.

use super::*;

impl AlpacaCamera {
    /// Download image as parsed pixel data
    /// Returns (width, height, data as u16 vec)
    /// Uses very long timeout (configurable, defaults to 15 minutes for large images)
    pub async fn download_image_data(&self) -> Result<(u32, u32, Vec<u16>), String> {
        self.download_image_data_typed()
            .await
            .map_err(|e| e.to_string())
    }

    /// Download image with typed error handling.
    ///
    /// Returns `(width, height, pixels)` for **rank 2 (monochrome)** Alpaca
    /// image arrays only. For rank-3 color frames the function fails fast with
    /// `AlpacaError::ColorImageUnsupported` so callers cannot silently lose the
    /// channel dimension; use [`download_image_array_full_typed`] for those.
    ///
    /// A pixel that fails `as_i64`/`as_f64` propagates as
    /// `AlpacaError::PixelParseError` carrying the exact offset and offending
    /// JSON token; substituting `0` would corrupt a whole frame on any JSON
    /// anomaly. Rank 3 is rejected outright until a multi-plane consumer lands.
    ///
    /// The transport is the pooled client from `AlpacaClient::http_client()`
    /// with the per-request timeout set via `RequestBuilder::timeout(...)`, so
    /// a download does not cost a TLS handshake per frame.
    pub async fn download_image_data_typed(&self) -> Result<(u32, u32, Vec<u16>), AlpacaError> {
        let result = self.download_image_array_full_typed().await?;

        if result.planes != 1 {
            return Err(AlpacaError::ColorImageUnsupported {
                width: result.width,
                height: result.height,
                planes: result.planes,
            });
        }

        Ok((result.width, result.height, result.pixels))
    }

    /// Download image preserving the channel dimension (rank 2 OR rank 3).
    ///
    /// Why: callers that genuinely want color image arrays need access to
    /// the third dimension. Pixels are returned in **planar** order — all of
    /// plane 0, then all of plane 1, etc. — matching the on-the-wire Alpaca
    /// shape `[NumX][NumY][NumPlanes]` after the Y-then-X iteration order.
    ///
    /// Why: prefer the binary `imagearrayvariant` endpoint with
    /// `Accept: application/imagebytes`. A 24 MP frame is ~50 MB binary vs
    /// ~150 MB JSON; binary path is ~10x faster end-to-end. We send `Accept`
    /// for both binary and JSON so older servers that only know
    /// `application/json` still return a usable response, which we then parse
    /// on the JSON path.
    pub async fn download_image_array_full_typed(&self) -> Result<ImageArrayResult, AlpacaError> {
        // Why: subframe geometry tells us the expected shape; we cross-check
        // the parsed array against this so a server that reports inconsistent
        // sizes can't slip past as a partially-filled frame.
        // Why: `num_x`/`num_y` are ASCOM-wire i32 but
        // physically must be ≥ 1; a negative or zero value is a server-side
        // bug. `u32::try_from` surfaces that as a structured error rather
        // than wrapping into a giant u32 that would propagate through
        // pixel-count math.
        let width = u32::try_from(self.num_x().await.map_err(AlpacaError::OperationFailed)?)
            .map_err(|_| {
                AlpacaError::OperationFailed(
                    "NumX returned negative subframe width; ASCOM camera bug".to_string(),
                )
            })?;
        let height = u32::try_from(self.num_y().await.map_err(AlpacaError::OperationFailed)?)
            .map_err(|_| {
                AlpacaError::OperationFailed(
                    "NumY returned negative subframe height; ASCOM camera bug".to_string(),
                )
            })?;

        // Why: at minimum 10MB/s network speed plus extra margin; the configured
        // very-long timeout (camera preset = 15 min) covers a 24 MP frame in
        // the worst-case JSON-encoded path. Binary is ~3x smaller, but the
        // timeout budgets the worst case so the same value works for both.
        let timeout_ms = self.client.timeout_config().very_long_operation_ms;

        let (client_id, transaction_id) = self.client.client_transaction();
        // Why: `imagearrayvariant` is the v3 endpoint that may return
        // `application/imagebytes`. ASCOM mandates servers advertising binary
        // accept it here; servers that only know JSON still respond with their
        // standard JSON envelope on the same endpoint, so it is safe to prefer.
        let url = format!(
            "{}?ClientID={}&ClientTransactionID={}",
            self.client.build_url("imagearrayvariant"),
            client_id,
            transaction_id
        );

        // Why: reuse the pooled HTTP client so successive frames share
        // the keep-alive connection; only override the timeout per request.
        let http_client = self.client.http_client()?;

        // Why: estimate is for the timeout-error message, not for allocation.
        // Why: u32 → u64 widening, exact; subsequent
        // multiplies use u64 arithmetic which cannot overflow for any
        // realistic sensor (u64::MAX / 6 ≈ 3.07e18 bytes).
        let estimated_bytes = u64::from(width) * u64::from(height) * 2 * 3;

        // Why: include `application/json` as the fallback alternative so
        // servers that do not speak ImageBytes can still satisfy the request
        // without a 406. q=0.9 nudges binary-capable servers to pick binary.
        let response = http_client
            .get(&url)
            .header(
                reqwest::header::ACCEPT,
                "application/imagebytes, application/json;q=0.9",
            )
            .timeout(Duration::from_millis(timeout_ms))
            .send()
            .await
            .map_err(|e| {
                if e.is_timeout() {
                    AlpacaError::timeout(
                        format!(
                            "imagearrayvariant download ({}x{}, ~{} MB est)",
                            width,
                            height,
                            estimated_bytes / 1_000_000
                        ),
                        timeout_ms,
                    )
                } else {
                    AlpacaError::from(e)
                }
            })?;

        let status = response.status();
        if !status.is_success() {
            // Why: a 406 Not Acceptable means the server rejected our Accept
            // header set. Per ASCOM, that should not happen for these media
            // types — propagate as a hard error so it is diagnosable. The HTTP
            // error body itself is best-effort diagnostic context; if reading
            // it ALSO fails we propagate that reqwest error rather than
            // coercing a body-read failure into an empty string, since the
            // downstream confusion masks the real transport bug.
            let body = response.text().await?;
            return Err(AlpacaError::HttpError {
                status: status.as_u16(),
                message: body,
                retry_after: None,
            });
        }

        // Why: parse `Content-Type` once. ImageBytes is signaled
        // server-side; the spec allows parameters (charset, etc.) so we match
        // by prefix, not equality.
        //
        // Why: an absent/non-UTF-8 Content-Type header falls
        // through to the empty string, which fails the `starts_with("application/imagebytes")`
        // check below and routes us to the JSON parser. That is the correct
        // ASCOM-compatible fallback: pre-v3 Alpaca servers do not always set
        // Content-Type on the imagearrayvariant endpoint and unconditionally
        // emit JSON, so treating "header missing" as "JSON" matches the spec.
        let content_type = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .to_ascii_lowercase();

        if content_type.starts_with("application/imagebytes") {
            let bytes = response.bytes().await.map_err(|e| {
                AlpacaError::RequestFailed(format!(
                    "Failed to read ImageBytes binary response: {}",
                    e
                ))
            })?;
            return parse_image_bytes(&bytes, width, height);
        }

        // Why: JSON fallback for older Alpaca servers that do not support
        // ImageBytes; the body is parsed exactly like the `imagearray` one.
        let response_text = response.text().await.map_err(|e| {
            AlpacaError::RequestFailed(format!("Failed to read image array response: {}", e))
        })?;

        parse_image_array_json(&response_text, width, height)
    }
}
