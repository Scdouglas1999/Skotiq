//! RGB working spaces (section 11.8) and the CIE L*a*b* to RGB transformation
//! of Annex B, which decoding a `CIELab` image needs.

use super::header::Node;
use super::XisfError;

/// An RGB working space relative to D50: primaries' chromaticities, their
/// luminance coefficients, and a gamma exponent (`None` for the sRGB
/// function).
#[derive(Debug, Clone, PartialEq)]
pub struct RgbWorkingSpace {
    pub x: [f64; 3],
    pub y: [f64; 3],
    pub luminance: [f64; 3],
    pub gamma: Option<f64>,
    pub name: Option<String>,
}

/// D50 reference white, CIE 1931 2° observer, as Annex B uses it.
const D50_X: f64 = 0.964_22;
const D50_Z: f64 = 0.825_21;

impl RgbWorkingSpace {
    /// sRGB adapted to D50 with the Bradford transform: the space of an image
    /// that names none (section 8.5.4.1).
    pub fn srgb() -> Self {
        Self {
            x: [0.648_431, 0.321_152, 0.155_886],
            y: [0.330_856, 0.597_871, 0.066_044],
            luminance: [0.222_491, 0.716_888, 0.060_621],
            gamma: None,
            name: Some("sRGB IEC61966-2.1".to_string()),
        }
    }

    pub(crate) fn parse(node: &Node) -> Result<Self, XisfError> {
        let triple = |attr: &str| -> Result<[f64; 3], XisfError> {
            let text = node.attr(attr).unwrap_or_default();
            let values: Vec<f64> = text
                .split(':')
                .map(|v| v.trim().parse::<f64>())
                .collect::<Result<_, _>>()
                .map_err(|_| {
                    XisfError::Malformed(format!("RGB working space {attr} \"{text}\""))
                })?;
            values
                .try_into()
                .map_err(|_| XisfError::Malformed(format!("RGB working space {attr} \"{text}\"")))
        };
        let gamma_text = node.attr("gamma").unwrap_or("sRGB").trim();
        let gamma = if gamma_text.eq_ignore_ascii_case("srgb") {
            None
        } else {
            Some(
                gamma_text
                    .parse::<f64>()
                    .ok()
                    .filter(|g| *g > 0.0)
                    .ok_or_else(|| {
                        XisfError::Malformed(format!("RGB working space gamma \"{gamma_text}\""))
                    })?,
            )
        };
        Ok(Self {
            x: triple("x")?,
            y: triple("y")?,
            luminance: triple("Y")?,
            gamma,
            name: node.attr("name").map(str::to_string),
        })
    }

    pub(crate) fn attributes(&self) -> Vec<(&'static str, String)> {
        let join = |v: &[f64; 3]| format!("{}:{}:{}", v[0], v[1], v[2]);
        let mut attrs = vec![
            ("x", join(&self.x)),
            ("y", join(&self.y)),
            ("Y", join(&self.luminance)),
            (
                "gamma",
                self.gamma
                    .map(|g| g.to_string())
                    .unwrap_or_else(|| "sRGB".to_string()),
            ),
        ];
        if let Some(name) = &self.name {
            attrs.push(("name", name.clone()));
        }
        attrs
    }

    /// The matrix M of Equation 51, linear RGB to XYZ.
    fn rgb_to_xyz(&self) -> [[f64; 3]; 3] {
        let column = |i: usize| {
            let (x, y, yl) = (self.x[i], self.y[i], self.luminance[i]);
            [yl * x / y, yl, yl * (1.0 - x - y) / y]
        };
        let (r, g, b) = (column(0), column(1), column(2));
        [0, 1, 2].map(|row| [r[row], g[row], b[row]])
    }

    fn delinearize(&self, v: f64) -> f64 {
        let v = v.clamp(0.0, 1.0);
        match self.gamma {
            Some(g) => v.powf(1.0 / g),
            None if v <= 0.003_130_8 => 12.92 * v,
            None => 1.055 * v.powf(1.0 / 2.4) - 0.055,
        }
    }

    #[cfg(test)]
    fn linearize(&self, v: f64) -> f64 {
        match self.gamma {
            Some(g) => v.powf(g),
            None if v <= 0.040_45 => v / 12.92,
            None => ((v + 0.055) / 1.055).powf(2.4),
        }
    }

