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
        match &mut self.store {
            Store::Memory(frames) => frames.push(pixels.to_vec()),
            Store::Disk(dir) => {
                let path = Self::file(dir, self.count);
                let mut bytes = Vec::with_capacity(pixels.len() * 4);
                for v in pixels {
                    bytes.extend_from_slice(&v.to_le_bytes());
                }
                std::fs::File::create(&path)
                    .and_then(|mut f| f.write_all(&bytes))
                    .map_err(|e| {
                        format!(
                            "cannot write the registered sub '{}' ({} MB; is the disk full?): {e}",
                            path.display(),
                            bytes.len() / 1_000_000
                        )
                    })?;
            }
        }
        self.count += 1;
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
                        .chunks_exact(4)
                        .map(|c| f64::from(f32::from_le_bytes([c[0], c[1], c[2], c[3]]))),
                );
            }
        }
        Ok(())
    }
}

impl Drop for FrameSpool {
    fn drop(&mut self) {
        if let Store::Disk(dir) = &self.store {
            for index in 0..self.count {
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
