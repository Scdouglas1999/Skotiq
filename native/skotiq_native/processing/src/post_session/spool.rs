//! Registered, normalized subs held for a batch integration that reads them
//! back one band of rows at a time.
//!
//! A batch rejection must see every sub's sample at a pixel at once, but a
//! night of full-size subs does not fit in memory. Each sub is written once,
//! as `f32` on the reference grid with `NaN` where it has no coverage, and
//! integration then reads the same band of rows from every sub. Small stacks
//! stay in memory.

use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

pub(crate) struct FrameSpool {
    width: usize,
    height: usize,
    channels: usize,
    store: Store,
    count: usize,
    partial_samples: usize,
}

enum Store {
    Memory(Vec<Vec<f32>>),
    Disk(PathBuf),
}

impl FrameSpool {
    /// A spool for frames of `width` × `height` × `channels`. Frames stay in
    /// memory when `frames` of them fit in `budget_bytes`, otherwise they are
    /// written to a new directory `dir`.
    pub(crate) fn new(
        width: usize,
        height: usize,
        channels: usize,
        frames: usize,
        budget_bytes: usize,
        dir: &Path,
    ) -> Result<Self, String> {
        let bytes = width * height * channels * 4 * frames;
        let store = if bytes <= budget_bytes {
            Store::Memory(Vec::with_capacity(frames))
        } else {
            std::fs::create_dir_all(dir).map_err(|e| {
                format!(
                    "cannot create the working folder '{}' for registered subs: {e}",
                    dir.display()
                )
            })?;
            Store::Disk(dir.to_path_buf())
        };
        Ok(Self {
            width,
            height,
            channels,
            store,
            count: 0,
            partial_samples: 0,
        })
    }

    pub(crate) fn len(&self) -> usize {
        self.count
    }

    /// Width, height and channels of every frame.
    pub(crate) fn geometry(&self) -> (usize, usize, usize) {
        (self.width, self.height, self.channels)
    }

    fn file(dir: &Path, index: usize) -> PathBuf {
        dir.join(format!("sub-{index:05}.f32"))
    }

    /// Append one frame; `pixels` is channel-interleaved on the grid.
    pub(crate) fn push(&mut self, pixels: &[f32]) -> Result<(), String> {
        if pixels.len() != self.width * self.height * self.channels {
            return Err("a registered sub does not match the grid".into());
        }
        if self.partial_samples != 0 {
            return Err("A partial frame is still being written".into());
        }
        self.push_rows(pixels)
    }

    /// Append consecutive bands; a frame becomes readable only when complete.
    pub(crate) fn push_rows(&mut self, pixels: &[f32]) -> Result<(), String> {
        let expected = self.width * self.height * self.channels;
        if pixels.is_empty()
            || pixels.len() % (self.width * self.channels) != 0
            || self.partial_samples + pixels.len() > expected
        {
            return Err("Invalid band of registered pixels".into());
        }
        match &mut self.store {
            Store::Memory(frames) => {
                if self.partial_samples == 0 {
                    frames.push(Vec::with_capacity(expected));
                }
                frames[self.count].extend_from_slice(pixels);
            }
            Store::Disk(dir) => {
                let path = Self::file(dir, self.count);
                let file = if self.partial_samples == 0 {
                    std::fs::File::create(&path)
                } else {
                    std::fs::OpenOptions::new().append(true).open(&path)
                }
                .map_err(|e| format!("Cannot open spool '{}': {e}", path.display()))?;
                let mut writer = std::io::BufWriter::new(file);
                for value in pixels {
                    writer
                        .write_all(&value.to_le_bytes())
                        .map_err(|e| format!("Cannot write spool '{}': {e}", path.display()))?;
                }
                writer
                    .flush()
                    .map_err(|e| format!("Cannot flush spool '{}': {e}", path.display()))?;
            }
        }
        self.partial_samples += pixels.len();
        if self.partial_samples == expected {
            self.count += 1;
            self.partial_samples = 0;
        }
        Ok(())
    }

