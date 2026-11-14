use super::*;
use skotiq_sequencer::ExecutorEvent;

/// The applied map and the sequencer are process-wide.
static SERIAL: Mutex<()> = Mutex::const_new(());

const W: u32 = 64;
const H: u32 = 48;

/// Dark frames with `hot` pixels lit in every frame, written to a fresh
/// directory.
fn darks(name: &str, hot: &[(u32, u32)]) -> Vec<String> {
    let dir = std::env::temp_dir().join(format!("sk-defect-{}-{}", name, std::process::id()));
    std::fs::create_dir_all(&dir).expect("dark dir");
    (0..MIN_CONSISTENCY_FRAMES)
        .map(|i| {
            let mut pixels = vec![800u16; (W * H) as usize];
            for (n, p) in pixels.iter_mut().enumerate() {
                *p += ((n * 7 + i * 13) % 11) as u16;
            }
            for &(x, y) in hot {
                pixels[(y * W + x) as usize] = 40_000;
            }
            let path = dir.join(format!("dark_{i}.fits"));
            skotiq_imaging::write_fits(
                &path,
                &ImageData::from_u16(W, H, 1, &pixels),
                &skotiq_imaging::FitsHeader::new(),
            )
            .expect("dark written");
            path.to_string_lossy().into_owned()
        })
        .collect()
}

async fn enable(camera: &str, celsius: f64) {
    api_defect_map_set_correction(
        camera.to_string(),
        W,
        H,
        celsius,
        true,
        "median".to_string(),
        3,
        false,
    )
    .await
    .expect("correction on");
}

async fn applied_here(camera: &str, celsius: f64) -> bool {
    api_defect_map_get_status(camera.to_string(), W, H, celsius)
        .await
        .expect("status")
        .is_some_and(|s| s.apply_during_capture)
}

/// Whether the sequencer was handed a defect map change since `events` was
/// taken.
fn sequencer_told(events: &mut tokio::sync::broadcast::Receiver<ExecutorEvent>) -> bool {
    std::iter::from_fn(|| events.try_recv().ok())
        .any(|e| matches!(e, ExecutorEvent::RuntimeConfigUpdated { what } if what == "defect_map"))
}

async fn executor_events() -> tokio::sync::broadcast::Receiver<ExecutorEvent> {
    crate::api::sequencer::get_sequence_executor()
        .read()
        .await
        .subscribe()
}

#[tokio::test(flavor = "multi_thread")]
async fn clearing_the_map_in_use_stops_correction_from_the_next_exposure() {
    let _serial = SERIAL.lock().await;
    let camera = "sk-test-clear-in-use";
    api_defect_map_build(camera.to_string(), darks("clear", &[(5, 5)]), 20.0)
        .await
        .expect("map built");
    enable(camera, 20.0).await;
    assert!(applied_here(camera, 20.0).await);

    let mut events = executor_events().await;
    api_defect_map_clear(camera.to_string(), W, H, 20.0)
        .await
        .expect("cleared");

    assert!(
        sequencer_told(&mut events),
        "the sequencer still holds the deleted map"
    );
    assert!(APPLIED.lock().await.is_none());
    assert!(api_defect_map_get_status(camera.to_string(), W, H, 20.0)
        .await
        .expect("status")
        .is_none());
}

#[tokio::test(flavor = "multi_thread")]
async fn clearing_a_map_not_in_use_leaves_correction_on() {
    let _serial = SERIAL.lock().await;
    let camera = "sk-test-clear-other-bucket";
    let frames = darks("other", &[(9, 9)]);
    api_defect_map_build(camera.to_string(), frames.clone(), 20.0)
        .await
        .expect("warm map built");
    api_defect_map_build(camera.to_string(), frames, -10.0)
        .await
        .expect("cold map built");
    enable(camera, 20.0).await;

    let mut events = executor_events().await;
    api_defect_map_clear(camera.to_string(), W, H, -10.0)
        .await
        .expect("cold map cleared");

    assert!(!sequencer_told(&mut events));
    assert!(applied_here(camera, 20.0).await);
    api_defect_map_clear(camera.to_string(), W, H, 20.0)
        .await
        .expect("warm map cleared");
}

#[tokio::test(flavor = "multi_thread")]
async fn rebuilding_the_map_in_use_applies_the_new_map() {
    let _serial = SERIAL.lock().await;
    let camera = "sk-test-rebuild-in-use";
    api_defect_map_build(camera.to_string(), darks("rebuild-a", &[(3, 3)]), 20.0)
        .await
        .expect("first map built");
    enable(camera, 20.0).await;
    let before = APPLIED
        .lock()
        .await
        .as_ref()
        .map(|a| a.map.defective_count());

    let rebuilt = api_defect_map_build(
        camera.to_string(),
        darks("rebuild-b", &[(3, 3), (20, 30), (40, 10)]),
        20.0,
    )
    .await
    .expect("map rebuilt");

    let after = APPLIED
        .lock()
        .await
        .as_ref()
        .map(|a| a.map.defective_count());
    assert!(rebuilt.apply_during_capture);
    assert_ne!(before, after);
    assert_eq!(after, Some(rebuilt.defective_pixel_count));
    api_defect_map_clear(camera.to_string(), W, H, 20.0)
        .await
        .expect("cleared");
}
