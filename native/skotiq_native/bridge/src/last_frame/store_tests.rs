use super::{frames, put, RawFrame, StoredFrame, STORE_CAPACITY};
use crate::api::imaging::{CapturedImageResult, ImageStatsResult};

fn fixture_display() -> CapturedImageResult {
    CapturedImageResult {
        width: 1,
        height: 1,
        display_data: vec![0, 0, 0, 255],
        histogram: vec![0u32; 256],
        stats: ImageStatsResult {
            min: 0.0,
            max: 0.0,
            mean: 0.0,
            median: 0.0,
            std_dev: 0.0,
            hfr: None,
            eccentricity: None,
            fwhm: None,
            star_count: 0,
        },
        exposure_time: 0.1,
        timestamp: "test".to_string(),
        is_color: false,
    }
}

fn fixture_frame(marker: u16) -> StoredFrame {
    StoredFrame {
        display: fixture_display(),
        raw: RawFrame {
            width: 1,
            height: 1,
            data: vec![marker],
            bayer_pattern: None,
        },
    }
}

// Why a single test rather than two: `the store` is a
// process-global `OnceLock`. Cargo runs tests in parallel threads inside
// the same process, so two tests that both `clear()` and re-insert into
// the same cache would race. We fold both assertions (LRU eviction order
// and overwrite-doesn't-grow) into one test phased by `clear()` calls.
#[tokio::test]
async fn enforces_lru_cap_and_fifo_eviction() {
    // Phase 1: insert 60 entries — 10 over the capacity of 50 — and
    // verify the oldest 10 are evicted in FIFO order. Compile-time check
    // that the insert count is strictly greater than the capacity so the
    // FIFO assertions below are meaningful.
    const INSERT_COUNT: usize = 60;
    const _: () = assert!(
        INSERT_COUNT > STORE_CAPACITY,
        "test only meaningful when insert count exceeds capacity",
    );

    {
        let mut storage = frames().lock().await;
        storage.clear();
    }

    let key_for = |i: usize| format!("test-cq-w1-unified-img:{i:03}");

    for i in 0..INSERT_COUNT {
        put(&key_for(i), fixture_frame(i as u16)).await;
    }

    {
        let storage = frames().lock().await;

        assert_eq!(
            storage.len(),
            STORE_CAPACITY,
            "LRU should cap at {STORE_CAPACITY} entries"
        );

        // First (INSERT_COUNT - CAPACITY) entries must have been evicted in
        // FIFO order; the remaining CAPACITY entries are the most-recent ones.
        let evicted_upper_bound = INSERT_COUNT - STORE_CAPACITY;
        for i in 0..evicted_upper_bound {
            assert!(
                !storage.contains(&key_for(i)),
                "key {} should have been evicted (FIFO)",
                key_for(i)
            );
        }
        for i in evicted_upper_bound..INSERT_COUNT {
            assert!(
                storage.contains(&key_for(i)),
                "key {} should still be present",
                key_for(i)
            );
        }
    }

    // Phase 2: writing the same key multiple times must not grow the cache.
    {
        let mut storage = frames().lock().await;
        storage.clear();
    }

    let key = "test-cq-w1-unified-img:overwrite";
    for marker in 0..5u16 {
        put(key, fixture_frame(marker)).await;
    }

    let mut storage = frames().lock().await;
    assert_eq!(storage.len(), 1, "overwrites must not grow the cache");
    let entry = storage.get(key).expect("entry must be present");
    assert_eq!(
        entry.raw.data,
        vec![4u16],
        "last write must win for an existing key"
    );
}