    /// Rows `y0 .. y0 + rows` of frame `index`, as `f64`, into `out`.
    pub(crate) fn read_rows(
        &self,
        index: usize,
        y0: usize,
        rows: usize,
        out: &mut Vec<f64>,
    ) -> Result<(), String> {
        let row = self.width * self.channels;
        let (start, len) = (y0 * row, rows * row);
        out.clear();
        match &self.store {
            Store::Memory(frames) => out.extend(
                frames[index][start..start + len]
                    .iter()
                    .map(|&v| f64::from(v)),
            ),
            Store::Disk(dir) => {
                let path = Self::file(dir, index);
                let mut bytes = vec![0u8; len * 4];
                std::fs::File::open(&path)
                    .and_then(|mut f| {
                        f.seek(SeekFrom::Start((start * 4) as u64))?;
                        f.read_exact(&mut bytes)
                    })
                    .map_err(|e| format!("cannot read '{}': {e}", path.display()))?;
                out.extend(
                    bytes
                        .as_chunks::<4>()
                        .0
                        .iter()
                        .map(|c| f64::from(f32::from_le_bytes(*c))),
                );
            }
        }
        Ok(())
    }
}

impl Drop for FrameSpool {
    fn drop(&mut self) {
        if let Store::Disk(dir) = &self.store {
            for index in 0..=self.count {
                let _ = std::fs::remove_file(Self::file(dir, index));
            }
            let _ = std::fs::remove_dir(dir);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn streamed_bands_match_in_memory_and_disk_and_remove_partial_files() {
        let dir = std::env::temp_dir().join(format!("sk_spool_bands_{}", std::process::id()));
        let frame: Vec<f32> = (0..24).map(|v| v as f32).collect();
        let mut memory = FrameSpool::new(4, 3, 2, 2, usize::MAX, &dir).unwrap();
        let mut disk = FrameSpool::new(4, 3, 2, 2, 0, &dir).unwrap();
        for spool in [&mut memory, &mut disk] {
            spool.push_rows(&frame[..8]).unwrap();
            assert_eq!(spool.len(), 0);
            assert!(spool.push(&frame).is_err());
            assert!(spool.push_rows(&frame[..7]).is_err());
            spool.push_rows(&frame[8..]).unwrap();
            assert_eq!(spool.len(), 1);
            spool.push_rows(&frame[..8]).unwrap();
        }
        let (mut a, mut b) = (Vec::new(), Vec::new());
        memory.read_rows(0, 1, 2, &mut a).unwrap();
        disk.read_rows(0, 1, 2, &mut b).unwrap();
        assert_eq!(a, b);
        assert_eq!(a, (8..24).map(|v| v as f64).collect::<Vec<_>>());
        drop(disk);
        assert!(
            !dir.exists(),
            "a cancelled partial write must also be removed"
        );
    }

    #[test]
    fn memory_and_disk_spools_return_the_same_rows() {
        let dir = std::env::temp_dir().join(format!("sk_spool_{}", std::process::id()));
        let frame: Vec<f32> = (0..4 * 3 * 2).map(|v| v as f32).collect();
        let mut memory = FrameSpool::new(4, 3, 2, 2, usize::MAX, &dir).unwrap();
        let mut disk = FrameSpool::new(4, 3, 2, 2, 0, &dir).unwrap();
        for spool in [&mut memory, &mut disk] {
            spool.push(&frame).unwrap();
            spool.push(&frame).unwrap();
        }
        let (mut a, mut b) = (Vec::new(), Vec::new());
        memory.read_rows(1, 1, 2, &mut a).unwrap();
        disk.read_rows(1, 1, 2, &mut b).unwrap();
        assert_eq!(a, b);
        assert_eq!(a[0], 8.0);
        assert_eq!(a.len(), 16);
        drop(disk);
        assert!(!dir.exists(), "the disk spool removes its folder");
    }
}
