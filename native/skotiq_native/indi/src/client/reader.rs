//! Socket reader/writer tasks and the INDI XML stream state machine.

use super::*;

impl IndiClient {
    /// Writer task - sends commands to INDI server
    ///
    /// A write failure means the socket's send side is gone. The read side of a
    /// half-open TCP connection can stay quiet indefinitely, so the reader will
    /// not notice; without clearing `connected` here the client would keep
    /// reporting itself connected while every `send_command` failed.
    pub(super) async fn writer_task<W: AsyncWrite + Unpin>(
        mut writer: W,
        mut rx: mpsc::Receiver<String>,
        connected: Arc<AtomicBool>,
        event_tx: broadcast::Sender<IndiEvent>,
    ) {
        while let Some(cmd) = rx.recv().await {
            let write_result = async {
                writer.write_all(cmd.as_bytes()).await?;
                writer.write_all(b"\n").await
            }
            .await;

            if let Err(e) = write_result {
                tracing::error!("INDI write error: {}", e);
                if connected.swap(false, Ordering::SeqCst) {
                    send_indi_event(
                        &event_tx,
                        IndiEvent::Error(format!("INDI write failed: {}", e)),
                        "writer.write_failed",
                    );
                    send_indi_event(
                        &event_tx,
                        IndiEvent::ConnectionStateChanged(false),
                        "writer.connection_state_disconnected",
                    );
                }
                return;
            }
        }
    }

    /// Supervised reader task - wraps the reader with supervision logic
    ///
    /// This function monitors the reader task and tracks failures. When the reader
    /// crashes, it:
    /// 1. Increments the consecutive failure counter
    /// 2. Updates the reader status to Crashed
    /// 3. Emits appropriate events (ReaderDied, ReaderHealthChanged)
    /// 4. Sets connected to false
    ///
    /// The caller (usually IndiClient via its event subscriber) is responsible for
    /// deciding whether to reconnect based on the failure count and configuration.
    #[allow(clippy::too_many_arguments)]
    pub(super) async fn supervised_reader_task<R: AsyncRead + Unpin>(
        reader: R,
        devices: Arc<RwLock<HashMap<String, IndiDevice>>>,
        properties: Arc<RwLock<HashMap<(String, String), IndiProperty>>>,
        property_values: Arc<RwLock<PropertyValueMap>>,
        property_updated_ms: Arc<RwLock<PropertyUpdateMap>>,
        number_limits: Arc<RwLock<NumberLimitsMap>>,
        latest_blobs: Arc<RwLock<BlobMap>>,
        connected: Arc<AtomicBool>,
        event_tx: broadcast::Sender<IndiEvent>,
        reader_status: Arc<RwLock<ReaderStatus>>,
        reader_consecutive_failures: Arc<AtomicU32>,
        server_version: Arc<RwLock<Option<String>>>,
        last_keepalive_response_ms: Arc<AtomicU64>,
        timeout_config: IndiTimeoutConfig,
        reader_task_config: ReaderTaskConfig,
        jitter_rng: JitterRng,
        mut shutdown_rx: oneshot::Receiver<()>,
    ) {
        // Run the reader task with panic catching via AssertUnwindSafe
        let result = tokio::select! {
            result = Self::reader_task_with_timeout(
                reader,
                devices,
                properties,
                property_values,
                property_updated_ms,
                number_limits,
                latest_blobs,
                connected.clone(),
                event_tx.clone(),
                server_version,
                last_keepalive_response_ms,
                timeout_config,
            ) => {
                result
            }
            _ = &mut shutdown_rx => {
                tracing::info!("INDI reader task received shutdown signal - graceful stop");
                // Graceful shutdown - reset failure counter
                reader_consecutive_failures.store(0, Ordering::SeqCst);
                Ok(())
            }
        };

        // Update status based on result
        match result {
            Ok(_) => {
                // Graceful shutdown - reset failure counter and update status
                *reader_status.write().await = ReaderStatus::Stopped;
                send_indi_event(
                    &event_tx,
                    IndiEvent::ReaderHealthChanged {
                        healthy: false,
                        status: ReaderStatus::Stopped,
                        consecutive_failures: 0,
                    },
                    "supervised_reader.stopped_health",
                );
                tracing::info!("INDI reader task stopped gracefully");
            }
            Err(ref e) => {
                // Failure - increment failure counter
                let failures = reader_consecutive_failures.fetch_add(1, Ordering::SeqCst) + 1;
                let max_failures = reader_task_config.max_consecutive_failures;

                tracing::error!(
                    "INDI reader task crashed (failure {}/{}): {}",
                    failures,
                    max_failures,
                    e
                );

                // Update status to Crashed
                *reader_status.write().await = ReaderStatus::Crashed;

                // Emit ReaderDied event with error details
                send_indi_event(
                    &event_tx,
                    IndiEvent::ReaderDied(e.to_string()),
                    "supervised_reader.reader_died",
                );

                // Emit health changed event
                send_indi_event(
                    &event_tx,
                    IndiEvent::ReaderHealthChanged {
                        healthy: false,
                        status: ReaderStatus::Crashed,
                        consecutive_failures: failures,
                    },
                    "supervised_reader.crashed_health",
                );

                // Check if we've exceeded max failures
                if failures >= max_failures {
                    tracing::error!(
                        "INDI reader task exceeded max consecutive failures ({}) - giving up",
                        max_failures
                    );
                    send_indi_event(
                        &event_tx,
                        IndiEvent::ReaderRestartFailed {
                            attempts: failures,
                            last_error: e.to_string(),
                        },
                        "supervised_reader.restart_failed",
                    );
                } else if reader_task_config.auto_restart {
                    // Calculate restart delay and emit restart event
                    let delay = reader_task_config.calculate_restart_delay(failures, &jitter_rng);
                    tracing::info!(
                        "INDI reader task will suggest restart in {:?} (attempt {}/{})",
                        delay,
                        failures,
                        max_failures
                    );
                    send_indi_event(
                        &event_tx,
                        IndiEvent::ReaderRestarting {
                            attempt: failures,
                            max_attempts: max_failures,
                            delay_secs: delay.as_secs_f64(),
                        },
                        "supervised_reader.restarting",
                    );
                }
            }
        };

        // Always mark as disconnected when reader stops
        connected.store(false, Ordering::SeqCst);
        send_indi_event(
            &event_tx,
            IndiEvent::ConnectionStateChanged(false),
            "supervised_reader.connection_state_disconnected",
        );
    }