    /// Convert normalized XISF `L, a, b` (each in [0, 1]) to normalized RGB,
    /// clipped to [0, 1] (Annex B, Equations 61-63 then 53-55).
    pub(crate) fn lab_to_rgb(&self, lab: [f64; 3]) -> [f64; 3] {
        const EPSILON: f64 = 216.0 / 24389.0;
        const KAPPA: f64 = 24389.0 / 27.0;
        let g = |t: f64| {
            let t3 = t * t * t;
            if t3 > EPSILON {
                t3
            } else {
                (116.0 * t - 16.0) / KAPPA
            }
        };
        let fy = (lab[0] + 0.16) / 1.16;
        let fx = fy + 50.0 / 29.0 * (lab[1] - 0.5);
        let fz = fy - 50.0 / 29.0 * (lab[2] - 0.5);
        let xyz = [g(fx) * D50_X, g(fy), g(fz) * D50_Z];
        let inverse = invert(self.rgb_to_xyz());
        let mut rgb = [0.0; 3];
        for (i, out) in rgb.iter_mut().enumerate() {
            let linear: f64 = (0..3).map(|j| inverse[i][j] * xyz[j]).sum();
            *out = self.delinearize(linear);
        }
        rgb
    }

    /// The forward transformation, normalized RGB to normalized `L, a, b`.
    #[cfg(test)]
    pub(crate) fn rgb_to_lab(&self, rgb: [f64; 3]) -> [f64; 3] {
        const EPSILON: f64 = 216.0 / 24389.0;
        const KAPPA: f64 = 24389.0 / 27.0;
        let f = |t: f64| {
            if t > EPSILON {
                t.cbrt()
            } else {
                (KAPPA * t + 16.0) / 116.0
            }
        };
        let m = self.rgb_to_xyz();
        let linear = rgb.map(|v| self.linearize(v));
        let xyz: Vec<f64> = (0..3)
            .map(|i| (0..3).map(|j| m[i][j] * linear[j]).sum())
            .collect();
        let (fx, fy, fz) = (f(xyz[0] / D50_X), f(xyz[1]), f(xyz[2] / D50_Z));
        [
            1.16 * fy - 0.16,
            0.5 + 29.0 / 50.0 * (fx - fy),
            0.5 + 29.0 / 50.0 * (fy - fz),
        ]
    }
}

fn invert(m: [[f64; 3]; 3]) -> [[f64; 3]; 3] {
    let det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
        - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
        + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
    let c =
        |r1: usize, c1: usize, r2: usize, c2: usize| m[r1][c1] * m[r2][c2] - m[r1][c2] * m[r2][c1];
    [
        [
            c(1, 1, 2, 2) / det,
            -c(0, 1, 2, 2) / det,
            c(0, 1, 1, 2) / det,
        ],
        [
            -c(1, 0, 2, 2) / det,
            c(0, 0, 2, 2) / det,
            -c(0, 0, 1, 2) / det,
        ],
        [
            c(1, 0, 2, 1) / det,
            -c(0, 0, 2, 1) / det,
            c(0, 0, 1, 1) / det,
        ],
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn srgb_white_maps_to_the_d50_white_point() {
        let m = RgbWorkingSpace::srgb().rgb_to_xyz();
        let white: Vec<f64> = (0..3).map(|i| m[i].iter().sum()).collect();
        assert!((white[0] - D50_X).abs() < 2e-3, "{white:?}");
        assert!((white[1] - 1.0).abs() < 1e-5, "{white:?}");
        assert!((white[2] - D50_Z).abs() < 2e-3, "{white:?}");
    }

    #[test]
    fn lab_round_trips_through_rgb() {
        for ws in [
            RgbWorkingSpace::srgb(),
            RgbWorkingSpace {
                gamma: Some(2.2),
                ..RgbWorkingSpace::srgb()
            },
        ] {
            for rgb in [
                [0.2, 0.5, 0.8],
                [1.0, 1.0, 1.0],
                [0.0, 0.0, 0.0],
                [0.9, 0.1, 0.3],
                [0.01, 0.02, 0.005],
            ] {
                let back = ws.lab_to_rgb(ws.rgb_to_lab(rgb));
                for c in 0..3 {
                    assert!((back[c] - rgb[c]).abs() < 1e-3, "{rgb:?} -> {back:?}");
                }
            }
            let gray = ws.rgb_to_lab([0.5, 0.5, 0.5]);
            assert!(
                (gray[1] - 0.5).abs() < 2e-3 && (gray[2] - 0.5).abs() < 2e-3,
                "{gray:?}"
            );
        }
    }
}