    /// Reader task with XML parse timeout - processes incoming INDI messages
    #[allow(clippy::too_many_arguments)]
    pub(super) async fn reader_task_with_timeout<R: AsyncRead + Unpin>(
        reader: R,
        devices: Arc<RwLock<HashMap<String, IndiDevice>>>,
        properties: Arc<RwLock<HashMap<(String, String), IndiProperty>>>,
        property_values: Arc<RwLock<PropertyValueMap>>,
        property_updated_ms: Arc<RwLock<PropertyUpdateMap>>,
        number_limits: Arc<RwLock<NumberLimitsMap>>,
        latest_blobs: Arc<RwLock<BlobMap>>,
        connected: Arc<AtomicBool>,
        event_tx: broadcast::Sender<IndiEvent>,
        server_version: Arc<RwLock<Option<String>>>,
        last_keepalive_response_ms: Arc<AtomicU64>,
        timeout_config: IndiTimeoutConfig,
    ) -> IndiResult<()> {
        let mut reader = quick_xml::reader::Reader::from_reader(tokio::io::BufReader::new(reader));
        reader.trim_text(true);
        // INDI is a continuous STREAM of independent top-level vectors, not a
        // single rooted document, and we maintain our own depth stack
        // (`xml_stack`) below with explicit stray-end-tag recovery. quick-xml's
        // built-in end-name matching is therefore redundant — and harmful: when
        // a closing tag like `</setSwitchVector>` lands on a buffer/TCP-read
        // boundary (common during the bursty switch-vector traffic an exposure
        // produces) it raises a hard "expected </<...>" mismatch, which forces a
        // reader teardown that drops the in-flight exposure. Defer structure
        // validation to our own stack, which degrades gracefully.
        reader.check_end_names(false);

        let mut buf = Vec::new();

        // Why: INDI is delivered as a stream of nested XML elements (`def*Vector` containing
        // `def*` elements, `set*Vector` containing `one*` elements, etc.). A malformed or
        // mid-stream-truncated message with unbalanced tags would, with a flat-string parser,
        // attribute the next valid element's text to the wrong (device, property) pair.
        // We track a depth stack of XmlContext frames and restore the surrounding device /
        // property / element identifiers on every `End`/`Empty` event. The flat
        // `current_device`/`current_property`/`current_element` strings remain as derived
        // mirrors of the top-of-stack values so the rest of this function reads them as
        // before — but the source of truth is now `xml_stack`.
        let mut xml_stack: Vec<XmlContext> = Vec::new();
        let mut current_device = String::new();
        let mut current_property = String::new();
        let mut current_element = String::new();
        let mut current_blob_format: Option<String> = None;
        let mut current_blob_active = false;
        let mut current_blob_size: usize = 0;

        // XML parse timeout tracking - use configured timeout
        let xml_timeout = timeout_config.message_timeout();

        // BLOB reception timeout tracking
        let mut blob_start_time: Option<Instant> = None;
        let blob_timeout = timeout_config.blob_timeout();

        // Track consecutive timeouts for message parse detection
        let mut incomplete_message_start: Option<Instant> = None;
        let mut incomplete_message_bytes: usize = 0;

        loop {
            // Check for XML parse timeout (incomplete messages)
            if let Some(start) = incomplete_message_start {
                if start.elapsed() > xml_timeout {
                    tracing::warn!(
                        "XML message parse timeout: incomplete message after {:?}. Received {} bytes. Resetting parser.",
                        xml_timeout,
                        incomplete_message_bytes
                    );
                    send_indi_event(
                        &event_tx,
                        IndiEvent::Error(format!(
                            "XML parse timeout after {:?}: {} bytes of incomplete message",
                            xml_timeout, incomplete_message_bytes
                        )),
                        "reader.xml_parse_timeout",
                    );
                    buf.clear();
                    incomplete_message_start = None;
                    incomplete_message_bytes = 0;
                    continue;
                }
            }

            // Check for BLOB reception timeout
            if let Some(start) = blob_start_time {
                if start.elapsed() > blob_timeout {
                    tracing::error!(
                        "BLOB reception timeout for {}.{}: expected {} bytes after {:?}",
                        current_device,
                        current_property,
                        current_blob_size,
                        blob_timeout
                    );
                    send_indi_event(
                        &event_tx,
                        IndiEvent::Error(format!(
                            "BLOB timeout for {}.{}: expected {} bytes after {:?}",
                            current_device, current_property, current_blob_size, blob_timeout
                        )),
                        "reader.blob_timeout",
                    );
                    // Reset BLOB state
                    blob_start_time = None;
                    current_blob_format = None;
                    current_blob_active = false;
                    current_blob_size = 0;
                }
            }

            // Use timeout for reading events
            let read_timeout = Duration::from_secs(5);
            let read_result = timeout(read_timeout, reader.read_event_into_async(&mut buf)).await;

            match read_result {
                // Why: quick-xml emits self-closing tags (`<defSwitch …/>`) as `Event::Empty`
                // rather than `Event::Start` + `Event::End`. INDI servers do legitimately
                // produce self-closing element definitions when a switch/light has no body
                // text. Routing both into the same arm — and popping immediately at the end
                // when `is_empty == true` — keeps the depth stack in lockstep with the actual
                // XML structure regardless of whether the server self-closed the tag.
                Ok(Ok(ev @ Event::Start(_))) | Ok(Ok(ev @ Event::Empty(_))) => {
                    let is_empty = matches!(ev, Event::Empty(_));
                    let e = match &ev {
                        Event::Start(b) | Event::Empty(b) => b,
                        _ => unreachable!("matched Start/Empty above"),
                    };
                    // Reset incomplete message tracking on successful event
                    incomplete_message_start = None;
                    incomplete_message_bytes = 0;
                    // Work with raw bytes to avoid allocating a String for every XML element name.
                    // INDI element names are always ASCII, so byte comparison is safe and efficient.
                    let qname = e.name();
                    let name_bytes: &[u8] = qname.as_ref();
                    let frame_kind = classify_indi_tag(name_bytes);
                    // Snapshot mirrors so we can attribute new values to the frame even if
                    // the body below overwrites them.
                    let snapshot_device_before = current_device.clone();
                    let snapshot_property_before = current_property.clone();
                    let snapshot_element_before = current_element.clone();

                    // Handle property definitions (def*Vector)
                    if name_bytes.starts_with(b"def") && name_bytes.ends_with(b"Vector") {
                        if let Some(dev) = get_attribute(e, "device") {
                            current_device = dev;
                            if let Some(prop) = get_attribute(e, "name") {
                                current_property = prop;

                                // Determine type from the byte slice (avoids String allocation)
                                let prop_type = if name_bytes == b"defSwitchVector" {
                                    IndiPropertyType::Switch
                                } else if name_bytes == b"defNumberVector" {
                                    IndiPropertyType::Number
                                } else if name_bytes == b"defTextVector" {
                                    IndiPropertyType::Text
                                } else if name_bytes == b"defLightVector" {
                                    IndiPropertyType::Light
                                } else if name_bytes == b"defBLOBVector" {
                                    IndiPropertyType::Blob
                                } else {
                                    IndiPropertyType::Text
                                };

                                // Parse state and perm
                                // Why: per INDI 1.7 protocol the `state`
                                // and `perm` attributes on def*Vector elements are NOT mandatory
                                // and many drivers omit them on initial vector definition. The
                                // INDI convention is to assume `Idle`/`rw` until a subsequent
                                // set*Vector element carries an explicit value — which our reader
                                // applies via `parse_state` / `parse_perm` on the next message.
                                let state_str =
                                    get_attribute(e, "state").unwrap_or_else(|| "Idle".to_string());
                                let state = parse_state(&state_str);

                                let perm_str =
                                    get_attribute(e, "perm").unwrap_or_else(|| "rw".to_string());
                                let perm = parse_perm(&perm_str);

                                let switch_rule = if name_bytes == b"defSwitchVector" {
                                    get_attribute(e, "rule").map(|r| parse_switch_rule(&r))
                                } else {
                                    None
                                };

                                // Add device if new
                                {
                                    let mut devs = devices.write().await;
                                    if !devs.contains_key(&current_device) {
                                        devs.insert(
                                            current_device.clone(),
                                            IndiDevice {
                                                name: current_device.clone(),
                                                driver: String::new(),
                                            },
                                        );
                                        let _ = event_tx
                                            .send(IndiEvent::DeviceDefined(current_device.clone()));
                                    }
                                }

                                // Add property
                                {
                                    let mut props = properties.write().await;
                                    props.insert(
                                        (current_device.clone(), current_property.clone()),
                                        IndiProperty {
                                            device: current_device.clone(),
                                            name: current_property.clone(),
                                            // Why: per INDI 1.7 `label` is
                                            // optional; the convention when omitted is to display
                                            // the property NAME as the label. `group` is also
                                            // optional — empty string means "ungrouped" and the
                                            // UI groups by name in that case.
                                            label: get_attribute(e, "label")
                                                .unwrap_or_else(|| current_property.clone()),
                                            group: get_attribute(e, "group").unwrap_or_default(),
                                            property_type: prop_type.clone(),
                                            state,
                                            perm,
                                            elements: Vec::new(),
                                            switch_rule,
                                        },
                                    );
                                }

                                send_indi_event(
                                    &event_tx,
                                    IndiEvent::PropertyDefined(
                                        current_device.clone(),
                                        current_property.clone(),
                                        prop_type,
                                    ),
                                    "reader.property_defined",
                                );
                            }
                        }
                    }
                    // Handle element definitions (defText, defNumber, etc. inside Vector)
                    else if name_bytes.starts_with(b"def") && !name_bytes.ends_with(b"Vector") {
                        if !current_device.is_empty() && !current_property.is_empty() {
                            if let Some(elem_name) = get_attribute(e, "name") {
                                current_element = elem_name.clone();

                                // Add element to property
                                let mut props = properties.write().await;
                                if let Some(prop) =
                                    map_get_mut_2(&mut props, &current_device, &current_property)
                                {
                                    prop.elements.push(elem_name.clone());
                                }

                                // Extract min/max/step/format for number elements
                                if name_bytes == b"defNumber" {
                                    let limits = NumberLimits {
                                        min: get_attribute(e, "min").and_then(|s| {
                                            parse_indi_number_attribute(
                                                "min",
                                                &current_device,
                                                &current_property,
                                                &elem_name,
                                                &s,
                                            )
                                        }),
                                        max: get_attribute(e, "max").and_then(|s| {
                                            parse_indi_number_attribute(
                                                "max",
                                                &current_device,
                                                &current_property,
                                                &elem_name,
                                                &s,
                                            )
                                        }),
                                        step: get_attribute(e, "step").and_then(|s| {
                                            parse_indi_number_attribute(
                                                "step",
                                                &current_device,
                                                &current_property,
                                                &elem_name,
                                                &s,
                                            )
                                        }),
                                        format: get_attribute(e, "format"),
                                    };

                                    // Store limits
                                    let mut limits_map = number_limits.write().await;
                                    limits_map.insert(
                                        (
                                            current_device.clone(),
                                            current_property.clone(),
                                            elem_name,
                                        ),
                                        limits,
                                    );
                                }
                            }
                        }
                    }
                    // Handle property updates (set*Vector, new*Vector)
                    else if (name_bytes.starts_with(b"set") || name_bytes.starts_with(b"new"))
                        && name_bytes.ends_with(b"Vector")
                    {
                        if let Some(dev) = get_attribute(e, "device") {
                            current_device = dev;
                            if let Some(prop) = get_attribute(e, "name") {
                                current_property = prop;

                                // Update state (and switch rule when present on set*Vector)
                                if let Some(state_str) = get_attribute(e, "state") {
                                    let state = parse_state(&state_str);
                                    let mut props = properties.write().await;
                                    if let Some(p) = map_get_mut_2(
                                        &mut props,
                                        &current_device,
                                        &current_property,
                                    ) {
                                        p.state = state;
                                    }
                                }
                                if name_bytes == b"setSwitchVector" {
                                    if let Some(rule_str) = get_attribute(e, "rule") {
                                        let rule = parse_switch_rule(&rule_str);
                                        let mut props = properties.write().await;
                                        if let Some(p) = map_get_mut_2(
                                            &mut props,
                                            &current_device,
                                            &current_property,
                                        ) {
                                            p.switch_rule = Some(rule);
                                        }
                                    }
                                }
                            }
                        }
                    }
                    // Handle BLOB elements with format attribute
                    else if name_bytes == b"oneBLOB" {
                        if let Some(elem) = get_attribute(e, "name") {
                            current_element = elem;
                        }
                        // Extract format attribute (e.g., ".fits", ".jpeg", ".png")
                        // Missing/empty format stays unknown until payload magic-byte inference below.
                        // Why: per INDI 1.7 the `format` attribute is
                        // protocol-OPTIONAL on `oneBLOB` and almost-universally omitted by INDI.
                        // Missing or empty format stays unknown until payload magic-byte inference.
                        // `size` defaults to 0 so
                        // the BLOB pump computes the length from the decoded base64 payload
                        // rather than relying on a possibly-absent header hint.
                        current_blob_active = true;
                        current_blob_format = get_attribute(e, "format").and_then(|format| {
                            let trimmed = format.trim().to_string();
                            if trimmed.is_empty() {
                                None
                            } else {
                                Some(trimmed)
                            }
                        });
                        // Extract size attribute
                        current_blob_size = get_attribute(e, "size")
                            .and_then(|s| {
                                parse_indi_usize_attribute(
                                    "size",
                                    &current_device,
                                    &current_property,
                                    &current_element,
                                    &s,
                                )
                            })
                            .unwrap_or(0);
                        // Start BLOB reception timeout tracking
                        blob_start_time = Some(Instant::now());
                        tracing::debug!(
                            "Starting BLOB reception for {}.{}.{}: expected size {} bytes",
                            current_device,
                            current_property,
                            current_element,
                            current_blob_size
                        );
                    }
                    // Handle elements values (oneSwitch, oneNumber, etc.)
                    else if name_bytes.starts_with(b"one") && name_bytes != b"oneBLOB" {
                        if let Some(elem) = get_attribute(e, "name") {
                            current_element = elem;
                        }
                    }
                    // Detect protocol version from server response
                    else if name_bytes == b"getProperties" {
                        if let Some(version) = get_attribute(e, "version") {
                            let mut sv = server_version.write().await;
                            *sv = Some(version.clone());
                            send_indi_event(
                                &event_tx,
                                IndiEvent::ProtocolVersionDetected(version),
                                "reader.protocol_version_detected",
                            );
                        }
                    }

                    // Update keepalive response timestamp on any valid message
                    // This is used to detect connection health - any server response counts
                    last_keepalive_response_ms.store(current_time_ms(), Ordering::SeqCst);

                    // Build a frame describing what this tag contributed to the mirrors.
                    // Why: the parser body above clobbered the flat strings to apply attribute
                    // values; on `End` we have to be able to undo those clobbers and restore
                    // the surrounding (parent) context. Each frame stores only the
                    // identifiers IT introduced, so refreshing from the stack rebuilds the
                    // correct state regardless of how deep we are.
                    let mut frame = XmlContext::new(frame_kind, name_bytes);
                    match frame_kind {
                        XmlContextKind::DefVector | XmlContextKind::SetOrNewVector => {
                            if current_device != snapshot_device_before {
                                frame.device = Some(current_device.clone());
                            }
                            if current_property != snapshot_property_before {
                                frame.property = Some(current_property.clone());
                            }
                        }
                        XmlContextKind::DefElement
                        | XmlContextKind::OneElement
                        | XmlContextKind::OneBlob => {
                            if current_element != snapshot_element_before {
                                frame.element = Some(current_element.clone());
                            }
                        }
                        XmlContextKind::Other => {}
                    }
                    let was_set_or_new_vector = frame.kind == XmlContextKind::SetOrNewVector;
                    let frame_device_for_event = frame.device.clone();
                    let frame_property_for_event = frame.property.clone();
                    xml_stack.push(frame);

                    if is_empty {
                        // Why: quick-xml does not synthesise an `End` event for self-closing
                        // tags. Pop our just-pushed frame so the depth stack does not leak,
                        // then re-derive the mirror strings from whatever parent context
                        // remains on the stack.
                        let _ = xml_stack.pop();
                        refresh_xml_context_mirrors(
                            &xml_stack,
                            &mut current_device,
                            &mut current_property,
                            &mut current_element,
                        );
                        // A self-closing `setVector` / `newVector` has no body but should
                        // still notify subscribers that the property update completed —
                        // mirror what `Event::End` does for the multi-event form.
                        if was_set_or_new_vector {
                            if let (Some(dev), Some(prop)) =
                                (frame_device_for_event, frame_property_for_event)
                            {
                                {
                                    let mut updated = property_updated_ms.write().await;
                                    updated.insert((dev.clone(), prop.clone()), current_time_ms());
                                }
                                send_indi_event(
                                    &event_tx,
                                    IndiEvent::PropertyUpdated(dev, prop),
                                    "reader.self_closing_property_updated",
                                );
                            }
                        }
                    }
                }
                Ok(Ok(Event::Text(e))) => {
                    // Reset incomplete message tracking on successful event
                    incomplete_message_start = None;
                    incomplete_message_bytes = 0;
                    // Why: `unescape()` returns Err only on malformed XML
                    // entity references (e.g. `&unterminated`) — quick-xml's BytesText is
                    // already validated by the tokenizer, so an Err here would mean a
                    // truncated payload mid-entity. Empty-string fallback causes the value
                    // store to receive an empty payload, which downstream parsers
                    // (`get_number`, `get_switch`) treat as "value not yet present" — the
                    // exact same semantics as an absent element.
                    let text = e.unescape().unwrap_or_default().to_string();
                    if !current_device.is_empty()
                        && !current_property.is_empty()
                        && !current_element.is_empty()
                    {
                        {
                            let mut updated = property_updated_ms.write().await;
                            updated.insert(
                                (current_device.clone(), current_property.clone()),
                                current_time_ms(),
                            );
                        }

                        // Handle BLOB data with format validation
                        if current_blob_active {
                            // The base64 body of a frame is never a readable property
                            // value — `property_values` is only cleared on disconnect,
                            // so storing it here would pin ~1.33x the frame size for the
                            // rest of the session on top of the decoded copy below.
                            //
                            // Decoding is CPU-bound and proportional to frame size
                            // (hundreds of milliseconds for a 62 MP sensor), so it runs
                            // on a blocking thread; inline it would stall every other
                            // task on this reader's Tokio worker, keepalives included.
                            let decode_start = blob_start_time;
                            let decoded =
                                tokio::task::spawn_blocking(move || BASE64.decode(text.trim()))
                                    .await;
                            match decoded {
                                Ok(Ok(data)) => {
                                    if let Some(start) = decode_start {
                                        tracing::debug!(
                                            "BLOB received for {}.{}.{}: {} bytes in {:?}",
                                            current_device,
                                            current_property,
                                            current_element,
                                            data.len(),
                                            start.elapsed()
                                        );
                                    }

                                    // Validate declared format or infer it when INDI omitted
                                    // the optional format attribute.
                                    let validated_format =
                                        resolve_blob_format(current_blob_format.as_deref(), &data);

                                    latest_blobs.write().await.insert(
                                        (
                                            current_device.clone(),
                                            current_property.clone(),
                                            current_element.clone(),
                                        ),
                                        data.clone(),
                                    );

                                    send_indi_event(
                                        &event_tx,
                                        IndiEvent::BlobReceived {
                                            device: current_device.clone(),
                                            property: current_property.clone(),
                                            element: current_element.clone(),
                                            data,
                                            format: validated_format,
                                            size: current_blob_size,
                                        },
                                        "reader.blob_received",
                                    );
                                }
                                Ok(Err(e)) => {
                                    tracing::warn!(
                                        "Failed to decode BLOB base64 for {}.{}.{}: {}",
                                        current_device,
                                        current_property,
                                        current_element,
                                        e
                                    );
                                }
                                Err(e) => {
                                    tracing::error!(
                                        "BLOB decode task failed for {}.{}.{}: {}",
                                        current_device,
                                        current_property,
                                        current_element,
                                        e
                                    );
                                }
                            }
                            // Reset BLOB tracking state
                            current_blob_format = None;
                            current_blob_active = false;
                            current_blob_size = 0;
                            blob_start_time = None;
                        } else {
                            property_values.write().await.insert(
                                (
                                    current_device.clone(),
                                    current_property.clone(),
                                    current_element.clone(),
                                ),
                                text,
                            );
                        }
                    }
                }
                Ok(Ok(Event::End(e))) => {
                    // Reset incomplete message tracking on successful event
                    incomplete_message_start = None;
                    incomplete_message_bytes = 0;
                    // Use byte comparison to avoid allocating a String for every end tag
                    let end_qname = e.name();
                    let end_name = end_qname.as_ref();

                    match xml_stack.pop() {
                        Some(popped) => {
                            if popped.tag.as_slice() != end_name {
                                // Why: the INDI spec implies well-formed XML, but real
                                // servers (and lossy proxies) occasionally emit malformed
                                // streams — duplicate `</setNumberVector>`, mismatched
                                // nesting, etc. Rather than poison the rest of the stream
                                // by trusting the broken nesting, we log a warning and
                                // attempt to recover by walking the stack to find a
                                // matching opener. If none is found, we restore the frame
                                // we just popped so siblings are still attributed sanely.
                                tracing::warn!(
                                    "INDI XML unbalanced end tag: got </{}>, expected </{}>. \
                                     Attempting recovery.",
                                    String::from_utf8_lossy(end_name),
                                    String::from_utf8_lossy(&popped.tag)
                                );
                                send_indi_event(
                                    &event_tx,
                                    IndiEvent::Error(format!(
                                        "Unbalanced XML: got </{}>, expected </{}>",
                                        String::from_utf8_lossy(end_name),
                                        String::from_utf8_lossy(&popped.tag)
                                    )),
                                    "reader.unbalanced_xml",
                                );

                                if let Some(match_idx) =
                                    xml_stack.iter().rposition(|f| f.tag.as_slice() == end_name)
                                {
                                    // Drop everything above (and including) the matched
                                    // frame to re-establish a consistent depth.
                                    xml_stack.truncate(match_idx);
                                } else {
                                    // No matching opener anywhere on the stack — keep the
                                    // pre-pop state so the next event still has reasonable
                                    // device/property context.
                                    xml_stack.push(popped.clone());
                                }
                            } else if popped.kind == XmlContextKind::SetOrNewVector {
                                // Why: `set*Vector` / `new*Vector` close == "property update
                                // complete" notification. Read identifiers from the popped
                                // frame so we always use the device/property that THIS frame
                                // established, not whatever sibling frames may have set.
                                if let (Some(dev), Some(prop)) = (popped.device, popped.property) {
                                    {
                                        let mut updated = property_updated_ms.write().await;
                                        updated
                                            .insert((dev.clone(), prop.clone()), current_time_ms());
                                    }
                                    send_indi_event(
                                        &event_tx,
                                        IndiEvent::PropertyUpdated(dev, prop),
                                        "reader.property_updated",
                                    );
                                }
                            }

                            refresh_xml_context_mirrors(
                                &xml_stack,
                                &mut current_device,
                                &mut current_property,
                                &mut current_element,
                            );
                        }
                        None => {
                            // Why: end tag with no matching opener on the stack. This is a
                            // protocol violation; log and continue. The recovery branch
                            // above handles partial nesting; here we can only swallow the
                            // stray closer.
                            tracing::warn!(
                                "INDI XML stray end tag </{}>: no matching opener on stack",
                                String::from_utf8_lossy(end_name)
                            );
                            send_indi_event(
                                &event_tx,
                                IndiEvent::Error(format!(
                                    "Stray XML end tag </{}>",
                                    String::from_utf8_lossy(end_name)
                                )),
                                "reader.stray_xml_end_tag",
                            );
                        }
                    }
                }
                Ok(Ok(Event::Eof)) => {
                    tracing::info!("INDI connection closed (EOF)");
                    connected.store(false, Ordering::SeqCst);
                    send_indi_event(
                        &event_tx,
                        IndiEvent::ConnectionStateChanged(false),
                        "reader.eof_connection_state",
                    );
                    break;
                }
                Ok(Err(e)) => {
                    tracing::error!(
                        "INDI XML parse error: {}. Raw buffer (first 200 chars): {:?}",
                        e,
                        String::from_utf8_lossy(&buf[..buf.len().min(200)])
                    );
                    send_indi_event(
                        &event_tx,
                        IndiEvent::Error(format!("XML parse error: {}", e)),
                        "reader.xml_parse_error",
                    );
                    buf.clear();
                    // Why: a hard parser error means the underlying stream is no longer
                    // trustable — drop all in-flight depth bookkeeping along with the
                    // mirror strings so the freshly-recreated reader starts from a clean
                    // top-level context.
                    xml_stack.clear();
                    current_device.clear();
                    current_property.clear();
                    current_element.clear();
                    current_blob_format = None;
                    current_blob_active = false;
                    current_blob_size = 0;
                    blob_start_time = None;
                    incomplete_message_start = None;
                    incomplete_message_bytes = 0;

                    let inner = reader.into_inner();
                    reader = quick_xml::reader::Reader::from_reader(inner);
                    reader.trim_text(true);
                    // Match the primary reader: defer end-name validation to our
                    // own xml_stack (see the construction site above).
                    reader.check_end_names(false);
                }
                Err(_) => {
                    // Read timeout - check if connection is still alive
                    if !connected.load(Ordering::SeqCst) {
                        break;
                    }
                    // Track incomplete message if we have partial data in the buffer
                    if !buf.is_empty() {
                        if incomplete_message_start.is_none() {
                            incomplete_message_start = Some(Instant::now());
                        }
                        incomplete_message_bytes = buf.len();
                    }
                    // Continue waiting for data
                }
                _ => {}
            }
            buf.clear();
        }

        Ok(())
    }
}
